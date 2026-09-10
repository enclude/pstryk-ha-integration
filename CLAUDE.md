# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project does

A bash script integration that fetches energy prices from the Pstryk API (`api.pstryk.pl`) and pushes them as sensors into Home Assistant via its REST API. Designed to run hourly via cron or as a Docker container.

## Running the script

```bash
# Directly with arguments
./ha_pstryk.sh "PSTRYK_API_TOKEN" "http://homeassistant.local:8123" "HA_LONG_LIVED_TOKEN"

# Skip auto-update from GitHub
./ha_pstryk.sh "TOKEN" "HA_IP" "HA_TOKEN" --no-update

# With debug logs redirected
./ha_pstryk.sh "TOKEN" "HA_IP" "HA_TOKEN" 2> debug.log

# Via Docker
docker build -t pstryk-ha .
docker run --rm \
  -e API_TOKEN="..." -e HA_IP="..." -e HA_TOKEN="..." \
  -e TZ="Europe/Warsaw" \
  -v /var/tmp:/var/tmp \
  -v /var/lib/pstryk:/var/lib/pstryk \
  pstryk-ha:latest
```

## Key architecture decisions

**Single script, no tests framework** — `ha_pstryk.sh` is the entire codebase. All logic lives there: cache management, API calls, timezone math, and Home Assistant sensor updates.

**API endpoint** — Single call to `/integrations/meter-data/unified-metrics/?metrics=meter_values,cost,carbon,pricing&resolution=hour`. Legacy endpoints `/pricing/` and `/prosumer-pricing/` were decommissioned April 2026. The unified response is normalized after fetch: `.metrics.pricing.*` fields are flattened to frame top-level and `Z` timestamps converted to `+00:00` for backward-compatible jq comparisons. `SELL_JSON` is the same data but with `price_gross` overridden by `price_prosumer_gross`. The `meter_values`, `cost`, and `carbon` metrics are NOT flattened — they are read directly from `frames[].metrics.{metric}.{field}` via `EXTRA_JSON` (only Z timestamps normalized) and the `sum_today` helper. Note: `for_tz=Europe/Warsaw` is rejected by the API for `resolution=hour`, so the manual timezone math cannot be delegated to the API.

**Cache system** — Two files in `/var/tmp/`:
- `pstryk_cache.txt` — base64-encoded JSON responses, keyed by `endpoint_YYYY-MM-DDTHH`
- `pstryk_cache_timestamps.txt` — Unix timestamps for cache freshness checks
- Cache expires after 4 minutes (`CACHE_MAX_AGE_MINUTES`). Fallback to stale cache on rate limit.
- The short expiry lets a second cron run within the same hour actually refetch — the cache key is per-hour (`endpoint_YYYY-MM-DDTHH`), so at the old 55 minutes an `HH:10` run would have hit the `HH:00` entry and seen nothing new. The expiry only *permits* a refetch, never causes one; cron drives the call volume.
- **Why sub-hour runs exist: the API publishes actuals provisionally, then revises them.** A closed hour's frame appears within ~10 seconds, so it is never *missing* — but it is initially incomplete. Measured against `raw_responses` on 2026-09-10 for the frame starting `09:00:00Z` (closed `10:00:00Z`): at `10:00:08Z` `cost.energy_balance_value` was `+0.07251875` with `meter_values.energy_active_export_register` still absent; at `10:05:08Z` the export reading (`0.354`) had landed and the value **changed sign** to `-0.06437993`, stable in every later fetch. The `HH:00` run computes cost from import alone and records a provisional number; a later run in the same hour corrects it.
- This is why a naive "is the frame there yet" check is misleading — it tests presence, not completeness. Any lag query must compare *values* across successive fetches (see the history-DB section), not `IS NOT NULL`.
- The `frames` table self-heals: `ON CONFLICT(frame_start) DO UPDATE` overwrites the provisional row on the next run. Sensors posted at `HH:00` are transiently wrong until the following run.
- Caveat: the 5-minute figure comes from a single observed frame. The stabilization-time distribution across all frames has not been measured.
- This cache is pruned after 7 days and is NOT the long-term store — see History DB below.

