#!/bin/bash

# System update / maintenance helper for Manjaro (pacman/yay/flatpak).
#
# Notes:
# - This script is interactive and uses sudo.
# - Output is logged under /tmp/manjaro/ and a cleaned log is saved to $HOME.
# - Error reporting uses Bash traps; line numbers may shift if whitespace changes.

# ANSI color codes
cyan='\033[38;5;38m'           # Running command
red='\033[38;5;162m'           # Command failure or file deletion
yellow='\033[38;5;178m'        # User input
orange='\033[38;5;173m'        # Distinct info
green='\033[38;5;77m'          # Command success
purple='\033[38;5;105m'        # Progress bar
blue='\033[38;5;39m'           # Extra info (summaries)
reset='\033[0m'                # Commands output

# --- Error tracking for end-of-script report ---
ERROR_COUNT=0
ERRORS=()

log_error() {
  local cmd="$1"
  local code="$2"
  ERRORS+=("[exit ${code}] ${cmd}")
  ((ERROR_COUNT++))
}

# --- Auto-capture failing commands (even if they didn't use runcommand) ---
__last_cmd=""
__last_ctx=""
__err_trap_active=0

__debug_capture() {
  # Don't capture commands while we're running traps/handlers (prevents false attribution).
  case "${FUNCNAME[1]:-}" in
    __err_handler|on_exit) return 0 ;;
  esac

  # Avoid polluting capture while inside the error handler itself.
  (( __err_trap_active )) && return 0
  __last_cmd="$BASH_COMMAND"
  __last_ctx="line ${BASH_LINENO[0]} in ${FUNCNAME[1]:-MAIN}"
}

__err_handler() {
  local rc=$?

  # Prevent recursion if the handler itself triggers ERR/DEBUG activity.
  (( __err_trap_active )) && return "$rc"
  __err_trap_active=1

  # Only log if we actually have something meaningful.
  if [[ -n "${__last_cmd}" ]]; then
    log_error "${__last_cmd} (${__last_ctx})" "$rc"
  fi

  __err_trap_active=0
  return "$rc"
}

# Make ERR trap propagate into functions/subshells invoked by the script.
set -o errtrace

# Make DEBUG trap propagate into functions too (so __last_cmd is accurate inside functions).
set -o functrace

# Record every command; on failure, ERR trap logs the recorded command.
trap '__debug_capture' DEBUG
trap '__err_handler' ERR

print_errors_summary() {

  if (( ERROR_COUNT == 0 )); then
    echo -e "${green}No errors detected during this run.${reset}"
    return 0
  fi

  echo -e "${red}Total errors:${reset} ${orange}${ERROR_COUNT}${reset}"
  echo
  echo -e "Errors list:"
  echo

  local i=1
  local e
  for e in "${ERRORS[@]}"; do
    echo -e "${red}${i})${reset} ${e}"
    ((i++))
  done

  # Optional pointer to full log (you already set log_path)
  if [[ -n "${log_path:-}" ]]; then
    echo
    echo -e "${blue}Full log:${reset} ${log_path}"
  fi
}

# --- Static top progress bar (centered) ---
PROG_WIDTH=20
total_steps=5  # Update this if you add/remove major blocks
current_step=0

# Title text prefix (keep simple: no ANSI colors in title)
TITLE_PREFIX="Update"

set_term_title() {
  # OSC 0: set icon name + window title: ESC ] 0 ; string BEL
  # Write to /dev/tty so it never pollutes your logged stdout/stderr.
  local tty="/dev/tty"
  local title="$1"
  printf '\033]0;%s\007' "$title" >"$tty"
}

progress_ui_init() {
  # No scroll-region manipulation (no tput csr), so GNOME Terminal scrollback keeps working.
  show_progress "$current_step" "$total_steps"
}

progress_ui_end() {
  # Optional: leave final title; change text if you want.
  set_term_title "${TITLE_PREFIX}"
}

show_progress() {
  local current="$1"
  local total="$2"

  (( total <= 0 )) && total=1
  (( current < 0 )) && current=0
  (( current > total )) && current=$total

  local percent=$(( 100 * current / total ))
  local filled=$(( PROG_WIDTH * current / total ))
  local empty=$(( PROG_WIDTH - filled ))

  local done_sub_bar todo_sub_bar text
  done_sub_bar=$(printf "%${filled}s" "" | tr " " "#")
  todo_sub_bar=$(printf "%${empty}s" "" | tr " " "-")
  text="[${done_sub_bar}${todo_sub_bar}] ${percent}%"

  set_term_title "${TITLE_PREFIX}  ${text}"
}

echo -ne "${cyan}"
echo '    888     888               888          888                 .d8888b.                   d8b          888   '
echo '    888     888               888          888                d88P  Y88b                  Y8P          888   '
echo '    888     888               888          888                Y88b.                                    888   '
echo '    888     888 88888b.   .d88888  8888b.  888888 .d88b.       "Y888b.    .d8888b 888d888 888 88888b.  888888'
echo '    888     888 888 "88b d88" 888     "88b 888   d8P  Y8b         "Y88b. d88P"    888P"   888 888 "88b 888   '
echo '    888     888 888  888 888  888 .d888888 888   88888888           "888 888      888     888 888  888 888   '
echo '    Y88b. .d88P 888 d88P Y88b 888 888  888 Y88b. Y8b.         Y88b  d88P Y88b.    888     888 888 d88P Y88b. '
echo '    "Y88888P"  88888P"   "Y88888 "Y888888  "Y888 "Y8888       "Y8888P"   "Y8888P 888     888 88888P"   "Y888"'
echo '                888                                                                           888            '
echo '                888                                                                           888            '
echo '                888                                                                                          '
echo -ne "${reset}"

# Keep sudo alive during the script
echo -e "\n\n"
echo -ne "${yellow}"
sudo -v
(sudo -v && while sleep 60; do sudo -n -v || exit; done) &
SUDOREFRESHPID=$!

on_exit() {
  local rc=$?

  print_errors_summary
  echo 

  # Cleanly end the progress UI
  progress_ui_end

  # Stop sudo keepalive
  [[ -n "${SUDOREFRESHPID:-}" ]] && kill "$SUDOREFRESHPID" 2>/dev/null || true

  # Keep the terminal open so you can actually see the report
 printf "%b" "${yellow}Press Enter to close...${reset}"
 read -r </dev/tty

# Stop logging - Final log
exec 1>&3 2>&4

# Reuse datetime_str from earlier logging step
# final_filename must match log file name (used in $log_path)
final_filename="Update-${datetime_str}.log"

# Temp file in tmpfs
cleaned_tmp="/tmp/manjaro/cleaned_tmp.log"

# Clean the log: remove ANSI codes and non-printables
sed -E 's/\x1B\[[0-9;?]*[A-Za-z]//g; s/\x1B\][^\x07\x1B]*(\x07|\x1B\\)//g' "$log_path" | \
tr -cd '\11\12\15\40-\176' | \
awk '
BEGIN { skip = 0 }
/^ *8.888888888e+09/ { skip = 1 }
skip && /88P" */ { skip = 0; next }
skip == 0 { print }
' > "$cleaned_tmp"

# Delete existing logs before saving new one
find $HOME -maxdepth 1 -type f -name 'Update-*.log' -exec rm -f {} \;

# Copy cleaned log to final destination with Greek timestamped name
cp -f "$cleaned_tmp" "$HOME/$final_filename"

# Clean /tmp
rm -rf /tmp/manjaro

  return "$rc"
}

trap on_exit EXIT INT TERM

echo -ne "${reset}"
clear

progress_ui_init
show_progress "$current_step" "$total_steps"

# Create /tmp/manjaro if it doesn't exist
rm -rf /tmp/manjaro
mkdir -p /tmp/manjaro

# Log update to file in tmpfs
# Save original stdout and stderr
exec 3>&1 4>&2

# Define log path in /tmp/manjaro/
log_dir="/tmp/manjaro/"
datetime_str=$(LC_TIME=el_GR.UTF-8 date +'%A_%d_%B_%I-%M%p')
log_file="Update-${datetime_str}.log"
log_path="${log_dir}${log_file}"

# Redirect all stdout and stderr to tee: live output + logging in tmpfs
exec > >(tee -a "$log_path") 2>&1

# --- NVMe SMART health gate (run early) ---

echo -e "\n${orange}Checking NVMe SMART health...${reset}"

if ! command -v smartctl >/dev/null 2>&1; then
echo -e "\n${red}Error: smartctl not found (smartmontools).${reset}"
echo -e "${yellow}Install it (sudo pacman -S smartmontools), then re-run the script.${reset}"
echo -e "\n${red}Exiting script...${reset}"
read -r
exit 1
fi

# Detect the physical disk behind /
root_src="$(findmnt -n -o SOURCE / 2>/dev/null)"

# btrfs may return: /dev/nvme0n1p2[/@] -> strip "[/@]" so smartctl gets a real device path
root_src="${root_src%%[*}"

