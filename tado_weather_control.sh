#!/bin/bash

# ==============================================================================
# File: tado_weather_control.sh
# Version: 2.17
# Last Updated: 2026-05-12 04:40 CEST
#
# HISTORY:
# v2.17 (2026-05-12) - Added 'auto' mode to dynamically switch off heating 
#                      if outside > inside, or if inside > outside by 10C.
# v2.16 (2026-05-12) - Added '--force' flag to prevent overwriting existing manual 
#                      heating temperatures unless explicitly requested.
# v2.15 (2026-05-12) - Added '--city <name>' parameter to override the default city.
# v2.14 (2026-05-12) - Replaced hardcoded coordinates with dynamic city name 
#                      lookup via Open-Meteo Geocoding API.
# v2.13 (2026-05-12) - Added 'reset' manual override to resume schedule for all zones.
# v2.12 (2026-05-12) - Added support to manually set a temperature for heating zones 
#                      until the next schedule block (e.g., '21C').
# v2.11 (2026-05-12) - Added validation for command-line arguments to exit on unrecognized parameters.
# v2.10 (2026-05-12) - Fixed logger unrecognized option error when logging dashes.
# v2.9 (2026-05-12) - Added logger to the prerequisites check.
# v2.8 (2026-05-12) - Decoupled --syslog from --notime so users can decide independently.
# v2.7 (2026-05-12) - Added --syslog parameter to route logs to syslog (implies --notime).
# v2.6 (2026-05-12) - Added --notime parameter to disable timestamps in logs.
# v2.5 (2026-05-12) - Added support for AIR_CONDITIONING zones. AC actions are
#                     always the opposite of HEATING actions.
# v2.4 (2026-05-12) - Added --help (-h) and --version (-V) command-line arguments.
# v2.3 (2026-05-12) - Added zone names to the logging output for better readability.
# v2.2 (2026-05-12) - Fixed JSON parsing for Home ID to use '.homes[0].id'.
# v2.1 (2026-05-12) - Added pre-checks to prevent redundant API calls if a zone 
#                     is already in the desired target state.
# v2.0 (2026-05-12) - Migrated to OAuth2 Device Code Flow (Tado deprecated password auth).
#                     Added '--auth' command and automatic token rotation.
# v1.2 (2026-05-12) - Added script header, versioning, and changelog history.
# v1.1 (2026-05-12) - Added manual overrides ('on'/'off') and '--dryrun' flag.
# v1.0 (2026-05-12) - Initial release with Open-Meteo and Tado integration.
# ==============================================================================

SCRIPT_VERSION="2.16"

# ==============================================================================
# TADO WEATHER AUTOMATION SCRIPT
# ==============================================================================
# Description:
# This script checks the current outside temperature for your specified city.
# - If the temperature is ABOVE 15°C, it puts the Tado heating zone into MANUAL OFF mode.
# - If the temperature is BELOW 16°C, it deletes the manual overlay, resuming the smart schedule.
# - Air Conditioning zones act identically but in reverse (e.g., cooling enabled when hot).
#
# HOW TO USE:
# 1. Run the interactive setup ONCE to authenticate with Tado securely:
#    ./tado_weather_control.sh --auth
# 2. Run it manually to test: 
#    ./tado_weather_control.sh
# 3. Automate it using Cron. Run 'crontab -e' and add this line to run it every 15 mins:
#    */15 * * * * /path/to/your/tado_weather_control.sh >> /tmp/tado_script.log 2>&1
# ==============================================================================

# ==============================================================================
# 1. USER CONFIGURATION
# ==============================================================================
# File where the Tado refresh token will be securely stored
TOKEN_FILE="$HOME/.tado_token"

# Tado's official public Client ID for Device Auth (no secret required)
TADO_CLIENT_ID="1bb50063-6b0c-4d11-bd99-387f4a91cc46"

# Target City for Weather Data
CITY_NAME="Amsterdam"

# Temperature Thresholds (Celsius)
TEMP_OFF_THRESHOLD=16.0
TEMP_RESUME_THRESHOLD=15.0

