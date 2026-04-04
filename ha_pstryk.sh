#!/bin/bash
#
# Jarosław Zjawiński - kontakt@zjawa.it
#
# Example usage:
#   ./ha.sh "PSTRYK_API_TOKEN" "HA_IP" "HA_TOKEN"
#   ./ha.sh "JhbGciOiJIUzI1NiIsInR5cCI6IkpXV" "http://homeAssistant.local:8123" "JXXD0WsJSfTzac[...]YUkIYJywndt1rqo"
#
# Container usage (using environment variables):
#   docker run --rm -e API_TOKEN="..." -e HA_IP="..." -e HA_TOKEN="..." -v /var/tmp:/var/tmp pstryk-ha
#
# Cron job (runs every hour):
#   1 * * * * /path/to/ha.sh "JhbGciOiJIUzI1NiIsInR5cCI6IkpXV" "http://homeAssistant.local:8123" "JXXD0WsJSfTzac[...]YUkIYJywndt1rqo"
#
# ────────────────────────────────────────────────────────────────────────────────
#
# This script integrates Pstryk energy pricing API with Home Assistant, providing real-time
# energy price monitoring with intelligent caching and rate limit handling.
#
# FEATURES:
# ═════════════════════════════════════════════════════════════════════════════════
# 1. ENERGY PRICE MONITORING:
#    - Fetches current and next hour energy prices (buy/sell)
#    - Determines if current/next hour has cheap or expensive rates
#    - Calculates if current/next hour is the cheapest of the day
#    - Price ranking index for current hour (0=cheapest, 23=most expensive)
#
# 2. INTELLIGENT CACHING SYSTEM:
#    - Two-tier cache: data cache + timestamp cache
#    - Cache expires after 55 minutes (configurable)
#    - Base64 encoded cache prevents JSON corruption
#    - Automatic cleanup of broken/old cache entries
#
# 3. RATE LIMIT PROTECTION:
#    - Detects API rate limiting (Polish: "Żądanie zostało zdławione")
#    - Falls back to cached data when rate limited
#    - Uses most recent valid cache if current cache unavailable
#
# 4. CONTAINERIZATION SUPPORT:
#    - Can read configuration from environment variables
#    - Docker-ready with proper volume mounting for cache persistence
#    - Supports both script arguments and environment variables
#
# 5. HOME ASSISTANT INTEGRATION:
#    - Updates 11 sensors per run: current/next × buy/sell/cheap/expensive + cheapest + index
#    - Additional cheapest hour detection sensors
#    - Price ranking index sensor (0-23 scale)
#    - Proper units (PLN/kWh) and state management
#    - Debug logging for troubleshooting
#
# CONFIGURATION:
# ═════════════════════════════════════════════════════════════════════════════════
# Script Arguments: API_TOKEN, HA_IP, HA_TOKEN
# Environment Variables: API_TOKEN, HA_IP, HA_TOKEN (for container use)
# Cache Location: /var/tmp/pstryk_cache.txt + /var/tmp/pstryk_cache_timestamps.txt
# Cache Expiry: 55 minutes (CACHE_MAX_AGE_MINUTES)
#
# DATA FLOW:
# ═════════════════════════════════════════════════════════════════════════════════
# 1. Check cache freshness (< 55 minutes) → Use cache if fresh
# 2. If stale cache or no cache → Call Pstryk API
# 3. If API success → Save to cache + update Home Assistant
# 4. If API rate limited → Use stale cache as fallback
# 5. Extract price data for current/next hour
# 6. Calculate cheapest hour comparisons
# 7. Update all Home Assistant sensors with new data
#
# DEPENDENCIES:
# ═════════════════════════════════════════════════════════════════════════════════
# - curl: API requests and Home Assistant updates
# - jq: JSON parsing and data extraction
# - base64: Cache encoding/decoding
# - date: Timestamp handling and cache expiry
#
# ERROR HANDLING:
# ═════════════════════════════════════════════════════════════════════════════════
# - Robust error handling with `set -euo pipefail`
# - Graceful fallback to cache when API fails
# - Null value handling for missing data points
# - Debug logging to stderr for troubleshooting
# ────────────────────────────────────────────────────────────────────────────────

# Set system time zone to UTC only for this script
#export TZ=UTC
#echo "System time zone temporarily set to UTC for script execution"

set -euo pipefail               # stop on errors, unset vars, or failed pipelines
sleep 5                      # wait a bit to avoid bad timestamps from too-early execution

# ── AUTO-UPDATE ──────────────────────────────────────────────────────────────────
_autoupdate() {
  local script_path update_url tmp_file current_md5 remote_md5
  # Skip auto-update if --no-update flag is present
  for arg in "$@"; do
    if [[ "$arg" == "--no-update" ]]; then
      echo "Auto-update skipped (--no-update flag)" >&2
      return 0
    fi
  done
  script_path="$(readlink -f "$0")"
  update_url="https://raw.githubusercontent.com/enclude/pstryk-ha-integration/main/ha_pstryk.sh"
  echo "Checking for script updates from GitHub..."
  tmp_file=$(mktemp) || return 0
  if curl -sf --max-time 15 -o "$tmp_file" "$update_url" 2>/dev/null; then
    current_md5=$(md5sum "$script_path" | cut -d' ' -f1)
    remote_md5=$(md5sum "$tmp_file" | cut -d' ' -f1)
    if [[ "$current_md5" != "$remote_md5" ]]; then
      echo "Update available! Applying and restarting..."
      cp "$tmp_file" "$script_path"
      chmod +x "$script_path"
      rm -f "$tmp_file"
      exec "$script_path" "$@"
    else
      echo "Script is up to date."
    fi
  else
    echo "Could not check for updates (network error), continuing..." >&2
  fi
  rm -f "$tmp_file"
}
_autoupdate "$@"
# ────────────────────────────────────────────────────────────────────────────────

# ── CONFIG ──────────────────────────────────────────────────────────────────────
API_TOKEN=$1
HA_IP=$2
HA_TOKEN=$3

# ── CACHE CONFIG ────────────────────────────────────────────────────────────────
CACHE_FILE="/var/tmp/pstryk_cache.txt"
CACHE_TIMESTAMP_FILE="/var/tmp/pstryk_cache_timestamps.txt"
CACHE_MAX_AGE_MINUTES=55

echo "Cache file: "$CACHE_FILE
echo "Cache timestamp file: "$CACHE_TIMESTAMP_FILE

API_BASE="https://api.pstryk.pl/integrations"
# TODO: Migrate /pricing/ and /prosumer-pricing/ to /meter-data/unified-metrics/?metrics=pricing
#       before April 1, 2026 when legacy endpoints are decommissioned.
#       The new endpoint returns frames[].metrics.pricing.{field} instead of frames[].{field}.
# Request data from yesterday 22:00 UTC to cover Warsaw 00:00 in both CET and CEST
# CET (winter): Warsaw 00:00 = yesterday 23:00 UTC
# CEST (summer): Warsaw 00:00 = yesterday 22:00 UTC
START=$(date -u -d 'yesterday 22:00' +"%Y-%m-%dT%H:00:00+00:00")
STOP=$(date -u -d 'tomorrow 23:59:59' +"%Y-%m-%dT%H:%M:%S+00:00")