[[ -n "$root_src" && "$root_src" == /dev/* ]] && root_src="$(realpath "$root_src" 2>/dev/null || echo "$root_src")"

disk="$root_src"
while true; do
pk="$(lsblk -no PKNAME "$disk" 2>/dev/null | head -n 1)"
[[ -z "$pk" ]] && break
disk="/dev/$pk"
done

if [[ -z "$disk" || "$disk" != /dev/* ]]; then
echo -e "\n${red}Error: could not detect OS disk device for /.${reset}"
echo -e "\n${red}Exiting script...${reset}"
read -r
exit 1
fi

# Prefer NVMe namespace node (/dev/nvmeXnY) for SMART (avoid partition nodes)
SMART_DEV="$disk"
if [[ "$SMART_DEV" =~ ^/dev/nvme[0-9]+n[0-9]+p[0-9]+$ ]]; then
SMART_DEV="${SMART_DEV%p*}"      # /dev/nvme0n1p2 -> /dev/nvme0n1
fi

echo
echo -e "Device: ${blue}${SMART_DEV}${reset}"

while true; do

out="$(sudo smartctl -a "$SMART_DEV" 2>/dev/null)"
st=$?

if (( st == 0 )); then
break
fi

echo -e "\n${red}Error: smartctl failed on ${SMART_DEV}.${reset}"

while true; do
echo
echo -ne "${yellow}(r)etry SMART check or (e)xit script: ${reset}"
read -r choice
echo

case "${choice,,}" in
r) break ;;
e)
echo -e "${red}Exiting script...${reset}"
exit 1
;;
*)
echo -e "${red}Please answer with (r)etry or (e)xit.${reset}"
;;
esac
done

done

crit="$(printf '%s\n' "$out" | grep -m1 -oP 'Critical Warning:\s*\K0x[0-9a-fA-F]+' || true)"
temp="$(printf '%s\n' "$out" | grep -m1 -oP 'Temperature:\s*\K[0-9]+' || true)"
spare="$(printf '%s\n' "$out" | grep -m1 -oP 'Available Spare:\s*\K[0-9]+' || true)"
thresh="$(printf '%s\n' "$out" | grep -m1 -oP 'Available Spare Threshold:\s*\K[0-9]+' || true)"
used="$(printf '%s\n' "$out" | grep -m1 -oP 'Percentage Used:\s*\K[0-9]+' || true)"
media_err="$(printf '%s\n' "$out" | grep -m1 -oP 'Media and Data Integrity Errors:\s*\K[0-9]+' || true)"
err_log="$(printf '%s\n' "$out" | grep -m1 -oP 'Error Information Log Entries:\s*\K[0-9]+' || true)"

crit="${crit:-0x00}"
temp="${temp:-NA}"
spare="${spare:-NA}"
thresh="${thresh:-NA}"
used="${used:-NA}"
media_err="${media_err:-NA}"
err_log="${err_log:-NA}"

echo
echo -e "Critical Warning:${reset} ${orange}${crit}${reset}"
echo -e "Temperature:${reset} ${orange}${temp}${reset} C"
echo -e "Available Spare:${reset} ${orange}${spare}${reset}%  Threshold:${reset} ${orange}${thresh}${reset}%"
echo -e "Percentage Used:${reset} ${orange}${used}${reset}%"
echo -e "Media/Data Integrity Errors:${reset} ${orange}${media_err}${reset}"
echo -e "Error Log Entries:${reset} ${orange}${err_log}${reset}"

health_ok=true
health_warn=false

if [[ "$crit" != "0x00" ]]; then
health_warn=true
fi

if [[ "$spare" != "NA" && "$thresh" != "NA" ]] && (( spare < thresh )); then
health_ok=false
fi

if [[ "$media_err" != "NA" ]] && (( media_err > 0 )); then
health_warn=true
fi

if [[ "$health_ok" == false ]]; then
echo -e "\n${red}SMART health looks BAD (Available Spare below threshold).${reset}"
while true; do
echo
echo -ne "${yellow}(r)etry SMART check or (e)xit script: ${reset}"
read -r choice
echo
case "${choice,,}" in
r) break ;;
e)
echo -e "${red}Exiting script...${reset}"
exit 1
;;
*)
echo -e "${red}Please answer with (r)etry or (e)xit.${reset}"
;;
esac
done
fi

if [[ "$health_warn" == true ]]; then
echo -e "\n${yellow}SMART reports warnings. Backups recommended.${reset}"
echo -ne "${yellow}Proceed anyway? (y)es or (e)xit script: ${reset}"
read -r go
echo
if [[ "${go,,}" != "y" ]]; then
echo -e "${red}Exiting script...${reset}"
exit 1
fi
else
echo -e "\n${green}SMART health looks OK.${reset}"
fi

echo -e "\n"

# --- Snapper safety gate (run early) ---
echo -e "\n${orange}Checking for btrfs snapshots...${reset}"

if ! command -v snapper >/dev/null 2>&1; then
echo -e "\n${red}Error: snapper not found.${reset}"
echo -e "${yellow}Install/configure snapper first, then re-run the script.${reset}"
echo -e "\n${red}Exiting script...${reset}"
read -r
exit 1
fi

if [[ ! -d "/.snapshots" ]]; then
echo -e "\n${red}Error: /.snapshots not found.${reset}"
echo -e "${yellow}Btrfs snapshots are not mounted/configured for root.${reset}"
echo -e "\n${red}Exiting script...${reset}"
read -r
exit 1
fi

# Try to auto-pick the config whose subvolume is "/". Fallback to "root".
SNAPPER_CONFIG="$(
sudo snapper --csvout --separator '|' --no-headers list-configs --columns config,subvolume 2>/dev/null \
| awk -F'|' '$2=="/"{print $1; exit}'
)"
SNAPPER_CONFIG="${SNAPPER_CONFIG:-root}"

cutoff_epoch="$(date -d '7 days ago' +%s)"

get_recent_snapshots_sorted() {

local out
while true; do

out="$(sudo snapper -c "$SNAPPER_CONFIG" --csvout --separator '|' --no-headers list --columns number,date,description 2>/dev/null)"
local status=$?

if (( status == 0 )); then
break
fi

echo -e "\n${red}Error: snapper list failed (config: ${SNAPPER_CONFIG}).${reset}"

while true; do
echo
echo -ne "${yellow}(r)etry or (e)xit script: ${reset}"
read -r choice
echo

case "${choice,,}" in
r) break ;;
e)
echo -e "${red}Exiting script...${reset}"
exit 1
;;
*)
echo -e "${red}Please answer with (r)etry or (e)xit.${reset}"
;;
esac
done

done

printf '%s\n' "$out" \
| awk -F'|' '$1 ~ /^[0-9]+$/ && $1 != "0" {print $1 "|" $2 "|" $3}' \
| while IFS='|' read -r num sdate desc; do

local snap_epoch
snap_epoch="$(date -d "$sdate" +%s 2>/dev/null || echo 0)"

if (( snap_epoch >= cutoff_epoch )); then
printf '%s|%s|%s|%s\n' "$snap_epoch" "$num" "$sdate" "$desc"
fi

done \
| sort -nr
}

mapfile -t recent_lines < <(get_recent_snapshots_sorted)

if (( ${#recent_lines[@]} > 0 )); then

echo -e "\n${green}Found Btrfs snapshot 7 days or newer, continuing...${reset}"

for line in "${recent_lines[@]}"; do
IFS='|' read -r epoch num sdate desc <<< "$line"
echo -e "${reset}${num}${reset}  ${sdate}  ${desc}"
done

echo -e "\n\n"

else

echo -e "\n${yellow}No snapshots found from the last 7 days.${reset}"

# --- Step 1: create snapshot (retry only this step) ---
snapshot_desc="Update-$(date +%F_%H-%M-%S)"
new_num=""

while true; do

echo -e "\n${cyan}Creating snapshot: ${orange}${snapshot_desc}${reset}"

new_num="$(sudo snapper -c "$SNAPPER_CONFIG" create --description "$snapshot_desc" --print-number 2>/dev/null)"
snap_status=$?

if (( snap_status == 0 )) && [[ "$new_num" =~ ^[0-9]+$ ]]; then
echo -e "\n${green}Snapshot created: #${new_num} ${orange}${snapshot_desc}${reset}"
break
fi

echo -e "\n${red}Error: snapper snapshot creation failed.${reset}"

while true; do
echo
echo -ne "${yellow}(r)etry snapshot or (e)xit script: ${reset}"
read -r choice
echo

case "${choice,,}" in
r) break ;;
e)
echo -e "${red}Exiting script...${reset}"
exit 1
;;
*)
echo -e "${red}Please answer with (r)etry or (e)xit.${reset}"
;;
esac
done

done

# --- Step 2: update grub (retry only this step; do not re-create snapshot) ---
while true; do

echo -e "\n${cyan}Updating GRUB config...${reset}"

if sudo grub-mkconfig -o /boot/grub/grub.cfg; then
echo -e "\n${green}GRUB updated successfully.${reset}"
echo -e "\n\n"
break
fi

echo -e "\n${red}Error: grub-mkconfig failed.${reset}"

while true; do
echo
echo -ne "${yellow}(r)etry grub update or (e)xit script: ${reset}"
read -r choice
echo

case "${choice,,}" in
r) break ;;
e)
echo -e "${red}Exiting script...${reset}"
exit 1
;;
*)
echo -e "${red}Please answer with (r)etry or (e)xit.${reset}"
;;
esac
done

done

fi

# Days and hours since last full update
log_file=$(find "$HOME" -maxdepth 1 -type f -name 'Update-*.log' -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1 {print $2}')

if [[ -f "$log_file" ]]; then
  # Get modification time and current time in seconds
  file_time=$(stat -c %Y "$log_file")
  now_time=$(date +%s)

  # Total difference in seconds
  seconds_diff=$(( now_time - file_time ))

  # Calculate days and hours
  days=$(( seconds_diff / 86400 ))
  hours=$(( (seconds_diff % 86400) / 3600 ))

echo -e "${blue}Time since last update: ${orange}${days}${reset} days and ${orange}${hours}${reset} hours"
else
  echo -e "${red}No update logs found.${reset}"
fi
echo

#Latest stable topic info
CATEGORY_HTML="/tmp/manjaro/category.html"
TOPIC_JSON="/tmp/manjaro/topic.json"

# Download the category page
curl -s "https://forum.manjaro.org/c/announcements/stable-updates/12" -o "$CATEGORY_HTML"

# Extract first topic URL inside tbody with exact <a> pattern
FIRST_TOPIC_URL=$(sed -n '/<tbody>/,/<\/tbody>/p' "$CATEGORY_HTML" | \
  grep -Po "<a itemprop='url' href='\K[^']+(?=' class='title raw-link raw-topic-link')" | head -1)

# Append .json to get topic JSON URL
TOPIC_JSON_URL="${FIRST_TOPIC_URL}.json"

# Download the topic JSON data
curl -s "$TOPIC_JSON_URL" -o "$TOPIC_JSON"

# Extract total voters
VOTERS=$(grep -oP '\"voters\":\K[0-9]+' "$TOPIC_JSON" | head -1)

# Extract no issue votes count
NO_ISSUE_VOTES=$(grep -oP 'No issue, everything went smoothly\",\"votes\":\K[0-9]+' "$TOPIC_JSON" | head -1)

# Sanity check to avoid division by zero
if [[ -n "$VOTERS" && "$VOTERS" -ne 0 ]]; then
  NO_ISSUE_PERCENT=$(( 100 * NO_ISSUE_VOTES / VOTERS ))
  PERCENT_TEXT="${NO_ISSUE_PERCENT}"
else
  NO_ISSUE_PERCENT=-1  # use sentinel for "N/A"
  PERCENT_TEXT="N/A"
fi

echo -e "No issue: ${orange}${PERCENT_TEXT}${reset}%  Total votes: ${VOTERS:-0}"
echo

# Packages count
aur_count=$(pacman -Qm | wc -l)
extensions_count=$(gext list | wc -l)
flatpak_count=$(flatpak list --app --columns=application 2>/dev/null | wc -l)

echo -e "${reset}Aur: ${orange}${aur_count}${reset}  Extensions: ${orange}${extensions_count}${reset}  Flatpaks: ${flatpak_count}"

read total used avail <<< $(df / --block-size=1 | awk 'NR==2 {print $2, $3, $4}')
percent=$(awk -v u="$used" -v t="$total" 'BEGIN { printf "%.1f", (u/t)*100 }')
used_gb=$(awk -v u="$used" 'BEGIN { printf "%.1f", u/1e9 }')
explicit_count=$(pacman -Qe | wc -l)

echo -e "${reset}Disk used: ${orange}${used_gb}${reset}GB (${percent}% full)  Programs: ${explicit_count}"
echo -e "\n\n"

# Function to execute commands and check for errors
run_command() {
  echo -e "\n\n\n"
  echo -e "${cyan}Running: $*${reset}"

  if [[ "$1" == "sudo" && "$2" == "pacman" ]]; then
    shift 2
    sudo script -q /dev/null -c "pacman $*"
  elif [[ "$1" == "yay" ]]; then
    shift 1
    script -q /dev/null -c "yay $*"
  else
    "$@"
  fi

  local status=$?
  if [ $status -ne 0 ]; then
    echo -e "${red}Error: Command '$*' failed with exit code $status${reset}"
    return 1
  else
    echo -e "${green}Command '$*' completed successfully.${reset}"
    return 0
  fi
}

# Lock-handling prompt function
prompt_for_db_lock_resolution() {
  while [ -f /var/lib/pacman/db.lck ]; do
    echo
    echo -ne "${yellow}Pacman database is locked. (r)etry  (d)elete lock  (e)xit:${reset}"
    read -rp "" choice
    echo

    case "${choice,,}" in
      r)
        echo -e "${cyan}Retrying in 5 seconds...${reset}"
        sleep 5
        ;;
      d)
        echo -e "${cyan}Deleting pacman lock file...${reset}"
        if ! sudo fuser -v /var/lib/pacman/db.lck && ! sudo rm -f /var/lib/pacman/db.lck*; then
          echo -e "${red}Warning: Failed to delete lock file. It may still be in use or require manual removal.${reset}"
        fi
        ;;
      e)
        echo -e "${red}Exiting due to pacman lock.${reset}"
        exit 1
        ;;
      *)
        echo -e "${red}Invalid choice. Try again.${reset}"
        ;;
    esac
  done
}

# Prompt if percentage low or low voter count
if (( NO_ISSUE_PERCENT < 85 || VOTERS < 200 )); then
  echo -ne "${red}Low 'No issue' percentage or low Voters count. (y)es to open Manjaro topic or any other key to continue: ${reset}"
  read -r REPLY
  if [[ "${REPLY,,}" == "y" ]]; then
    xdg-open "$FIRST_TOPIC_URL" >/dev/null 2>&1 &
  fi
  echo -e "\n\n"
fi

# Proceed with update prompt
echo -ne "${yellow}Proceed with the update? (n)o or any other key: ${reset}"
read -rp "" update
if [[ "${update,,}" = "n" ]]; then
  exit
fi

echo -e "\n\n\n\n${purple}$(printf '%*s' 49 '' | tr ' ' '-') Mirrors refresh $(printf '%*s' 49 '' | tr ' ' '-')${reset}"

# --- Simple pacman rescue: on error, wipe sync DBs and force full refresh ---
pacman_rescue() {
  local rescue_log
  rescue_log=$(mktemp /tmp/manjaro/pacman_rescue.XXXXXX)

  local had_pipefail=0
  set -o | grep -q 'pipefail[[:space:]]*on' && had_pipefail=1
  set -o pipefail

  if ! run_command sudo pacman "$@" 2>&1 | tee "$rescue_log"; then
    if grep -qiE 'invalid or corrupted package|failed to commit transaction|database' "$rescue_log"; then
      echo
      echo -e "${red}Pacman error detected; purging sync databases and forcing full refresh...${reset}"
      sudo rm -f /var/lib/pacman/sync/*
      run_command sudo pacman -Syyu --noconfirm
    else
      [[ $had_pipefail -eq 0 ]] && set +o pipefail
      rm -f "$rescue_log"
      return 1
    fi
  fi

  [[ $had_pipefail -eq 0 ]] && set +o pipefail
  rm -f "$rescue_log"
}

# Refresh mirrors

refresh_mirrors=true
MIRRORLIST="/etc/pacman.d/mirrorlist"
if [[ -f "$MIRRORLIST" ]]; then
  mirrorlist_age=$(( $(date +%s) - $(stat -c %Y "$MIRRORLIST") ))
  if (( mirrorlist_age < 7200 )); then
    echo -e "\n\n\n"
    echo -ne "${yellow}Mirrorlist refreshed within the last 2 hours. (r)efresh anyway or any other key to continue: ${reset}"
    read -r mirror_recent_choice
    if [[ "${mirror_recent_choice,,}" != "r" ]]; then
      refresh_mirrors=false
    fi
  fi
fi

if [[ "$refresh_mirrors" == true ]]; then
while true; do
  if run_command sudo pacman-mirrors --fasttrack 10 --api --protocols all --set-branch stable; then
    MIRRORLIST="/etc/pacman.d/mirrorlist"
    mirror_count=$(grep -c '^Server *= *' "$MIRRORLIST")
    echo
    echo -e "${reset}Mirrors saved: ${orange}$mirror_count${reset}"

    if (( mirror_count >= 6 )); then
      break
    else
      if [[ -z "${mirror_prompt_shown:-}" ]]; then
        echo
        echo -ne "${red}Synced mirrors are less than 6.  ${yellow}(o)pen Manjaro status of mirrors page, or any other key to continue: ${reset}"
        read -r open_status
        if [[ "${open_status,,}" == "o" ]]; then
          xdg-open "https://repo.manjaro.org/" >/dev/null 2>&1 &
        fi
        mirror_prompt_shown=1
      fi
      echo
      echo -e "${red}Mirror count too low.${reset}"
    fi
  else
    echo
    echo -e "${red}Failed to refresh mirrors.${reset}"
  fi

  while true; do
    echo
    echo -ne "${yellow}(r)etry Fasttrack  (u)se Global mirrors  (c)ontinue script  or (e)xit: ${reset}"
    read -r choice
    case "${choice,,}" in
      r)
        break  # restart fasttrack attempt
        ;;
      u)
        if run_command sudo pacman-mirrors --country all --api --protocols all --set-branch stable; then
          MIRRORLIST="/etc/pacman.d/mirrorlist"
          mirror_count=$(grep -c '^Server *= *' "$MIRRORLIST")
          echo
          echo -e "${reset}Mirrors saved: ${orange}$mirror_count${reset}"

          if (( mirror_count >= 6 )); then
            break 2  # done with mirror setup, exit both loops
          else
            echo
            echo -e "${red}Mirror count too low.${reset}"
          fi
        else
          echo
          echo -e "${red}Global mirrors refresh failed.${reset}"
        fi
        ;;
      c)
        echo
        echo -e "${cyan}Continuing script despite mirror issues...${reset}"
        break 2  # break out of both loops, continue script
        ;;
      e)
        echo -e "${red}Exiting.${reset}"
        exit 1
        ;;
      *)
        echo
        echo -e "${red}Invalid choice. Please try again.${reset}"
        ;;
    esac
  done
done
fi
# Refresh mirrors
((++current_step)); show_progress $current_step $total_steps

echo -e "\n\n\n\n${purple}$(printf '%*s' 48 '' | tr ' ' '-') Packages updates $(printf '%*s' 49 '' | tr ' ' '-')${reset}"

# Perform updates

replace_aur_with_repo() {
echo -e "\n\n\n"
echo -e "${cyan}Checking for AUR packages that now exist in Manjaro repos...${reset}"

# Permanent exclude list
local exclude_file="$HOME/.aur_excluded_pkg"
sudo -u "$USER" touch "$exclude_file"

# Load excludes into a set (associative array)
declare -A excluded=()
while IFS= read -r line; do
# skip blanks/comments
[[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
excluded["$line"]=1
done < "$exclude_file"

# Define default suffixes for variant stripping
local default_suffixes=(
"-git" "-bin" "-vcs" "-aur" "-devel" "-nightly" "-wayland" "-stable" "-legacy"
"-nox" "-gtk2" "-gtk3" "-gtk4" "-qt4" "-qt5" "-qt6" "-beta" "-alpha"
)
local suffixes=("${default_suffixes[@]}")

# Load cached repo packages list
if [[ ! -f /tmp/manjaro/repo_pkgs.txt ]]; then
echo -e "${red}Repo package list file /tmp/manjaro/repo_pkgs.txt not found! Run pacman -Sl to generate it.${reset}"
return 1
fi
mapfile -t repo_pkgs < "/tmp/manjaro/repo_pkgs.txt"

# Get installed AUR packages (local foreign)
mapfile -t aur_pkgs < <(pacman -Qm | awk '{print $1}' | sort)
if (( ${#aur_pkgs[@]} == 0 )); then
echo
echo -e "${orange}No AUR packages detected.${green} Nothing to check.${reset}"
return 0
fi

# Helper: append package to exclude file once (idempotent)
add_to_exclude_file() {
local pkg="$1"
# Append only if exact line does not already exist (no duplicates)
if ! grep -qxF "$pkg" "$exclude_file"; then
printf '%s\n' "$pkg" >> "$exclude_file"
fi
excluded["$pkg"]=1
}

# Multi-match fuzzy search function + new exclude option
fuzzy_match() {
local aur_pkg="$1" # original AUR name
local aur_base="$2" # stripped base used for searching
local aur_base_esc
aur_base_esc=$(printf '%s' "$aur_base" | sed -e 's/[][(){}.^$*+?|\\]/\\&/g')
mapfile -t matches < <(printf '%s\n' "${repo_pkgs[@]}" | grep -iE "(^|[-_])${aur_base_esc}($|[-_])")

if (( ${#matches[@]} == 0 )); then
echo ""
return
fi

{
echo
echo -e "${yellow}Fuzzy matches for '$aur_base' (from AUR '$aur_pkg'):${reset}"
local i=1
for match in "${matches[@]}"; do
echo " [$i] $match"
((i++))
done
echo " [0] Skip"
echo " [x] Exclude '$aur_pkg' permanently"
} > /dev/tty

local choice
while true; do
echo -ne "${cyan}Choose number / 0 / x: ${reset}" > /dev/tty
read -r choice < /dev/tty
if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 0 && choice < i )); then
break
elif [[ "${choice,,}" == "x" ]]; then
break
fi
done

if [[ "${choice,,}" == "x" ]]; then
add_to_exclude_file "$aur_pkg"
echo ""
elif (( choice == 0 )); then
echo ""
else
echo "${matches[choice-1]}"
fi
}

# Find AUR replacements
find_aur_replacements() {
local aur_pkgs=("$@")
to_replace=() # global

for aur in "${aur_pkgs[@]}"; do
# NEW: skip excluded packages early
if [[ -n "${excluded[$aur]:-}" ]]; then
echo -e "Excluded from replacement (persistent):${blue} ${aur}${reset}"
continue
fi

local base="$aur"
for suf in "${suffixes[@]}"; do
if [[ "$aur" == *"$suf" ]]; then
base="${aur%"$suf"}"
break
fi
done

if [[ " ${repo_pkgs[*]} " == *" $base "* ]]; then
to_replace+=("$aur|$base")
else
# interactive fuzzy match with exclude option
local matched_pkg
matched_pkg=$(fuzzy_match "$aur" "$base")
[[ -n "$matched_pkg" ]] && to_replace+=("$aur|$matched_pkg") || true
fi
done
}

# Run replacement finder
find_aur_replacements "${aur_pkgs[@]}"

# Filter valid entries only
local valid_replace=()
for entry in "${to_replace[@]}"; do
local aur="${entry%%|*}"
local base="${entry##*|}"
if [[ -n "$aur" && -n "$base" ]]; then
valid_replace+=("$entry")
fi
done

if (( ${#valid_replace[@]} == 0 )); then
echo -e "${orange}No AUR packages found in official repos (after exclusions).${cyan} Nothing to replace.${reset}"
return 0
fi

# Summary of replacements
echo
echo -e "${yellow}The following AUR packages are now in the official repos:${reset}"
printf "%-30s %-30s\n" "AUR Package" "Repo Package"
printf "%-30s %-30s\n" "-----------" "------------"
for entry in "${valid_replace[@]}"; do
local aur="${entry%%|*}"
local base="${entry##*|}"
printf "%-30s %-30s\n" "$aur" "$base"
done

# Confirm to proceed
echo
echo -ne "${cyan}Proceed with replacing them? (y)es or any other key to skip: ${reset}"
read -r choice < /dev/tty
if [[ "$choice" =~ ^[Yy]$ ]]; then
# Perform replacements
for entry in "${valid_replace[@]}"; do
local aur="${entry%%|*}"
local base="${entry##*|}"

echo -e "${cyan}Removing AUR package: $aur...${reset}"
if ! run_command yay -Rns --noconfirm "$aur"; then
echo -e "${red}Failed to remove $aur. Skipping this package.${reset}"
continue
fi

echo -e "${cyan}Installing repo package: $base...${reset}"
if ! pacman_rescue -S --noconfirm "$base"; then
echo -e "${red}Failed to install $base. Attempting to reinstall $aur...${reset}"
run_command yay -S --noconfirm "$aur"
continue
fi

echo -e "${green}Replaced $aur with $base successfully.${reset}"
done

echo
echo -e "${green}All replacements completed.${reset}"
else
echo
echo -e "${red}Replacement operation skipped by user.${reset}"
fi
}

replace_flatpaks_with_repo() {
echo -e "\n\n\n"
echo -e "${cyan}Checking for Flatpak apps that also exist as Manjaro repo packages...${reset}"

# Permanent exclude list
local exclude_file="$HOME/.flatpak_excluded_app"
touch "$exclude_file"

# Load excludes into a set (associative array)
declare -A excluded=()
while IFS= read -r line; do
# skip blanks/comments
[[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
excluded["$line"]=1
done < "$exclude_file"

# Define default suffixes for variant stripping (applied to derived base name)
local default_suffixes=(
"-git" "-bin" "-vcs" "-aur" "-devel" "-nightly" "-wayland" "-stable" "-legacy"
"-nox" "-gtk2" "-gtk3" "-gtk4" "-qt4" "-qt5" "-qt6" "-beta" "-alpha"
)
local suffixes=("${default_suffixes[@]}")

# Load cached repo packages list
if [[ ! -f /tmp/manjaro/repo_pkgs.txt ]]; then
echo -e "${red}Repo package list file /tmp/manjaro/repo_pkgs.txt not found! Run pacman -Sl to generate it.${reset}"
return 1
fi
mapfile -t repo_pkgs < "/tmp/manjaro/repo_pkgs.txt"

# Get installed Flatpaks with origin + installation (user/system)
# Format: appid|origin|install
mapfile -t flatpak_rows < <(
  flatpak list --app --columns=application,origin,installation 2>/dev/null \
  | awk 'NF{print $1 "|" $2 "|" $3}' \
  | sort -u
)

if (( ${#flatpak_rows[@]} == 0 )); then
echo
echo -e "${orange}No Flatpaks detected.${green} Nothing to check.${reset}"
return 0
fi

# Helper: append appid to exclude file once (idempotent)
add_to_exclude_file() {
local appid="$1"
if ! grep -qxF "$appid" "$exclude_file"; then
printf '%s\n' "$appid" >> "$exclude_file"
fi
excluded["$appid"]=1
}

# Derive a repo-ish base name from Flatpak ID
# Examples:
#   org.mozilla.firefox        -> firefox
#   com.spotify.Client         -> spotify   (Client is too generic)
flatpak_base_from_appid() {
local appid="$1"
local last="${appid##*.}"
local base="$last"

# If the last segment is generic, use the previous one
case "$last" in
Client|client|Desktop|desktop|App|app)
local prev="${appid%.*}"
base="${prev##*.}"
;;
esac

# Strip known suffix variants from the derived base
local suf
for suf in "${suffixes[@]}"; do
if [[ "$base" == *"$suf" ]]; then
base="${base%"$suf"}"
break
fi
done

printf '%s' "$base"
}

# Multi-match fuzzy search + exclude option (searches repo_pkgs)
fuzzy_match() {
local appid="$1"     # original flatpak id
local base="$2"      # derived base used for searching
local base_esc
base_esc=$(printf '%s' "$base" | sed -e 's/[][(){}.^$*+?|\\]/\\&/g')

mapfile -t matches < <(printf '%s\n' "${repo_pkgs[@]}" | grep -iE "(^|[-_])${base_esc}($|[-_])")

if (( ${#matches[@]} == 0 )); then
echo ""
return
fi

{
echo
echo -e "${yellow}Fuzzy matches for '$base' (from Flatpak '$appid'):${reset}"
local i=1
for match in "${matches[@]}"; do
echo " [$i] $match"
((i++))
done
echo " [0] Skip"
echo " [x] Exclude '$appid' permanently"
} > /dev/tty

local choice
while true; do
echo -ne "${cyan}Choose number / 0 / x: ${reset}" > /dev/tty
read -r choice < /dev/tty
if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 0 && choice < i )); then
break
elif [[ "${choice,,}" == "x" ]]; then
break
fi
done

if [[ "${choice,,}" == "x" ]]; then
add_to_exclude_file "$appid"
echo ""
elif (( choice == 0 )); then
echo ""
else
echo "${matches[choice-1]}"
fi
}

# Find Flatpak -> repo replacements
find_flatpak_replacements() {
local rows=("$@")
to_replace=() # global

local row appid origin install base matched_pkg
for row in "${rows[@]}"; do
appid="${row%%|*}"
origin="${row#*|}"; origin="${origin%%|*}"
install="${row##*|}"

# Skip excluded apps early
if [[ -n "${excluded[$appid]:-}" ]]; then
echo -e "Excluded from replacement (persistent):${blue} ${appid}${reset}"
continue
fi

base="$(flatpak_base_from_appid "$appid")"

# Exact match first
if [[ " ${repo_pkgs[*]} " == *" $base "* ]]; then
to_replace+=("$appid|$origin|$install|$base")
else
# interactive fuzzy match with exclude option
matched_pkg="$(fuzzy_match "$appid" "$base")"
[[ -n "$matched_pkg" ]] && to_replace+=("$appid|$origin|$install|$matched_pkg") || true
fi
done
}

# Run replacement finder
find_flatpak_replacements "${flatpak_rows[@]}"

# Filter valid entries only
local valid_replace=()
local entry appid origin install repo_pkg
for entry in "${to_replace[@]}"; do
appid="$(cut -d'|' -f1 <<<"$entry")"
origin="$(cut -d'|' -f2 <<<"$entry")"
install="$(cut -d'|' -f3 <<<"$entry")"
repo_pkg="$(cut -d'|' -f4- <<<"$entry")"
if [[ -n "$appid" && -n "$repo_pkg" ]]; then
valid_replace+=("$entry")
fi
done

if (( ${#valid_replace[@]} == 0 )); then
echo -e "${orange}No Flatpaks found with matching Manjaro repo packages (after exclusions).${cyan} Nothing to replace.${reset}"
return 0
fi

# Summary of replacements
echo
echo -e "${yellow}The following Flatpaks appear to exist as Manjaro repo packages:${reset}"
printf "%-45s %-8s %-20s %-30s\n" "Flatpak AppID" "Scope" "Origin" "Repo Package"
printf "%-45s %-8s %-20s %-30s\n" "-----------" "-----" "------" "------------"
for entry in "${valid_replace[@]}"; do
appid="$(cut -d'|' -f1 <<<"$entry")"
origin="$(cut -d'|' -f2 <<<"$entry")"
install="$(cut -d'|' -f3 <<<"$entry")"
repo_pkg="$(cut -d'|' -f4- <<<"$entry")"
printf "%-45s %-8s %-20s %-30s\n" "$appid" "$install" "${origin:-NA}" "$repo_pkg"
done

# Confirm to proceed
echo
echo -ne "${cyan}Proceed with replacing them? (y)es or any other key to skip: ${reset}"
read -r choice < /dev/tty

if [[ "$choice" =~ ^[Yy]$ ]]; then
for entry in "${valid_replace[@]}"; do
appid="$(cut -d'|' -f1 <<<"$entry")"
origin="$(cut -d'|' -f2 <<<"$entry")"
install="$(cut -d'|' -f3 <<<"$entry")"
repo_pkg="$(cut -d'|' -f4- <<<"$entry")"

echo -e "${cyan}Removing Flatpak app: $appid...${reset}"

if [[ "$install" == "user" ]]; then
if ! run_command flatpak uninstall -y --user "$appid"; then
echo -e "${red}Failed to remove Flatpak (user): $appid. Skipping this app.${reset}"
continue
fi
else
if ! run_command sudo flatpak uninstall -y --system "$appid"; then
echo -e "${red}Failed to remove Flatpak (system): $appid. Skipping this app.${reset}"
continue
fi
fi

echo -e "${cyan}Installing repo package: $repo_pkg...${reset}"
if ! pacman_rescue -S --noconfirm "$repo_pkg"; then
echo -e "${red}Failed to install $repo_pkg. Attempting to reinstall Flatpak $appid...${reset}"

# Best-effort reinstall if origin is known
if [[ -n "$origin" && "$origin" != "NA" ]]; then
if [[ "$install" == "user" ]]; then
run_command flatpak install -y --user "$origin" "$appid"
else
run_command sudo flatpak install -y --system "$origin" "$appid"
fi
else
echo -e "${yellow}Flatpak origin unknown for $appid; reinstall skipped.${reset}"
fi

continue
fi

echo -e "${green}Replaced Flatpak $appid with repo package $repo_pkg successfully.${reset}"
done

echo
echo -e "${green}All Flatpak replacements completed.${reset}"
else
echo
echo -e "${red}Replacement operation skipped by user.${reset}"
fi
}

perform_updates() {
  echo
  prompt_for_db_lock_resolution

  # Loop pacman + PGP handling until a clean attempt
  while true; do
    pacman_tmp_log="/tmp/manjaro/pacman_attempt.log"
    : > "$pacman_tmp_log"

    if pacman_rescue -Syyu --noconfirm 2>&1 | tee -a "$pacman_tmp_log"; then
      pacman_failed=false
    else
      pacman_failed=true
    fi

    # Check only this attempt for PGP signature errors
    if grep -qiE 'signature.*(could not be verified|invalid|error|unknown|revoked|failed)' "$pacman_tmp_log"; then
      echo
      echo -e "${red}PGP signature errors detected in pacman output.${reset}"
      echo
      echo -ne "${yellow}Press any key to reset keyring and retry pacman update...${reset}"
      read -r -n 1
      echo

      sudo rm -rf /etc/pacman.d/gnupg
      sudo pacman-key --init
      sudo pacman-key --populate archlinux manjaro

      echo -e "${cyan}Retrying pacman update after keyring reset...${reset}"
      continue
    fi

    echo
    echo -e "${orange}No PGP signature errors detected. ${cyan}Continuing...${reset}"
    break
  done

  # List repo packages for AUR replacement
  pacman -Sl core extra multilib | awk '{print $2}' | sort -u > /tmp/manjaro/repo_pkgs.txt

  # Replace AUR packages that now exist in official repos (including known AUR variants)
  replace_aur_with_repo

  prompt_for_db_lock_resolution
  if ! run_command yay -Syu --devel --timeupdate --noconfirm --cleanafter --editmenu=false --combinedupgrade --combinedupgrade; then
    echo
    echo -e "${red}Yay update failed.${reset}"
    yay_failed=true
  else
    yay_failed=false
  fi

  return 0
}

# Replace AUR packages that now exist in official repos (including known AUR variants)

# Run updates first time
perform_updates

# Retry loop if either failed
while [[ "$pacman_failed" == true || "$yay_failed" == true ]]; do
  echo
  echo -ne "${red}Pacman and or Yay failed (r)etry  (e)xit: ${reset} "
  read -rp "" choice
  case "$choice" in
    [Rr]* )
      echo
      echo -e "${cyan}Retrying updates...${reset}"
      perform_updates
      ;;
    [Ee]* )
      echo -e "${red}Exiting script...${reset}"
      exit 1
      ;;
    * )
      echo
      echo -e "${red}Please answer with (r)etry or (e)xit.${reset}"
      ;;
  esac
done
# Perform updates
((++current_step)); show_progress $current_step $total_steps

echo -e "\n\n\n\n${purple}$(printf '%*s' 43 '' | tr ' ' '-') Extensions-Flatpaks updates $(printf '%*s' 43 '' | tr ' ' '-')${reset}"

# User extensions updates
if ! run_command gext update -y; then
  echo
  echo -e "${red}User extensions updates failed, continuing...${reset}"
fi

# Replace Flatpaks with repo packages (before Flatpak updates)
if [[ ! -f /tmp/manjaro/repo_pkgs.txt ]]; then
  pacman -Sl core extra multilib | awk '{print $2}' | sort -u > /tmp/manjaro/repo_pkgs.txt
fi
replace_flatpaks_with_repo

# Flatpak updates sudo
if ! run_command sudo flatpak update -y; then
  echo
  echo -e "${red}Flatpak update (sudo) failed, continuing...${reset}"
fi

# Flatpak updates user
if ! run_command flatpak update -y; then
  echo
  echo -e "${red}Flatpak update (user) failed, continuing...${reset}"
fi
((++current_step)); show_progress $current_step $total_steps

echo -e "\n\n\n\n${purple}$(printf '%*s' 49 '' | tr ' ' '-') Cleanup-Repairs $(printf '%*s' 49 '' | tr ' ' '-')${reset}"
echo -e "\n\n\n"

# Remove orphaned packages (auto-confirm)
echo -e "${cyan}Checking for orphaned packages...${reset}"
mapfile -t orphaned_packages < <(sudo pacman -Qtdq)
if [ ${#orphaned_packages[@]} -ne 0 ]; then
  if sudo pacman -Rns --noconfirm "${orphaned_packages[@]}"; then
    echo
    echo -e "${green}Orphaned packages removed.${reset}"
  else
    echo
    echo -e "${red}Failed to remove orphaned packages, continuing...${reset}"
  fi
else
  echo
  echo -e "${cyan}No orphaned packages found.${reset}"
fi

# Clean pacman package cache (auto-confirm)
if ! run_command bash -c "yes | sudo pacman -Scc"; then
  echo
  echo -e "${red}Failed to clean package cache with pacman -Scc, trying manual cache deletion...${reset}"
  run_command sudo rm -rf /var/cache/pacman/pkg/*
fi

# Flatpak repair (system)
if ! run_command sudo flatpak repair; then
  echo
  echo -e "${red}Flatpak system repair failed, continuing...${reset}"
fi

# Flatpak repair (user)
if ! run_command flatpak repair --user; then
  echo
  echo -e "${red}Flatpak user repair failed, continuing...${reset}"
fi

# Flatpak clean orphaned components
if ! run_command flatpak uninstall --unused -y; then
  echo
  echo -e "${red}Flatpak clean orphaned components failed, continuing...${reset}"
fi
echo -e "\n\n\n"

# Remove unowned Flatpak app data (Flatpak-native)
# NOTE: "--delete-data" without a REF removes all "unowned" app data.
echo -e "${cyan}Running: flatpak uninstall --delete-data -y${reset}\n"

flatpak uninstall --delete-data -y
status=$?

if (( status == 0 )); then
echo -e "${green}Command 'flatpak uninstall --delete-data -y' completed successfully.${reset}"
else
echo
echo -e "${red}Error: Command 'flatpak uninstall --delete-data -y' failed with exit code ${status}${reset}"
echo
echo -e "${red}Flatpak unowned app data cleanup failed, continuing...${reset}"
fi
echo -e "\n\n\n"

# Remove leftover Flatpak app data for uninstalled apps
echo -e "${cyan}Checking for leftover Flatpak app data...${reset}"
mapfile -t leftover_apps < <(comm -23 <(ls ~/.var/app | sort) <(flatpak list --app --columns=application | sort))
if [ ${#leftover_apps[@]} -ne 0 ]; then
  if rm -rf -- "${leftover_apps[@]/#/$HOME/.var/app/}"; then
    echo
    echo -e "${green}Leftover Flatpak app data deleted.${reset}"
  else
    echo
    echo -e "${red}Failed to remove some leftover Flatpak app data, continuing...${reset}"
  fi
else
  echo
  echo -e "${cyan}No leftover Flatpak app data found.${reset}"
fi
echo -e "\n\n\n"

# --- Flatpak remotes hygiene (interactive) ---

echo -e "${cyan}Checking Flatpak remotes for unused entries...${reset}"
echo
cleanup_flatpak_remotes() {

local scope="$1"   # "user" or "system"

local list_cmd remote_del_cmd
if [[ "$scope" == "user" ]]; then
list_cmd=(flatpak --user)
remote_del_cmd=(flatpak --user remote-delete --force)
else
list_cmd=(sudo flatpak --system)
remote_del_cmd=(sudo flatpak --system remote-delete --force)
fi

mapfile -t all_remotes < <("${list_cmd[@]}" remote-list --columns=name 2>/dev/null | sort -u)
mapfile -t used_origins < <("${list_cmd[@]}" list --app --columns=origin 2>/dev/null | sort -u)

if (( ${#all_remotes[@]} == 0 )); then
echo -e "${cyan}No ${scope} Flatpak remotes found.${reset}"
return 0
fi

declare -A used=()
for o in "${used_origins[@]}"; do
[[ -n "$o" ]] && used["$o"]=1
done

unused=()
for r in "${all_remotes[@]}"; do
[[ -n "$r" ]] || continue
if [[ -z "${used[$r]:-}" ]]; then
unused+=("$r")
fi
done

if (( ${#unused[@]} == 0 )); then
echo -e "${cyan}No unused ${scope} Flatpak remotes detected.${reset}"
return 0
fi

echo
echo -e "${yellow}Unused ${scope} Flatpak remotes:${reset}"
printf '%s\n' "${unused[@]}"

echo
echo -ne "${yellow}Remove these remotes? (y)es or any other key to skip: ${reset}"
read -r ans
echo

if [[ "${ans,,}" != "y" ]]; then
echo -e "${cyan}Skipping ${scope} remotes cleanup.${reset}"
return 0
fi

for r in "${unused[@]}"; do
echo -e "${cyan}Removing ${scope} remote: ${orange}${r}${reset}"
if ! "${remote_del_cmd[@]}" "$r"; then
echo -e "${red}Failed to remove remote: ${r}${reset}"
fi
done

echo -e "${green}${scope} remotes cleanup done.${reset}"
}

cleanup_flatpak_remotes user
echo
cleanup_flatpak_remotes system
echo -e "\n\n\n"

# Delete unwanted Manjaro GNOME extensions, keeping only anything with "pamac" in the name (case-insensitive)
echo -e "${cyan}Checking for unwanted Manjaro Gnome extensions...${reset}"

mapfile -t unwanted_exts < <(find /usr/share/gnome-shell/extensions/ \
  -mindepth 1 -maxdepth 1 -type d \
  ! -iname '*pamac*')

if [[ ${#unwanted_exts[@]} -eq 0 ]]; then
  echo
  echo -e "${cyan}No Manjaro Gnome extensions found.${reset}"
else
  if sudo rm -rf "${unwanted_exts[@]}"; then
    echo
    echo -e "${green}Manjaro Gnome extensions deleted.${reset}"
  else
    echo
    echo -e "${red}Failed to delete Manjaro Gnome extensions, continuing...${reset}"
  fi
fi
echo -e "\n\n\n"

# Cleanup thumbnails, screenshots, and downloads
echo -e "${cyan}Checking thumbnails, screenshots, and downloads...${reset}"
echo

TARGETS=(
  "$HOME/.cache/thumbnails"
  "$HOME/Screenshots"
  "$HOME/Downloads"
)

for DIR in "${TARGETS[@]}"; do
    if [ -d "$DIR" ]; then
        if find "$DIR" -mindepth 1 -print -quit 2>/dev/null | read -r _; then
            if find "$DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null; then
                echo -e "${green}Cleaned: $DIR${reset}"
            else
                echo -e "${red}Failed to clean: $DIR${reset}"
            fi
        else
            echo -e "${cyan}Nothing to clean in: $DIR${reset}"
        fi
    else
        echo -e "${yellow}Directory not found: $DIR${reset}"
    fi
done
echo -e "\n\n\n"

# === Orphaned Home App Data Cleanup (exclude instead of quarantine) ===
echo -e "${cyan}Checking orphaned app configs...${reset}\n"

normalize_key() { tr '[:upper:]' '[:lower:]' <<<"$1" | sed 's/[^a-z0-9]//g'; }

# --- Persistent exclude list (in $HOME) ---
EXCLUDE_FILE="$HOME/.orphaned_home_apps.exclude"
touch "$EXCLUDE_FILE"
chmod 600 "$EXCLUDE_FILE"

declare -A EXCLUDED_PATHS=()
while IFS= read -r line; do
  [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
  EXCLUDED_PATHS["$line"]=1
done < "$EXCLUDE_FILE"

exclude_path() {
  local p="$1"
  [[ -n "${EXCLUDED_PATHS[$p]:-}" ]] && return 0
  printf '%s\n' "$p" >> "$EXCLUDE_FILE"
  EXCLUDED_PATHS["$p"]=1
}

# --- Build installed set ---
declare -A INSTALLED_SET=()

while IFS= read -r pkg; do
  k=$(normalize_key "$pkg")
  [[ -n "$k" ]] && INSTALLED_SET["$k"]=1
done < <(pacman -Qq 2>/dev/null || true)

while IFS= read -r appid; do
  [[ -z "$appid" ]] && continue
  k_full=$(normalize_key "$appid")
  k_last=$(normalize_key "${appid##*.}")
  [[ -n "$k_full" ]] && INSTALLED_SET["$k_full"]=1
  [[ -n "$k_last" ]] && INSTALLED_SET["$k_last"]=1
done < <(flatpak list --app --columns=application 2>/dev/null || true)

SCAN_DIRS=("$HOME/.config" "$HOME/.cache" "$HOME/.local/share" "$HOME/.local/state")

KEEP_BASENAMES=("Trash" "dconf" "gtk-3.0" "gtk-4.0" "fontconfig" "pulse" "pipewire")
is_kept_basename() {
  local b="$1"
  for k in "${KEEP_BASENAMES[@]}"; do [[ "$b" == "$k" ]] && return 0; done
  return 1
}

: "${ORPHAN_FUZZY:=1}"

matches_installed() {
  local base="$1"
  local key
  key=$(normalize_key "$base")
  [[ ${#key} -lt 3 ]] && return 0
  [[ -n "${INSTALLED_SET[$key]:-}" ]] && return 0

  if (( ORPHAN_FUZZY == 1 )); then
    local k
    for k in "${!INSTALLED_SET[@]}"; do
      [[ ${#k} -lt 4 ]] && continue
      [[ "$key" == *"$k"* || "$k" == *"$key"* ]] && return 0
    done
  fi
  return 1
}

CANDIDATES=()

for dir in "${SCAN_DIRS[@]}"; do
  [[ -d "$dir" ]] || continue

  while IFS= read -r -d '' entry; do
    base=${entry##*/}

    is_kept_basename "$base" && continue
    matches_installed "$base" && continue

    # Canonicalize early so exclusions work even if symlinks are involved.
    entry_real=$(realpath -e -- "$entry" 2>/dev/null || printf '%s' "$entry")
    [[ -n "${EXCLUDED_PATHS[$entry_real]:-}" ]] && continue

    CANDIDATES+=("$entry_real")
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
done

mkdir -p /tmp/manjaro
outfile=$(mktemp -p /tmp/manjaro orphaned_home_apps.XXXXXX.txt 2>/dev/null || echo "/tmp/manjaro/orphaned_home_apps.txt")
printf "%s\n" "${CANDIDATES[@]}" > "$outfile"

DELETED_ANY=false

if (( ${#CANDIDATES[@]} == 0 )); then
  echo -e "${cyan}No orphaned app configs detected.${reset}"
else
  echo -e "${orange}Probable orphaned app directories found (${#CANDIDATES[@]}).${reset}"
  echo -e "${blue}Saved list:${reset} $outfile"
  echo -e "${blue}Exclude list:${reset} $EXCLUDE_FILE\n"

  for candidate in "${CANDIDATES[@]}"; do
    [[ -d "$candidate" ]] || continue

    cand_real=$(realpath -e -- "$candidate" 2>/dev/null || printf '%s' "$candidate")
    case "$cand_real" in
      "$HOME/.config/"*|"$HOME/.cache/"*|"$HOME/.local/share/"*|"$HOME/.local/state/"*) ;;
      *)
        echo -e "${red}Refusing to touch outside scan roots:${reset} $cand_real\n"
        continue
        ;;
    esac

    echo -e "$cand_real"
    echo -ne "${yellow}(e)xclude forever  (d)elete permanently  (s)kip: ${reset}"
    read -r action
    echo

    case "${action,,}" in
      e|"")
        exclude_path "$cand_real"
        echo -e "${green}Excluded:${reset} $cand_real"
        ;;
      d)
        if rm -rf -- "$cand_real"; then
          echo -e "${green}Deleted:${reset} $cand_real"
          DELETED_ANY=true
        else
          echo -e "${red}Failed to delete:${reset} $cand_real"
        fi
        ;;
      *)
        echo -e "${cyan}Skipped:${reset} $cand_real"
        ;;
    esac
    echo
  done