**History DB (SQLite, permanent)** — `/var/lib/pstryk/pstryk_history.sqlite`, deliberately NOT under `/var/tmp`: systemd-tmpfiles' default rule deletes files under `/var/tmp` untouched for 30 days, which would silently defeat a "permanent" archive during any extended outage. `/var/lib` is the standard home for durable application state and isn't subject to that cleanup. The script `mkdir -p`s the directory itself; Docker needs its own volume mount (`-v /var/lib/pstryk:/var/lib/pstryk`) separate from the `/var/tmp` cache mount. Requires `sqlite3` on PATH (installed in the Docker image); if absent, or if a write ever fails (locked/full disk), the script logs a warning and continues without it — the history DB is a best-effort archival add-on and never aborts the run.
- `raw_responses` table — one full, unmodified API response per *fresh* fetch (skipped on cache hits, since the data is unchanged). Columns: `fetched_at`, `window_start`, `window_end`, `response_json`. This is the complete audit trail of everything the API ever returned.
- `frames` table — one row per hourly frame (`frame_start` as PRIMARY KEY), covering pricing (`full_price`, `price_gross`, `price_prosumer_gross`, `is_cheap`, `is_expensive`, `is_live`), energy (`energy_import`/`energy_export`/`energy_balance`), cost (`cost_import`/`cost_sold`/`cost_balance`), and `carbon_footprint`. Upserted via `ON CONFLICT(frame_start) DO UPDATE` on every run (whether data came from cache, a fresh fetch, or a stale-cache fallback), so later-arriving actuals overwrite earlier forecasts instead of duplicating rows. This is the table to query for historical trends.
- Both tables are built via `db_init`/`db_archive_raw`/`db_upsert_frames` (defined near the cache functions). SQL is generated by jq filters (`JQ_RAW_RESPONSE_SQL`, `JQ_FRAMES_SQL`) that emit literal SQL text — numbers/booleans unquoted, strings single-quoted with `''`-escaping — piped straight into `sqlite3 "$SQLITE_DB"`; no `.import`/`.nullvalue` CLI quirks involved.
- `db_archive_raw` is called from inside `get_json()` right after a fresh API response is validated and cached. `db_upsert_frames` is called once after `EXTRA_JSON` is built, using the full ~48h fetch window.

**Timezone handling** — Pstryk API returns UTC timestamps. All price rankings are calculated for the Warsaw local day (`Europe/Warsaw`). The script dynamically computes the UTC offset to handle CET (+1) vs CEST (+2). The API window always starts at `yesterday 22:00 UTC` to ensure Warsaw midnight is covered in both DST states.

**Current hour detection** — The new unified API does not expose `is_live`. Current hour is always derived from UTC time (`TZ=UTC date +"%Y-%m-%dT%H:00:00+00:00"`).

**Price ranking (`current_index`)** — Uses dense ranking: count of distinct `full_price` levels strictly cheaper than the current hour. Tied hours share the same rank, so values never skip (0, 1, 2… without gaps). Same logic applies to `current_index_sell` (uses `price_prosumer_gross`).