echo $START
echo $STOP
echo "Cache max age: $CACHE_MAX_AGE_MINUTES minutes"
echo "---"

# first‑dimension labels → timestamps (UTC format for Pstryk API)
# We will get current hour from API's is_live flag after fetching data
# For now, declare empty HOUR array - will be populated after API call
declare -A HOUR

echo "Local time (Warsaw): $(TZ='Europe/Warsaw' date +"%Y-%m-%d %H:%M:%S %Z")"
echo "UTC time: $(TZ=UTC date +"%Y-%m-%d %H:%M:%S %Z")"
# ────────────────────────────────────────────────────────────────────────────────

# ── CACHE FUNCTIONS ─────────────────────────────────────────────────────────────
# --- helpers -------------------------------------------------------------------
cleanup_old_cache() {  # remove cache entries older than 7 days
  local cutoff_timestamp=$(date -d '7 days ago' +%s)
  local removed=0

  if [[ -f "$CACHE_TIMESTAMP_FILE" ]]; then
    local tmp_ts=/var/tmp/tmp_timestamps_cleanup_$$.txt
    touch "$tmp_ts"
    while IFS='|' read -r key ts; do
      if [[ -n "$ts" && "$ts" -ge "$cutoff_timestamp" ]]; then
        echo "$key|$ts" >> "$tmp_ts"
      else
        removed=$((removed + 1))
      fi
    done < "$CACHE_TIMESTAMP_FILE"
    mv "$tmp_ts" "$CACHE_TIMESTAMP_FILE"
    echo "Cache cleanup: removed $removed old timestamp entries (older than 7 days)" >&2
  fi

  if [[ -f "$CACHE_FILE" && -f "$CACHE_TIMESTAMP_FILE" ]]; then
    local tmp_cache=/var/tmp/tmp_cache_cleanup_$$.txt
    touch "$tmp_cache"
    while IFS='|' read -r key encoded; do
      if grep -q "^$key|" "$CACHE_TIMESTAMP_FILE" 2>/dev/null; then
        echo "$key|$encoded" >> "$tmp_cache"
      fi
    done < "$CACHE_FILE"
    mv "$tmp_cache" "$CACHE_FILE"
    echo "Cache cleanup: data file pruned to match remaining timestamps" >&2
  fi
}

is_cache_fresh() {    # check if cache is less than 55 minutes old
  local endpoint=$1
  local cache_key="${endpoint}_$(date -u +"%Y-%m-%dT%H")"

  # Check if timestamp file exists and has entry for this cache key
  if [[ -f "$CACHE_TIMESTAMP_FILE" ]]; then
    local cache_timestamp=$(grep "^$cache_key|" "$CACHE_TIMESTAMP_FILE" 2>/dev/null | tail -n1 | cut -d'|' -f2)
    if [[ -n "$cache_timestamp" ]]; then
      local current_timestamp=$(date +%s)
      local cache_age_minutes=$(( (current_timestamp - cache_timestamp) / 60 ))

      echo "Cache age for $cache_key: $cache_age_minutes minutes" >&2

      if [[ $cache_age_minutes -lt $CACHE_MAX_AGE_MINUTES ]]; then
        echo "Cache is fresh (< $CACHE_MAX_AGE_MINUTES minutes)" >&2
        return 0  # Cache is fresh
      else
        echo "Cache is stale (>= $CACHE_MAX_AGE_MINUTES minutes)" >&2
        return 1  # Cache is stale
      fi
    fi
  fi

  echo "No cache timestamp found for $cache_key" >&2
  return 1  # No cache or no timestamp
}

get_json() {      # hit one endpoint once and return its JSON, with cache fallback
  local endpoint=$1
  local cache_key="${endpoint}_$(date -u +"%Y-%m-%dT%H")"
  local cache_entry

  # Check if we have fresh cache first
  if is_cache_fresh "$endpoint"; then
    echo "Using fresh cache for $endpoint" >&2
    # Get data from cache
    local cached_line=$(grep "^$cache_key|" "$CACHE_FILE" 2>/dev/null | tail -n1)
    if [[ -n "$cached_line" ]]; then
      local cache_data_encoded=$(echo "$cached_line" | cut -d'|' -f2-)
      local cache_data=$(echo "$cache_data_encoded" | base64 -d 2>/dev/null || echo "$cache_data_encoded")

      if echo "$cache_data" | jq -e '.frames' >/dev/null 2>&1; then
        echo "$cache_data"
        return
      fi
    fi
    echo "Fresh cache found but data invalid, falling back to API" >&2
  fi

  # Try API
  echo "API Request: $API_BASE/$endpoint/ with window_start=$START window_end=$STOP" >&2
  local response
  response=$(curl -sG \
       -H "accept: application/json" \
       -H "Authorization: $API_TOKEN" \
       --data-urlencode resolution=hour \
       --data-urlencode window_start="$START" \
       --data-urlencode window_end="$STOP" \
       "$API_BASE/$endpoint/") || true
  echo "API Response for $endpoint (first 200 chars): $(echo "$response" | head -c 200)" >&2
  echo "$response" > /tmp/pstryk_last_api_response.json

  # Debug: Check response validity
  echo "Response validation for $endpoint:" >&2
  echo "  - Non-empty: $([[ -n "$response" && "$response" != "null" ]] && echo "YES" || echo "NO")" >&2
  echo "  - Has frames: $(echo "$response" | jq -e '.frames' >/dev/null 2>&1 && echo "YES" || echo "NO")" >&2
  echo "  - Has detail (rate limit): $(echo "$response" | jq -e '.detail' >/dev/null 2>&1 && echo "YES" || echo "NO")" >&2

  # Check if response is valid (has frames) and not rate limited
  if [[ -n "$response" && "$response" != "null" ]] && echo "$response" | jq -e '.frames' >/dev/null 2>&1 && ! echo "$response" | jq -e '.detail' >/dev/null 2>&1; then
    # Save to cache - use simpler format: key|base64_encoded_json
    cache_data_encoded=$(echo "$response" | base64 -w 0 2>/dev/null || echo "$response" | base64)

    # Remove old entries for this key and add new one
    if [[ -f "$CACHE_FILE" ]]; then
      grep -v "^$cache_key|" "$CACHE_FILE" 2>/dev/null > /var/tmp/tmp_cache_$$.txt || true
    else
      touch /var/tmp/tmp_cache_$$.txt
    fi
    echo "$cache_key|$cache_data_encoded" >> /var/tmp/tmp_cache_$$.txt
    mv /var/tmp/tmp_cache_$$.txt "$CACHE_FILE"

    # Save timestamp
    local current_timestamp=$(date +%s)
    if [[ -f "$CACHE_TIMESTAMP_FILE" ]]; then
      grep -v "^$cache_key|" "$CACHE_TIMESTAMP_FILE" 2>/dev/null > /var/tmp/tmp_timestamps_$$.txt || true
    else
      touch /var/tmp/tmp_timestamps_$$.txt
    fi
    echo "$cache_key|$current_timestamp" >> /var/tmp/tmp_timestamps_$$.txt
    mv /var/tmp/tmp_timestamps_$$.txt "$CACHE_TIMESTAMP_FILE"

    echo "Cached data and timestamp for $cache_key" >&2
    echo "$response"
  else
    # Check if rate limited
    if echo "$response" | jq -e '.detail' >/dev/null 2>&1; then
      echo "Rate limited detected: $response" >&2
    fi

    # Debug: Show cache file contents and clean broken entries
    echo "Cache file contents:" >&2
    if [[ -f "$CACHE_FILE" ]]; then
      # Clean up broken cache entries (those that are just "{" or incomplete)
      if grep -q "^${endpoint}_.*|{$" "$CACHE_FILE" 2>/dev/null; then
        echo "Found broken cache entries, cleaning up..." >&2
        grep -v "^${endpoint}_.*|{$" "$CACHE_FILE" 2>/dev/null > /var/tmp/tmp_clean_cache_$$.txt || touch /var/tmp/tmp_clean_cache_$$.txt
        mv /var/tmp/tmp_clean_cache_$$.txt "$CACHE_FILE"
      fi

      echo "Cache entries for $endpoint:" >&2
      grep "^${endpoint}_" "$CACHE_FILE" 2>/dev/null | head -3 >&2 || echo "No cache entries for $endpoint" >&2
    else
      echo "Cache file $CACHE_FILE does not exist" >&2
    fi

    # Fallback to cache - look for the most recent cache entry for this endpoint
    echo "Searching for cached data for endpoint: $endpoint" >&2

    # Find the most recent cache entry for this endpoint (any timestamp)
    latest_cache=$(grep "^${endpoint}_" "$CACHE_FILE" 2>/dev/null | tail -n1)
    if [[ -n "$latest_cache" ]]; then
      cache_key_found=$(echo "$latest_cache" | cut -d'|' -f1)
      cache_data_encoded=$(echo "$latest_cache" | cut -d'|' -f2-)

      # Decode cache data (try base64 first, fallback to direct if it fails)
      cache_data=$(echo "$cache_data_encoded" | base64 -d 2>/dev/null || echo "$cache_data_encoded")

      # Validate that we got valid JSON with frames
      if echo "$cache_data" | jq -e '.frames' >/dev/null 2>&1; then
        echo "Using cached data from $cache_key_found for $endpoint" >&2
        echo "$cache_data"
      else
        echo "Found cache entry but data is invalid for $endpoint" >&2
        echo "{}"
      fi
    else
      echo "No cached entries found for $endpoint" >&2
      echo "{}"
    fi
  fi
}

