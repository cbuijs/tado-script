```
# Tado Weather Control

A robust, dependency-light Bash script designed to automatically manage your Tado Heating and Air Conditioning zones based on real-time weather data from Open-Meteo.

By continuously evaluating the outside temperature (and optionally inside temperature), this script prevents your heating from running on unusually warm days and manages your air conditioning logically, saving energy without sacrificing comfort.

## Features

* **No Weather API Keys Required:** Uses the free, open Open-Meteo API for geocoding and weather fetching.
* **Smart Device Code Authentication:** Fully supports Tado's modern OAuth2 Device Code flow. No passwords stored.
* **Auto Mode:** Intelligent evaluation comparing inside vs. outside temperatures.
* **AC Support:** Automatically applies inverse logic for Air Conditioning zones.
* **Manual Overrides:** Instantly force all zones `on`, `off`, `reset`, or to a specific temperature (e.g., `21C`).
* **Rate-Limit Safe:** Built-in exponential backoff to respect Tado's API limits.
* **Syslog Integration:** Native logging capabilities for system-level monitoring.

## Prerequisites

Ensure the following common packages are installed on your system:
* `curl` (for making API requests)
* `jq` (for parsing JSON responses)
* `bc` (for floating-point math comparisons)
* `logger` (for syslog integration, usually pre-installed on Linux/macOS)

**Debian/Ubuntu:**
```bash
sudo apt-get install curl jq bc
```

**macOS (via Homebrew):**
```bash
brew install jq bc
```

## Setup & Authentication

1. Download the script and make it executable:
   ```bash
   chmod +x tado_weather_control.sh
   ```
2. Run the one-time authentication flow to securely link your Tado account:
   ```bash
   ./tado_weather_control.sh --auth
   ```
   *The script will provide a link. Open it in your browser, log in to Tado, and approve the application. The script will securely save an expiring refresh token to `~/.tado_token` and automatically handle future rotations.*

## Usage

Run the script manually to process the default weather logic:
```bash
./tado_weather_control.sh
```

### Commands

| Command | Description |
| :--- | :--- |
| `auto` | **Smart Mode:** Overrides default weather logic. Switches heating OFF if Outside Temp > Inside Temp, OR if Inside Temp is higher than Outside Temp by more than 10°C. |
| `on` | **Resume:** Deletes manual overlays and returns all zones to their Smart Schedule. |
| `off` | **Disable:** Puts all Heating zones into MANUAL OFF mode. (AC zones will be turned ON). |
| `reset` | **Reset:** Resumes the Smart Schedule for ALL zones, regardless of type. |
| `<temp>C` | **Set Temp:** Forces all Heating zones to a specific temperature (0-25) until the next scheduled block begins. Example: `./tado_weather_control.sh 21.5C` |

### Flags

| Flag | Description |
| :--- | :--- |
| `--city <name>` | Override the default configured city for the weather check (e.g., `--city "New York"`). |
| `--force` | Force overwrite existing manual temperature overrides on heating zones. By default, the script skips zones the user has manually adjusted. |
| `--dryrun` | Simulates the execution. Fetches weather and evaluates states, but does NOT send PUT/DELETE commands to Tado. |
| `--notime` | Disables internal date/time stamps in standard output logging. |
| `--syslog` | Pipes output directly to your system's syslog (`/var/log/syslog` or `journalctl`) under the tag `tado_weather`. |
| `-h, --help` | Display the help menu. |
| `-V, --version` | Display the script version. |

## Configuration

You can tweak the default behavior by editing the variables at the top of the `tado_weather_control.sh` file:

* `CITY_NAME`: Default city used for the Open-Meteo weather check (Default: `"Amsterdam"`).
* `TEMP_OFF_THRESHOLD`: Outside temperature at which heating switches OFF (Default: `16.0`).
* `TEMP_RESUME_THRESHOLD`: Outside temperature at which heating schedule resumes (Default: `15.0`).
* `AUTO_MAX_DIFF`: Max allowed difference between inside/outside temps before Auto mode turns off heating (Default: `10.0`).

*(Note: Keeping a 1°C gap between your OFF and RESUME thresholds creates a "deadzone" that prevents your heating from flapping on and off every few minutes if the temperature hovers around the limit).*

## Automation (Cron)

To fully automate the script, set it up to run periodically using `cron`. 

Open your crontab:
```bash
crontab -e
```

Add the following line to run the script every 15 minutes and log the output:
```bash
*/15 * * * * /path/to/your/tado_weather_control.sh >> /tmp/tado_script.log 2>&1
```

Or, to integrate cleanly with system logs:
```bash
*/15 * * * * /path/to/your/tado_weather_control.sh --syslog > /dev/null 2>&1
```

```