# Auto Mode Threshold (Celsius)
# If the temperature inside is higher than outside by more than this value, 
# heating will be switched OFF (when using 'auto' mode).
AUTO_MAX_DIFF=10.0

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
    echo "  - Anything in between acts as a deadzone/buffer to prevent flapping."
    echo ""
    echo "Usage:"
    echo "  ./tado_weather_control.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -h, --help       Show this help message and exit."
    echo "  -V, --version    Show the script version and exit."
    echo "  --auth           Run the interactive OAuth2 setup to link your Tado account."
    echo "  --city <name>    Override the default city ($CITY_NAME) for weather data."
    echo "  --dryrun         Run the script normally but do not send commands to Tado."
    echo "  --force          Overwrite existing manual temperature settings on heating zones."
    echo "  --notime         Disable date/time stamps in the logging output."
    echo "  --syslog         Output logs to syslog in addition to standard output."
    echo "  auto             Manual override: Smart evaluation comparing inside/outside temps."
    echo "  on               Manual override: Force Tado to RESUME schedule (ignores weather)."
    echo "  off              Manual override: Force Tado to switch OFF (ignores weather)."
    echo "  reset            Manual override: Reset all zones to their default smart schedule."
    echo "  <temp>C          Manual override: Set heating zones to a specific temperature (0-25)"
    echo "                   until the next schedule block begins (e.g., 20.5C or 21C)."
    echo "=========================================================="
    exit 0
}

# ==============================================================================
# 3. ARGUMENT PARSING & SETUP
# ==============================================================================
DRY_RUN=0
FORCE_ACTION=""
TARGET_TEMP=""
RUN_AUTH=0
EXPECT_CITY=0
FORCE_FLAG=0

for arg in "$@"; do
    if [ "$EXPECT_CITY" -eq 1 ]; then
        CITY_NAME="$arg"
        EXPECT_CITY=0
        continue
    fi

    if [ "$arg" == "-h" ] || [ "$arg" == "--help" ]; then
        show_help
    elif [ "$arg" == "-V" ] || [ "$arg" == "--version" ]; then
        show_version
    elif [ "$arg" == "--city" ]; then
        EXPECT_CITY=1
    elif [ "$arg" == "--dryrun" ]; then
        DRY_RUN=1
        log "NOTICE: Running in DRY RUN mode. No actions will be sent to Tado."
    elif [ "$arg" == "--force" ]; then
        FORCE_FLAG=1
        log "NOTICE: Force mode enabled. Existing manual temperature settings will be overwritten."
    elif [ "$arg" == "--notime" ]; then
        SHOW_TIME=0
    elif [ "$arg" == "--syslog" ]; then
        USE_SYSLOG=1
    elif [ "$arg" == "auto" ]; then
        FORCE_ACTION="AUTO"
        log "NOTICE: Override 'auto' specified. Smart inside/outside temp comparison enabled."
    elif [ "$arg" == "on" ]; then
        FORCE_ACTION="RESUME"
        log "NOTICE: Manual override 'on' specified. Will force Tado to resume schedule."
    elif [ "$arg" == "off" ]; then
        FORCE_ACTION="TURN_OFF"
        log "NOTICE: Manual override 'off' specified. Will force Tado to switch OFF."
    elif [ "$arg" == "reset" ]; then
        FORCE_ACTION="RESET_ALL"
        log "NOTICE: Manual override 'reset' specified. Will force all zones to resume schedule."
    elif [[ "$arg" =~ ^([0-9]+(\.[0-9]+)?)C$ ]]; then
        TEMP_VAL="${BASH_REMATCH[1]}"
        # Ensure the temperature is between 0 and 25
        if [ "$(echo "$TEMP_VAL >= 0 && $TEMP_VAL <= 25" | bc -l)" -eq 1 ]; then
            FORCE_ACTION="SET_TEMP"
            TARGET_TEMP="$TEMP_VAL"
            log "NOTICE: Manual override specified. Will force Heating zones to ${TARGET_TEMP}°C until next schedule."
        else
            log "ERROR: Manual temperature must be between 0 and 25 Celsius."
            exit 1
        fi
    elif [ "$arg" == "--auth" ]; then
        RUN_AUTH=1
    else
        log "ERROR: Unrecognized command-line parameter: '$arg'"
        log "Use --help to see available options."
        exit 1
    fi
done

if [ "$EXPECT_CITY" -eq 1 ]; then
    log "ERROR: --city parameter requires a city name argument (e.g., --city \"New York\")."
    exit 1
fi

# Check prerequisites
for cmd in curl jq bc logger; do
    if ! command -v $cmd &> /dev/null; then
        log "ERROR: Required command '$cmd' is not installed."
        exit 1
    fi