jq_field() {      # jq_field <json> <timestamp> <field>
  local json="$1"
  local timestamp="$2"
  local field="$3"

  # Check if JSON has frames before trying to access them
  if echo "$json" | jq -e 'has("frames")' >/dev/null 2>&1; then
    local result
    result=$(jq -r --arg t "$timestamp" ".frames[] | select(.start==\$t) | .$field" <<<"$json")
    echo "${result:-null}"
  else
    echo "null"
  fi
}

ha_post() {       # ha_post <entity_id> <json_body>
  echo "Posting to HA: $1 -> $2"
  
  # Create log directory if it doesn't exist
  local log_dir="/tmp/ha_pstryk"
  mkdir -p "$log_dir"
  
  # Create log file with current date and hour (YYYY-MM-DD_HH format - no spaces)
  local log_datetime=$(date +"%Y-%m-%d_%H%M")
  local log_file="$log_dir/$log_datetime.json"
  
  # Create JSON log entry
  local log_entry=$(jq -n \
    --arg timestamp "$(date '+%Y-%m-%d %H:%M:%S')" \
    --arg entity "$1" \
    --argjson data "$2" \
    '{timestamp: $timestamp, entity: $entity, data: $data}')
  
  # Append to JSON array in log file
  if [[ -f "$log_file" ]]; then
    # File exists, append to array
    jq --argjson entry "$log_entry" '. += [$entry]' "$log_file" > "${log_file}.tmp" && mv "${log_file}.tmp" "$log_file"
  else
    # New file, create array with first entry
    echo "[$log_entry]" > "$log_file"
  fi
  
  local response=$(curl -s -X POST \
       -H "Authorization: Bearer $HA_TOKEN" \
       -H "Content-Type: application/json" \
       -d "$2" \
       "$HA_IP/api/states/$1")
  echo "HA Response: $response"
}
# --------------------------------------------------------------------------------

cleanup_old_cache

# download once, reuse many times
BUY_JSON=$( get_json pricing )
SELL_JSON=$( get_json prosumer-pricing )

# Debug: Check if we got valid JSON
echo "BUY_JSON length: $(echo "$BUY_JSON" | wc -c)"
echo "SELL_JSON length: $(echo "$SELL_JSON" | wc -c)"
echo "BUY_JSON has frames: $(echo "$BUY_JSON" | jq -e 'has("frames")' 2>/dev/null || echo "false")"
echo "SELL_JSON has frames: $(echo "$SELL_JSON" | jq -e 'has("frames")' 2>/dev/null || echo "false")"

# Debug: Show first and last timestamp in API response to verify data range
echo "First timestamp in BUY_JSON: $(echo "$BUY_JSON" | jq -r '.frames[0].start // "none"')"
echo "Last timestamp in BUY_JSON: $(echo "$BUY_JSON" | jq -r '.frames[-1].start // "none"')"
echo "Total frames in BUY_JSON: $(echo "$BUY_JSON" | jq '.frames | length')"

# Get current and next hour from API's is_live flag (most reliable method)
# The API marks the current hour with is_live:true
HOUR[current]=$(echo "$BUY_JSON" | jq -r '.frames[] | select(.is_live == true) | .start' 2>/dev/null || echo "")
ACTUAL_UTC_HOUR="$(TZ=UTC date +"%Y-%m-%dT%H:00:00+00:00")"
if [[ -z "${HOUR[current]}" ]]; then
  echo "WARNING: No is_live frame found in API response, falling back to UTC calculation" >&2
  HOUR[current]="$ACTUAL_UTC_HOUR"
elif [[ "${HOUR[current]}" != "$ACTUAL_UTC_HOUR" ]]; then
  echo "WARNING: is_live frame (${HOUR[current]}) from stale cache doesn't match actual UTC hour ($ACTUAL_UTC_HOUR), using UTC calculation" >&2
  HOUR[current]="$ACTUAL_UTC_HOUR"
fi

# Calculate next hour from current hour
CURRENT_HOUR_NUM=$(echo "${HOUR[current]}" | sed 's/.*T\([0-9][0-9]\):.*/\1/' | sed 's/^0//')
NEXT_HOUR_NUM=$(( (CURRENT_HOUR_NUM + 1) % 24 ))
NEXT_HOUR_PADDED=$(printf "%02d" $NEXT_HOUR_NUM)
# Handle date change at midnight
if [[ $NEXT_HOUR_NUM -eq 0 ]]; then
  NEXT_DATE=$(TZ=UTC date -d "$(echo "${HOUR[current]}" | cut -dT -f1) + 1 day" +"%Y-%m-%d")
