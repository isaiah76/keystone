#!/usr/bin/env bash

# configurations
CONFIG_FILE="/etc/keystone.conf"
REFLECTOR_COUNTRY=""
AUR_HELPERS=("paru" "yay" "paman" "pikaur")
LOG_FILE="/var/log/keystone-$(date +%F).log"
CACHE_VER=2
JOURNAL_SIZE="100M"

# state
START_TIME=$(date +%s)
INTERACTIVE=false
DRY_RUN=false
UPDATE_MIRRORS=true
RUN_AS_USER=""
SUDO_LOOP_PID=""

set -o pipefail # pipelines exit code to exit with a non zero status
set -o nounset # exit when trying to use a undeclared variable

# helpers
print_step(){ printf "\n==> %s\n" "$*"; }
print_info(){ printf "    ➜ %s\n" "$*"; }
print_success(){ printf "    ✔ %s\n" "$*"; }
print_error(){ printf "    ✖ %s\n" "$*"; }

usage(){
  cat <<EOF
Usage:
  sudo ./keystone.sh [options]

Options:
  -i, --interactive    Enable interactive mode
  -c, --country CODE   Use a two-letter country code with reflector (e.g. US, DE).
  -l, --logfile PATH   Write log output to the specified file.
  -n, --dry-run        Show what would be done, but make no changes.
  -m, --update-mirrors Refresh the pacman mirrorlist before running updates.
  -h, --help           Show this help message and exit.

You can set defaults in $CONFIG_FILE instead of putting options every time.
EOF
}

# process
sudo_alive(){
  if ! $DRY_RUN; then
    while true; do 
      sudo -n true
      sleep 45
    done >/dev/null 2>&1 &
    SUDO_LOOP_PID=$!
  fi
}

kill_sudo(){
  if [[ -n "$SUDO_LOOP_PID" ]]; then
    kill "$SUDO_LOOP_PID" 2>/dev/null || true
  fi
}

on_exit(){
  local rc=${1:-$?}
  kill_sudo
  if [ "$rc" -ne 0 ]; then
    print_error "Script exited with a non-zero status: $rc."
  else
    print_success "Script successfully finished."
  fi 
  local END_TIME
  END_TIME=$(date +%s)
  local RUNTIME=$((END_TIME - START_TIME))
  print_step "Total execution time: $((RUNTIME / 60)) minutes and $((RUNTIME % 60)) seconds."
  print_info "Reboot if kernel or other core system components have been updated."
  echo "Log finished at $(date)"
}
trap 'on_exit $?' EXIT 
trap 'exit 130' INT TERM

prompt_user(){
  local msg="$1"
  if $INTERACTIVE && ! $DRY_RUN; then
    read -r -p "    ? ${msg} [y/N] " resp
    case "$resp" in 
      [yY]|[yY][eE][sS]) return 0;;
      *) return 1;;
    esac
  else
    return 0
  fi
}

run_cmd(){
  if $DRY_RUN; then
    printf "    [DRY-RUN] %q\n" "$@"
    return 0
  fi
  "$@"
}

load_config(){
  if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
    print_info "Loaded configuration from $CONFIG_FILE"
  fi
}

check_root(){
  if [[ "$EUID" -ne 0 ]]; then
    print_error "This script must be run with sudo."
    exit 1 
  fi 
  if [[ -z "${SUDO_USER:-}" ]]; then
    print_error "This script should be run with sudo, not directly as root."
    exit 1 
  fi 
  RUN_AS_USER="$SUDO_USER"
}

check_network(){
  print_step "Checking networking connectivity.."
  if ping -c 1 -W 2 "archlinux.org" &>/dev/null; then
    print_success "Network OK (archlinux.org is reachable)."
  else
    print_error "Network failed. Updates are likely to fail."
    prompt_user "Continue anyway?" || exit 1 
  fi
}

