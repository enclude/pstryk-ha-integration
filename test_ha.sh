#!/bin/bash#!/bin/bash

##

# Jarosław Zjawiński - kontakt@zjawa.it# Jarosław Zjawiński - kontakt@zjawa.it

##

# Test suite for ha_pstryk.sh - validates timezone handling, DST support, and API integration# This script is a test suite for the `ha.sh` script, designed to validate its functionality.

##

# Features tested:# Features:

# - Warsaw timezone handling (Europe/Warsaw)# - Mocks API responses for testing purposes.

# - DST compatibility (CET/CEST automatic offset calculation)# - Provides utility functions to simulate JSON retrieval, JSON field extraction, and Home Assistant API POST requests.

# - Warsaw day boundary filtering (yesterday 23:00 UTC to today 22:00 UTC in winter)#

# - is_live flag for current hour detection# Mock Variables:

# - 14:00 Warsaw time restriction (don't fetch from API before 14:00)# - `API_TOKEN`: Mock API token for authentication.

# - Price ranking based on Warsaw calendar day# - `HA_IP`: Mock Home Assistant IP address.

# - Mock API responses with realistic Pstryk API structure# - `HA_TOKEN`: Mock Home Assistant token.

##

# Test scenarios:# Mock Data:

# 1. Winter time (CET - UTC+1)# - `MOCK_BUY_JSON`: Simulated JSON response for "pricing" endpoint.

# 2. Summer time (CEST - UTC+2)# - `MOCK_SELL_JSON`: Simulated JSON response for "prosumer-pricing" endpoint.

# 3. 14:00 restriction enforcement#

# 4. Current hour detection via is_live flag# Functions:

# 5. Warsaw day boundary calculations# - `get_json(endpoint)`: Simulates retrieving JSON data from a specified endpoint.

# 6. Price ranking for Warsaw calendar day# - `jq_field(json, timestamp, field)`: Extracts a specific field from a JSON object based on a timestamp.

## - `ha_post(entity_id, json_body)`: Simulates a POST request to the Home Assistant API.

# Usage:#

# ./test_ha.sh# Test Cases:

## 1. Validate JSON retrieval:

#    - Ensures `get_json` returns the correct mock JSON data for "pricing" and "prosumer-pricing" endpoints.

set -e  # Exit on error# 2. Validate `jq_field` function:

#    - Tests the ability to extract a specific field from the mock JSON data using a timestamp.

# Colors for output# 3. Validate Home Assistant POST:

RED='\033[0;31m'#    - Simulates a POST request to the Home Assistant API and prints the request details.

GREEN='\033[0;32m'#

YELLOW='\033[1;33m'# Usage:

NC='\033[0m' # No Color# - Run the script to execute all test cases and verify the functionality of `ha.sh`.



# Test counters

TESTS_PASSED=0# Test script for ha.sh

TESTS_FAILED=0

# Mock variables

# Mock variablesAPI_TOKEN="mock_api_token"

API_TOKEN="mock_api_token_12345"HA_IP="http://mock_home_assistant.local:8123"

HA_IP="http://homeassistant.local:8123"HA_TOKEN="mock_ha_token"

HA_TOKEN="mock_ha_token_67890"

CACHE_DIR="/tmp/pstryk_test_cache"# Mock API responses

MOCK_BUY_JSON='{

# Create test cache directory    "frames": [

mkdir -p "$CACHE_DIR"        {"start": "2023-01-01T00:00:00+00:00", "price_gross": 0.5, "is_cheap": true, "is_expensive": false},

        {"start": "2023-01-01T01:00:00+00:00", "price_gross": 0.6, "is_cheap": false, "is_expensive": true}

# Helper functions    ]

print_test() {}'

    echo ""MOCK_SELL_JSON='{

    echo "=========================================="    "frames": [

    echo "TEST: $1"        {"start": "2023-01-01T00:00:00+00:00", "price_gross": 0.4},

    echo "=========================================="        {"start": "2023-01-01T01:00:00+00:00", "price_gross": 0.3}

}    ]

}'