fi

if $DELETED_ANY; then
  echo -e "${green}Orphaned app configs cleaned.${reset}"
fi

# Clean yay package cache (auto-confirm)
if ! run_command bash -c "yes | yay -Scc"; then
  echo
  echo -e "${red}Failed to clean package cache with yay -Scc, trying manual cache deletion...${reset}"
  run_command rm -rf "$HOME/.cache/yay/"*
fi
((++current_step)); show_progress $current_step $total_steps

echo -e "\n\n\n\n${purple}$(printf '%*s' 44 '' | tr ' ' '-') .Pacsave .Pacnew handling $(printf '%*s' 44 '' | tr ' ' '-')${reset}"
echo -e "\n\n\n"

# Pacnew Pacsave handling
# --- Pacnew/Pacsave Discovery ---
mapfile -t pac_files < <(
  sudo find / \
    \( -path "/.snapshots" -prune \) -o \
    -regextype posix-extended -regex ".+\.pac(new|save)" -print 2>/dev/null
)

echo -e "${cyan}Checking for .pacnew and .pacsave files...${reset}"

if [ "${#pac_files[@]}" -eq 0 ]; then
  echo
  echo -e "${cyan}No .pacnew or .pacsave found.${reset}"
else
  echo
  echo -e "${red}Found: ${#pac_files[@]} files${reset}"
  printf '%s\n' "${pac_files[@]}"
  echo