check_db_lock(){
  print_step "Checking for pacman database lock.."
  local lock_file="/var/lib/pacman/db.lck"
  if [[ ! -f "$lock_file" ]]; then
    print_success "Pacman database is not locked."
    return 0
  fi

  local pid 
  pid=$(lsof -t "$lock_file" 2>/dev/null || fuser "$lock_file" 2>/dev/null || echo "")
  if [[ -n "$pid" ]]; then
    print_error "Pacman DB lock is held by PID: $pid ($(ps -o comm= -p "$pid" 2>/dev/null || echo 'unkown'))"
    if prompt_user "Attempt to kill process $pid and remove the lock?"; then
      print_info "Sending TERM signal (15) to PID $pid..."
      run_cmd kill -15 "$pid"
      sleep 2
      if ps -p "$pid" >/dev/null; then
        print_info "Process still running. Sending KILL signal (9)."
        run_cmd kill -9 "$pid"
      fi 
      run_cmd rm -f "$lock_file"
      print_success "Killed process and removed lock."
    else 
      print_error "Cannot proceed with a locked database. Exiting.."
      exit 1 
    fi 
  else 
    print_error "A stale pacman DB lock file was found."
    if prompt_user "Remove stale lock file '$lock_file'?"; then 
      run_cmd rm -f "$lock_file"
      print_success "Removed stale lock file."
    else 
      print_error "Cannot proceed with a locked database. Exiting.."
      exit 1 
    fi 
  fi
}

clean_partial(){
  print_step "Cleaning partial package downloads..."
  local partial_files
  mapfile -t partial_files < <(find /var/cache/pacman/pkg/ -iname "*.part" -type f)

  if [[ ${#partial_files[@]} -eq 0 ]]; then
    print_success "No partial download files found."
    return 0
  fi

  print_info "Found and removing ${#partial_files[@]} partial downloads:"
  printf "    %s\n" "${partial_files[@]}"
  run_cmd rm -f -- "${partial_files[@]}"
}

update_mirrors(){
  print_step "Updating pacman mirrorlist..."
  # prioritize pacman-mirrors for manjaro systems
  if command -v pacman-mirrors &>/dev/null; then
    print_info "Detected 'pacman-mirrors' (Manjaro)\nRanking the 3 fastest mirrors.."
    if ! run_cmd sudo pacman-mirrors --fasttrack 3; then
      print_error "pacman-mirrors failed. The mirrorlist was not updated!"
    else 
      print_success "Mirrorlist successfully updated by pacman-mirrors."
    fi 
  elif command -v reflector &>/dev/null; then
    print_info "Detected 'reflector' (Arch Linux)."
    local country_arg=()
    if [[ -n "$REFLECTOR_COUNTRY" ]]; then
      country_arg=("--country" "$REFLECTOR_COUNTRY")
      print_info "Using country: $REFLECTOR_COUNTRY"
    else 
      print_info "No country specified; using global mirrors.."
    fi
    print_info "Backing up current mirrorlist to /etc/pacman.d/mirrorlist.bak"
    run_cmd cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.bak 
    print_info "Querying for the 10 latest fastest HTTPS mirrors..."
    local reflector_cmd=(reflector "${country_arg[@]}" --latest 10 --sort rate --save /etc/pacman.d/mirrorlist --protocol https)
    if ! run_cmd "${reflector_cmd[@]}"; then
      print_error "Reflector failed. Restoring backup mirrorlist.."
      run_cmd mv /etc/pacman.d/mirrorlist.bak /etc/pacman.d/mirrorlist
    else 
      print_success "Mirrorlist successfully updated."
    fi 
  else 
    print_info "Neither 'reflector' and 'pacman-mirrors' found. Skipping mirror update."
  fi
}

update_system(){
  print_step "Performing full system update..."
  local pacman_cmd=(pacman -Syu)
  if ! $INTERACTIVE; then
    pacman_cmd+=(--noconfirm --needed)
  fi 
  if ! run_cmd "${pacman_cmd[@]}"; then
    print_error "System update failed. This could be due to file conflicts."
    print_info "If errors mention 'exists in filesystem', you may need to intervene manually."
    print_info "For more info, see: https://wiki.archlinux.org/title/Pacman#'Failed_to_commit_transaction_(conflicting_files)'"
  else 
    print_success "System successfully updated."
  fi
}

update_aur(){
  print_step "Updating AUR packages..."
  local aur_helper=""
  for helper in "${AUR_HELPERS[@]}"; do 
    if command -v "$helper" &>/dev/null; then
      aur_helper="$helper"
      break 
    fi 
  done

  if [[ -z "$aur_helper" ]]; then
    print_info "No supported AUR helper found. Skipping.."
    return 0
  fi 
  print_info "Found AUR helper: $aur_helper"

  local aur_cmd=()
  case "$aur_helper" in 
    paru|yay) aur_cmd=("$aur_helper" -Sua);;
    pamac) aur_cmd=("$aur_helper" "update" "--aur");;
    pikaur) aur_cmd=("$aur_helper" -Syu);;
  esac

  if ! $INTERACTIVE; then
    case "$aur_helper" in 
      paru|yay|pikaur) aur_cmd+=("--noconfirm");;
      pamac) aur_cmd+=("--no-confirm");;
    esac
  fi 

  print_info "Running AUR update as user '$RUN_AS_USER'..."
  if ! run_cmd sudo -H -u "$RUN_AS_USER" -- "${aur_cmd[@]}"; then
    print_error "AUR helper failed."
  else 
    print_success "AUR successfully updated."
  fi
}

