#!/bin/bash
#
# Jarosław Zjawiński - kontakt@zjawa.it
#
# Example usage:
#   ./ha.sh "PSTRYK_API_TOKEN" "HA_IP" "HA_TOKEN"
#   ./ha.sh "JhbGciOiJIUzI1NiIsInR5cCI6IkpXV" "http://homeAssistant.local:8123" "JXXD0WsJSfTzac[...]YUkIYJywndt1rqo" 
# You can add this script to your crontab to run it every hour:
#   1 * * * * /path/to/ha.sh "http://homeAssistant.local:8123" "JXXD0WsJSfTzac[...]YUkIYJywndt1rqo"
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
START=$(date -u +"%Y-%m-%dT%H")
STOP=$(date  -u -d '+24 hours' +"%Y-%m-%dT%H")

# first‑dimension labels → timestamps
declare -A HOUR=(
  [current]="$(date -u +"%Y-%m-%dT%H:00:00+00:00")"
  [next]="$(date -u -d '+1 hour' +"%Y-%m-%dT%H:00:00+00:00")"
)
# ────────────────────────────────────────────────────────────────────────────────

# --- helpers -------------------------------------------------------------------
get_json() {      # hit one endpoint once and return its JSON
  local endpoint=$1
  curl -sG \
       -H "accept: application/json" \
       -H "Authorization: $API_TOKEN" \
       --data-urlencode resolution=hour \
       --data-urlencode window_start="$START" \
       --data-urlencode window_end="$STOP" \
       "$API_BASE/$endpoint/"
}

jq_field() {      # jq_field <json> <timestamp> <field>
  jq -r --arg t "$2" ".frames[] | select(.start==\$t) | .$3" <<<"$1"
}

ha_post() {       # ha_post <entity_id> <json_body>
  curl -s -o /dev/null -X POST \
       -H "Authorization: Bearer $HA_TOKEN" \
       -H "Content-Type: application/json" \
       -d "$2" \
       "$HA_IP/api/states/$1"
}
# --------------------------------------------------------------------------------

# download once, reuse many times
BUY_JSON=$( get_json pricing )
SELL_JSON=$( get_json prosumer-pricing )

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

ha_post "sensor.pstryk_current_cheapest" \ 
  "{\"state\":\"$(echo $BUY_JSON | jq --arg now "$(date -u +%Y-%m-%dT%H:00:00+00:00)" \
   --arg today "$(date -u +%Y-%m-%d)" '
  .frames as $f
  # lowest gross price today ───────────────────────────────
  | ($f | map(select(.start | startswith($today)))
          | min_by(.price_gross).price_gross)                as $min
  # the frame for the current hour ───────────────────────
  | ($f[] | select(.start==$now).price_gross)               as $cur
  # compare and return literal true/false ────────────────
  | ($cur==$min)
')\"}"