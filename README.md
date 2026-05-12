# Tado Automation Suite

A robust, dependency-light suite of Bash scripts designed to manage your Tado Heating and Air Conditioning zones.

This suite includes an automated weather-based climate control script to save energy without sacrificing comfort, alongside powerful manual utility scripts to query states and force configurations across your local network or via Cron.

## Features

* **No Passwords Stored:** Fully supports Tado's modern OAuth2 Device Code flow. Authenticate once, and all tools share the same securely rotated token.

* **Weather Automation:** Intelligently checks Open-Meteo to disable heating on unusually warm days or compare inside vs. outside temperatures (`tado_weather_control.sh`).

* **Instant Overrides:** Turn zones `on`, `off`, `reset`, or to specific temperatures via the command line (`tado_set.sh`).

* **Easy Status Checks:** Instantly see the temperature and schedule state of every zone in your home. Or, output directly to JSON for third-party integrations (`tado_get.sh`).

* **Multi-Home & Multi-Zone:** Specify exact Tado homes and zones by name or ID across all scripts.

## Prerequisites

Ensure the following common packages are installed on your system:

* `curl` (for making API requests)

* `jq` (for parsing JSON responses)

* `bc` (for floating-point math comparisons)

* `logger` (for syslog integration, usually pre-installed on Linux/macOS)

**Debian/Ubuntu:**

```
sudo apt-get install curl jq bc

```

## Setup & Authentication

1. Download the scripts and make them executable:

   ```
   chmod +x tado_weather_control.sh tado_get.sh tado_set.sh
   
   ```

2. Run the one-time authentication flow to securely link your Tado account. **You only need to do this on one of the scripts; they share the same token (`~/.tado_token`)**:

   ```
   ./tado_get.sh --auth
   
   ```

   *The script will provide a link. Open it in your browser, log in to Tado, and approve the application.*

## Tools Included

### 1. `tado_get.sh` (Status & Monitoring)

Lists all zones across all your Tado homes by default, including their ID, name, schedule state, current temperature, and set temperature.

**Usage:**

```
# List all zones in all available homes (Default)
./tado_get.sh

# List all zones across all homes and format the output as JSON
./tado_get.sh --json

# List zones for a specific home
./tado_get.sh --home "Summer House"

# Get details for a specific zone only
./tado_get.sh --zone "Living Room"

```

### 2. `tado_set.sh` (Manual Override)

Manually force the state or temperature of specific zones, bypassing schedules.

**Commands:**

* `<temp>C` - Set to a specific temperature until next schedule block (e.g., `21C`)

* `off` - Turn the zone entirely OFF (Manual override)

* `on` / `reset` - Delete manual overlays and resume the smart schedule.

**Usage:**

```
# Set the Living Room to 21.5C
./tado_set.sh --zone "Living Room" 21.5C

# Turn off a specific zone
./tado_set.sh --zone "Bedroom" off

# Reset/Resume schedules for ALL zones in the default home
./tado_set.sh reset

```

### 3. `tado_weather_control.sh` (Weather Automation)

Automatically manages your zones based on real-time weather data.
By continuously evaluating the outside temperature, this script prevents your heating from running on warm days.

**Usage:**

```
# Run weather logic against the default configured city
./tado_weather_control.sh

# Run smart Auto mode (evaluates Inside vs. Outside temps)
./tado_weather_control.sh auto

# Run against a specific city
./tado_weather_control.sh --city "London"

```

#### Automation (Cron)

To fully automate the weather logic, set it up to run periodically using `cron`.

Open your crontab (`crontab -e`) and add:

```
# Run every 15 minutes, piping logs to syslog
*/15 * * * * /path/to/your/tado_weather_control.sh --syslog > /dev/null 2>&1

```

## Configuration

You can tweak the default weather behavior by editing the variables at the top of the `tado_weather_control.sh` file:

* `CITY_NAME`: Default city used for the Open-Meteo weather check.

* `TEMP_OFF_THRESHOLD`: Outside temperature at which heating switches OFF.

* `TEMP_RESUME_THRESHOLD`: Outside temperature at which heating schedule resumes.

* `AUTO_MAX_DIFF`: Max allowed difference between inside/outside temps before Auto mode turns off heating.


