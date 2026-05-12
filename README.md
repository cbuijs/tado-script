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

**Parameters:**

* `-h`, `--help`: Show the help message and exit.

* `-V`, `--version`: Show the script version and exit.

* `--auth`: Run the interactive OAuth2 setup to link your Tado account.

* `--home <target>`: Specify which Tado home to query by Name or ID.

* `--json`: Output the results in raw JSON format (useful for integrations).

* `--zone <target>`: Filter output to a specific zone by Name or ID.

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

**Positional Actions (Pick One):**

* `<temp>C` - Set to a specific temperature until next schedule block (e.g., `21.5C`)

* `off` - Turn the zone entirely OFF (Manual override)

* `on` / `reset` - Delete manual overlays and resume the smart schedule.

**Parameters:**

* `-h`, `--help`: Show the help message and exit.

* `--auth`: Run the interactive OAuth2 setup to link your Tado account.

* `--home <target>`: Specify which Tado home to control by Name or ID.

* `--zone <target>`: Specify a specific zone by Name or ID. If omitted, applies to **ALL** zones.

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

**Parameters:**

* `-h`, `--help`: Show the help message and exit.

* `-V`, `--version`: Show the script version and exit.

* `--auth`: Run the interactive OAuth2 setup to link your Tado account.

* `--city <name>`: Override the default city (configured in the script) for Open-Meteo weather data.

* `--dryrun`: Run the script normally and evaluate logic, but do not send actual commands to Tado.

* `--force`: Overwrite existing manual temperature settings on heating zones. (By default, manual user adjustments are respected).

* `--home <target>`: Specify which Tado home to control by exact Name or ID.

* `--notime`: Disable date/time stamps in the standard logging output.

* `--syslog`: Output logs to syslog in addition to standard output (highly recommended for Cron usage).

**Manual Action Overrides (Optional):**

* `auto`: Smart evaluation comparing inside/outside temps dynamically.

* `on`: Force Tado to RESUME schedule (ignores weather logic).

* `off`: Force Tado to switch OFF (ignores weather logic).

* `reset`: Reset all zones to their default smart schedule.

* `<temp>C`: Force heating zones to a specific temperature (0-25) until the next schedule.

#### How the Automation Rules Work

The script applies a set of logical rules based on outside weather, inside temperatures, and your configured zone types.

**1. Standard Weather Rules (Default)**
Evaluates the outside temperature from Open-Meteo against configurable thresholds (Default: OFF at 16°C, Resume at 15°C).

* **Heating Zones:**

  * **Warm Days (>= 16°C):** Sets zone to **MANUAL OFF**.

  * **Cool Days (<= 15°C):** Deletes manual overlays, **RESUMING** the smart schedule.

  * **Buffer Zone (15°C - 16°C):** Does nothing. This acts as a deadzone to prevent rapid toggling (flapping) if the temperature fluctuates right at the threshold.

* **Air Conditioning Zones (Inverse Logic):**

  * **Warm Days (>= 16°C):** **RESUMES** AC smart schedule (cooling allowed).

  * **Cool Days (<= 15°C):** Sets AC to **MANUAL OFF**.

**2. Smart "Auto" Mode Rules (`auto` argument)**
Instead of relying solely on static weather thresholds, this mode intelligently compares the *inside* temperature of each specific zone against the *outside* temperature:

* If **Outside Temp > Inside Temp**: Forces Heating OFF.

* If **Inside Temp > Outside Temp** by more than `AUTO_MAX_DIFF` (default 10°C): Forces Heating OFF to save extreme heating costs.

**3. Protection & Efficiency Safeguards**

* **Manual Override Protection:** If a heating zone already has a manual temperature set (e.g., someone boosted the heat via the physical thermostat or app), the script **will skip** that zone to respect human preference. You can bypass this using the `--force` flag.

* **API State Awareness:** The script reads the current state of all zones first. If a zone is already in the target state (e.g., already OFF), it skips sending redundant API commands. This speeds up execution and prevents you from hitting Tado's rate limits.

**Usage:**

```
# Run weather logic against the default configured city
./tado_weather_control.sh

# Run smart Auto mode (evaluates Inside vs. Outside temps)
./tado_weather_control.sh auto

# Run against a specific city
./tado_weather_control.sh --city "London"

# Run weather logic and overwrite any manual user settings
./tado_weather_control.sh --force

# Perform a dry run to see what the script WOULD do
./tado_weather_control.sh --dryrun

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

* `CITY_NAME`: Default city used for the Open-Meteo geocoding and weather check.

* `TEMP_OFF_THRESHOLD`: Outside temperature at which heating switches OFF.

* `TEMP_RESUME_THRESHOLD`: Outside temperature at which heating schedule resumes.

* `AUTO_MAX_DIFF`: Max allowed difference between inside/outside temps before Auto mode turns off heating.