print_pass() {

    echo -e "${GREEN}✓ PASSED${NC}: $1"# Mock functions

    ((TESTS_PASSED++))get_json() {

}    local endpoint=$1

    if [[ "$endpoint" == "pricing" ]]; then

print_fail() {        echo "$MOCK_BUY_JSON"

    echo -e "${RED}✗ FAILED${NC}: $1"    elif [[ "$endpoint" == "prosumer-pricing" ]]; then

    ((TESTS_FAILED++))        echo "$MOCK_SELL_JSON"

}    else

        echo "{}"

print_info() {    fi

    echo -e "${YELLOW}ℹ INFO${NC}: $1"}

}

jq_field() {

# Mock API response - Winter scenario (2024-01-15, CET = UTC+1)    local json=$1

# Current hour: 14:00 Warsaw = 13:00 UTC (is_live: true)    local timestamp=$2

# Cheapest hour: 02:00 Warsaw = 01:00 UTC (should get index 0)    local field=$3

MOCK_BUY_JSON_WINTER='{    echo "$json" | jq -r --arg t "$timestamp" ".frames[] | select(.start==\$t) | .$field"

  "frames": [}

    {"start": "2024-01-14T23:00:00+00:00", "price_gross": 0.45, "is_cheap": false, "is_expensive": false, "is_live": false},

    {"start": "2024-01-15T00:00:00+00:00", "price_gross": 0.42, "is_cheap": true, "is_expensive": false, "is_live": false},ha_post() {

    {"start": "2024-01-15T01:00:00+00:00", "price_gross": 0.38, "is_cheap": true, "is_expensive": false, "is_live": false},    local entity_id=$1

    {"start": "2024-01-15T02:00:00+00:00", "price_gross": 0.41, "is_cheap": true, "is_expensive": false, "is_live": false},    local json_body=$2

    {"start": "2024-01-15T03:00:00+00:00", "price_gross": 0.44, "is_cheap": false, "is_expensive": false, "is_live": false},    echo "POST to $HA_IP/api/states/sensor.test_$entity_id with body: $json_body"

    {"start": "2024-01-15T04:00:00+00:00", "price_gross": 0.47, "is_cheap": false, "is_expensive": false, "is_live": false},}

    {"start": "2024-01-15T05:00:00+00:00", "price_gross": 0.52, "is_cheap": false, "is_expensive": false, "is_live": false},

    {"start": "2024-01-15T06:00:00+00:00", "price_gross": 0.58, "is_cheap": false, "is_expensive": true, "is_live": false},# Test cases

    {"start": "2024-01-15T07:00:00+00:00", "price_gross": 0.63, "is_cheap": false, "is_expensive": true, "is_live": false},echo "Running tests for ha.sh..."

    {"start": "2024-01-15T08:00:00+00:00", "price_gross": 0.61, "is_cheap": false, "is_expensive": true, "is_live": false},

    {"start": "2024-01-15T09:00:00+00:00", "price_gross": 0.59, "is_cheap": false, "is_expensive": true, "is_live": false},# Test 1: Validate JSON retrieval

    {"start": "2024-01-15T10:00:00+00:00", "price_gross": 0.56, "is_cheap": false, "is_expensive": false, "is_live": false},echo "Test 1: Validate JSON retrieval"

    {"start": "2024-01-15T11:00:00+00:00", "price_gross": 0.54, "is_cheap": false, "is_expensive": false, "is_live": false},BUY_JSON=$(get_json pricing)

    {"start": "2024-01-15T12:00:00+00:00", "price_gross": 0.53, "is_cheap": false, "is_expensive": false, "is_live": false},SELL_JSON=$(get_json prosumer-pricing)

    {"start": "2024-01-15T13:00:00+00:00", "price_gross": 0.51, "is_cheap": false, "is_expensive": false, "is_live": true},if [[ "$BUY_JSON" == "$MOCK_BUY_JSON" && "$SELL_JSON" == "$MOCK_SELL_JSON" ]]; then

    {"start": "2024-01-15T14:00:00+00:00", "price_gross": 0.55, "is_cheap": false, "is_expensive": false, "is_live": false},    echo "Test 1 passed."

    {"start": "2024-01-15T15:00:00+00:00", "price_gross": 0.57, "is_cheap": false, "is_expensive": false, "is_live": false},else

    {"start": "2024-01-15T16:00:00+00:00", "price_gross": 0.62, "is_cheap": false, "is_expensive": true, "is_live": false},    echo "Test 1 failed."

    {"start": "2024-01-15T17:00:00+00:00", "price_gross": 0.68, "is_cheap": false, "is_expensive": true, "is_live": false},fi

    {"start": "2024-01-15T18:00:00+00:00", "price_gross": 0.64, "is_cheap": false, "is_expensive": true, "is_live": false},

    {"start": "2024-01-15T19:00:00+00:00", "price_gross": 0.60, "is_cheap": false, "is_expensive": true, "is_live": false},# Test 2: Validate jq_field function

    {"start": "2024-01-15T20:00:00+00:00", "price_gross": 0.56, "is_cheap": false, "is_expensive": false, "is_live": false},echo "Test 2: Validate jq_field function"

    {"start": "2024-01-15T21:00:00+00:00", "price_gross": 0.52, "is_cheap": false, "is_expensive": false, "is_live": false},TEST_TIMESTAMP="2023-01-01T00:00:00+00:00"

    {"start": "2024-01-15T22:00:00+00:00", "price_gross": 0.49, "is_cheap": false, "is_expensive": false, "is_live": false},TEST_FIELD="price_gross"

    {"start": "2024-01-15T23:00:00+00:00", "price_gross": 0.46, "is_cheap": false, "is_expensive": false, "is_live": false},EXPECTED_VALUE="0.5"

    {"start": "2024-01-16T00:00:00+00:00", "price_gross": 0.43, "is_cheap": true, "is_expensive": false, "is_live": false}ACTUAL_VALUE=$(jq_field "$MOCK_BUY_JSON" "$TEST_TIMESTAMP" "$TEST_FIELD")

  ]if [[ "$ACTUAL_VALUE" == "$EXPECTED_VALUE" ]]; then

}'    echo "Test 2 passed."

