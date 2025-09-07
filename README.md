# Keystone

This Bash script is designed to automate the maintenance and update tasks for Arch Linux and its derivatives like Manjaro, EndeavourOS, etc.

-  Verifies network connectivity and checks for a locked `pacman` database before starting the script.
-  Can use `reflector` (for Arch) or `pacman-mirrors` (for Manjaro) to find the fastest and most up to date package servers.
-  Does a system update `pacman -Syu` and updates packages from the AUR, Flatpak, etc.
-  Removes orphaned packages that are no longer needed.
-  Safely cleans the package cache using `paccache`, keeping recent versions for easy downgrades.
-  Clears out broken or partial package downloads.
-  Checks for `.pacnew` files.
-  Verifies `pacman` database consistency.
-  Looks for broken symbolic links in system directories.
-  Checks for failed `systemd` units.
-  Logs all operations to `var/log/keystone-YYYY-MM-DD.log`.
-  Supports a configuration file at `/etc/keystone.conf`.
-  Dry-Run mode to see what would happen without making any changes.

## Installation
**Manual**
```bash
git clone https://github.com/isaiah76/keystone.git
cd keystone
chmod +x keystone.sh
sudo cp keystone.sh /usr/bin/keystone
```

## Prerequisites
While the script can run on a base Arch Linux installation, the following packages are highly recommended.

- `reflector`: For automatically updating and ranking the best Arch Linux mirrors.
- `pacman-contrib`: Provides `paccache` for safe cache cleaning and `pacdiff` for managing `.pacnew` files.
- `lsof`: Helps identify the process holding a `pacman` database lock.
- `AUR Helper`: (Optional) like `paru` or `yay` to enable AUR package updates.

You can install the essential dependencies with:
`sudo pacman -S reflector pacman-contrib lsof`

## Usage
Run with `sudo`:
```bash 
sudo keystone [options]
```

**Options**
Defaults can be set at `~/.config/keystone.conf`
```lua 
  -i, --interactive     Enable interactive mode.
  -c, --country CODE    Use a two-letter country code with reflector (e.g. US, DE).
  -l, --logfile PATH    Write log output to the specified file.
  -n, --dry-run         Show what would be done, but make no changes.
  -m, --update-mirrors  Refresh the pacman mirrorlist before running updates.
  -h, --help            Show this help message and exit.
```

**Example Usage**

Update system packages interactively and refresh mirrors for the US:
```bash 
sudo keystone -i -c US -m
```

## Configuration 
For persistent settings, you can create a configuration file at `/etc/keystone.conf`. The script will automatically load any variables defined overriding the default config.

**Example** `/etc/keystone.conf`:
```
# Run in interactive mode by default
INTERACTIVE=true

# Default country for reflector
COUNTRY=US

# Path to log file
LOGFILE=/var/log/keystone.log

# Skip mirror updates unless explicitly enabled
SKIP_MIRRORS=true
```
