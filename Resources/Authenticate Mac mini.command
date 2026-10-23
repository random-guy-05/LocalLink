#!/bin/bash
set -euo pipefail
umask 077
task_work="$HOME/Library/Application Support/LocalLink/SSH"
task_socket="$task_work/mini.sock"
task_hosts="$task_work/known_hosts"
mkdir -p "$task_work"
chmod 700 "$task_work"
echo "LocalLink — authenticate your host Mac"
echo "Your password goes directly to SSH and is not saved."
echo
task_host=""
if [[ -f "$task_work/target" ]]; then task_host="$(cat "$task_work/target")"; fi
if [[ -z "$task_host" ]]; then read -r -p "Host Tailscale IP or hostname: " task_host; fi
if [[ ! "$task_host" =~ ^[A-Za-z0-9][A-Za-z0-9.:-]*$ || ${#task_host} -gt 253 ]]; then
  echo "Enter a hostname or IP without a URL, username, spaces, or port."
  read -r -p "Press Return to close. " task_reply
  exit 1
fi
echo "Checking SSH on $task_host…"
if ! /usr/bin/nc -z -G 5 "$task_host" 22 >/dev/null 2>&1; then
  echo "SSH port 22 is unavailable. No password has been checked."
  echo "Wake the host and check its internet and Tailscale connection."
  echo "On the HOST: System Settings > General > Sharing > Remote Login."
  echo "Enable Remote Login and allow your account."
  read -r -p "Press Return to close. " task_reply
  exit 1
fi
task_default_user="${USER:-admin}"
read -r -p "Host account short name [$task_default_user]: " task_user
task_user="${task_user:-$task_default_user}"
if [[ ! "$task_user" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]]; then
  echo "Use the account short name, without spaces or an @ sign."
  read -r -p "Press Return to close. " task_reply
  exit 1
fi
if [[ -S "$task_socket" ]]; then
  /usr/bin/ssh -S "$task_socket" -O exit "$task_user@$task_host" 2>/dev/null || true
fi
echo "Connecting to $task_user@$task_host. Password typing will be invisible."
echo "On first connection, review and verify SSH's host-key fingerprint."
if /usr/bin/ssh -M -S "$task_socket" \
  -o ControlPersist=10m -o ControlMaster=auto \
  -o "UserKnownHostsFile=\"$task_hosts\"" -o StrictHostKeyChecking=ask \
  -o ConnectTimeout=10 -o PubkeyAuthentication=no \
  -o PreferredAuthentications=keyboard-interactive,password \
  -fN "$task_user@$task_host"; then
  printf '%s\n' "$task_user" > "$task_work/username"
  printf '%s\n' "$task_host" > "$task_work/connected-host"
  echo
  echo "Authenticated. Return to LocalLink to install the host or open its dashboard."
  echo "The connection expires after ten idle minutes. No password was saved."
else
  echo "SSH did not establish a session. Read its error above."
  echo "A timeout indicates a network or service problem."
  echo "Permission denied indicates account authentication or access settings."
  echo "For a changed host key, verify the host before replacing trusted information."
fi
read -r -p "Press Return to close. " task_reply