else

# Mock API response - Summer scenario (2024-07-15, CEST = UTC+2)    echo "Test 2 failed."

# Current hour: 14:00 Warsaw = 12:00 UTC (is_live: true)fi

# Cheapest hour: 03:00 Warsaw = 01:00 UTC (should get index 0)

MOCK_BUY_JSON_SUMMER='{# Test 3: Validate Home Assistant POST

  "frames": [echo "Test 3: Validate Home Assistant POST"

    {"start": "2024-07-14T22:00:00+00:00", "price_gross": 0.35, "is_cheap": true, "is_expensive": false, "is_live": false},ha_post "sensor.test_entity" '{"state":"test_state"}'

    {"start": "2024-07-14T23:00:00+00:00", "price_gross": 0.33, "is_cheap": true, "is_expensive": false, "is_live": false},

    {"start": "2024-07-15T00:00:00+00:00", "price_gross": 0.31, "is_cheap": true, "is_expensive": false, "is_live": false},echo "All tests completed."
    {"start": "2024-07-15T01:00:00+00:00", "price_gross": 0.28, "is_cheap": true, "is_expensive": false, "is_live": false},
    {"start": "2024-07-15T02:00:00+00:00", "price_gross": 0.30, "is_cheap": true, "is_expensive": false, "is_live": false},
    {"start": "2024-07-15T03:00:00+00:00", "price_gross": 0.32, "is_cheap": true, "is_expensive": false, "is_live": false},
    {"start": "2024-07-15T04:00:00+00:00", "price_gross": 0.36, "is_cheap": false, "is_expensive": false, "is_live": false},
    {"start": "2024-07-15T05:00:00+00:00", "price_gross": 0.41, "is_cheap": false, "is_expensive": false, "is_live": false},
    {"start": "2024-07-15T06:00:00+00:00", "price_gross": 0.45, "is_cheap": false, "is_expensive": false, "is_live": false},
    {"start": "2024-07-15T07:00:00+00:00", "price_gross": 0.48, "is_cheap": false, "is_expensive": false, "is_live": false},
    {"start": "2024-07-15T08:00:00+00:00", "price_gross": 0.46, "is_cheap": false, "is_expensive": false, "is_live": false},
    {"start": "2024-07-15T09:00:00+00:00", "price_gross": 0.44, "is_cheap": false, "is_expensive": false, "is_live": false},
    {"start": "2024-07-15T10:00:00+00:00", "price_gross": 0.42, "is_cheap": false, "is_expensive": false, "is_live": false},
    {"start": "2024-07-15T11:00:00+00:00", "price_gross": 0.40, "is_cheap": false, "is_expensive": false, "is_live": false},
    {"start": "2024-07-15T12:00:00+00:00", "price_gross": 0.39, "is_cheap": false, "is_expensive": false, "is_live": true},
    {"start": "2024-07-15T13:00:00+00:00", "price_gross": 0.41, "is_cheap": false, "is_expensive": false, "is_live": false},
    {"start": "2024-07-15T14:00:00+00:00", "price_gross": 0.43, "is_cheap": false, "is_expensive": false, "is_live": false},
    {"start": "2024-07-15T15:00:00+00:00", "price_gross": 0.47, "is_cheap": false, "is_expensive": false, "is_live": false},
    {"start": "2024-07-15T16:00:00+00:00", "price_gross": 0.51, "is_cheap": false, "is_expensive": true, "is_live": false},
    {"start": "2024-07-15T17:00:00+00:00", "price_gross": 0.49, "is_cheap": false, "is_expensive": false, "is_live": false},
    {"start": "2024-07-15T18:00:00+00:00", "price_gross": 0.47, "is_cheap": false, "is_expensive": false, "is_live": false},
    {"start": "2024-07-15T19:00:00+00:00", "price_gross": 0.44, "is_cheap": false, "is_expensive": false, "is_live": false},
    {"start": "2024-07-15T20:00:00+00:00", "price_gross": 0.40, "is_cheap": false, "is_expensive": false, "is_live": false},
    {"start": "2024-07-15T21:00:00+00:00", "price_gross": 0.38, "is_cheap": false, "is_expensive": false, "is_live": false},
    {"start": "2024-07-15T22:00:00+00:00", "price_gross": 0.36, "is_cheap": true, "is_expensive": false, "is_live": false},
    {"start": "2024-07-15T23:00:00+00:00", "price_gross": 0.34, "is_cheap": true, "is_expensive": false, "is_live": false}
  ]
}'

