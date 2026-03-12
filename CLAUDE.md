# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project does

A bash script integration that fetches energy prices from the Pstryk API (`api.pstryk.pl`) and pushes them as sensors into Home Assistant via its REST API. Designed to run hourly via cron or as a Docker container.

## Running the script

```bash
# Directly with arguments
./ha_pstryk.sh "PSTRYK_API_TOKEN" "http://homeassistant.local:8123" "HA_LONG_LIVED_TOKEN"

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

**Cache system** — Two files in `/var/tmp/`:
- `pstryk_cache.txt` — base64-encoded JSON responses, keyed by `endpoint_YYYY-MM-DDTHH`
- `pstryk_cache_timestamps.txt` — Unix timestamps for cache freshness checks
- Cache expires after 55 minutes (`CACHE_MAX_AGE_MINUTES`). Fallback to stale cache on rate limit.

**Timezone handling** — Pstryk API returns UTC timestamps. All price rankings are calculated for the Warsaw local day (`Europe/Warsaw`). The script dynamically computes the UTC offset to handle CET (+1) vs CEST (+2). The API window always starts at `yesterday 22:00 UTC` to ensure Warsaw midnight is covered in both DST states.

**Current hour detection** — Primary method: find the frame with `is_live == true` in the API response. Fallback: calculate from current UTC time.

**Home Assistant sensors updated per run (11 total):**
- `sensor.pstryk_script_current_buy/sell/is_cheap/is_expensive`
- `sensor.pstryk_script_next_buy/sell/is_cheap/is_expensive`
- `sensor.pstryk_current_cheapest` / `sensor.pstryk_next_cheapest`
- `sensor.pstryk_current_index` — price rank 0 (cheapest) to 23 (most expensive)

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
