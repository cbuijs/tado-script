#!/bin/bash

# ==============================================================================
# File: tado_weather_control.sh
# Version: 2.30
# Last Updated: 2026-05-13
#
# HISTORY:
# v2.30 - Added empty body check to 'call_weather_api' wrapper.
# v2.29 - Added 'call_weather_api' wrapper to implement retry logic for 
#         Open-Meteo geocoding and forecast API calls.
# v2.28 - Added '--heating-only' parameter to ignore non-heating zones.
# v2.27 - Added '--auto-off' parameter and ARP-based presence detection to 
#         automatically turn off all zones when no configured MAC addresses 
#         are found on the local network.
# v2.26 - Added comprehensive State Tracking. The script now remembers what 
#         it previously set. If it detects a manual change from the app or 
#         thermostat, it will skip modifying that zone to respect user 
#         preference unless '--force' is used.
# v2.23 - Added '--home' parameter to specify which Tado home to 
#         control by name or ID.
# v2.22 - Added Home Name to the logging output alongside Home ID.
# v2.21 - Fixed jq adding literal double quotes to the URL-encoded city name.
# v2.20 - Added fallback to Amsterdam coordinates if city geocoding fails.
# v2.19 - Optimized jq processing in the evaluation loop for better performance.
# v2.18 - Added logging to always display current and set temperatures.
# v2.17 - Added 'auto' mode to dynamically switch off heating based on temps.
# v2.16 - Added '--force' flag to overwrite existing manual settings.
# v2.15 - Added '--city <name>' parameter to override the default city.
# v2.14 - Replaced hardcoded coordinates with Open-Meteo Geocoding API.
# v2.13 - Added 'reset' manual override to resume schedule for all zones.
# v2.12 - Added support to manually set a temperature for heating zones.
# v2.11 - Added validation for command-line arguments.
# v2.10 - Fixed logger unrecognized option error.
# v2.9  - Added logger to the prerequisites check.
# v2.8  - Decoupled --syslog from --notime.
# v2.7  - Added --syslog parameter.
# v2.6  - Added --notime parameter.
# v2.5  - Added support for AIR_CONDITIONING zones.
# v2.4  - Added --help (-h) and --version (-V).
# v2.3  - Added zone names to the logging output.
# v2.2  - Fixed JSON parsing for Home ID.
# v2.1  - Added pre-checks to prevent redundant API calls.
# v2.0  - Migrated to OAuth2 Device Code Flow.
# v1.0  - Initial release.
# ==============================================================================

SCRIPT_VERSION="2.30"

# ==============================================================================
# 1. USER CONFIGURATION
# ==============================================================================
# Authentication & Tracking Files
TOKEN_FILE="$HOME/.tado_token"
STATE_FILE="$HOME/.tado_zone_states"

# Tado's official public Client ID for Device Auth (no secret required)
TADO_CLIENT_ID="1bb50063-6b0c-4d11-bd99-387f4a91cc46"

# Target City for Weather Data
CITY_NAME="Amsterdam"

# Temperature Thresholds (Celsius)
TEMP_OFF_THRESHOLD=16.0
TEMP_RESUME_THRESHOLD=15.0

# Auto Mode Threshold (Celsius)
AUTO_MAX_DIFF=10.0

# Auto-Off Presence Detection (MAC Addresses)
# Comma-separated list of MAC addresses to check for presence.
# Leave empty if you prefer to pass them via the command-line argument.
PRESENCE_MACS=""

# ==============================================================================
# 2. HELPER FUNCTIONS
# ==============================================================================
SHOW_TIME=1
USE_SYSLOG=0

log() {
    if [ "$SHOW_TIME" -eq 1 ]; then
        local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
        echo "[$timestamp] $1"
    else
        echo "$1"
    fi
    
    if [ "$USE_SYSLOG" -eq 1 ]; then
        logger -t "tado_weather" -- "$1"
    fi
}

show_version() {
    echo "tado_weather_control.sh version $SCRIPT_VERSION"
    exit 0
}