# --- Prompt for Handling ---
  echo -ne "${yellow}Deal with .pacsave/.pacnew? (n)o or any other key: ${reset}"
  read -r choice
  if [[ ! "$choice" =~ ^[Nn]$ ]]; then

# --- Pacnew/Pacsave Review ---
    echo
    echo -ne "${yellow}Press Enter to review...${reset}"
    read -r
    echo

    rm -rf ~/meld-temp
    mkdir -p ~/meld-temp
    sudo chown "$USER":"$USER" ~/meld-temp
    chmod 700 ~/meld-temp

    declare -A siblings

    for pac_file in "${pac_files[@]}"; do
      dir=$(dirname "$pac_file")
      base=$(basename "$pac_file")
      base_name="${base%.pacnew}"
      base_name="${base_name%.pacsave}"

      for match in "$dir"/"$base_name"*; do
        [[ "$match" == "$pac_file" ]] && continue
        [[ "$match" == *.pacnew || "$match" == *.pacsave ]] && continue

        if [[ -f "$match" ]]; then
          siblings["$pac_file"]="$match"

          # Delete all old backups
          for old_backup in "$match".backup-*; do
            [[ -e "$old_backup" ]] && sudo rm -f "$old_backup"
          done

          # Create new backup
          backup="${match}.backup-$(date +%Y%m%d-%H%M%S)"
          echo -e "${cyan}Backing up sibling:${reset} $match -> $backup"
          sudo cp -a "$match" "$backup"

          break
        fi
      done
    done

    # Copy pacnew/pacsave files and siblings to ~/meld-temp
    for pac_file in "${pac_files[@]}"; do
      dest=~/meld-temp"${pac_file}"
      mkdir -p "$(dirname "$dest")"
      sudo cp -a "$pac_file" "$dest"
      sudo chown "$USER":"$USER" "$dest"

      sibling="${siblings[$pac_file]}"
      if [[ -n "$sibling" ]]; then
        sibling_dest=~/meld-temp"${sibling}"
        mkdir -p "$(dirname "$sibling_dest")"
        sudo cp -a "$sibling" "$sibling_dest"
        sudo chown "$USER":"$USER" "$sibling_dest"
      fi
    done

    declare -A processed
    for pac_file in "${pac_files[@]}"; do
      [[ ${processed["$pac_file"]} ]] && continue

      temp_file=~/meld-temp"${pac_file}"
      sibling="${siblings[$pac_file]}"
      sibling_temp=~/meld-temp"${sibling}"

      echo
      echo -e "${cyan}Processing:${reset} $temp_file"
      echo

      if [[ -n "$sibling" && -f "$sibling_temp" ]]; then
        echo -e "${cyan}Launching meld for:$reset\n$temp_file\n$sibling_temp"
        meld "$sibling_temp" "$temp_file"
        processed["$pac_file"]=1
        processed["$sibling"]=1
      else
        echo -e "${cyan}Opening in gnome-text-editor:$reset $temp_file"
        gnome-text-editor "$temp_file" &> /dev/null
        processed["$pac_file"]=1
      fi

      if [[ "$pac_file" == *.pacnew || "$pac_file" == *.pacsave ]]; then
        echo
        echo -ne "${red}Delete $temp_file? (y)es or any other key: ${reset}"
        read -r del
        echo
        if [[ "$del" =~ ^[Yy]$ ]]; then
          rm -v "$temp_file"
        fi
      fi

      echo
      echo -ne "${yellow}Press Enter to continue to next file...${reset}"
      read -r
      echo
    done

    echo -ne "${yellow}Finalize all changes to files? (y)es or any key to continue with the script: ${reset}"
    read -r sync
    echo
    if [[ "${sync,,}" == "y" ]]; then
      for pac_file in "${pac_files[@]}"; do
        original_file="$pac_file"
        temp_file=~/meld-temp"${pac_file}"

        if [[ -f "$temp_file" ]]; then
          if ! cmp -s "$temp_file" "$original_file"; then
            echo -e "${cyan}Copying back: $temp_file → $original_file${reset}"
            sudo cp -a "$temp_file" "$original_file"
          else
            echo -e "${cyan}Unchanged:${reset} $original_file"
          fi
        else
          echo -e "${red}Removing: $original_file${reset}"
          sudo rm -f "$original_file"
        fi
      done

      total_count=0
      updated_count=0
      unchanged_count=0

      for pac_file in "${pac_files[@]}"; do
        sibling="${siblings[$pac_file]}"
        if [[ -n "$sibling" ]]; then
          ((total_count++))
          sibling_temp=~/meld-temp"${sibling}"
          if [[ -f "$sibling_temp" ]]; then
            if ! cmp -s "$sibling_temp" "$sibling"; then
              echo
              echo -e "${cyan}Copying back: $sibling_temp → $sibling${reset}"
              sudo cp -a "$sibling_temp" "$sibling"
              ((updated_count++))
            else
              echo
              echo -e "${yellow}Unchanged:${reset} $sibling"
              ((unchanged_count++))
            fi
          else
            echo
            echo -e "${red}Removing sibling: $sibling${reset}"
            sudo rm -f "$sibling"
          fi
        fi
      done
      if (( total_count > 0 )); then
        echo
        echo -e "${cyan}Config files sync summary:${reset}  ${blue}Total: $total_count${reset}  ${green}Updated: $updated_count${reset}  ${yellow}Unchanged: $unchanged_count${reset}"
      fi

    else
      echo
      echo -e "\n${cyan}Continuing without syncing changes...${reset}"
    fi

    # Cleanup
    rm -rf ~/meld-temp
    echo -e "\n\n\n"
  else
    echo
    echo -e "${cyan}Skipping .pacnew/.pacsave handling${reset}"
  fi