done

# ==============================================================================
# 4. TADO DEVICE AUTHENTICATION (ONE-TIME SETUP)
# ==============================================================================
if [ "$RUN_AUTH" -eq 1 ]; then
    log "Starting Tado Device Code Authorization Flow..."
    
    # Step 1: Request Device Code
    AUTH_RES=$(curl -s -X POST "https://login.tado.com/oauth2/device_authorize" \
        -d "client_id=$TADO_CLIENT_ID" \
        -d "scope=offline_access")
        
    DEVICE_CODE=$(echo "$AUTH_RES" | jq -r '.device_code')
    VERIFY_URI=$(echo "$AUTH_RES" | jq -r '.verification_uri_complete')
    INTERVAL=$(echo "$AUTH_RES" | jq -r '.interval')
    
    if [ "$DEVICE_CODE" == "null" ] || [ -z "$DEVICE_CODE" ]; then
        log "ERROR: Failed to initiate auth flow. Response: $AUTH_RES"
        exit 1
    fi

    echo ""
    echo "=========================================================="
    echo " ACTION REQUIRED:"
    echo " 1. Please open this URL in your browser (phone or desktop):"
    echo "    $VERIFY_URI"
    echo " 2. Log in to your Tado account to approve this script."
    echo "=========================================================="
    echo -n "Waiting for your approval "

    # Step 2: Poll for Token Approval
    TOKEN_URL="https://login.tado.com/oauth2/token"
    while true; do
        sleep "${INTERVAL:-5}"
        
        TOKEN_RES=$(curl -s -X POST "$TOKEN_URL" \
            -d "client_id=$TADO_CLIENT_ID" \
            -d "device_code=$DEVICE_CODE" \
            -d "grant_type=urn:ietf:params:oauth:grant-type:device_code")
            
        ERR=$(echo "$TOKEN_RES" | jq -r '.error')
        
        if [ "$ERR" == "authorization_pending" ]; then
            echo -n "."
        elif [ "$ERR" == "null" ] || [ -z "$ERR" ]; then
            REFRESH_TOKEN=$(echo "$TOKEN_RES" | jq -r '.refresh_token')
            
            # Save the token securely
            echo "$REFRESH_TOKEN" > "$TOKEN_FILE"
            chmod 600 "$TOKEN_FILE"
            
            echo ""
            echo "=========================================================="
            echo " SUCCESS! Authentication complete."
            echo " Token securely saved to: $TOKEN_FILE"
            echo " You can now run the script normally."
            echo "=========================================================="
            exit 0
        else
            echo ""
            log "ERROR during authorization: $ERR"
            exit 1
        fi
    done
fi

# Ensure Token exists before proceeding
if [ ! -f "$TOKEN_FILE" ]; then
    log "ERROR: Authentication token missing."
    log "Please run './tado_weather_control.sh --auth' first to log in to Tado."
    exit 1
fi

# ==============================================================================
# 5. FETCH WEATHER DATA (OR USE OVERRIDE)
# ==============================================================================
if [ -n "$FORCE_ACTION" ] && [ "$FORCE_ACTION" != "AUTO" ]; then
    ACTION="$FORCE_ACTION"
    log "Skipping weather check due to manual override. Main Action set to: $ACTION"
