#!/bin/bash
#
# Jarosław Zjawiński - kontakt@zjawa.it
#
# Example usage:
#   ./ha.sh "PSTRYK_API_TOKEN" "HA_IP" "HA_TOKEN"
#   ./ha.sh "JhbGciOiJIUzI1NiIsInR5cCI6IkpXV" "http://homeAssistant.local:8123" "JXXD0WsJSfTzac[...]YUkIYJywndt1rqo"
# You can add this script to your crontab to run it every hour:
#   1 * * * * /path/to/ha.sh "JhbGciOiJIUzI1NiIsInR5cCI6IkpXV" "http://homeAssistant.local:8123" "JXXD0WsJSfTzac[...]YUkIYJywndt1rqo"
#
# ────────────────────────────────────────────────────────────────────────────────
#
# This script interacts with the Pstryk API and Home Assistant to fetch energy pricing data
# and update Home Assistant sensors with the retrieved information. It performs the following tasks:
#
# 1. Configuration:
#    - Accepts three arguments: API_TOKEN, HA_IP, and HA_TOKEN.
#    - Defines API_BASE, START, and STOP for API requests.
#    - Sets up a dictionary (HOUR) to store timestamps for the current and next hour.
#
# 2. Helper Functions:
#    - get_json(endpoint): Fetches JSON data from a specified API endpoint.
#    - jq_field(json, timestamp, field): Extracts a specific field from the JSON data for a given timestamp.
#    - ha_post(entity_id, json_body): Sends a POST request to update a Home Assistant sensor with the provided JSON body.
#
# 3. Data Retrieval:
#    - Fetches pricing data for buying and selling energy using the get_json function.
#    - Stores the data in a 2D associative array (A) for the current and next hour.
#
# 4. Data Processing:
#    - Extracts specific fields (price_gross, is_cheap, is_expensive) from the JSON data for each timestamp.
#    - Populates the associative array (A) with the extracted values.
#
# 5. Home Assistant Updates:
#    - Updates Home Assistant sensors for the current and next hour with the retrieved pricing and flag data.
#    - Posts the cheapest price comparison for the current hour to a specific Home Assistant sensor.
#
# Notes:
# - The script uses `set -euo pipefail` to ensure robust error handling.
# - The `jq` tool is used for JSON parsing.
# - The script assumes that the API and Home Assistant endpoints are accessible and that the provided tokens are valid.
# ────────────────────────────────────────────────────────────────────────────────

set -euo pipefail               # stop on errors, unset vars, or failed pipelines

# ── CONFIG ──────────────────────────────────────────────────────────────────────
API_TOKEN=$1
HA_IP=$2
HA_TOKEN=$3

API_BASE="https://api.pstryk.pl/integrations"
START=$(date -u +"%Y-%m-%dT00")
STOP=$(date  -u -d '+24 hours' +"%Y-%m-%dT%H")

echo $START
echo $STOP
echo "---"

# first‑dimension labels → timestamps
declare -A HOUR=(
  [current]="$(date -u +"%Y-%m-%dT%H:00:00+00:00")"
  [next]="$(date -u -d '+1 hour' +"%Y-%m-%dT%H:00:00+00:00")"
)
# ────────────────────────────────────────────────────────────────────────────────

# ── CACHE ──────────────────────────────────────────────────────────────────────
CACHE_FILE="/var/tmp/pstryk_cache.txt"

# --- helpers -------------------------------------------------------------------
get_json() {      # hit one endpoint once and return its JSON, with cache fallback
  local endpoint=$1
  local cache_key="${endpoint}_$(date -u +"%Y-%m-%dT%H")"
  local cache_entry

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
  echo "API Response for $endpoint: $response" >&2

  if [[ -n "$response" && "$response" != "null" && $(jq -e .frames <<<"$response" 2>/dev/null) ]]; then
    # Save to cache
    jq -n --arg key "$cache_key" --argjson val "$response" \
      '{($key): $val}' > tmp_cache_entry.json
    # Remove old entry for this key
    grep -v "^$cache_key|" "$CACHE_FILE" 2>/dev/null > tmp_cache.txt || true
    # Append new entry
    echo "$cache_key|$(cat tmp_cache_entry.json)" >> tmp_cache.txt
    mv tmp_cache.txt "$CACHE_FILE"
    rm -f tmp_cache_entry.json
    echo "$response"
  else
    # Fallback to cache
    cache_entry=$(grep "^$cache_key|" "$CACHE_FILE" 2>/dev/null | tail -n1 | cut -d'|' -f2-)
    if [[ -n "$cache_entry" ]]; then
      # Extract the JSON value from the cache entry
      echo "$cache_entry" | jq -r ".[\"$cache_key\"]" 2>/dev/null || echo "{}"
    else
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

# fill a 2‑D associative array
declare -A A
for row in current next; do
  ts=${HOUR[$row]}

  A[$row,buy]=$( jq_field "$BUY_JSON"  "$ts" price_gross )
  A[$row,sell]=$( jq_field "$SELL_JSON" "$ts" price_gross )
  A[$row,is_cheap]=$( jq_field "$BUY_JSON"  "$ts" is_cheap )
  A[$row,is_expensive]=$( jq_field "$BUY_JSON"  "$ts" is_expensive )
done

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

# Debug the cheapest calculation
echo "=== DEBUGGING CHEAPEST CALCULATION ==="
echo "Current time: $(date -u +%Y-%m-%dT%H:00:00+00:00)"
echo "Today date: $(date -u +%Y-%m-%d)"

# Test the individual parts
min_price=$(echo $BUY_JSON | jq -r --arg today "$(date -u +%Y-%m-%d)" '
  .frames | map(select(.start | startswith($today))) | min_by(.price_gross).price_gross
')
echo "Minimum price today: $min_price"

current_price=$(echo $BUY_JSON | jq -r --arg now "$(date -u +%Y-%m-%dT%H:00:00+00:00)" '
  .frames[] | select(.start==$now).price_gross
')
echo "Current hour price: $current_price"

# Show frames for today
echo "Frames for today:"
echo $BUY_JSON | jq -r --arg today "$(date -u +%Y-%m-%d)" '
  .frames[] | select(.start | startswith($today)) | .start + " -> " + (.price_gross | tostring)
' | head -10

# Simplified version to avoid parsing errors
current_cheapest_result=$(echo "$BUY_JSON" | jq -r --arg now "$(date -u +%Y-%m-%dT%H:00:00+00:00)" \
   --arg today "$(date -u +%Y-%m-%d)" '
  if (.frames | length) > 0 then
    (.frames | map(select(.start | startswith($today))) | min_by(.price_gross).price_gross) as $min_price |
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
echo "Current time: $(date -u +%Y-%m-%dT%H:00:00+00:00)"
echo "Today date: $(date -u +%Y-%m-%d)"

ha_post "sensor.pstryk_current_cheapest" \
  "{\"state\":\"$current_cheapest_result\"}"

# Debug the next cheapest calculation
# Simplified version to avoid parsing errors  
next_cheapest_result=$(echo "$BUY_JSON" | jq -r --arg now "$(date -u -d '+1 hour' +%Y-%m-%dT%H:00:00+00:00)" \
   --arg today "$(date -u +%Y-%m-%d)" '
  if (.frames | length) > 0 then
    (.frames | map(select(.start | startswith($today))) | min_by(.price_gross).price_gross) as $min_price |
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
echo "Next time: $(date -u -d '+1 hour' +%Y-%m-%dT%H:00:00+00:00)"

ha_post "sensor.pstryk_next_cheapest" \
  "{\"state\":\"$next_cheapest_result\"}"