fi

# --- Old Backups Cleanup (always runs now) ---
echo
echo
echo -e "${cyan}Checking for .pacnew, .pacsave, and config backup files older than 30 days...${reset}"

today=$(date +%s)
cutoff_days=30
cutoff_secs=$((cutoff_days * 86400))

find_old_files() {
  while read -r file; do
    if [[ "$file" =~ \.backup-([0-9]{8})- ]]; then
      file_date="${BASH_REMATCH[1]}"
      file_epoch=$(date -d "${file_date}" +%s 2>/dev/null)
      if (( today - file_epoch > cutoff_secs )); then
        echo "$file"
      fi
    elif [[ "$file" =~ \.(pacnew|pacsave)$ ]]; then
      if [ "$(stat -c %Y "$file")" -lt $((today - cutoff_secs)) ]; then
        echo "$file"
      fi
    fi
  done
}

mapfile -t pac_files < <(
  sudo find / \
    \( -path "/.snapshots" -prune \) -o \
    -type f \( -name "*.pacnew" -o -name "*.pacsave" -o -name "*.backup-[0-9]*" \) -print 2>/dev/null |
  find_old_files
)

if [ "${#pac_files[@]}" -eq 0 ]; then
  echo
  echo -e "${cyan}No files found${reset}"
else
  echo
  echo -e "${red}Found: ${#pac_files[@]} files${reset}"
  printf '%s\n' "${pac_files[@]}"
  echo

  deleted_count=0
  skipped_count=0

  for file in "${pac_files[@]}"; do
    echo -ne "${yellow}Delete $file? (y)es or any other key: ${reset}"
    read -r confirm
    echo
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      sudo rm -f "$file"
      echo -e "${red}Deleted: $file${reset}"
      ((deleted_count++))
    else
      echo -e "${blue}Skipped: $file${reset}"
      ((skipped_count++))
    fi
  done

  echo -e "\n${cyan}Cleanup summary:${reset}  ${cyan}Total: $((deleted_count + skipped_count))${reset}  ${red}Deleted: $deleted_count${reset}   ${yellow}Skipped: $skipped_count${reset}"
