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
  pstryk-ha:latest
```

## Key architecture decisions

**Single script, no tests framework** — `ha_pstryk.sh` is the entire codebase. All logic lives there: cache management, API calls, timezone math, and Home Assistant sensor updates.

**API endpoint** — Single call to `/integrations/meter-data/unified-metrics/?metrics=pricing&resolution=hour`. Legacy endpoints `/pricing/` and `/prosumer-pricing/` were decommissioned April 2026. The unified response is normalized after fetch: `.metrics.pricing.*` fields are flattened to frame top-level and `Z` timestamps converted to `+00:00` for backward-compatible jq comparisons. `SELL_JSON` is the same data but with `price_gross` overridden by `price_prosumer_gross`.

**Cache system** — Two files in `/var/tmp/`:
- `pstryk_cache.txt` — base64-encoded JSON responses, keyed by `endpoint_YYYY-MM-DDTHH`
- `pstryk_cache_timestamps.txt` — Unix timestamps for cache freshness checks
- Cache expires after 55 minutes (`CACHE_MAX_AGE_MINUTES`). Fallback to stale cache on rate limit.

**Timezone handling** — Pstryk API returns UTC timestamps. All price rankings are calculated for the Warsaw local day (`Europe/Warsaw`). The script dynamically computes the UTC offset to handle CET (+1) vs CEST (+2). The API window always starts at `yesterday 22:00 UTC` to ensure Warsaw midnight is covered in both DST states.

**Current hour detection** — The new unified API does not expose `is_live`. Current hour is always derived from UTC time (`TZ=UTC date +"%Y-%m-%dT%H:00:00+00:00"`).

**Price ranking (`current_index`)** — Uses dense ranking: count of distinct `full_price` levels strictly cheaper than the current hour. Tied hours share the same rank, so values never skip (0, 1, 2… without gaps). Same logic applies to `current_index_sell` (uses `price_prosumer_gross`).

**Home Assistant sensors updated per run (38 total):**
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