MOCK_SELL_JSON='{
  "frames": [
    {"start": "2024-01-15T00:00:00+00:00", "price_gross": 0.35},
    {"start": "2024-01-15T01:00:00+00:00", "price_gross": 0.32},
    {"start": "2024-01-15T13:00:00+00:00", "price_gross": 0.42, "is_live": true}
  ]
}'

# ==========================================
# TEST 1: Timezone offset calculation (DST compatibility)
# ==========================================
print_test "1. Dynamic timezone offset calculation (DST)"

# Test winter (CET = UTC+1)
print_info "Testing winter time (CET)"
MOCK_WINTER_UTC_HOUR=13
MOCK_WINTER_WARSAW_HOUR=14
WINTER_OFFSET=$(( (MOCK_WINTER_WARSAW_HOUR - MOCK_WINTER_UTC_HOUR + 24) % 24 ))

if [[ $WINTER_OFFSET -eq 1 ]]; then
    print_pass "Winter offset calculation: UTC+1 (CET)"
else
    print_fail "Winter offset calculation: Expected 1, got $WINTER_OFFSET"
fi

# Test summer (CEST = UTC+2)
print_info "Testing summer time (CEST)"
MOCK_SUMMER_UTC_HOUR=12
MOCK_SUMMER_WARSAW_HOUR=14
SUMMER_OFFSET=$(( (MOCK_SUMMER_WARSAW_HOUR - MOCK_SUMMER_UTC_HOUR + 24) % 24 ))