remove_orphans(){
  print_step "Removing orphan packages..."
  mapfile -t orphans < <(pacman -Qtdq)
  if [[ ${#orphans[@]} -eq 0 ]]; then
    print_success "No orphan packages found."
    return 0
  fi

  print_info "Orphan packages found:"
  printf "    %s\n" "${orphans[@]}"

  if prompt_user "Remove these ${#orphans[@]} orphan packages?"; then
    local orphan_cmd=(pacman -Rns --)
    if ! $INTERACTIVE; then
      orphan_cmd+=(--noconfirm)
    fi 
    if ! run_cmd "${orphan_cmd[@]}" "${orphans[@]}"; then
      print_error "Failed to remove some orphan packages."
    else 
      print_success "Orphan packages successfully removed."
    fi 
  fi
}

clean_package_cache(){
  print_step "Cleaning package cache..."
  if ! command -v paccache &>/dev/null; then
    print_info "'paccache' not found. Install 'pacman-contrib' to enable this feature."
  fi 

  print_info "Removing all cached packages except for the last $CACHE_VER versions."
  if ! run_cmd paccache -rk"$CACHE_VER"; then
    print_error "paccache failed."
  else
    print_success "Package cache successfully cleaned."
  fi 

  print_info "Removing uninstalled package cache."
  if ! run_cmd paccache -ruk0; then 
    print_error "paccache (uninstall clean) failed."
  else 
    print_success "Uninstalled package cache cleaned."
  fi
}

handle_pac_files(){
  print_step "Checking for .pacnew and .pacsave files"
  if ! command -v pacdiff &>/dev/null; then
    print_info "'pacdiff' not found. Install 'pacman-contrib' to enable this feature."
    local pacfiles 
    pacfiles=$(find /etc -type f -name '*.pacnew' 2>/dev/null)
    if [[ -n "$pacfiles" ]]; then
      print_error "Found .pacnew files. Please resolve them manually."
      echo "$pacfiles"
    else 
      print_success "No .pacnew files found in /etc."
    fi 
    return 1
  fi 

  if [[ -z "$(pacdiff -o)" ]]; then
    print_success "No .pacnew/.pacsave files found."
    return 0 
  fi 

  print_error "Found .pacnew/.pacsave files."
  if ! $INTERACTIVE; then
    print_info "listing files. Please review them manually later."
    run_cmd pacdiff -o
  else 
    print_info "Launching 'pacdiff' to resolve conflicts..."
    run_cmd pacdiff 
    print_success "Pacdiff session finished."
  fi
}

check_db_consistency(){
  print_step "Checking pacman database consistency"
  local db_output
  if ! db_output=$(pacman -Dk 2>&1); then
    print_error "Pacman database consistency check failed with the following issues:"
    while IFS= read -r line; do
      printf "    %s\n" "$line"
    done <<< "$db_output"
  else 
    print_success "Pacman database is consistent."
  fi
}

check_broken_symlinks(){
  print_step "Checking for broken symbolic links"
  local broken_links
  mapfile -t broken_links < <(find /etc /usr -xtype l 2>/dev/null)
  if [[ ${#broken_links[@]} -eq 0 ]]; then
    print_success "No broken symbolic links found."
  else 
    print_error "Found ${#broken_links[@]} broken symbolic links. Please review and fix them manually."
    printf "    %s\n" "${broken_links[@]}"
  fi
}

check_kernels(){
  print_step "Checking installed kernels..."
  local current_kernel installed_kernels avail_kernels eol_kernels
  current_kernel=$(uname -r)
  print_info "Currently running kernel: $current_kernel"

  local kernel_regex='^linux(-lts|-zen|-hardened)?$|^linux[0-9]+$'
  mapfile -t installed_kernels < <(pacman -Qq | grep -E "$kernel_regex")
  if [[ ${#installed_kernels[@]} -eq 0 ]]; then
    print_info "No standard kernel packages detected."
    return 0 
  fi 
  print_info "Installed kernel packages:"
  printf "    %s\n" "${installed_kernels[@]}"

  mapfile -t available_kernels < <(pacman -Ssq | grep -E "$kernel_regex")
  mapfile -t eol_kernels < <(comm -23 <(printf "%s\n" "${installed_kernels[@]}" | sort) <(printf "%s\n" "${available_kernels[@]}" | sort))

  if [[ ${#eol_kernels[@]} -gt 0 ]]; then
    print_error "The following installed kernels are End of Life (EOL) or no longer in the repositories:"
    printf "    %s\n" "${eol_kernels[@]}"
    print_info "It is highly recommended to switch to a supported kernel and remove these."
  else 
    print_success "All installed kernels are supported."
  fi
}

check_systemd_failed(){
  print_step "Checking for failed systemd units..."
  failed_units=$(systemctl list-units --failed --no-legend --no-pager)
  if [[ -z "$failed_units" ]]; then
    print_success "No failed systemd units."
  else 
    print_error "Found failed systemd units:"
    echo "$failed_units"
  fi
}

# run the script
main(){
  while [[ $# -gt 0 ]]; do 
    case "$1" in
      -i|--interactive) INTERACTIVE=true; shift ;;
      -m|--update-mirrors) UPDATE_MIRRORS=false; shift ;;
      -c|--country)
        if [[ -z "${2-}" || "${2-}" =~ ^- ]]; then
          print_error "[Error] --country option requires a two letter code." >&2; exit 
        fi 
        REFLECTOR_COUNTRY="$2"; shift 2 ;;
      -l|--logfile)
        if [[ -z "${2-}" || "${2-}" =~ ^- ]]; then
          print_error "[Error] --logfile option requires a path." >&2; exit 2 
        fi 
        LOG_FILE="$2"; shift 2 ;;
      -n|--dry-run) DRY_RUN=true; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
  done
  
  check_root
  load_config

  local log_dir 
  log_dir=$(dirname "$LOG_FILE")
  mkdir -p "$log_dir" || { print_error "Could not create log directory: $log_dir"; exit 1; }
  touch "$LOG_FILE" || { print_error "Could not write to log file: $LOG_FILE"; exit 1; }
  exec > >(tee -a "${LOG_FILE}") 2>&1 
  echo "Log started at $(date) for user $RUN_AS_USER"
  if $INTERACTIVE; then print_info "Running in interactive mode."; fi 
  if $DRY_RUN; then print_info "Dry-run mode enabled; no changes will be made."; fi 

  sudo_alive 
  check_network 
  check_db_lock
  clean_partial 
  if ! $UPDATE_MIRRORS; then
    update_mirrors 
  fi
  update_system 
  update_aur 
  remove_orphans 
  clean_package_cache 
  handle_pac_files
  check_db_consistency
  check_broken_symlinks 
  check_kernels
  check_systemd_failed

  command -v flatpak &>/dev/null && {
    print_step "Updating Flatpak packages..."
    run_cmd flatpak update --noninteractive || print_error "Flatpak update failed."
    run_cmd flatpak uninstall --unused --noninteractive || print_error "Flatpak cleanup failed."
  }
}

main "$@"