else
    log "Resolving coordinates for city: $CITY_NAME..."
    # Replace spaces with %20 for URL encoding
    ENCODED_CITY=$(echo "$CITY_NAME" | sed 's/ /%20/g')
    GEO_URL="https://geocoding-api.open-meteo.com/v1/search?name=${ENCODED_CITY}&count=1&language=en&format=json"

    GEO_RESPONSE=$(curl -s "$GEO_URL")
    if [ -z "$GEO_RESPONSE" ]; then
        log "ERROR: Failed to fetch geocoding data from Open-Meteo."
        exit 1
    fi

    # Extract latitude and longitude of the top result
    LATITUDE=$(echo "$GEO_RESPONSE" | jq -r '.results[0].latitude // empty')
    LONGITUDE=$(echo "$GEO_RESPONSE" | jq -r '.results[0].longitude // empty')

    if [ -z "$LATITUDE" ] || [ -z "$LONGITUDE" ]; then
        log "ERROR: Could not find coordinates for city: $CITY_NAME. Please check the spelling."
        exit 1
    fi

    log "Found coordinates for $CITY_NAME -> Latitude: $LATITUDE, Longitude: $LONGITUDE"

    log "Fetching current weather..."
    WEATHER_URL="https://api.open-meteo.com/v1/forecast?latitude=${LATITUDE}&longitude=${LONGITUDE}&current_weather=true"

    WEATHER_RESPONSE=$(curl -s "$WEATHER_URL")
    if [ -z "$WEATHER_RESPONSE" ]; then
        log "ERROR: Failed to fetch weather data."
        exit 1
    fi

    CURRENT_TEMP=$(echo "$WEATHER_RESPONSE" | jq -r '.current_weather.temperature')

    if [ "$CURRENT_TEMP" == "null" ] || [ -z "$CURRENT_TEMP" ]; then
        log "ERROR: Could not parse temperature from weather API response."
        exit 1
    fi

    log "Current outside temperature is: ${CURRENT_TEMP}°C"

    ACTION="NONE"
    if [ "$(echo "$CURRENT_TEMP >= $TEMP_OFF_THRESHOLD" | bc -l)" -eq 1 ]; then
        ACTION="TURN_OFF"
        log "Temperature is >= ${TEMP_OFF_THRESHOLD}°C. Action: Disable Heating (Enable AC)."
    elif [ "$(echo "$CURRENT_TEMP <= $TEMP_RESUME_THRESHOLD" | bc -l)" -eq 1 ]; then
        ACTION="RESUME"
        log "Temperature is <= ${TEMP_RESUME_THRESHOLD}°C. Action: Resume Heating Schedule (Disable AC)."
    else
        log "Temperature is in the buffer zone. Doing nothing."
        exit 0
    fi
fi

# ==============================================================================
# 6. TADO TOKEN REFRESH
# ==============================================================================
log "Authenticating with Tado using saved token..."
SAVED_REFRESH_TOKEN=$(cat "$TOKEN_FILE")

TOKEN_RES=$(curl -s -X POST "https://login.tado.com/oauth2/token" \
    -d "client_id=$TADO_CLIENT_ID" \
    -d "grant_type=refresh_token" \
    -d "refresh_token=${SAVED_REFRESH_TOKEN}")

ACCESS_TOKEN=$(echo "$TOKEN_RES" | jq -r '.access_token')

if [ "$ACCESS_TOKEN" == "null" ] || [ -z "$ACCESS_TOKEN" ]; then
    ERROR_DESC=$(echo "$TOKEN_RES" | jq -r '.error_description')
    log "ERROR: Failed to refresh Tado token! $ERROR_DESC"
    log "Your token may have expired. Please run './tado_weather_control.sh --auth' again."
    exit 1
fi

# Tado uses Token Rotation. We must save the newly issued refresh token 
# to keep the chain alive for the next time the script runs.
NEW_REFRESH_TOKEN=$(echo "$TOKEN_RES" | jq -r '.refresh_token')
echo "$NEW_REFRESH_TOKEN" > "$TOKEN_FILE"

log "Authentication successful."

