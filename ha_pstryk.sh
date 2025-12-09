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
START=$(date -u +"%Y-%m-%dT00:00:00+00:00")
STOP=$(date -u +"%Y-%m-%dT23:59:59+00:00")

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
  
  # Get current Warsaw hour (for API fetch restriction)
  local warsaw_hour=$(TZ='Europe/Warsaw' date +%H | sed 's/^0//')
  
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

  # Before 14:00 Warsaw time, prefer cache over API (next day prices not available yet)
  if [[ $warsaw_hour -lt 14 ]]; then
    echo "Before 14:00 Warsaw time ($warsaw_hour:xx) - preferring cache over API" >&2
    # Try to use any available cache first
    local latest_cache=$(grep "^${endpoint}_" "$CACHE_FILE" 2>/dev/null | tail -n1)
    if [[ -n "$latest_cache" ]]; then
      local cache_key_found=$(echo "$latest_cache" | cut -d'|' -f1)
      local cache_data_encoded=$(echo "$latest_cache" | cut -d'|' -f2-)
      local cache_data=$(echo "$cache_data_encoded" | base64 -d 2>/dev/null || echo "$cache_data_encoded")
      
      if echo "$cache_data" | jq -e '.frames' >/dev/null 2>&1; then
        echo "Using cached data from $cache_key_found (before 14:00 Warsaw)" >&2
        echo "$cache_data"
        return
      fi
    fi
    echo "No valid cache found before 14:00, will try API anyway" >&2
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
  echo $response > /tmp/pstryk_last_api_response.json

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
      grep -v "^$cache_key|" "$CACHE_FILE" 2>/dev/null > tmp_cache.txt || true
    else
      touch tmp_cache.txt
    fi
    echo "$cache_key|$cache_data_encoded" >> tmp_cache.txt
    mv tmp_cache.txt "$CACHE_FILE"

    # Save timestamp
    local current_timestamp=$(date +%s)
    if [[ -f "$CACHE_TIMESTAMP_FILE" ]]; then
      grep -v "^$cache_key|" "$CACHE_TIMESTAMP_FILE" 2>/dev/null > tmp_timestamps.txt || true
    else
      touch tmp_timestamps.txt
    fi
    echo "$cache_key|$current_timestamp" >> tmp_timestamps.txt
    mv tmp_timestamps.txt "$CACHE_TIMESTAMP_FILE"

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
        grep -v "^${endpoint}_.*|{$" "$CACHE_FILE" 2>/dev/null > tmp_clean_cache.txt || touch tmp_clean_cache.txt
        mv tmp_clean_cache.txt "$CACHE_FILE"
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
    jq -r --arg t "$timestamp" ".frames[] | select(.start==\$t) | .$field" <<<"$json"
  else
    echo "null"
  fi
}

ha_post() {       # ha_post <entity_id> <json_body>
  echo "Posting to HA: $1 -> $2"
  local response=$(curl -s -X POST \
       -H "Authorization: Bearer $HA_TOKEN" \
       -H "Content-Type: application/json" \
       -d "$2" \
       "$HA_IP/api/states/$1")
  echo "HA Response: $response"
}
# --------------------------------------------------------------------------------

# download once, reuse many times
BUY_JSON=$( get_json pricing )
SELL_JSON=$( get_json prosumer-pricing )

# Debug: Check if we got valid JSON
echo "BUY_JSON length: $(echo "$BUY_JSON" | wc -c)"
echo "SELL_JSON length: $(echo "$SELL_JSON" | wc -c)"
echo "BUY_JSON has frames: $(echo "$BUY_JSON" | jq -e 'has("frames")' 2>/dev/null || echo "false")"
echo "SELL_JSON has frames: $(echo "$SELL_JSON" | jq -e 'has("frames")' 2>/dev/null || echo "false")"

# Get current and next hour from API's is_live flag (most reliable method)
# The API marks the current hour with is_live:true
HOUR[current]=$(echo "$BUY_JSON" | jq -r '.frames[] | select(.is_live == true) | .start' 2>/dev/null || echo "")
if [[ -z "${HOUR[current]}" ]]; then
  echo "WARNING: No is_live frame found in API response, falling back to UTC calculation" >&2
  HOUR[current]="$(TZ=UTC date +"%Y-%m-%dT%H:00:00+00:00")"
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

  A[$row,buy]=$( jq_field "$BUY_JSON"  "$ts" price_gross )
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

echo "Warsaw today: $WARSAW_TODAY"
echo "Warsaw day start in UTC: $WARSAW_DAY_START_UTC"
echo "Warsaw day end in UTC: $WARSAW_DAY_END_UTC"

current_index=$(echo "$BUY_JSON" | jq -r --arg now "${HOUR[current]}" \
   --arg day_start "$WARSAW_DAY_START_UTC" --arg day_end "$WARSAW_DAY_END_UTC" '
  if (.frames | length) > 0 then
    # Get all frames for Warsaw local day (from day_start to day_end inclusive)
    (.frames | map(select(
      .start >= $day_start and .start <= $day_end
    )) | sort_by(.price_gross)) as $sorted_frames |
    # Find the index of current hour in the sorted array
    ($sorted_frames | map(.start) | index($now)) as $index |
    if $index != null then
      $index
    else
      "unknown"
    end
  else
    "no_frames"
  end
')

echo "Current hour index (0=cheapest, 23=most expensive): '$current_index'"
A[current,index]=$current_index

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
WARSAW_OFFSET=$(( ($(TZ='Europe/Warsaw' date +%H) - $(TZ=UTC date +%H) + 24) % 24 ))
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
        "{\"state\":\"${A[current,index]}\",\"attributes\":{\"unit_of_measurement\":\"\",\"friendly_name\":\"Pstryk Current Hour Price Index\",\"description\":\"Price ranking for current hour (0=cheapest, 23=most expensive)\"}}"

# Debug the cheapest calculation
echo "=== DEBUGGING CHEAPEST CALCULATION ==="
echo "Current time (UTC): ${HOUR[current]}"
echo "Warsaw day: $WARSAW_TODAY"

# Test the individual parts
min_price=$(echo $BUY_JSON | jq -r --arg day_start "$WARSAW_DAY_START_UTC" --arg day_end "$WARSAW_DAY_END_UTC" '
  .frames | map(select(
    .start >= $day_start and .start <= $day_end
  )) | min_by(.price_gross).price_gross
')
echo "Minimum price today (Warsaw): $min_price"

current_price=$(echo $BUY_JSON | jq -r --arg now "${HOUR[current]}" '
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