show_help() {
    echo "=========================================================="
    echo " Tado Weather Automation Script (v$SCRIPT_VERSION)"
    echo "=========================================================="
    echo "Description:"
    echo "  Checks the current outside temperature in $CITY_NAME using Open-Meteo."
    echo "  - If temperature is >= ${TEMP_OFF_THRESHOLD}°C: Switches heating OFF (AC ON)."
    echo "  - If temperature is <= ${TEMP_RESUME_THRESHOLD}°C: Resumes Tado smart schedule for Heating (AC OFF)."
    echo ""
    echo "Options:"
    echo "  -h, --help       Show this help message and exit."
    echo "  -V, --version    Show the script version and exit."
    echo "  --auth           Run the interactive OAuth2 setup to link your account."
    echo "  --auto-off[=MACs] Check ARP table for presence MACs (comma-separated)."
    echo "                   If absent, bypasses weather and forces ALL zones OFF."
    echo "  --city <name>    Override the default city ($CITY_NAME)."
    echo "  --dryrun         Run the script normally but do not send commands to Tado."
    echo "  --force          Overwrite existing user manual settings and reset tracking memory."
    echo "  --heating-only   Only apply to heating zones, ignore air conditioning."
    echo "  --home <target>  Specify which Tado home to control by Name or ID."
    echo "  --notime         Disable date/time stamps in the logging output."
    echo "  --syslog         Output logs to syslog in addition to standard output."
    echo "  auto             Manual override: Smart evaluation comparing inside/outside temps."
    echo "  on               Manual override: Force Tado to RESUME schedule."
    echo "  off              Manual override: Force Tado to switch OFF."
    echo "  reset            Manual override: Reset all zones to their default smart schedule."
    echo "  <temp>C          Manual override: Set heating zones to a specific temperature."
    echo "=========================================================="
    exit 0
}

# --- State Tracking Functions ---
get_tracked_state() {
    local key="$1"
    if [ -f "$STATE_FILE" ]; then
        grep "^${key}=" "$STATE_FILE" | cut -d'=' -f2-
    fi
}

set_tracked_state() {
    local key="$1"
    local state="$2"
    if [ -f "$STATE_FILE" ]; then
        # Cross-platform safe in-place replacement
        grep -v "^${key}=" "$STATE_FILE" > "${STATE_FILE}.tmp"
        mv "${STATE_FILE}.tmp" "$STATE_FILE"
    fi
    echo "${key}=${state}" >> "$STATE_FILE"
}

get_normalized_state() {
    local overlay="$1"
    local power="$2"
    local temp="$3"
    local term="$4"

    # Normalize temp to 1 decimal point for reliable string comparison
    if [ -n "$temp" ]; then
        temp=$(printf "%.1f" "$temp")
    fi

    # If overlay is null or empty, the zone is following the Smart Schedule
    if [ -z "$overlay" ] || [ "$overlay" == "null" ]; then
        echo "SCHEDULE"
    else
        echo "${overlay}|${power}|${temp}|${term}"
    fi
}

# ==============================================================================
# 3. ARGUMENT PARSING & SETUP
# ==============================================================================
DRY_RUN=0
FORCE_ACTION=""
TARGET_TEMP=""
RUN_AUTH=0
EXPECT_CITY=0
EXPECT_HOME=0
FORCE_FLAG=0
TARGET_HOME=""
ENABLE_AUTO_OFF=0
HEATING_ONLY=0