**Home Assistant sensors updated per run (65 total):**
- `sensor.pstryk_script_current_buy/sell/is_cheap/is_expensive`
- `sensor.pstryk_script_next_buy/sell/is_cheap/is_expensive`
- `sensor.pstryk_current_cheapest` / `sensor.pstryk_next_cheapest`
- `sensor.pstryk_current_index` — dense buy price rank (0=cheapest tier, no gaps)
- `sensor.pstryk_current_index_sell` — dense sell price rank
- `sensor.pstryk_price_relative` — current `full_price` / today avg
- `sensor.pstryk_tomorrow_cheapest_hour` — cheapest hour tomorrow incl. negative prices (Warsaw HH:MM); attribute `price`
- `sensor.pstryk_next_cheap_hour` — next upcoming `is_cheap=true` hour (Warsaw datetime)
- `sensor.pstryk_hour_next2_buy` / `sensor.pstryk_hour_next2_index` — hour +2
- `sensor.pstryk_hour_next3_buy` / `sensor.pstryk_hour_next3_index` — hour +3
- `sensor.pstryk_today_min_buy` / `sensor.pstryk_today_max_buy` / `sensor.pstryk_today_avg_buy` — use `full_price`; avg rounded to 2 dp; filter: `!= null` (0 and negative are valid)
- `sensor.pstryk_today_min_sell` / `sensor.pstryk_today_max_sell` / `sensor.pstryk_today_avg_sell` — use `price_prosumer_gross`; filter: `!= null`
- `sensor.pstryk_next{6,10,12}h_max_buy` / `_avg_buy` / `_max_sell` / `_avg_sell` (12 sensors) — max/avg of `full_price` (buy) and `price_prosumer_gross` (sell) over the window starting at the next hour (current hour excluded — it has its own sensors), `[HOUR[next], HOUR[next]+Nh)`; attribute `hours_available` = frames actually present (windows may be truncated before tomorrow's prices publish); state `null` if window empty
- `sensor.pstryk_today_energy_import` / `sensor.pstryk_today_energy_export` / `sensor.pstryk_today_energy_balance` — sum of `meter_values.energy_active_import_register` / `energy_active_export_register` / `energy_balance` over today (kWh, 3 dp); balance = import − export
- `sensor.pstryk_today_cost` / `sensor.pstryk_today_revenue` / `sensor.pstryk_today_net_cost` — sum of `cost.energy_import_cost` / `energy_sold_value` / `energy_balance_value` over today (PLN, 2 dp); net = import cost − sold value
- `sensor.pstryk_today_co2` — sum of `carbon.carbon_footprint` over today (g CO₂, 1 dp)
- `sensor.pstryk_current_energy_import` / `sensor.pstryk_current_energy_export` / `sensor.pstryk_current_energy_balance` / `sensor.pstryk_current_cost` / `sensor.pstryk_current_revenue` / `sensor.pstryk_current_net_cost` / `sensor.pstryk_current_co2` — same `meter_values`/`cost`/`carbon` fields but for the **previous full hour** (single frame at `HOUR[current] − 1h`, via `frame_at`), because these are actuals and the hour that just started has no data when cron fires at HH:00:15. Each carries a `prev_hour_utc` attribute. `frame_at` preserves `0` and returns `null` for a missing frame. When the value is `null` (the API hasn't published that hour yet), `ha_post_actual` **skips the POST entirely** rather than overwriting the sensor with `null` — HA keeps the last known value until the next run fills it in. Deliberately no fallback to an older frame: a stale-but-labelled value would be worse than leaving the sensor alone.
- `sensor.pstryk_today_prices` — state = Warsaw date; attribute `prices` holds the full Warsaw-day hourly array `[{t, buy, sell}]` (`t` = UTC ISO hour start, `buy` = `full_price`, `sell` = `price_prosumer_gross`, both rounded to 2 dp). Built from `BUY_JSON` (both fields already flattened). Intended for chart cards (e.g. ApexCharts `data_generator`).
- `sensor.pstryk_current_buy_diff_min` / `sensor.pstryk_current_buy_diff_max` — buy − min/max (PLN/kWh)
- `sensor.pstryk_current_sell_diff_min` / `sensor.pstryk_current_sell_diff_max` — sell − min/max (PLN/kWh)
- `sensor.pstryk_buy_relative` / `sensor.pstryk_sell_relative` — current / avg_day (1.0=avg); computed with `calc()` helper (awk, guards null and div-by-zero)
- `sensor.pstryk_cheap_hours_remaining` / `sensor.pstryk_cheap_hours_today_total`
- `sensor.pstryk_next_cheap_block_hours` — consecutive `is_cheap` hours from next cheap hour
- `sensor.pstryk_hours_until_cheap` — whole hours until next `is_cheap` hour (today or tomorrow)
- `sensor.pstryk_hours_until_cheap_today` — whole hours until next `is_cheap` hour today; `0` if none remain today
- `sensor.pstryk_hours_until_cheap6_block` — whole hours until the 6-consecutive-hour window with lowest total `full_price` starts; attribute `start_warsaw` (HH:MM)
- `sensor.pstryk_daily_summary` — text summary of tomorrow's cheapest hours, sent at 21:00 Warsaw (also triggers `persistent_notification` in HA UI)

**Daily summary (21:00 Warsaw)** — Sends both a `persistent_notification` and updates `sensor.pstryk_daily_summary` with tomorrow's 3 cheapest buy hours, day min/max, and a warning if any hours have negative prices (includes time range of negative-price block).

**Price rounding** — All price/PLN values are rounded to 2 dp at emission via the `round()` helper (defined near `ha_post`): current/next buy+sell, hour +2/+3 buy, today min/max/avg buy+sell, tomorrow cheapest `price` attribute, and the `today_prices` array. Diffs and relatives use `calc()` (awk `%.2f`). Rankings/indices are unaffected — they are computed directly from `BUY_JSON`/`SELL_JSON` full-precision values, not from the rounded emitted vars.

**HA POST logging** — Every `ha_post` call writes a JSON log entry to `/tmp/ha_pstryk/YYYY-MM-DD_HHMM.json`.

## Known dockerfile discrepancy

The `dockerfile` copies `ha.sh` but the actual script is named `ha_pstryk.sh`. This needs to be kept in sync when modifying either file.

## Debugging cache issues

```bash
# Inspect cache
cat /var/tmp/pstryk_cache_timestamps.txt
cat /var/tmp/pstryk_cache.txt | cut -d'|' -f2- | base64 -d | jq .

# Clear cache to force fresh API call
rm -f /var/tmp/pstryk_cache*.txt

# Check last raw API response
cat /tmp/pstryk_last_api_response.json | jq .
```

## Querying the history DB

```bash
# Hourly price/energy/cost/carbon trend, most recent first
sqlite3 -header -column /var/lib/pstryk/pstryk_history.sqlite \
  "SELECT frame_start, full_price, price_prosumer_gross, energy_balance, cost_balance FROM frames ORDER BY frame_start DESC LIMIT 48;"

# Row counts / date range covered
sqlite3 /var/lib/pstryk/pstryk_history.sqlite \
  "SELECT COUNT(*), MIN(frame_start), MAX(frame_start) FROM frames;"

# List recent fetches without dragging out the payloads
sqlite3 -header -column /var/lib/pstryk/pstryk_history.sqlite \
  "SELECT rowid, fetched_at, window_start, length(response_json) AS bytes
   FROM raw_responses ORDER BY fetched_at DESC LIMIT 20;"

# Inspect the latest archived raw API response.
# Select response_json ALONE — sqlite3 joins multiple columns with "|", which
# would put a "fetched_at|" prefix in front of the JSON and break jq.
sqlite3 -noheader /var/lib/pstryk/pstryk_history.sqlite \
  "SELECT response_json FROM raw_responses ORDER BY fetched_at DESC LIMIT 1;" | jq .

# Newest hour that has ANY actuals per fetch. NOTE: this measures presence, not
# completeness — a frame shows up here ~10s after closing while its numbers are
# still provisional. Do not use it to conclude "no lag"; use the revision queries below.
sqlite3 -header -column /var/lib/pstryk/pstryk_history.sqlite \
  "SELECT fetched_at,
          (SELECT MAX(json_extract(f.value,'\$.start'))
           FROM json_each(response_json,'\$.frames') f
           WHERE json_extract(f.value,'\$.metrics.cost.energy_balance_value') IS NOT NULL
          ) AS last_hour_with_data
   FROM raw_responses ORDER BY fetched_at DESC LIMIT 48;"

# One frame as seen by every successive fetch — shows whether the API revises actuals
sqlite3 -header -column /var/lib/pstryk/pstryk_history.sqlite \
  "SELECT r.fetched_at,
          json_extract(f.value,'\$.metrics.cost.energy_balance_value') AS cost_bal
   FROM raw_responses r, json_each(r.response_json,'\$.frames') f
   WHERE json_extract(f.value,'\$.start') = '2026-09-10T09:00:00Z'
   ORDER BY r.fetched_at;"

# Every frame the API revised, with first sighting and time of stabilization
sqlite3 -header -column /var/lib/pstryk/pstryk_history.sqlite \
  "WITH obs AS (
     SELECT json_extract(f.value,'\$.start') AS fs, r.fetched_at AS t,
            json_extract(f.value,'\$.metrics.cost.energy_balance_value') AS v
     FROM raw_responses r, json_each(r.response_json,'\$.frames') f
     WHERE json_extract(f.value,'\$.metrics.cost.energy_balance_value') IS NOT NULL)
   SELECT fs, COUNT(DISTINCT v) AS versions, MIN(t) AS first_seen,
          MIN(CASE WHEN v = (SELECT v FROM obs x WHERE x.fs=obs.fs ORDER BY t DESC LIMIT 1)
                   THEN t END) AS settled_at
   FROM obs GROUP BY fs HAVING COUNT(DISTINCT v) > 1 ORDER BY fs DESC LIMIT 30;"
```