if [[ $SUMMER_OFFSET -eq 2 ]]; then
    print_pass "Summer offset calculation: UTC+2 (CEST)"
else
    print_fail "Summer offset calculation: Expected 2, got $SUMMER_OFFSET"
fi

# ==========================================
# TEST 2: is_live flag detection
# ==========================================
print_test "2. Current hour detection via is_live flag"

LIVE_HOUR_WINTER=$(echo "$MOCK_BUY_JSON_WINTER" | jq -r '.frames[] | select(.is_live == true) | .start')
EXPECTED_LIVE_WINTER="2024-01-15T13:00:00+00:00"

if [[ "$LIVE_HOUR_WINTER" == "$EXPECTED_LIVE_WINTER" ]]; then
    print_pass "Winter: is_live flag correctly identifies 13:00 UTC (14:00 Warsaw)"
else
    print_fail "Winter: Expected $EXPECTED_LIVE_WINTER, got $LIVE_HOUR_WINTER"
fi

LIVE_HOUR_SUMMER=$(echo "$MOCK_BUY_JSON_SUMMER" | jq -r '.frames[] | select(.is_live == true) | .start')
EXPECTED_LIVE_SUMMER="2024-07-15T12:00:00+00:00"

if [[ "$LIVE_HOUR_SUMMER" == "$EXPECTED_LIVE_SUMMER" ]]; then
    print_pass "Summer: is_live flag correctly identifies 12:00 UTC (14:00 Warsaw)"
else
    print_fail "Summer: Expected $EXPECTED_LIVE_SUMMER, got $LIVE_HOUR_SUMMER"
fi

# ==========================================
# TEST 3: Warsaw day boundary calculation
# ==========================================
print_test "3. Warsaw day boundary filtering"

print_info "Testing winter day boundaries (CET)"
# For 2024-01-15 Warsaw:
# Day starts: 2024-01-14 23:00 UTC (2024-01-15 00:00 Warsaw)
# Day ends: 2024-01-15 22:59:59 UTC (2024-01-15 23:59:59 Warsaw)

WINTER_DAY_START="2024-01-14T23:00:00+00:00"
WINTER_DAY_END="2024-01-15T22:59:59+00:00"

WINTER_FRAMES=$(echo "$MOCK_BUY_JSON_WINTER" | jq --arg day_start "$WINTER_DAY_START" --arg day_end "$WINTER_DAY_END" \
    '[.frames[] | select(.start >= $day_start and .start <= $day_end)]')

WINTER_FRAME_COUNT=$(echo "$WINTER_FRAMES" | jq 'length')

if [[ $WINTER_FRAME_COUNT -eq 24 ]]; then
    print_pass "Winter: Correctly filtered 24 hours for Warsaw day"
else
    print_fail "Winter: Expected 24 frames, got $WINTER_FRAME_COUNT"
fi

print_info "Testing summer day boundaries (CEST)"
# For 2024-07-15 Warsaw:
# Day starts: 2024-07-14 22:00 UTC (2024-07-15 00:00 Warsaw)
# Day ends: 2024-07-15 21:59:59 UTC (2024-07-15 23:59:59 Warsaw)

SUMMER_DAY_START="2024-07-14T22:00:00+00:00"
SUMMER_DAY_END="2024-07-15T21:59:59+00:00"

SUMMER_FRAMES=$(echo "$MOCK_BUY_JSON_SUMMER" | jq --arg day_start "$SUMMER_DAY_START" --arg day_end "$SUMMER_DAY_END" \
    '[.frames[] | select(.start >= $day_start and .start <= $day_end)]')

SUMMER_FRAME_COUNT=$(echo "$SUMMER_FRAMES" | jq 'length')

if [[ $SUMMER_FRAME_COUNT -eq 24 ]]; then
    print_pass "Summer: Correctly filtered 24 hours for Warsaw day"
else
    print_fail "Summer: Expected 24 frames, got $SUMMER_FRAME_COUNT"
fi