else
  NEXT_DATE=$(echo "${HOUR[current]}" | cut -dT -f1)
fi
HOUR[next]="${NEXT_DATE}T${NEXT_HOUR_PADDED}:00:00+00:00"

echo "Current hour (from API is_live): ${HOUR[current]}"
echo "Next hour (calculated): ${HOUR[next]}"

# fill a 2‑D associative array
declare -A A
for row in current next; do
  ts=${HOUR[$row]}

  A[$row,buy]=$( jq_field "$BUY_JSON"  "$ts" full_price )
  A[$row,sell]=$( jq_field "$SELL_JSON" "$ts" price_gross )
  A[$row,is_cheap]=$( jq_field "$BUY_JSON"  "$ts" is_cheap )
  A[$row,is_expensive]=$( jq_field "$BUY_JSON"  "$ts" is_expensive )
done

# Calculate current_index (price ranking for current hour: 0=cheapest, 23=most expensive)
# For Warsaw (UTC+1 in winter, UTC+2 in summer), we need to filter for Warsaw local day
echo "=== CALCULATING CURRENT INDEX ==="

# Get Warsaw local day boundaries in UTC
# Warsaw 00:00 = UTC 23:00 (previous day in winter) or UTC 22:00 (previous day in summer)
# Warsaw 23:00 = UTC 22:00 (same day in winter) or UTC 21:00 (same day in summer)
WARSAW_TODAY=$(TZ='Europe/Warsaw' date +%Y-%m-%d)
WARSAW_DAY_START_UTC=$(TZ=UTC date -d "TZ=\"Europe/Warsaw\" $WARSAW_TODAY 00:00:00" +"%Y-%m-%dT%H:00:00+00:00")
WARSAW_DAY_END_UTC=$(TZ=UTC date -d "TZ=\"Europe/Warsaw\" $WARSAW_TODAY 23:00:00" +"%Y-%m-%dT%H:00:00+00:00")

WARSAW_TOMORROW=$(TZ='Europe/Warsaw' date -d 'tomorrow' +%Y-%m-%d)
WARSAW_TOMORROW_START_UTC=$(TZ=UTC date -d "TZ=\"Europe/Warsaw\" $WARSAW_TOMORROW 00:00:00" +"%Y-%m-%dT%H:00:00+00:00")
WARSAW_TOMORROW_END_UTC=$(TZ=UTC date -d "TZ=\"Europe/Warsaw\" $WARSAW_TOMORROW 23:00:00" +"%Y-%m-%dT%H:00:00+00:00")

echo "Warsaw today: $WARSAW_TODAY"
echo "Warsaw day start in UTC: $WARSAW_DAY_START_UTC"
echo "Warsaw day end in UTC: $WARSAW_DAY_END_UTC"