# ==============================================================================
# 7. TADO API RATE-LIMIT WRAPPER
# ==============================================================================
call_tado_api() {
    local METHOD="$1"
    local URL="$2"
    local PAYLOAD="$3"
    
    local RETRIES=0
    local MAX_RETRIES=5
    local SLEEP_TIME=30
    
    while [ "$RETRIES" -lt "$MAX_RETRIES" ]; do
        if [ -n "$PAYLOAD" ]; then
            RESPONSE=$(curl -s -w "\n%{http_code}" -X "$METHOD" \
                -H "Authorization: Bearer ${ACCESS_TOKEN}" \
                -H "Content-Type: application/json;charset=UTF-8" \
                -d "$PAYLOAD" "$URL")
        else
            RESPONSE=$(curl -s -w "\n%{http_code}" -X "$METHOD" \
                -H "Authorization: Bearer ${ACCESS_TOKEN}" "$URL")
        fi
        
        HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
        BODY=$(echo "$RESPONSE" | sed '$d')
        
        if [ "$HTTP_CODE" -eq 429 ]; then
            log "WARNING: Rate Limit hit (HTTP 429). Sleeping for ${SLEEP_TIME}s..."
            sleep "$SLEEP_TIME"
            RETRIES=$((RETRIES + 1))
            SLEEP_TIME=$((SLEEP_TIME * 2))
        elif [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
            echo "$BODY"
            return 0
        else
            log "ERROR: API Call failed. HTTP Code: $HTTP_CODE | Response: $BODY"
            return 1
        fi
    done
    
    log "ERROR: Max retries reached. Aborting."
    return 1
}

# ==============================================================================
# 8. GET TADO HOME ID & ZONES
# ==============================================================================
HOME_DATA=$(call_tado_api "GET" "https://my.tado.com/api/v2/me")
# Parse 'id' from the first object inside the 'homes' array
HOME_ID=$(echo "$HOME_DATA" | jq -r '.homes[0].id')

if [ -z "$HOME_ID" ] || [ "$HOME_ID" == "null" ]; then
    log "ERROR: Could not retrieve Home ID."
    log "Raw response from Tado: $HOME_DATA"
    exit 1
fi
log "Successfully retrieved Home ID: $HOME_ID"

ZONES_DATA=$(call_tado_api "GET" "https://my.tado.com/api/v2/homes/${HOME_ID}/zones")

# Extract ID, Name, and Type for both HEATING and AIR_CONDITIONING zones
TARGET_ZONES=$(echo "$ZONES_DATA" | jq -r '.[] | select(.type=="HEATING" or .type=="AIR_CONDITIONING") | "\(.id)|\(.name)|\(.type)"')

if [ -z "$TARGET_ZONES" ]; then
    log "ERROR: No Heating or Air Conditioning zones found."
    exit 1
fi

# ==============================================================================
# 9. APPLY ACTIONS TO ZONES
# ==============================================================================
# Read through the extracted zones line by line
while IFS='|' read -r ZONE_ID ZONE_NAME ZONE_TYPE; do
    log "--------------------------------------------------"
    log "Evaluating Zone: '$ZONE_NAME' (ID: $ZONE_ID, Type: $ZONE_TYPE)"
    
    # 9a. Check Current Zone State
    ZONE_STATE_URL="https://my.tado.com/api/v2/homes/${HOME_ID}/zones/${ZONE_ID}/state"
    ZONE_STATE_DATA=$(call_tado_api "GET" "$ZONE_STATE_URL")
    
    # Extract relevant fields to determine the state
    CURRENT_OVERLAY_TYPE=$(echo "$ZONE_STATE_DATA" | jq -r '.overlayType')
    CURRENT_POWER=$(echo "$ZONE_STATE_DATA" | jq -r '.setting.power')
    CURRENT_TEMP_SETTING=$(echo "$ZONE_STATE_DATA" | jq -r '.setting.temperature.celsius')
    CURRENT_INSIDE_TEMP=$(echo "$ZONE_STATE_DATA" | jq -r '.sensorDataPoints.insideTemperature.celsius // empty')
    CURRENT_TERMINATION=$(echo "$ZONE_STATE_DATA" | jq -r '.overlay.termination.type')
    
    ZONE_OVERLAY_URL="https://my.tado.com/api/v2/homes/${HOME_ID}/zones/${ZONE_ID}/overlay"
    
    # 9b. Determine Action based on Auto Mode and Weather
    ZONE_ACTION="$ACTION"
    if [ "$FORCE_ACTION" == "AUTO" ] && [ -n "$CURRENT_INSIDE_TEMP" ]; then
        if [ "$(echo "$CURRENT_TEMP > $CURRENT_INSIDE_TEMP" | bc -l)" -eq 1 ]; then
            log "   [AUTO] Outside (${CURRENT_TEMP}°C) > Inside (${CURRENT_INSIDE_TEMP}°C). Triggering Heating OFF."
            ZONE_ACTION="TURN_OFF"
        elif [ "$(echo "($CURRENT_INSIDE_TEMP - $CURRENT_TEMP) > $AUTO_MAX_DIFF" | bc -l)" -eq 1 ]; then
            log "   [AUTO] Inside (${CURRENT_INSIDE_TEMP}°C) > Outside (${CURRENT_TEMP}°C) by more than ${AUTO_MAX_DIFF}°C. Triggering Heating OFF."
            ZONE_ACTION="TURN_OFF"
        else
            log "   [AUTO] Smart conditions not met. Falling back to default weather logic."
        fi
    fi
    
    # 9c. Handle Air Conditioning & Resets
    if [ "$ACTION" == "RESET_ALL" ]; then
        ZONE_ACTION="RESUME"
    elif [ "$ZONE_TYPE" == "AIR_CONDITIONING" ]; then
        if [ "$ZONE_ACTION" == "TURN_OFF" ]; then
            ZONE_ACTION="RESUME"
        elif [ "$ZONE_ACTION" == "RESUME" ]; then
            ZONE_ACTION="TURN_OFF"
        elif [ "$ZONE_ACTION" == "SET_TEMP" ]; then
            log "   Skipping Air Conditioning zone '$ZONE_NAME' for heating temperature override."
            continue
        fi
    fi
    
    # 9d. Protect existing manual temperature overrides on heating zones
    if [ "$FORCE_FLAG" -eq 0 ] && [ "$ZONE_TYPE" == "HEATING" ] && [ "$CURRENT_OVERLAY_TYPE" == "MANUAL" ] && [ "$CURRENT_POWER" == "ON" ] && [ "$ACTION" != "RESET_ALL" ]; then
        log "   Zone '$ZONE_NAME' has a manual temperature set. Skipping (use --force to overwrite)."
        continue
    fi
    
    # 9e. Evaluate and Execute Command
    if [ "$ZONE_ACTION" == "TURN_OFF" ]; then
        # Check if it's already OFF under a manual overlay
        if [ "$CURRENT_OVERLAY_TYPE" == "MANUAL" ] && [ "$CURRENT_POWER" == "OFF" ]; then
            log "   Zone '$ZONE_NAME' is already set to MANUAL OFF. Skipping needless update."
            continue
        fi
        
        log "-> Sending OFF command for Zone '$ZONE_NAME'..."
        # Notice we dynamically inject the ZONE_TYPE into the payload here
        PAYLOAD="{\"setting\": {\"type\": \"$ZONE_TYPE\", \"power\": \"OFF\"}, \"termination\": {\"type\": \"MANUAL\"}}"
        
        if [ "$DRY_RUN" -eq 1 ]; then
            log "   [DRY RUN] Would execute PUT to switch OFF."
        else
            call_tado_api "PUT" "$ZONE_OVERLAY_URL" "$PAYLOAD" > /dev/null
            log "   Successfully switched OFF."
        fi
        
    elif [ "$ZONE_ACTION" == "RESUME" ]; then
        # Check if it's already following the smart schedule (no overlay active)
        if [ "$CURRENT_OVERLAY_TYPE" == "null" ] || [ -z "$CURRENT_OVERLAY_TYPE" ]; then
            log "   Zone '$ZONE_NAME' is already following the schedule (no active overlay). Skipping needless update."
            continue
        fi
        
        log "-> Sending RESUME command for Zone '$ZONE_NAME'..."
        
        if [ "$DRY_RUN" -eq 1 ]; then
            log "   [DRY RUN] Would execute DELETE to resume schedule."
        else
            call_tado_api "DELETE" "$ZONE_OVERLAY_URL" > /dev/null
            log "   Successfully resumed schedule."
        fi
        
    elif [ "$ZONE_ACTION" == "SET_TEMP" ]; then
        # Check if it's already perfectly set to our target state
        if [ "$CURRENT_POWER" == "ON" ] && [ "$CURRENT_TEMP_SETTING" == "$TARGET_TEMP" ] && [ "$CURRENT_TERMINATION" == "TADO_MODE" ]; then
            log "   Zone '$ZONE_NAME' is already set to ${TARGET_TEMP}°C until next schedule block. Skipping needless update."
            continue
        fi
        
        log "-> Sending SET TEMPERATURE (${TARGET_TEMP}°C) command for Zone '$ZONE_NAME'..."
        PAYLOAD="{\"setting\": {\"type\": \"$ZONE_TYPE\", \"power\": \"ON\", \"temperature\": {\"celsius\": $TARGET_TEMP}}, \"termination\": {\"type\": \"TADO_MODE\"}}"
        
        if [ "$DRY_RUN" -eq 1 ]; then
            log "   [DRY RUN] Would execute PUT to set temperature to ${TARGET_TEMP}°C."
        else
            call_tado_api "PUT" "$ZONE_OVERLAY_URL" "$PAYLOAD" > /dev/null
            log "   Successfully set temperature to ${TARGET_TEMP}°C."
        fi
    fi
    
    sleep 1
done <<< "$TARGET_ZONES"

log "--------------------------------------------------"
log "Script execution completed successfully!"
exit 0