for arg in "$@"; do
    if [ "$EXPECT_CITY" -eq 1 ]; then
        CITY_NAME="$arg"
        EXPECT_CITY=0
        continue
    fi
    if [ "$EXPECT_HOME" -eq 1 ]; then
        TARGET_HOME="$arg"
        EXPECT_HOME=0
        continue
    fi

    if [ "$arg" == "-h" ] || [ "$arg" == "--help" ]; then show_help
    elif [ "$arg" == "-V" ] || [ "$arg" == "--version" ]; then show_version
    elif [ "$arg" == "--city" ]; then EXPECT_CITY=1
    elif [ "$arg" == "--home" ]; then EXPECT_HOME=1
    elif [ "$arg" == "--dryrun" ]; then DRY_RUN=1; log "NOTICE: Running in DRY RUN mode."
    elif [ "$arg" == "--force" ]; then FORCE_FLAG=1; log "NOTICE: Force mode enabled. User settings will be overwritten."
    elif [ "$arg" == "--heating-only" ]; then HEATING_ONLY=1
    elif [ "$arg" == "--notime" ]; then SHOW_TIME=0
    elif [ "$arg" == "--syslog" ]; then USE_SYSLOG=1
    elif [[ "$arg" == --auto-off=* ]]; then
        ENABLE_AUTO_OFF=1
        PRESENCE_MACS="${arg#*=}"
    elif [ "$arg" == "--auto-off" ]; then
        ENABLE_AUTO_OFF=1
    elif [ "$arg" == "auto" ]; then FORCE_ACTION="AUTO"
    elif [ "$arg" == "on" ]; then FORCE_ACTION="RESUME"
    elif [ "$arg" == "off" ]; then FORCE_ACTION="TURN_OFF"
    elif [ "$arg" == "reset" ]; then FORCE_ACTION="RESET_ALL"
    elif [[ "$arg" =~ ^([0-9]+(\.[0-9]+)?)C$ ]]; then
        TEMP_VAL="${BASH_REMATCH[1]}"
        if [ "$(echo "$TEMP_VAL >= 0 && $TEMP_VAL <= 25" | bc -l)" -eq 1 ]; then
            FORCE_ACTION="SET_TEMP"
            TARGET_TEMP="$TEMP_VAL"
        else
            log "ERROR: Manual temperature must be between 0 and 25 Celsius."
            exit 1
        fi
    elif [ "$arg" == "--auth" ]; then RUN_AUTH=1
    else
        log "ERROR: Unrecognized parameter: '$arg'"; exit 1
    fi
done

for cmd in curl jq bc logger grep; do
    if ! command -v $cmd &> /dev/null; then log "ERROR: Required command '$cmd' is not installed."; exit 1; fi
done

# ==============================================================================
# 3.5. PRESENCE DETECTION (AUTO-OFF)
# ==============================================================================
if [ "$ENABLE_AUTO_OFF" -eq 1 ]; then
    if [ -z "$PRESENCE_MACS" ]; then
        log "ERROR: --auto-off flag used but PRESENCE_MACS is empty in configuration/argument."
        exit 1
    fi
    
    # Remove spaces and trailing/leading commas, then replace commas with pipes for regex
    MAC_REGEX=$(echo "$PRESENCE_MACS" | tr -d ' ' | sed 's/^,*//;s/,*$//' | tr ',' '|')
    log "Checking ARP table for presence MACs..."
    
    # Use 'ip neigh' if available (modern linux), fallback to 'arp -an'
    if command -v ip &> /dev/null; then
        ARP_OUTPUT=$(ip neigh show)
    elif command -v arp &> /dev/null; then
        ARP_OUTPUT=$(arp -an)
    else
        log "ERROR: Neither 'ip' nor 'arp' commands are available for presence detection."
        exit 1
    fi
    
    if echo "$ARP_OUTPUT" | grep -iE "($MAC_REGEX)" > /dev/null; then
        log "Presence detected in ARP table. Continuing normally."
    else
        log "No configured MAC addresses found in ARP table. Forcing ALL zones OFF."
        # Override the normal action strictly to TURN_OFF
        FORCE_ACTION="TURN_OFF"
    fi
fi

