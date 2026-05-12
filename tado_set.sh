#!/bin/bash

# ==============================================================================
# File: tado_set.sh
# Version: 1.0
# Description:
#   Set temperature, off, on (resume), or reset for specific Tado zones.
# ==============================================================================

SCRIPT_VERSION="1.0"
TOKEN_FILE="$HOME/.tado_token"
TADO_CLIENT_ID="1bb50063-6b0c-4d11-bd99-387f4a91cc46"

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================
log() { echo "$1"; }

show_help() {
    echo "=========================================================="
    echo " Tado Set Utility (v$SCRIPT_VERSION)"
    echo "=========================================================="
    echo "Description:"
    echo "  Manually control the state of specific Tado zones."
    echo ""
    echo "Usage:"
    echo "  ./tado_set.sh [OPTIONS] <ACTION>"
    echo ""
    echo "Actions (Pick One):"
    echo "  <temp>C          Set zone to a specific temperature (e.g., 21.5C)"
    echo "  on               Resume smart schedule (delete manual overlay)"
    echo "  off              Set zone to MANUAL OFF"
    echo "  reset            Resume smart schedule (alias for 'on')"
    echo ""
    echo "Options:"
    echo "  -h, --help       Show this help message and exit."
    echo "  --auth           Run the interactive OAuth2 setup."
    echo "  --home <target>  Specify which Tado home to control by Name or ID."
    echo "  --zone <target>  Specify a specific zone. If omitted, applies to ALL zones."
    echo "=========================================================="
    exit 0
}

# ==============================================================================
# ARGUMENT PARSING
# ==============================================================================
RUN_AUTH=0
EXPECT_HOME=0
EXPECT_ZONE=0
TARGET_HOME=""
TARGET_ZONE=""
ACTION_ARG=""
TARGET_TEMP=""

for arg in "$@"; do
    if [ "$EXPECT_HOME" -eq 1 ]; then TARGET_HOME="$arg"; EXPECT_HOME=0; continue; fi
    if [ "$EXPECT_ZONE" -eq 1 ]; then TARGET_ZONE="$arg"; EXPECT_ZONE=0; continue; fi

    if [ "$arg" == "-h" ] || [ "$arg" == "--help" ]; then show_help
    elif [ "$arg" == "--home" ]; then EXPECT_HOME=1
    elif [ "$arg" == "--zone" ]; then EXPECT_ZONE=1
    elif [ "$arg" == "--auth" ]; then RUN_AUTH=1
    elif [ "$arg" == "on" ] || [ "$arg" == "reset" ]; then ACTION_ARG="RESUME"
    elif [ "$arg" == "off" ]; then ACTION_ARG="TURN_OFF"
    elif [[ "$arg" =~ ^([0-9]+(\.[0-9]+)?)C$ ]]; then
        ACTION_ARG="SET_TEMP"
        TARGET_TEMP="${BASH_REMATCH[1]}"
    else
        log "ERROR: Unrecognized parameter or action: '$arg'"
        exit 1
    fi
done

if [ "$RUN_AUTH" -eq 0 ] && [ -z "$ACTION_ARG" ]; then
    log "ERROR: You must specify an action (e.g., 21C, off, on, reset)."
    show_help
fi

# ==============================================================================
# AUTHENTICATION
# ==============================================================================
if [ "$RUN_AUTH" -eq 1 ]; then
    log "Starting Tado Device Code Authorization Flow..."
    AUTH_RES=$(curl -s -X POST "https://login.tado.com/oauth2/device_authorize" -d "client_id=$TADO_CLIENT_ID" -d "scope=offline_access")
    DEVICE_CODE=$(echo "$AUTH_RES" | jq -r '.device_code')
    VERIFY_URI=$(echo "$AUTH_RES" | jq -r '.verification_uri_complete')
    INTERVAL=$(echo "$AUTH_RES" | jq -r '.interval')
    
    echo -e "\nACTION REQUIRED:\n1. Open this URL in your browser:\n   $VERIFY_URI\n2. Log in to approve."
    echo -n "Waiting for approval "
    while true; do
        sleep "${INTERVAL:-5}"
        TOKEN_RES=$(curl -s -X POST "https://login.tado.com/oauth2/token" -d "client_id=$TADO_CLIENT_ID" -d "device_code=$DEVICE_CODE" -d "grant_type=urn:ietf:params:oauth:grant-type:device_code")
        ERR=$(echo "$TOKEN_RES" | jq -r '.error')
        if [ "$ERR" == "authorization_pending" ]; then echo -n ".";
        elif [ "$ERR" == "null" ] || [ -z "$ERR" ]; then
            echo "$TOKEN_RES" | jq -r '.refresh_token' > "$TOKEN_FILE"
            chmod 600 "$TOKEN_FILE"
            echo -e "\nSUCCESS! Token saved to $TOKEN_FILE."
            exit 0
        else
            echo -e "\nERROR: $ERR"; exit 1
        fi
    done
fi

if [ ! -f "$TOKEN_FILE" ]; then log "ERROR: Auth token missing. Run './tado_set.sh --auth' first."; exit 1; fi

SAVED_REFRESH_TOKEN=$(cat "$TOKEN_FILE")
TOKEN_RES=$(curl -s -X POST "https://login.tado.com/oauth2/token" -d "client_id=$TADO_CLIENT_ID" -d "grant_type=refresh_token" -d "refresh_token=${SAVED_REFRESH_TOKEN}")
ACCESS_TOKEN=$(echo "$TOKEN_RES" | jq -r '.access_token')

