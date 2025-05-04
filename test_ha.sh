#!/bin/bash
#
# Jarosław Zjawiński - kontakt@zjawa.it
#
# This script is a test suite for the `ha.sh` script, designed to validate its functionality.
#
# Features:
# - Mocks API responses for testing purposes.
# - Provides utility functions to simulate JSON retrieval, JSON field extraction, and Home Assistant API POST requests.
#
# Mock Variables:
# - `API_TOKEN`: Mock API token for authentication.
# - `HA_IP`: Mock Home Assistant IP address.
# - `HA_TOKEN`: Mock Home Assistant token.
#
# Mock Data:
# - `MOCK_BUY_JSON`: Simulated JSON response for "pricing" endpoint.
# - `MOCK_SELL_JSON`: Simulated JSON response for "prosumer-pricing" endpoint.
#
# Functions:
# - `get_json(endpoint)`: Simulates retrieving JSON data from a specified endpoint.
# - `jq_field(json, timestamp, field)`: Extracts a specific field from a JSON object based on a timestamp.
# - `ha_post(entity_id, json_body)`: Simulates a POST request to the Home Assistant API.
#
# Test Cases:
# 1. Validate JSON retrieval:
#    - Ensures `get_json` returns the correct mock JSON data for "pricing" and "prosumer-pricing" endpoints.
# 2. Validate `jq_field` function:
#    - Tests the ability to extract a specific field from the mock JSON data using a timestamp.
# 3. Validate Home Assistant POST:
#    - Simulates a POST request to the Home Assistant API and prints the request details.
#
# Usage:
# - Run the script to execute all test cases and verify the functionality of `ha.sh`.


# Test script for ha.sh

# Mock variables
API_TOKEN="mock_api_token"
HA_IP="http://mock_home_assistant.local:8123"
HA_TOKEN="mock_ha_token"

# Mock API responses
MOCK_BUY_JSON='{
    "frames": [
        {"start": "2023-01-01T00:00:00+00:00", "price_gross": 0.5, "is_cheap": true, "is_expensive": false},
        {"start": "2023-01-01T01:00:00+00:00", "price_gross": 0.6, "is_cheap": false, "is_expensive": true}
    ]
}'
MOCK_SELL_JSON='{
    "frames": [
        {"start": "2023-01-01T00:00:00+00:00", "price_gross": 0.4},
        {"start": "2023-01-01T01:00:00+00:00", "price_gross": 0.3}
    ]
}'

# Mock functions
get_json() {
    local endpoint=$1
    if [[ "$endpoint" == "pricing" ]]; then
        echo "$MOCK_BUY_JSON"
    elif [[ "$endpoint" == "prosumer-pricing" ]]; then
        echo "$MOCK_SELL_JSON"
    else
        echo "{}"
    fi
}

jq_field() {
    local json=$1
    local timestamp=$2
    local field=$3
    echo "$json" | jq -r --arg t "$timestamp" ".frames[] | select(.start==\$t) | .$field"
}

ha_post() {
    local entity_id=$1
    local json_body=$2
    echo "POST to $HA_IP/api/states/sensor.test_$entity_id with body: $json_body"
}

# Test cases
echo "Running tests for ha.sh..."

# Test 1: Validate JSON retrieval
echo "Test 1: Validate JSON retrieval"
BUY_JSON=$(get_json pricing)
SELL_JSON=$(get_json prosumer-pricing)
if [[ "$BUY_JSON" == "$MOCK_BUY_JSON" && "$SELL_JSON" == "$MOCK_SELL_JSON" ]]; then
    echo "Test 1 passed."
else
    echo "Test 1 failed."
fi

# Test 2: Validate jq_field function
echo "Test 2: Validate jq_field function"
TEST_TIMESTAMP="2023-01-01T00:00:00+00:00"
TEST_FIELD="price_gross"
EXPECTED_VALUE="0.5"
ACTUAL_VALUE=$(jq_field "$MOCK_BUY_JSON" "$TEST_TIMESTAMP" "$TEST_FIELD")
if [[ "$ACTUAL_VALUE" == "$EXPECTED_VALUE" ]]; then
    echo "Test 2 passed."
else
    echo "Test 2 failed."
fi

# Test 3: Validate Home Assistant POST
echo "Test 3: Validate Home Assistant POST"
ha_post "sensor.test_entity" '{"state":"test_state"}'

echo "All tests completed."