# ==============================================================================
# 4. AUTHENTICATION & WEATHER FETCHING
# ==============================================================================
if [ "$RUN_AUTH" -eq 1 ]; then
    log "Starting Tado Device Code Authorization Flow..."
    AUTH_RES=$(curl -s -X POST "https://login.tado.com/oauth2/device_authorize" -d "client_id=$TADO_CLIENT_ID" -d "scope=offline_access")
    DEVICE_CODE=$(echo "$AUTH_RES" | jq -r '.device_code')
    VERIFY_URI=$(echo "$AUTH_RES" | jq -r '.verification_uri_complete')
    INTERVAL=$(echo "$AUTH_RES" | jq -r '.interval')
    
    echo -e "\nACTION REQUIRED:\n1. Open this URL: $VERIFY_URI\n2. Log in to approve."
    echo -n "Waiting for approval "
    while true; do
        sleep "${INTERVAL:-5}"
        TOKEN_RES=$(curl -s -X POST "https://login.tado.com/oauth2/token" -d "client_id=$TADO_CLIENT_ID" -d "device_code=$DEVICE_CODE" -d "grant_type=urn:ietf:params:oauth:grant-type:device_code")
        ERR=$(echo "$TOKEN_RES" | jq -r '.error')
        if [ "$ERR" == "authorization_pending" ]; then echo -n "."
        elif [ -z "$ERR" ] || [ "$ERR" == "null" ]; then
            echo "$TOKEN_RES" | jq -r '.refresh_token' > "$TOKEN_FILE"
            chmod 600 "$TOKEN_FILE"
            echo -e "\nSUCCESS! Token saved to $TOKEN_FILE."; exit 0
        else echo -e "\nERROR: $ERR"; exit 1
        fi
    done
fi

if [ ! -f "$TOKEN_FILE" ]; then log "ERROR: Auth token missing. Run --auth first."; exit 1; fi

# --- Weather API Wrapper Function ---
call_weather_api() {
    local URL="$1"
    local RETRIES=0
    local MAX_RETRIES=3
    local SLEEP_TIME=5

    while [ "$RETRIES" -lt "$MAX_RETRIES" ]; do
        local RESPONSE=$(curl -s -w "\n%{http_code}" "$URL")
        local HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
        local BODY=$(echo "$RESPONSE" | sed '$d')

        if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
            if [ -n "$BODY" ]; then
                echo "$BODY"
                return 0
            else
                log "WARNING: Weather API returned HTTP ${HTTP_CODE} but with an empty body. Retrying in ${SLEEP_TIME}s... ($((RETRIES+1))/$MAX_RETRIES)"
            fi
        else
            log "WARNING: Weather API returned HTTP ${HTTP_CODE}. Retrying in ${SLEEP_TIME}s... ($((RETRIES+1))/$MAX_RETRIES)"
        fi
        
        sleep "$SLEEP_TIME"
        RETRIES=$((RETRIES + 1))
    done
    return 1
}

if [ -n "$FORCE_ACTION" ] && [ "$FORCE_ACTION" != "AUTO" ]; then
    ACTION="$FORCE_ACTION"
    log "Skipping weather check due to manual override/presence config: $ACTION"
else
    log "Resolving coordinates for city: $CITY_NAME..."
    ENCODED_CITY=$(jq -n -r --arg city "$CITY_NAME" '$city | @uri')
    
    # Using the new retry wrapper for Geocoding
    GEO_RESPONSE=$(call_weather_api "https://geocoding-api.open-meteo.com/v1/search?name=${ENCODED_CITY}&count=1&language=en&format=json")
    LATITUDE=$(echo "$GEO_RESPONSE" | jq -r '.results[0].latitude // empty')
    LONGITUDE=$(echo "$GEO_RESPONSE" | jq -r '.results[0].longitude // empty')

    if [ -z "$LATITUDE" ] || [ -z "$LONGITUDE" ]; then
        log "WARNING: Could not find coordinates from API. Falling back to Amsterdam."
        LATITUDE="52.3740"; LONGITUDE="4.8897"
    fi

    # Using the new retry wrapper for Weather Forecast
    WEATHER_RESPONSE=$(call_weather_api "https://api.open-meteo.com/v1/forecast?latitude=${LATITUDE}&longitude=${LONGITUDE}&current_weather=true")
    CURRENT_TEMP=$(echo "$WEATHER_RESPONSE" | jq -r '.current_weather.temperature')

    if [ -z "$CURRENT_TEMP" ] || [ "$CURRENT_TEMP" == "null" ]; then
        log "ERROR: Failed to retrieve current temperature after retries. Exiting to prevent incorrect automation."
        exit 1
    fi

    log "Current outside temperature is: ${CURRENT_TEMP}°C"
    ACTION="NONE"
    if [ "$(echo "$CURRENT_TEMP >= $TEMP_OFF_THRESHOLD" | bc -l)" -eq 1 ]; then ACTION="TURN_OFF"
    elif [ "$(echo "$CURRENT_TEMP <= $TEMP_RESUME_THRESHOLD" | bc -l)" -eq 1 ]; then ACTION="RESUME"
    else log "Temperature is in the buffer zone. Doing nothing."; exit 0; fi