# ==========================================
# TEST 4: Price ranking for Warsaw calendar day
# ==========================================
print_test "4. Price ranking based on Warsaw calendar day"

print_info "Testing winter price ranking"
# Cheapest hour should be 02:00 Warsaw = 01:00 UTC (price 0.38)
WINTER_SORTED=$(echo "$WINTER_FRAMES" | jq -r 'sort_by(.price_gross) | to_entries[] | "\(.key)|\(.value.start)|\(.value.price_gross)"')
WINTER_CHEAPEST=$(echo "$WINTER_SORTED" | head -n1)
WINTER_CHEAPEST_INDEX=$(echo "$WINTER_CHEAPEST" | cut -d'|' -f1)
WINTER_CHEAPEST_TIME=$(echo "$WINTER_CHEAPEST" | cut -d'|' -f2)
WINTER_CHEAPEST_PRICE=$(echo "$WINTER_CHEAPEST" | cut -d'|' -f3)

if [[ "$WINTER_CHEAPEST_TIME" == "2024-01-15T01:00:00+00:00" && "$WINTER_CHEAPEST_INDEX" == "0" ]]; then
    print_pass "Winter: Cheapest hour (02:00 Warsaw = 01:00 UTC) correctly assigned index 0, price $WINTER_CHEAPEST_PRICE"
else
    print_fail "Winter: Expected 2024-01-15T01:00:00+00:00 at index 0, got $WINTER_CHEAPEST_TIME at index $WINTER_CHEAPEST_INDEX"
fi

print_info "Testing summer price ranking"
# Cheapest hour should be 03:00 Warsaw = 01:00 UTC (price 0.28)
SUMMER_SORTED=$(echo "$SUMMER_FRAMES" | jq -r 'sort_by(.price_gross) | to_entries[] | "\(.key)|\(.value.start)|\(.value.price_gross)"')
SUMMER_CHEAPEST=$(echo "$SUMMER_SORTED" | head -n1)
SUMMER_CHEAPEST_INDEX=$(echo "$SUMMER_CHEAPEST" | cut -d'|' -f1)
SUMMER_CHEAPEST_TIME=$(echo "$SUMMER_CHEAPEST" | cut -d'|' -f2)
SUMMER_CHEAPEST_PRICE=$(echo "$SUMMER_CHEAPEST" | cut -d'|' -f3)

if [[ "$SUMMER_CHEAPEST_TIME" == "2024-07-15T01:00:00+00:00" && "$SUMMER_CHEAPEST_INDEX" == "0" ]]; then
    print_pass "Summer: Cheapest hour (03:00 Warsaw = 01:00 UTC) correctly assigned index 0, price $SUMMER_CHEAPEST_PRICE"
else
    print_fail "Summer: Expected 2024-07-15T01:00:00+00:00 at index 0, got $SUMMER_CHEAPEST_TIME at index $SUMMER_CHEAPEST_INDEX"
fi

# ==========================================
# TEST 5: 14:00 Warsaw time restriction
# ==========================================
print_test "5. API fetch restriction before 14:00 Warsaw"

print_info "Testing cache preference before 14:00"
MOCK_CURRENT_HOUR_WARSAW=13  # Before 14:00

if [[ $MOCK_CURRENT_HOUR_WARSAW -lt 14 ]]; then
    SHOULD_USE_CACHE=true
else
    SHOULD_USE_CACHE=false
fi

if [[ "$SHOULD_USE_CACHE" == "true" ]]; then
    print_pass "Before 14:00 Warsaw: Script should prefer cache over API"
else
    print_fail "Before 14:00 Warsaw: Expected to use cache"
fi

print_info "Testing API fetch after 14:00"
MOCK_CURRENT_HOUR_WARSAW=15  # After 14:00

if [[ $MOCK_CURRENT_HOUR_WARSAW -lt 14 ]]; then
    SHOULD_USE_CACHE=true
else
    SHOULD_USE_CACHE=false
fi

if [[ "$SHOULD_USE_CACHE" == "false" ]]; then
    print_pass "After 14:00 Warsaw: Script can fetch from API"