if [ "$ACCESS_TOKEN" == "null" ] || [ -z "$ACCESS_TOKEN" ]; then log "ERROR: Token refresh failed. Run --auth again."; exit 1; fi
echo "$TOKEN_RES" | jq -r '.refresh_token' > "$TOKEN_FILE"

call_tado_api() {
    local METHOD="$1"
    local URL="$2"
    local PAYLOAD="$3"
    local RESPONSE
    if [ -n "$PAYLOAD" ]; then
        RESPONSE=$(curl -s -w "\n%{http_code}" -X "$METHOD" -H "Authorization: Bearer ${ACCESS_TOKEN}" -H "Content-Type: application/json;charset=UTF-8" -d "$PAYLOAD" "$URL")
    else
        RESPONSE=$(curl -s -w "\n%{http_code}" -X "$METHOD" -H "Authorization: Bearer ${ACCESS_TOKEN}" "$URL")
    fi
    local HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then echo "$RESPONSE" | sed '$d'; else return 1; fi
}

# ==============================================================================
# APPLY SETTINGS
# ==============================================================================
HOME_DATA=$(call_tado_api "GET" "https://my.tado.com/api/v2/me")

if [ -n "$TARGET_HOME" ]; then
    HOME_MATCH=$(echo "$HOME_DATA" | jq -r --arg target "$TARGET_HOME" '.homes[] | select((.id | tostring) == $target or .name == $target) | "\(.id)|\(.name)"' | head -n 1)
    if [ -z "$HOME_MATCH" ]; then log "ERROR: Could not find Home '$TARGET_HOME'."; exit 1; fi
    HOME_ID=$(echo "$HOME_MATCH" | cut -d'|' -f1)
else
    HOME_ID=$(echo "$HOME_DATA" | jq -r '.homes[0].id')
fi

ZONES_DATA=$(call_tado_api "GET" "https://my.tado.com/api/v2/homes/${HOME_ID}/zones")

if [ -n "$TARGET_ZONE" ]; then
    ZONES_DATA=$(echo "$ZONES_DATA" | jq --arg tz "$TARGET_ZONE" '[.[] | select((.id | tostring) == $tz or .name == $tz)]')
    if [ "$ZONES_DATA" == "[]" ]; then log "ERROR: Could not find Zone '$TARGET_ZONE'."; exit 1; fi
fi

echo "$ZONES_DATA" | jq -c '.[] | select(.type=="HEATING" or .type=="AIR_CONDITIONING")' | while read -r zone; do
    ZONE_ID=$(echo "$zone" | jq -r '.id')
    ZONE_NAME=$(echo "$zone" | jq -r '.name')
    ZONE_TYPE=$(echo "$zone" | jq -r '.type')
    OVERLAY_URL="https://my.tado.com/api/v2/homes/${HOME_ID}/zones/${ZONE_ID}/overlay"
    STATE_URL="https://my.tado.com/api/v2/homes/${HOME_ID}/zones/${ZONE_ID}/state"
    
    log "Applying action '$ACTION_ARG' to Zone: '$ZONE_NAME'..."
    
    STATE_DATA=$(call_tado_api "GET" "$STATE_URL")
    IFS='|' read -r CURRENT_OVERLAY_TYPE CURRENT_POWER CURRENT_TEMP_SETTING CURRENT_TERMINATION <<< "$(echo "$STATE_DATA" | jq -r '
        "\(.overlayType // "")|\(.setting.power // "")|\(.setting.temperature.celsius // "")|\(.overlay.termination.type // "")"
    ')"
    
    if [ "$ACTION_ARG" == "TURN_OFF" ]; then
        if [ "$CURRENT_OVERLAY_TYPE" == "MANUAL" ] && [ "$CURRENT_POWER" == "OFF" ]; then
            log "  -> Zone is already set to MANUAL OFF. Skipping."
            continue
        fi
        PAYLOAD="{\"setting\": {\"type\": \"$ZONE_TYPE\", \"power\": \"OFF\"}, \"termination\": {\"type\": \"MANUAL\"}}"
        call_tado_api "PUT" "$OVERLAY_URL" "$PAYLOAD" > /dev/null
        log "  -> Set to OFF"
    elif [ "$ACTION_ARG" == "RESUME" ]; then
        if [ "$CURRENT_OVERLAY_TYPE" == "null" ] || [ -z "$CURRENT_OVERLAY_TYPE" ]; then
            log "  -> Zone is already following the schedule. Skipping."
            continue
        fi
        call_tado_api "DELETE" "$OVERLAY_URL" > /dev/null
        log "  -> Schedule Resumed"
    elif [ "$ACTION_ARG" == "SET_TEMP" ]; then
        if [ "$CURRENT_POWER" == "ON" ] && [ "$CURRENT_TEMP_SETTING" == "$TARGET_TEMP" ] && [ "$CURRENT_TERMINATION" == "TADO_MODE" ]; then
            log "  -> Zone is already set to ${TARGET_TEMP}°C. Skipping."
            continue
        fi
        PAYLOAD="{\"setting\": {\"type\": \"$ZONE_TYPE\", \"power\": \"ON\", \"temperature\": {\"celsius\": $TARGET_TEMP}}, \"termination\": {\"type\": \"TADO_MODE\"}}"
        call_tado_api "PUT" "$OVERLAY_URL" "$PAYLOAD" > /dev/null
        log "  -> Temperature set to ${TARGET_TEMP}°C"
    fi
done

log "Done."