fi

# ==============================================================================
# 5. TADO API
# ==============================================================================
SAVED_REFRESH_TOKEN=$(cat "$TOKEN_FILE")
TOKEN_RES=$(curl -s -X POST "https://login.tado.com/oauth2/token" -d "client_id=$TADO_CLIENT_ID" -d "grant_type=refresh_token" -d "refresh_token=${SAVED_REFRESH_TOKEN}")
ACCESS_TOKEN=$(echo "$TOKEN_RES" | jq -r '.access_token')

if [ -z "$ACCESS_TOKEN" ] || [ "$ACCESS_TOKEN" == "null" ]; then log "ERROR: Token refresh failed. Run --auth again."; exit 1; fi
echo "$TOKEN_RES" | jq -r '.refresh_token' > "$TOKEN_FILE"

call_tado_api() {
    local METHOD="$1"; local URL="$2"; local PAYLOAD="$3"; local RETRIES=0; local SLEEP_TIME=30
    while [ "$RETRIES" -lt 5 ]; do
        if [ -n "$PAYLOAD" ]; then RESPONSE=$(curl -s -w "\n%{http_code}" -X "$METHOD" -H "Authorization: Bearer ${ACCESS_TOKEN}" -H "Content-Type: application/json;charset=UTF-8" -d "$PAYLOAD" "$URL")
        else RESPONSE=$(curl -s -w "\n%{http_code}" -X "$METHOD" -H "Authorization: Bearer ${ACCESS_TOKEN}" "$URL"); fi
        
        HTTP_CODE=$(echo "$RESPONSE" | tail -n1); BODY=$(echo "$RESPONSE" | sed '$d')
        if [ "$HTTP_CODE" -eq 429 ]; then sleep "$SLEEP_TIME"; RETRIES=$((RETRIES + 1)); SLEEP_TIME=$((SLEEP_TIME * 2))
        elif [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then echo "$BODY"; return 0
        else return 1; fi
    done
}

# ==============================================================================
# 6. GET HOMES & ZONES
# ==============================================================================
HOME_DATA=$(call_tado_api "GET" "https://my.tado.com/api/v2/me")
if [ -n "$TARGET_HOME" ]; then
    HOME_MATCH=$(echo "$HOME_DATA" | jq -r --arg target "$TARGET_HOME" '.homes[] | select((.id | tostring) == $target or .name == $target) | "\(.id)|\(.name)"' | head -n 1)
    HOME_ID=$(echo "$HOME_MATCH" | cut -d'|' -f1); HOME_NAME=$(echo "$HOME_MATCH" | cut -d'|' -f2)
else
    HOME_ID=$(echo "$HOME_DATA" | jq -r '.homes[0].id'); HOME_NAME=$(echo "$HOME_DATA" | jq -r '.homes[0].name // "Unknown"')
fi

if [ -z "$HOME_ID" ]; then log "ERROR: Could not retrieve Home ID."; exit 1; fi
log "Successfully retrieved Home: '${HOME_NAME}' (ID: $HOME_ID)"

ZONES_DATA=$(call_tado_api "GET" "https://my.tado.com/api/v2/homes/${HOME_ID}/zones")

if [ "$HEATING_ONLY" -eq 1 ]; then
    TARGET_ZONES=$(echo "$ZONES_DATA" | jq -r '.[] | select(.type=="HEATING") | "\(.id)|\(.name)|\(.type)"')
else
    TARGET_ZONES=$(echo "$ZONES_DATA" | jq -r '.[] | select(.type=="HEATING" or .type=="AIR_CONDITIONING") | "\(.id)|\(.name)|\(.type)"')
fi

# ==============================================================================
# 7. APPLY ACTIONS & STATE TRACKING
# ==============================================================================
while IFS='|' read -r ZONE_ID ZONE_NAME ZONE_TYPE; do
    log "--------------------------------------------------"
    log "Evaluating Zone: '$ZONE_NAME' (Type: $ZONE_TYPE)"
    
    # Check Current Zone State
    ZONE_STATE_URL="https://my.tado.com/api/v2/homes/${HOME_ID}/zones/${ZONE_ID}/state"
    ZONE_STATE_DATA=$(call_tado_api "GET" "$ZONE_STATE_URL")
    
    IFS='|' read -r CURRENT_OVERLAY_TYPE CURRENT_POWER CURRENT_TEMP_SETTING CURRENT_INSIDE_TEMP CURRENT_TERMINATION <<< "$(echo "$ZONE_STATE_DATA" | jq -r '
        "\(.overlayType // "")|\(.setting.power // "")|\(.setting.temperature.celsius // "")|\(.sensorDataPoints.insideTemperature.celsius // "")|\(.overlay.termination.type // "")"')"
    
    # State Tracking Verification
    TRACKING_KEY="${HOME_ID}_${ZONE_ID}"
    NORMALIZED_CURRENT_STATE=$(get_normalized_state "$CURRENT_OVERLAY_TYPE" "$CURRENT_POWER" "$CURRENT_TEMP_SETTING" "$CURRENT_TERMINATION")
    TRACKED_STATE=$(get_tracked_state "$TRACKING_KEY")
    EXTERNAL_CHANGE=0
    
    if [ -n "$TRACKED_STATE" ] && [ "$TRACKED_STATE" != "$NORMALIZED_CURRENT_STATE" ]; then
        EXTERNAL_CHANGE=1
    fi

    # Logging current values
    DISPLAY_CUR_TEMP="${CURRENT_INSIDE_TEMP:-N/A}"
    [ "$DISPLAY_CUR_TEMP" != "N/A" ] && DISPLAY_CUR_TEMP="${DISPLAY_CUR_TEMP}°C"
    DISPLAY_SET_TEMP="${CURRENT_TEMP_SETTING:-N/A}"
    [ "$CURRENT_POWER" == "OFF" ] && DISPLAY_SET_TEMP="OFF" || [ "$DISPLAY_SET_TEMP" != "N/A" ] && DISPLAY_SET_TEMP="${DISPLAY_SET_TEMP}°C"
    log "   Current Temp: $DISPLAY_CUR_TEMP | Set Temp: $DISPLAY_SET_TEMP"
    
    ZONE_OVERLAY_URL="https://my.tado.com/api/v2/homes/${HOME_ID}/zones/${ZONE_ID}/overlay"
    ZONE_ACTION="$ACTION"

    # Evaluate Smart 'Auto' logic 
    if [ "$FORCE_ACTION" == "AUTO" ] && [ -n "$CURRENT_INSIDE_TEMP" ]; then
        if [ "$(echo "$CURRENT_TEMP > $CURRENT_INSIDE_TEMP" | bc -l)" -eq 1 ]; then
            log "   [AUTO] Outside > Inside. Triggering Heating OFF."; ZONE_ACTION="TURN_OFF"
        elif [ "$(echo "($CURRENT_INSIDE_TEMP - $CURRENT_TEMP) > $AUTO_MAX_DIFF" | bc -l)" -eq 1 ]; then
            log "   [AUTO] Inside > Outside by ${AUTO_MAX_DIFF}°C. Triggering Heating OFF."; ZONE_ACTION="TURN_OFF"
        fi
    fi
    
    # Air Conditioning Inversions
    if [ "$ACTION" == "RESET_ALL" ]; then ZONE_ACTION="RESUME"
    elif [ "$ZONE_TYPE" == "AIR_CONDITIONING" ]; then
        if [ "$ZONE_ACTION" == "TURN_OFF" ]; then ZONE_ACTION="RESUME"
        elif [ "$ZONE_ACTION" == "RESUME" ]; then ZONE_ACTION="TURN_OFF"
        elif [ "$ZONE_ACTION" == "SET_TEMP" ]; then continue; fi
    fi
    
    # Check if user externally modified the zone
    if [ "$EXTERNAL_CHANGE" -eq 1 ]; then
        if [ "$FORCE_FLAG" -eq 0 ]; then
            log "   [TRACKING] External modification detected for Zone '$ZONE_NAME'."
            log "   -> Script last set: '$TRACKED_STATE'"
            log "   -> Current state:   '$NORMALIZED_CURRENT_STATE'"
            log "   Notification: Skipping zone to preserve user settings. Use --force to override."
            continue
        else
            log "   [TRACKING] External modification detected, but --force flag is active. Overwriting settings..."
        fi
    fi
    
    # Execute Commands and Update Tracking Memory
    if [ "$ZONE_ACTION" == "TURN_OFF" ]; then
        EXPECTED_STATE="MANUAL|OFF||MANUAL"
        
        if [ "$NORMALIZED_CURRENT_STATE" == "$EXPECTED_STATE" ]; then
            log "   Zone '$ZONE_NAME' is already set to MANUAL OFF. Skipping needless update."
            set_tracked_state "$TRACKING_KEY" "$EXPECTED_STATE"
            continue
        fi
        
        log "-> Sending OFF command for Zone '$ZONE_NAME'..."
        if [ "$DRY_RUN" -eq 0 ]; then
            call_tado_api "PUT" "$ZONE_OVERLAY_URL" "{\"setting\": {\"type\": \"$ZONE_TYPE\", \"power\": \"OFF\"}, \"termination\": {\"type\": \"MANUAL\"}}" > /dev/null
            set_tracked_state "$TRACKING_KEY" "$EXPECTED_STATE"
        fi
        
    elif [ "$ZONE_ACTION" == "RESUME" ]; then
        EXPECTED_STATE="SCHEDULE"
        
        if [ "$NORMALIZED_CURRENT_STATE" == "$EXPECTED_STATE" ]; then
            log "   Zone '$ZONE_NAME' is already following the schedule. Skipping needless update."
            set_tracked_state "$TRACKING_KEY" "$EXPECTED_STATE"
            continue
        fi
        
        log "-> Sending RESUME command for Zone '$ZONE_NAME'..."
        if [ "$DRY_RUN" -eq 0 ]; then
            call_tado_api "DELETE" "$ZONE_OVERLAY_URL" > /dev/null
            set_tracked_state "$TRACKING_KEY" "$EXPECTED_STATE"
        fi
        
    elif [ "$ZONE_ACTION" == "SET_TEMP" ]; then
        FMT_TARGET=$(printf "%.1f" "$TARGET_TEMP")
        EXPECTED_STATE="MANUAL|ON|${FMT_TARGET}|TADO_MODE"
        
        if [ "$NORMALIZED_CURRENT_STATE" == "$EXPECTED_STATE" ]; then
            log "   Zone '$ZONE_NAME' is already set to ${TARGET_TEMP}°C. Skipping needless update."
            set_tracked_state "$TRACKING_KEY" "$EXPECTED_STATE"
            continue
        fi
        
        log "-> Sending SET TEMPERATURE (${TARGET_TEMP}°C) command for Zone '$ZONE_NAME'..."
        if [ "$DRY_RUN" -eq 0 ]; then
            call_tado_api "PUT" "$ZONE_OVERLAY_URL" "{\"setting\": {\"type\": \"$ZONE_TYPE\", \"power\": \"ON\", \"temperature\": {\"celsius\": $TARGET_TEMP}}, \"termination\": {\"type\": \"TADO_MODE\"}}" > /dev/null
            set_tracked_state "$TRACKING_KEY" "$EXPECTED_STATE"
        fi
    fi
    
    sleep 1
done <<< "$TARGET_ZONES"

log "--------------------------------------------------"
log "Script execution completed successfully!"
exit 0