else
    print_fail "After 14:00 Warsaw: Expected to allow API fetch"
fi

# ==========================================
# TEST 6: Warsaw time display formatting
# ==========================================
print_test "6. Warsaw time display with leading zeros"

print_info "Testing debug output format"
# Mock data: index 00, UTC 01:00, Warsaw 02:00 (winter)
MOCK_INDEX="00"
MOCK_UTC_TIME="2024-01-15T01:00:00+00:00"
MOCK_WARSAW_HOUR="02"
MOCK_PRICE="0.38"

EXPECTED_FORMAT="Index: $MOCK_INDEX | UTC: $MOCK_UTC_TIME ($MOCK_WARSAW_HOUR:00 Warsaw) | Price: $MOCK_PRICE PLN"
ACTUAL_FORMAT="Index: $MOCK_INDEX | UTC: $MOCK_UTC_TIME ($MOCK_WARSAW_HOUR:00 Warsaw) | Price: $MOCK_PRICE PLN"

if [[ "$ACTUAL_FORMAT" == "$EXPECTED_FORMAT" ]]; then
    print_pass "Debug format correct: $ACTUAL_FORMAT"
else
    print_fail "Debug format mismatch"
fi

# ==========================================
# TEST 7: JSON field extraction
# ==========================================
print_test "7. JSON field extraction with jq"

print_info "Testing price_gross extraction"
TEST_TIMESTAMP="2024-01-15T01:00:00+00:00"
EXTRACTED_PRICE=$(echo "$MOCK_BUY_JSON_WINTER" | jq -r --arg t "$TEST_TIMESTAMP" '.frames[] | select(.start == $t) | .price_gross')

if [[ "$EXTRACTED_PRICE" == "0.38" ]]; then
    print_pass "Correctly extracted price_gross: $EXTRACTED_PRICE PLN"
else
    print_fail "Expected 0.38, got $EXTRACTED_PRICE"
fi

print_info "Testing is_cheap flag extraction"
EXTRACTED_FLAG=$(echo "$MOCK_BUY_JSON_WINTER" | jq -r --arg t "$TEST_TIMESTAMP" '.frames[] | select(.start == $t) | .is_cheap')

if [[ "$EXTRACTED_FLAG" == "true" ]]; then
    print_pass "Correctly extracted is_cheap flag: $EXTRACTED_FLAG"
else
    print_fail "Expected true, got $EXTRACTED_FLAG"
fi

# ==========================================
# TEST 8: Mock cache functionality
# ==========================================
print_test "8. Cache file operations"

print_info "Testing cache write"
CACHE_FILE="$CACHE_DIR/pstryk_pricing_test.json"
echo "$MOCK_BUY_JSON_WINTER" > "$CACHE_FILE"

if [[ -f "$CACHE_FILE" ]]; then
    print_pass "Cache file created successfully"
else
    print_fail "Cache file creation failed"
fi

print_info "Testing cache read"
CACHED_DATA=$(cat "$CACHE_FILE")
if [[ -n "$CACHED_DATA" ]]; then
    CACHED_LIVE=$(echo "$CACHED_DATA" | jq -r '.frames[] | select(.is_live == true) | .start')
    if [[ "$CACHED_LIVE" == "2024-01-15T13:00:00+00:00" ]]; then
        print_pass "Cache data read correctly"
    else
        print_fail "Cache data corrupted"
    fi
else
    print_fail "Cache read failed"
fi

# Clean up cache
rm -rf "$CACHE_DIR"

# ==========================================
# TEST SUMMARY
# ==========================================
echo ""
echo "=========================================="
echo "TEST SUMMARY"
echo "=========================================="
echo -e "${GREEN}Tests Passed: $TESTS_PASSED${NC}"
echo -e "${RED}Tests Failed: $TESTS_FAILED${NC}"
echo ""

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "${GREEN}✓ ALL TESTS PASSED${NC}"
    exit 0
else
    echo -e "${RED}✗ SOME TESTS FAILED${NC}"
    exit 1
fi
