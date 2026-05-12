#!/bin/bash

# ==============================================================================
# File: tado_get.sh
# Version: 1.0
# Description:
#   List zones of a Tado home with their ID, name, schedule state, 
#   current temperature, and set temperature.
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
    echo " Tado Get Utility (v$SCRIPT_VERSION)"
    echo "=========================================================="
    echo "Description:"
    echo "  Retrieves and displays the current state of zones in your Tado home."
    echo ""
    echo "Usage:"
    echo "  ./tado_get.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -h, --help       Show this help message and exit."
    echo "  -V, --version    Show the script version and exit."
    echo "  --auth           Run the interactive OAuth2 setup to link your Tado account."
    echo "  --home <target>  Specify which Tado home to query by Name or ID."
    echo "  --json           Output the results in JSON format."
    echo "  --zone <target>  Filter output to a specific zone by Name or ID."
    echo "=========================================================="
    exit 0
}

# ==============================================================================
# ARGUMENT PARSING
# ==============================================================================
RUN_AUTH=0
EXPECT_HOME=0
EXPECT_ZONE=0
OUTPUT_JSON=0
TARGET_HOME=""
TARGET_ZONE=""

for arg in "$@"; do
    if [ "$EXPECT_HOME" -eq 1 ]; then TARGET_HOME="$arg"; EXPECT_HOME=0; continue; fi
    if [ "$EXPECT_ZONE" -eq 1 ]; then TARGET_ZONE="$arg"; EXPECT_ZONE=0; continue; fi

    if [ "$arg" == "-h" ] || [ "$arg" == "--help" ]; then show_help
    elif [ "$arg" == "-V" ] || [ "$arg" == "--version" ]; then echo "v$SCRIPT_VERSION"; exit 0
    elif [ "$arg" == "--home" ]; then EXPECT_HOME=1
    elif [ "$arg" == "--zone" ]; then EXPECT_ZONE=1
    elif [ "$arg" == "--json" ]; then OUTPUT_JSON=1
    elif [ "$arg" == "--auth" ]; then RUN_AUTH=1
    else
        log "ERROR: Unrecognized parameter: '$arg'"
        exit 1
    fi
done

for cmd in curl jq; do
    if ! command -v $cmd &> /dev/null; then log "ERROR: Required command '$cmd' is missing."; exit 1; fi
done

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

if [ ! -f "$TOKEN_FILE" ]; then log "ERROR: Auth token missing. Run './tado_get.sh --auth' first."; exit 1; fi

SAVED_REFRESH_TOKEN=$(cat "$TOKEN_FILE")
TOKEN_RES=$(curl -s -X POST "https://login.tado.com/oauth2/token" -d "client_id=$TADO_CLIENT_ID" -d "grant_type=refresh_token" -d "refresh_token=${SAVED_REFRESH_TOKEN}")
ACCESS_TOKEN=$(echo "$TOKEN_RES" | jq -r '.access_token')

if [ "$ACCESS_TOKEN" == "null" ] || [ -z "$ACCESS_TOKEN" ]; then log "ERROR: Token refresh failed. Run --auth again."; exit 1; fi
echo "$TOKEN_RES" | jq -r '.refresh_token' > "$TOKEN_FILE"

call_tado_api() {
    local RESPONSE=$(curl -s -w "\n%{http_code}" -X "$1" -H "Authorization: Bearer ${ACCESS_TOKEN}" "$2")
    local HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then echo "$RESPONSE" | sed '$d'; else return 1; fi
}

# ==============================================================================
# FETCH DATA
# ==============================================================================
HOME_DATA=$(call_tado_api "GET" "https://my.tado.com/api/v2/me")

if [ -n "$TARGET_HOME" ]; then
    HOMES_TO_PROCESS=$(echo "$HOME_DATA" | jq -c --arg target "$TARGET_HOME" '.homes[] | select((.id | tostring) == $target or .name == $target) | {id, name}')
    if [ -z "$HOMES_TO_PROCESS" ]; then log "ERROR: Could not find Home '$TARGET_HOME'."; exit 1; fi
else
    HOMES_TO_PROCESS=$(echo "$HOME_DATA" | jq -c '.homes[] | {id, name}')
fi

FINAL_JSON="[]"