fi

# Pacnew Pacsave handling
((++current_step)); show_progress $current_step $total_steps

echo -e "\n\n\n\n${purple}$(printf '%*s' 55 '' | tr ' ' '-') End $(printf '%*s' 55 '' | tr ' ' '-')${reset}"
echo -e "\n\n\n"

# Packages and installation size after
explicit_count2=$(pacman -Qe | wc -l)

read total used avail <<< $(df / --block-size=1 | awk 'NR==2 {print $2, $3, $4}')
percent=$(awk -v u="$used" -v t="$total" 'BEGIN { printf "%.1f", (u/t)*100 }')
used_gb2=$(awk -v u="$used" 'BEGIN { printf "%.1f", u/1e9 }')

# Calculate differences
explicit_diff=$((explicit_count2 - explicit_count))
used_diff=$(awk -v u1="$used_gb2" -v u2="$used_gb" 'BEGIN { d = u1 - u2; printf "%+.1f", d }')

echo -e "${reset}Disk used: ${used_gb2}GB${reset}  diff: ${orange}${used_diff}${reset}GB"
echo -e "${reset}Programs: ${explicit_count2}${reset}  diff: ${orange}${explicit_diff}${reset}"
echo

list_flatpaks_with_repo_check() {
    local repo_file="/tmp/manjaro/repo_pkgs.txt"

    # Check repo file
    if [[ ! -f "$repo_file" ]]; then
        echo -e "${red}Repo package list not found! Run pacman -Sl > $repo_file first.${reset}"
        return 1
    fi

    # Lowercase repo file once for case-insensitive matching
    local repo_file_lower="/tmp/manjaro/repo_pkgs_lower.txt"
    if [[ ! -f "$repo_file_lower" || "$repo_file_lower" -ot "$repo_file" ]]; then
        tr '[:upper:]' '[:lower:]' < "$repo_file" > "$repo_file_lower"
    fi

    # Get installed Flatpaks
    mapfile -t flatpaks < <(flatpak list --app --columns=application 2>/dev/null | sort)
    if (( ${#flatpaks[@]} == 0 )); then
        echo -e "${orange}No Flatpaks installed.${reset}"
        return 0
    fi

    echo -e "${cyan}Flatpaks:  ${orange}${#flatpaks[@]}${reset}"
    for app in "${flatpaks[@]}"; do
        # Extract last dot segment (actual app name)
        local app_base="${app##*.}"

        # Case-insensitive search in repo
        if grep -qiF "$app_base" "$repo_file_lower"; then
            echo -e "${app} ${orange}   in Manjaro repos${reset}"
        else
            echo "$app"
        fi
    done
    echo
}

list_aur_with_repo_check() {
    local repo_file="/tmp/manjaro/repo_pkgs.txt"

    # Check repo file
    if [[ ! -f "$repo_file" ]]; then
        echo -e "${red}Repo package list not found! Run pacman -Sl > $repo_file first.${reset}"
        return 1
    fi

    # Lowercase repo file once for case-insensitive matching
    local repo_file_lower="/tmp/manjaro/repo_pkgs_lower.txt"
    if [[ ! -f "$repo_file_lower" || "$repo_file_lower" -ot "$repo_file" ]]; then
        tr '[:upper:]' '[:lower:]' < "$repo_file" > "$repo_file_lower"
    fi

    # Same default suffix idea as in your replace logic
    local defaultsuffixes=(
        -git -bin -vcs -aur -devel -nightly -wayland -stable -legacy -nox
        -gtk2 -gtk3 -gtk4 -qt4 -qt5 -qt6 -beta -alpha
    )
    local suffixes=("${defaultsuffixes[@]}")

    # Get installed AUR (foreign) packages
    mapfile -t aurpkgs < <(pacman -Qm | awk '{print $1}' | sort)
    if (( ${#aurpkgs[@]} == 0 )); then
        echo -e "${orange}No AUR packages installed.${reset}"
        return 0
    fi

    echo -e "${cyan}AUR packages:  ${orange}${#aurpkgs[@]}${reset}"
    for pkg in "${aurpkgs[@]}"; do
        local base="$pkg"

        # Treat foo-git as foo (and similar suffix variants)
        local suf
        for suf in "${suffixes[@]}"; do
            if [[ "$base" == *"$suf" ]]; then
                base="${base%$suf}"
                break
            fi
        done

        # Case-insensitive search in repo (check base first, then fallback to full)
        if grep -qiF "$base" "$repo_file_lower" || grep -qiF "$pkg" "$repo_file_lower"; then
            echo -e "${pkg} ${orange}   in Manjaro repos${reset}"
        else
            echo "$pkg"
        fi
    done
    echo
}
list_aur_with_repo_check
list_flatpaks_with_repo_check