current_index=$(echo "$BUY_JSON" | jq -r --arg now "${HOUR[current]}" \
   --arg day_start "$WARSAW_DAY_START_UTC" --arg day_end "$WARSAW_DAY_END_UTC" '
  (.frames | map(select(
    .start >= $day_start and .start <= $day_end
  ))) as $day_frames |
  if ($day_frames | length) > 0 then
    ($day_frames | map(select(.start == $now)) | if length > 0 then .[0].price_gross else null end) as $current_price |
    if $current_price != null then
      # Dense rank: count distinct price levels strictly cheaper than current hour
      # Tied hours share the same rank, so values are never skipped (0,1,2... no gaps)
      ($day_frames | map(.price_gross) | unique | map(select(. < $current_price)) | length)
    else
      "unknown"
    end
  else
    "no_frames"
  end
')

echo "Current hour index (0=cheapest, 23=most expensive): '$current_index'"
A[current,index]=$current_index

# Calculate current_index_sell (sell price ranking for current hour: 0=cheapest sell, 23=most expensive sell)
current_index_sell=$(echo "$SELL_JSON" | jq -r --arg now "${HOUR[current]}" \
   --arg day_start "$WARSAW_DAY_START_UTC" --arg day_end "$WARSAW_DAY_END_UTC" '
  (.frames | map(select(
    .start >= $day_start and .start <= $day_end
  ))) as $day_frames |
  if ($day_frames | length) > 0 then
    ($day_frames | map(select(.start == $now)) | if length > 0 then .[0].price_gross else null end) as $current_price |
    if $current_price != null then
      # Dense rank: count distinct sell price levels strictly cheaper than current hour
      ($day_frames | map(.price_gross) | unique | map(select(. < $current_price)) | length)
    else
      "unknown"
    end
  else
    "no_frames"
  end
')

echo "Current hour sell index (0=cheapest sell, 23=most expensive sell): '$current_index_sell'"
A[current,index_sell]=$current_index_sell

# Calculate price_relative = current full_price / today's average full_price
# Values > 1.0 mean current hour is more expensive than today's average
today_avg_full=$(echo "$BUY_JSON" | jq -r --arg day_start "$WARSAW_DAY_START_UTC" --arg day_end "$WARSAW_DAY_END_UTC" '
  [.frames[] | select(.start >= $day_start and .start <= $day_end) | .full_price | select(. != null)] |
  if length > 0 then (add / length) else null end
')
if [[ -n "${A[current,buy]}" && "${A[current,buy]}" != "null" && -n "$today_avg_full" && "$today_avg_full" != "null" ]]; then
  price_relative=$(echo "$today_avg_full ${A[current,buy]}" | awk '{if ($1 > 0) printf "%.2f", $2/$1; else print "null"}')
else
  price_relative="null"
fi
echo "Today avg full price: $today_avg_full"
echo "Price relative (current/avg): $price_relative"

# Debug current_index calculation
echo "=== DEBUGGING CURRENT INDEX CALCULATION ===" >&2
echo "Current timestamp (UTC): ${HOUR[current]}" >&2
echo "Warsaw today: $WARSAW_TODAY" >&2
echo "Warsaw day start (UTC): $WARSAW_DAY_START_UTC" >&2
echo "Warsaw day end (UTC): $WARSAW_DAY_END_UTC" >&2

# Show all timestamps for Warsaw local day
echo "All timestamps for Warsaw local day:" >&2
echo "Current timestamp (local): $(TZ='Europe/Warsaw' date)"
echo "Current timestamp (UTC): $(TZ=UTC date)"
echo "$BUY_JSON" | jq -r --arg day_start "$WARSAW_DAY_START_UTC" --arg day_end "$WARSAW_DAY_END_UTC" '
  .frames | map(select(
    .start >= $day_start and .start <= $day_end
  )) | .[].start
' >&2

# Show sorted prices with timestamps for Warsaw local day (showing Warsaw time)
echo "Sorted prices for Warsaw local day (index: UTC -> Warsaw local -> price):" >&2

# Calculate current Warsaw offset from UTC (handles both CET +1 and CEST +2)
# Use 10# prefix to force base 10 interpretation (prevents octal errors with 08, 09)
WARSAW_OFFSET=$(( (10#$(TZ='Europe/Warsaw' date +%H) - 10#$(TZ=UTC date +%H) + 24) % 24 ))
echo "Current Warsaw offset from UTC: +$WARSAW_OFFSET hours" >&2

echo "$BUY_JSON" | jq -r --arg day_start "$WARSAW_DAY_START_UTC" --arg day_end "$WARSAW_DAY_END_UTC" --argjson offset "$WARSAW_OFFSET" '
  (.frames | map(select(
    .start >= $day_start and .start <= $day_end
  )) | sort_by(.price_gross)) |
  to_entries | .[] | 
  # Extract hour from UTC timestamp and add offset for Warsaw time
  (.value.start | split("T")[1] | split(":")[0] | tonumber) as $utc_hour |
  (($utc_hour + $offset) % 24) as $warsaw_hour |
  # Format with leading zeros
  (if .key < 10 then "0" + (.key | tostring) else (.key | tostring) end) as $idx |
  (if $warsaw_hour < 10 then "0" + ($warsaw_hour | tostring) else ($warsaw_hour | tostring) end) as $wh |
  "\($idx): \(.value.start) (Warsaw: \($wh):00) -> \(.value.price_gross)"
' >&2

# Check if current hour exists in Warsaw local day data
current_hour_exists=$(echo "$BUY_JSON" | jq -r --arg now "${HOUR[current]}" \
  --arg day_start "$WARSAW_DAY_START_UTC" --arg day_end "$WARSAW_DAY_END_UTC" '
  (.frames | map(select(
    .start >= $day_start and .start <= $day_end
  )) | map(.start) | index($now)) // "not_found"
')
echo "Current hour exists in Warsaw local day data: $current_hour_exists" >&2

# push values to Home‑Assistant
for row in current next; do
  for flag in is_cheap is_expensive; do
    ha_post "sensor.pstryk_script_${row}_${flag}" \
            "{\"state\":\"${A[$row,$flag]}\"}"
  done

  for price in buy sell; do
    ha_post "sensor.pstryk_script_${row}_${price}" \
            "{\"state\":\"${A[$row,$price]}\",\"attributes\":{\"unit_of_measurement\":\"PLN/kWh\"}}"
  done
done

# Send current_index to Home Assistant
ha_post "sensor.pstryk_current_index" \
        "{\"state\":\"${A[current,index]}\",\"attributes\":{\"unit_of_measurement\":\"\",\"friendly_name\":\"Pstryk Current Hour Price Index\",\"description\":\"Dense price rank for current hour (0=cheapest tier). Hours with identical prices share the same rank, so values increment without gaps.\"}}"

# Send current_index_sell to Home Assistant
ha_post "sensor.pstryk_current_index_sell" \
        "{\"state\":\"${A[current,index_sell]}\",\"attributes\":{\"unit_of_measurement\":\"\",\"friendly_name\":\"Pstryk Current Hour Sell Price Index\",\"description\":\"Dense sell price rank for current hour (0=cheapest sell tier, 23=most expensive). Hours with identical prices share the same rank.\"}}"

# Send price_relative to Home Assistant
ha_post "sensor.pstryk_price_relative" \
        "{\"state\":\"$price_relative\",\"attributes\":{\"unit_of_measurement\":\"\",\"friendly_name\":\"Pstryk Price Relative\",\"description\":\"Current full price divided by today average full price. >1.0 = expensive now, <1.0 = cheap now\"}}"

# Debug the cheapest calculation
echo "=== DEBUGGING CHEAPEST CALCULATION ==="
echo "Current time (UTC): ${HOUR[current]}"
echo "Warsaw day: $WARSAW_TODAY"

# Test the individual parts
min_price=$(echo "$BUY_JSON" | jq -r --arg day_start "$WARSAW_DAY_START_UTC" --arg day_end "$WARSAW_DAY_END_UTC" '
  .frames | map(select(
    .start >= $day_start and .start <= $day_end
  )) | min_by(.price_gross).price_gross
')
echo "Minimum price today (Warsaw): $min_price"

current_price=$(echo "$BUY_JSON" | jq -r --arg now "${HOUR[current]}" '
  .frames[] | select(.start==$now).price_gross
')
echo "Current hour price: $current_price"

# Show frames for Warsaw local day
echo "Frames for Warsaw local day sorted by price_gross:"
echo "$BUY_JSON" | jq -r --arg day_start "$WARSAW_DAY_START_UTC" --arg day_end "$WARSAW_DAY_END_UTC" --argjson offset "$WARSAW_OFFSET" '
  [.frames[] | select(
    .start >= $day_start and .start <= $day_end
  )] | sort_by(.price_gross) | to_entries | .[] |
  # Extract hour from UTC timestamp and add offset for Warsaw time
  (.value.start | split("T")[1] | split(":")[0] | tonumber) as $utc_hour |
  (($utc_hour + $offset) % 24) as $warsaw_hour |
  (if .key < 10 then "0" + (.key | tostring) else (.key | tostring) end) as $idx |
  (if $warsaw_hour < 10 then "0" + ($warsaw_hour | tostring) else ($warsaw_hour | tostring) end) as $wh |
  "\($idx): \(.value.start) (Warsaw: \($wh):00) -> \(.value.price_gross)"
' | head -24

# Simplified version to avoid parsing errors
current_cheapest_result=$(echo "$BUY_JSON" | jq -r --arg now "${HOUR[current]}" \
   --arg day_start "$WARSAW_DAY_START_UTC" --arg day_end "$WARSAW_DAY_END_UTC" '
  if (.frames | length) > 0 then
    (.frames | map(select(
      .start >= $day_start and .start <= $day_end
    )) | min_by(.price_gross).price_gross) as $min_price |
    (.frames[] | select(.start == $now) | .price_gross) as $current_price |
    if $current_price and $min_price then
      if $current_price == $min_price then "true" else "false" end
    else
      "unknown"
    end
  else
    "no_frames"
  end
')

echo "Current cheapest calculation result: '$current_cheapest_result'"
echo "Current time (UTC): ${HOUR[current]}"
echo "Today date (UTC): $(TZ=UTC date +%Y-%m-%d)"

ha_post "sensor.pstryk_current_cheapest" \
  "{\"state\":\"$current_cheapest_result\"}"

# Debug the next cheapest calculation
# Simplified version to avoid parsing errors
next_cheapest_result=$(echo "$BUY_JSON" | jq -r --arg now "${HOUR[next]}" \
   --arg day_start "$WARSAW_DAY_START_UTC" --arg day_end "$WARSAW_DAY_END_UTC" '
  if (.frames | length) > 0 then
    (.frames | map(select(
      .start >= $day_start and .start <= $day_end
    )) | min_by(.price_gross).price_gross) as $min_price |
    (.frames[] | select(.start == $now) | .price_gross) as $next_price |
    if $next_price and $min_price then
      if $next_price == $min_price then "true" else "false" end
    else
      "unknown"
    end
  else
    "no_frames"
  end
')

echo "Next cheapest calculation result: '$next_cheapest_result'"
echo "Next time (UTC): ${HOUR[next]}"

ha_post "sensor.pstryk_next_cheapest" \
  "{\"state\":\"$next_cheapest_result\"}"

# Tomorrow cheapest hour
tomorrow_cheapest_utc=$(echo "$BUY_JSON" | jq -r --arg day_start "$WARSAW_TOMORROW_START_UTC" --arg day_end "$WARSAW_TOMORROW_END_UTC" '
  [.frames[] | select(.start >= $day_start and .start <= $day_end and .full_price != null and .full_price > 0)] |
  if length > 0 then min_by(.full_price).start else "unknown" end
')
echo "Tomorrow cheapest hour (UTC): $tomorrow_cheapest_utc"

if [[ -n "$tomorrow_cheapest_utc" && "$tomorrow_cheapest_utc" != "unknown" && "$tomorrow_cheapest_utc" != "null" ]]; then
  tomorrow_cheapest_warsaw=$(TZ='Europe/Warsaw' date -d "$tomorrow_cheapest_utc" +"%H:%M")
  tomorrow_cheapest_date=$(TZ='Europe/Warsaw' date -d "$tomorrow_cheapest_utc" +"%Y-%m-%d")
  tomorrow_cheapest_price=$(echo "$BUY_JSON" | jq -r --arg ts "$tomorrow_cheapest_utc" '.frames[] | select(.start == $ts) | .full_price')
else
  tomorrow_cheapest_warsaw="unknown"
  tomorrow_cheapest_date="unknown"
  tomorrow_cheapest_price="null"
fi
echo "Tomorrow cheapest hour (Warsaw): $tomorrow_cheapest_warsaw on $tomorrow_cheapest_date, price: $tomorrow_cheapest_price"

ha_post "sensor.pstryk_tomorrow_cheapest_hour" \
  "{\"state\":\"$tomorrow_cheapest_warsaw\",\"attributes\":{\"unit_of_measurement\":\"\",\"friendly_name\":\"Pstryk Tomorrow Cheapest Hour\",\"date\":\"$tomorrow_cheapest_date\",\"price\":${tomorrow_cheapest_price:-null},\"description\":\"Cheapest hour tomorrow (Warsaw local time HH:MM)\"}}"

# Next cheap hour (first upcoming hour with is_cheap=true)
next_cheap_utc=$(echo "$BUY_JSON" | jq -r --arg now "${HOUR[current]}" '
  [.frames[] | select(.is_cheap == true and .start > $now)] |
  if length > 0 then (sort_by(.start) | first | .start) else "none" end
')
echo "Next cheap hour (UTC): $next_cheap_utc"

if [[ -n "$next_cheap_utc" && "$next_cheap_utc" != "none" && "$next_cheap_utc" != "null" ]]; then
  next_cheap_warsaw=$(TZ='Europe/Warsaw' date -d "$next_cheap_utc" +"%Y-%m-%d %H:%M")
else
  next_cheap_warsaw="none"
fi
echo "Next cheap hour (Warsaw): $next_cheap_warsaw"

ha_post "sensor.pstryk_next_cheap_hour" \
  "{\"state\":\"$next_cheap_warsaw\",\"attributes\":{\"unit_of_measurement\":\"\",\"friendly_name\":\"Pstryk Next Cheap Hour\",\"description\":\"Next upcoming hour with is_cheap=true (Warsaw time: YYYY-MM-DD HH:MM)\"}}"

# ── HOUR +2 AND +3 ───────────────────────────────────────────────────────────
HOUR[next2]=$(TZ=UTC date -d "${HOUR[current]} + 2 hours" +"%Y-%m-%dT%H:00:00+00:00")
HOUR[next3]=$(TZ=UTC date -d "${HOUR[current]} + 3 hours" +"%Y-%m-%dT%H:00:00+00:00")
echo "Hour +2 (UTC): ${HOUR[next2]}"
echo "Hour +3 (UTC): ${HOUR[next3]}"

A[next2,buy]=$(jq_field "$BUY_JSON" "${HOUR[next2]}" full_price)
A[next3,buy]=$(jq_field "$BUY_JSON" "${HOUR[next3]}" full_price)

for slot in next2 next3; do
  A[$slot,index]=$(echo "$BUY_JSON" | jq -r --arg now "${HOUR[$slot]}" \
     --arg day_start "$WARSAW_DAY_START_UTC" --arg day_end "$WARSAW_DAY_END_UTC" '
    (.frames | map(select(
      .start >= $day_start and .start <= $day_end
    ))) as $day_frames |
    if ($day_frames | length) > 0 then
      ($day_frames | map(select(.start == $now)) | if length > 0 then .[0].price_gross else null end) as $price |
      if $price != null then
        ($day_frames | map(.price_gross) | unique | map(select(. < $price)) | length)
      else
        "unknown"
      end
    else
      "no_frames"
    end
  ')
  echo "Hour $slot index: ${A[$slot,index]}"
done

ha_post "sensor.pstryk_hour_next2_buy" \
  "{\"state\":\"${A[next2,buy]}\",\"attributes\":{\"unit_of_measurement\":\"PLN/kWh\",\"friendly_name\":\"Pstryk Hour +2 Buy Price\"}}"
ha_post "sensor.pstryk_hour_next3_buy" \
  "{\"state\":\"${A[next3,buy]}\",\"attributes\":{\"unit_of_measurement\":\"PLN/kWh\",\"friendly_name\":\"Pstryk Hour +3 Buy Price\"}}"
ha_post "sensor.pstryk_hour_next2_index" \
  "{\"state\":\"${A[next2,index]}\",\"attributes\":{\"unit_of_measurement\":\"\",\"friendly_name\":\"Pstryk Hour +2 Price Index\",\"description\":\"Dense price rank for hour +2 (0=cheapest, 23=most expensive)\"}}"
ha_post "sensor.pstryk_hour_next3_index" \
  "{\"state\":\"${A[next3,index]}\",\"attributes\":{\"unit_of_measurement\":\"\",\"friendly_name\":\"Pstryk Hour +3 Price Index\",\"description\":\"Dense price rank for hour +3 (0=cheapest, 23=most expensive)\"}}"

# ── TODAY MIN / MAX / AVG BUY ────────────────────────────────────────────────
today_min_buy=$(echo "$BUY_JSON" | jq -r --arg day_start "$WARSAW_DAY_START_UTC" --arg day_end "$WARSAW_DAY_END_UTC" '
  [.frames[] | select(.start >= $day_start and .start <= $day_end) | .full_price | select(. != null)] |
  if length > 0 then min else null end
')
today_max_buy=$(echo "$BUY_JSON" | jq -r --arg day_start "$WARSAW_DAY_START_UTC" --arg day_end "$WARSAW_DAY_END_UTC" '
  [.frames[] | select(.start >= $day_start and .start <= $day_end) | .full_price | select(. != null)] |
  if length > 0 then max else null end
')
echo "Today min buy: $today_min_buy, max buy: $today_max_buy, avg buy: $today_avg_full"

ha_post "sensor.pstryk_today_min_buy" \
  "{\"state\":\"$today_min_buy\",\"attributes\":{\"unit_of_measurement\":\"PLN/kWh\",\"friendly_name\":\"Pstryk Today Min Buy Price\"}}"
ha_post "sensor.pstryk_today_max_buy" \
  "{\"state\":\"$today_max_buy\",\"attributes\":{\"unit_of_measurement\":\"PLN/kWh\",\"friendly_name\":\"Pstryk Today Max Buy Price\"}}"
ha_post "sensor.pstryk_today_avg_buy" \
  "{\"state\":\"$today_avg_full\",\"attributes\":{\"unit_of_measurement\":\"PLN/kWh\",\"friendly_name\":\"Pstryk Today Avg Buy Price\"}}"

# ── TODAY MIN / MAX / AVG SELL ───────────────────────────────────────────────
today_min_sell=$(echo "$SELL_JSON" | jq -r --arg day_start "$WARSAW_DAY_START_UTC" --arg day_end "$WARSAW_DAY_END_UTC" '
  [.frames[] | select(.start >= $day_start and .start <= $day_end) | .price_gross | select(. != null)] |
  if length > 0 then min else null end
')
today_max_sell=$(echo "$SELL_JSON" | jq -r --arg day_start "$WARSAW_DAY_START_UTC" --arg day_end "$WARSAW_DAY_END_UTC" '
  [.frames[] | select(.start >= $day_start and .start <= $day_end) | .price_gross | select(. != null)] |
  if length > 0 then max else null end
')
today_avg_sell=$(echo "$SELL_JSON" | jq -r --arg day_start "$WARSAW_DAY_START_UTC" --arg day_end "$WARSAW_DAY_END_UTC" '
  [.frames[] | select(.start >= $day_start and .start <= $day_end) | .price_gross | select(. != null)] |
  if length > 0 then (add / length) else null end
')
echo "Today min sell: $today_min_sell, max sell: $today_max_sell, avg sell: $today_avg_sell"

ha_post "sensor.pstryk_today_min_sell" \
  "{\"state\":\"$today_min_sell\",\"attributes\":{\"unit_of_measurement\":\"PLN/kWh\",\"friendly_name\":\"Pstryk Today Min Sell Price\"}}"
ha_post "sensor.pstryk_today_max_sell" \
  "{\"state\":\"$today_max_sell\",\"attributes\":{\"unit_of_measurement\":\"PLN/kWh\",\"friendly_name\":\"Pstryk Today Max Sell Price\"}}"
ha_post "sensor.pstryk_today_avg_sell" \
  "{\"state\":\"$today_avg_sell\",\"attributes\":{\"unit_of_measurement\":\"PLN/kWh\",\"friendly_name\":\"Pstryk Today Avg Sell Price\"}}"

# ── CURRENT HOUR DIFFS AND RELATIVES ─────────────────────────────────────────
# diff_min = current - min  (0 = jesteśmy na minimum; >0 = drożej niż minimum)
# diff_max = current - max  (0 = jesteśmy na maksimum; <0 = taniej niż maksimum)
# relative  = current / avg (1.0 = średnia; >1 = drożej; <1 = taniej)
current_buy="${A[current,buy]}"
current_sell="${A[current,sell]}"

calc() {
  # calc <a> <op(- or /)> <b>  — zwraca wynik lub "null" gdy któryś argument to null
  local a="$1" op="$2" b="$3"
  if [[ "$a" == "null" || -z "$a" || "$b" == "null" || -z "$b" ]]; then
    echo "null"; return
  fi
  if [[ "$op" == "/" ]]; then
    awk -v a="$a" -v b="$b" 'BEGIN { if (b != 0) printf "%.4f", a/b; else print "null" }'
  else
    awk -v a="$a" -v b="$b" 'BEGIN { printf "%.4f", a-b }'
  fi
}

buy_diff_min=$(calc  "$current_buy"  "-" "$today_min_buy")
buy_diff_max=$(calc  "$current_buy"  "-" "$today_max_buy")
sell_diff_min=$(calc "$current_sell" "-" "$today_min_sell")
sell_diff_max=$(calc "$current_sell" "-" "$today_max_sell")
buy_relative=$(calc  "$current_buy"  "/" "$today_avg_full")
sell_relative=$(calc "$current_sell" "/" "$today_avg_sell")

echo "Buy  diff_min=$buy_diff_min  diff_max=$buy_diff_max  relative=$buy_relative"
echo "Sell diff_min=$sell_diff_min diff_max=$sell_diff_max relative=$sell_relative"

ha_post "sensor.pstryk_current_buy_diff_min" \
  "{\"state\":\"$buy_diff_min\",\"attributes\":{\"unit_of_measurement\":\"PLN/kWh\",\"friendly_name\":\"Pstryk Buy Diff vs Min\",\"description\":\"Obecna cena zakupu minus minimum dnia (0=minimum, >0=drożej niż minimum)\"}}"
ha_post "sensor.pstryk_current_buy_diff_max" \
  "{\"state\":\"$buy_diff_max\",\"attributes\":{\"unit_of_measurement\":\"PLN/kWh\",\"friendly_name\":\"Pstryk Buy Diff vs Max\",\"description\":\"Obecna cena zakupu minus maksimum dnia (0=maksimum, <0=taniej niż maksimum)\"}}"
ha_post "sensor.pstryk_current_sell_diff_min" \
  "{\"state\":\"$sell_diff_min\",\"attributes\":{\"unit_of_measurement\":\"PLN/kWh\",\"friendly_name\":\"Pstryk Sell Diff vs Min\",\"description\":\"Obecna cena sprzedaży minus minimum dnia (0=minimum, >0=drożej niż minimum)\"}}"
ha_post "sensor.pstryk_current_sell_diff_max" \
  "{\"state\":\"$sell_diff_max\",\"attributes\":{\"unit_of_measurement\":\"PLN/kWh\",\"friendly_name\":\"Pstryk Sell Diff vs Max\",\"description\":\"Obecna cena sprzedaży minus maksimum dnia (0=maksimum, <0=taniej niż maksimum)\"}}"
ha_post "sensor.pstryk_buy_relative" \
  "{\"state\":\"$buy_relative\",\"attributes\":{\"unit_of_measurement\":\"\",\"friendly_name\":\"Pstryk Buy Relative to Avg\",\"description\":\"Obecna cena zakupu / średnia dnia (1.0=średnia, >1=drożej, <1=taniej)\"}}"
ha_post "sensor.pstryk_sell_relative" \
  "{\"state\":\"$sell_relative\",\"attributes\":{\"unit_of_measurement\":\"\",\"friendly_name\":\"Pstryk Sell Relative to Avg\",\"description\":\"Obecna cena sprzedaży / średnia dnia (1.0=średnia, >1=drożej, <1=taniej)\"}}"

# ── CHEAP HOURS COUNT ────────────────────────────────────────────────────────
cheap_hours_remaining=$(echo "$BUY_JSON" | jq -r --arg now "${HOUR[current]}" \
  --arg day_start "$WARSAW_DAY_START_UTC" --arg day_end "$WARSAW_DAY_END_UTC" '
  [.frames[] | select(.start >= $day_start and .start <= $day_end and .start > $now and .is_cheap == true)] |
  length
')
cheap_hours_today_total=$(echo "$BUY_JSON" | jq -r \
  --arg day_start "$WARSAW_DAY_START_UTC" --arg day_end "$WARSAW_DAY_END_UTC" '
  [.frames[] | select(.start >= $day_start and .start <= $day_end and .is_cheap == true)] |
  length
')
echo "Cheap hours remaining: $cheap_hours_remaining, total today: $cheap_hours_today_total"

ha_post "sensor.pstryk_cheap_hours_remaining" \
  "{\"state\":\"$cheap_hours_remaining\",\"attributes\":{\"unit_of_measurement\":\"h\",\"friendly_name\":\"Pstryk Cheap Hours Remaining Today\",\"description\":\"Number of cheap hours remaining today after the current hour\"}}"
ha_post "sensor.pstryk_cheap_hours_today_total" \
  "{\"state\":\"$cheap_hours_today_total\",\"attributes\":{\"unit_of_measurement\":\"h\",\"friendly_name\":\"Pstryk Cheap Hours Total Today\",\"description\":\"Total number of cheap hours today (Warsaw local day)\"}}"

# ── NEXT CHEAP BLOCK LENGTH ──────────────────────────────────────────────────
if [[ -n "$next_cheap_utc" && "$next_cheap_utc" != "none" && "$next_cheap_utc" != "null" ]]; then
  cheap_frame_list=$(echo "$BUY_JSON" | jq -r --arg start "$next_cheap_utc" '
    [.frames[] | select(.is_cheap == true and .start >= $start)] |
    sort_by(.start) | .[].start
  ')
  next_cheap_block_hours=0
  prev_epoch=""
  while IFS= read -r ts; do
    [[ -z "$ts" ]] && continue
    curr_epoch=$(date -d "$ts" +%s)
    if [[ -z "$prev_epoch" ]]; then
      next_cheap_block_hours=1
    else
      diff=$(( curr_epoch - prev_epoch ))
      if [[ $diff -eq 3600 ]]; then
        next_cheap_block_hours=$(( next_cheap_block_hours + 1 ))
      else
        break
      fi
    fi
    prev_epoch=$curr_epoch
  done <<< "$cheap_frame_list"
else
  next_cheap_block_hours="0"
fi
echo "Next cheap block length: $next_cheap_block_hours hours"

ha_post "sensor.pstryk_next_cheap_block_hours" \
  "{\"state\":\"$next_cheap_block_hours\",\"attributes\":{\"unit_of_measurement\":\"h\",\"friendly_name\":\"Pstryk Next Cheap Block Hours\",\"description\":\"Number of consecutive cheap hours starting from the next cheap hour\"}}"

# ── TOMORROW SUMMARY NOTIFICATION AT 21:00 WARSAW ────────────────────────────
CURRENT_WARSAW_HOUR=$(TZ='Europe/Warsaw' date +%H)
if [[ "$CURRENT_WARSAW_HOUR" == "21" ]]; then
  echo "=== SENDING TOMORROW SUMMARY (Warsaw 21:00) ==="

  # Top 3 cheapest hours for tomorrow: timestamp<TAB>full_price
  top3_raw=$(echo "$BUY_JSON" | jq -r --arg day_start "$WARSAW_TOMORROW_START_UTC" --arg day_end "$WARSAW_TOMORROW_END_UTC" '
    [.frames[] | select(.start >= $day_start and .start <= $day_end and .full_price != null)] |
    sort_by(.full_price) | .[0:3] |
    .[] | "\(.start)\t\(.full_price)"
  ')

  top3_parts=()
  while IFS=$'\t' read -r ts price; do
    [[ -z "$ts" ]] && continue
    wh=$(TZ='Europe/Warsaw' date -d "$ts" +%H:%M)
    formatted_price=$(printf "%.2f" "$price")
    top3_parts+=("${wh} (${formatted_price} PLN)")
  done <<< "$top3_raw"

  summary_top3=$(printf '%s, ' "${top3_parts[@]}")
  summary_top3="${summary_top3%, }"

  tomorrow_min_buy=$(echo "$BUY_JSON" | jq -r --arg day_start "$WARSAW_TOMORROW_START_UTC" --arg day_end "$WARSAW_TOMORROW_END_UTC" '
    [.frames[] | select(.start >= $day_start and .start <= $day_end) | .full_price | select(. != null)] |
    if length > 0 then min else null end
  ')
  tomorrow_max_buy=$(echo "$BUY_JSON" | jq -r --arg day_start "$WARSAW_TOMORROW_START_UTC" --arg day_end "$WARSAW_TOMORROW_END_UTC" '
    [.frames[] | select(.start >= $day_start and .start <= $day_end) | .full_price | select(. != null)] |
    if length > 0 then max else null end
  ')

  summary_min=$(printf "%.2f" "${tomorrow_min_buy:-0}")
  summary_max=$(printf "%.2f" "${tomorrow_max_buy:-0}")

  summary_msg="Jutro najtańsze godziny to: ${summary_top3}. Najniższa cena to: ${summary_min} PLN, najdroższa ${summary_max} PLN"

  # Negative price hours for tomorrow (full_price < 0) — append only when they exist
  negative_raw=$(echo "$BUY_JSON" | jq -r --arg day_start "$WARSAW_TOMORROW_START_UTC" --arg day_end "$WARSAW_TOMORROW_END_UTC" '
    [.frames[] | select(.start >= $day_start and .start <= $day_end and .full_price != null and .full_price < 0)] |
    sort_by(.start) | .[] | .start
  ')

  if [[ -n "$negative_raw" ]]; then
    neg_timestamps=()
    while IFS= read -r ts; do
      [[ -z "$ts" ]] && continue
      neg_timestamps+=("$ts")
    done <<< "$negative_raw"

    neg_first_wh=$(TZ='Europe/Warsaw' date -d "${neg_timestamps[0]}" +%H:%M)
    neg_last_wh=$(TZ='Europe/Warsaw' date -d "${neg_timestamps[-1]}" +%H:%M)
    neg_count=${#neg_timestamps[@]}

    if [[ $neg_count -eq 1 ]]; then
      summary_msg="${summary_msg} Uwaga: godzina z ceną ujemną: ${neg_first_wh}."
    else
      summary_msg="${summary_msg} Uwaga: ${neg_count} godziny z ceną ujemną: ${neg_first_wh}–${neg_last_wh}."
    fi
  fi

  echo "Tomorrow summary: $summary_msg"

  # Send as persistent notification
  daily_summary_response=$(curl -s -X POST \
    -H "Authorization: Bearer $HA_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg title "Ceny energii na jutro" --arg msg "$summary_msg" '{title: $title, message: $msg}')" \
    "$HA_IP/api/services/persistent_notification/create")
  echo "Tomorrow summary notification response: $daily_summary_response"

  # Send as sensor (for automations / phone notifications)
  ha_post "sensor.pstryk_daily_summary" \
    "$(jq -n --arg state "$summary_msg" '{state: $state, attributes: {friendly_name: "Pstryk Daily Summary", description: "Tomorrow energy price summary sent at 21:00 Warsaw time"}}')"
fi