while read -r home_obj; do
    [ -z "$home_obj" ] && continue
    HOME_ID=$(echo "$home_obj" | jq -r '.id')
    HOME_NAME=$(echo "$home_obj" | jq -r '.name')

    if [ "$OUTPUT_JSON" -eq 0 ]; then
        log "🏠 Home: $HOME_NAME (ID: $HOME_ID)"
        log "--------------------------------------------------------------------------------"
        printf "%-4s | %-20s | %-16s | %-5s | %-8s | %-8s | %s\n" "ID" "Zone Name" "Type" "Power" "Cur Temp" "Set Temp" "Mode"
        log "--------------------------------------------------------------------------------"
    fi

    ZONES_DATA=$(call_tado_api "GET" "https://my.tado.com/api/v2/homes/${HOME_ID}/zones")

    if [ -n "$TARGET_ZONE" ]; then
        ZONES_DATA=$(echo "$ZONES_DATA" | jq --arg tz "$TARGET_ZONE" '[.[] | select((.id | tostring) == $tz or .name == $tz)]')
        if [ "$ZONES_DATA" == "[]" ]; then log "ERROR: Could not find Zone '$TARGET_ZONE' in home '$HOME_NAME'."; exit 1; fi
    fi

    HOME_ZONES_JSON="[]"
    ZONES_TO_PROCESS=$(echo "$ZONES_DATA" | jq -c '.[]')

    while read -r zone; do
        [ -z "$zone" ] && continue
        ZONE_ID=$(echo "$zone" | jq -r '.id')
        ZONE_NAME=$(echo "$zone" | jq -r '.name')
        ZONE_TYPE=$(echo "$zone" | jq -r '.type')
        
        STATE_DATA=$(call_tado_api "GET" "https://my.tado.com/api/v2/homes/${HOME_ID}/zones/${ZONE_ID}/state")
        
        IFS='|' read -r OVERLAY_TYPE POWER RAW_CUR_TEMP RAW_SET_TEMP <<< "$(echo "$STATE_DATA" | jq -r '
            "\(.overlayType // "SCHEDULE")|\(.setting.power // "OFF")|\(.sensorDataPoints.insideTemperature.celsius // "null")|\(.setting.temperature.celsius // "null")"
        ')"
        
        if [ "$OUTPUT_JSON" -eq 1 ]; then
            ZONE_OBJ=$(jq -n \
                --arg id "$ZONE_ID" \
                --arg name "$ZONE_NAME" \
                --arg type "$ZONE_TYPE" \
                --arg power "$POWER" \
                --arg cur "$RAW_CUR_TEMP" \
                --arg set "$RAW_SET_TEMP" \
                --arg mode "$OVERLAY_TYPE" \
                '{
                    id: $id, 
                    name: $name, 
                    type: $type, 
                    power: $power, 
                    current_temp: (if $cur == "null" then null else ($cur | tonumber) end), 
                    set_temp: (if $set == "null" then null else ($set | tonumber) end), 
                    mode: $mode
                }')
            HOME_ZONES_JSON=$(echo "$HOME_ZONES_JSON" | jq --argjson z "$ZONE_OBJ" '. + [$z]')
        else
            CUR_TEMP_TEXT="$RAW_CUR_TEMP"
            [ "$CUR_TEMP_TEXT" != "null" ] && CUR_TEMP_TEXT="${CUR_TEMP_TEXT}°C" || CUR_TEMP_TEXT="N/A"
            
            if [ "$POWER" == "OFF" ]; then 
                SET_TEMP_TEXT="OFF"
            elif [ "$RAW_SET_TEMP" != "null" ]; then 
                SET_TEMP_TEXT="${RAW_SET_TEMP}°C"
            else
                SET_TEMP_TEXT="N/A"
            fi
            
            printf "%-4s | %-20s | %-16s | %-5s | %-8s | %-8s | %s\n" "$ZONE_ID" "${ZONE_NAME:0:20}" "$ZONE_TYPE" "$POWER" "$CUR_TEMP_TEXT" "$SET_TEMP_TEXT" "$OVERLAY_TYPE"
        fi
    done <<< "$(echo "$ZONES_TO_PROCESS")"
    
    if [ "$OUTPUT_JSON" -eq 1 ]; then
        HOME_OBJ_FULL=$(jq -n --arg id "$HOME_ID" --arg name "$HOME_NAME" --argjson zones "$HOME_ZONES_JSON" '{home_id: $id, home_name: $name, zones: $zones}')
        FINAL_JSON=$(echo "$FINAL_JSON" | jq --argjson h "$HOME_OBJ_FULL" '. + [$h]')
    else
        log "--------------------------------------------------------------------------------"
    fi
done <<< "$(echo "$HOMES_TO_PROCESS")"

if [ "$OUTPUT_JSON" -eq 1 ]; then
    echo "$FINAL_JSON" | jq .
fi

