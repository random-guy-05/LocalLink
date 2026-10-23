#!/bin/bash
# Run on the intended host Mac. An SSH caller supplies its expected host endpoint.
set -euo pipefail
task_volume=""
task_temp=""
task_fail() { echo "ERROR: $*" >&2; exit 1; }
task_cleanup() {
  if [[ -n "$task_volume" ]]; then /usr/bin/hdiutil detach "$task_volume" -quiet || true; fi
  if [[ -n "$task_temp" ]]; then /bin/rm -rf "$task_temp"; fi
}
trap task_cleanup EXIT

echo "LocalLink — Mac mini host setup"
echo "Installs official Sunshine v2026.914.233613, with SHA-256 verification."
echo "This does not install or use Parsec."
echo

task_expected=""
if [[ "${1:-}" == "--expected-ip" && -n "${2:-}" ]]; then
  task_expected="$2"
elif [[ -t 0 ]]; then
  echo "This installs Sunshine on the Mac where this script is running."
  read -r -p "Type INSTALL to confirm this is your intended HOST Mac: " task_confirmation
  [[ "$task_confirmation" == "INSTALL" ]] || task_fail "Setup cancelled."
else
  task_fail "Select the host in LocalLink, or run this interactively on the intended host."
fi

task_tailscale=""
for task_candidate in /usr/local/bin/tailscale /opt/homebrew/bin/tailscale /Applications/Tailscale.app/Contents/MacOS/Tailscale; do
  if [[ -x "$task_candidate" ]]; then task_tailscale="$task_candidate"; break; fi
done
[[ -n "$task_tailscale" ]] || task_fail "Install and connect Tailscale on the Mac mini first."
if [[ -n "$task_expected" ]]; then
  task_ips="$("$task_tailscale" ip)"
  printf '%s\n' "$task_ips" | /usr/bin/grep -Fxq -- "$task_expected" || task_fail "The expected SSH endpoint does not match this Mac's Tailscale addresses."
fi
task_version="$(/usr/bin/sw_vers -productVersion)"
task_major="${task_version%%.*}"
task_remainder="${task_version#*.}"
task_minor="${task_remainder%%.*}"
if (( task_major < 14 || (task_major == 14 && task_minor < 2) )); then
  task_fail "This Sunshine build requires macOS 14.2 or newer. Found $task_version."
fi

case "$(/usr/bin/uname -m)" in
  arm64)
    task_asset="Sunshine-macOS-arm64.dmg"
    task_sha="795f03a389c5726f9a7b15f501dc1ddf204b442cae565859ac83aae027a9e07c" ;;
  x86_64)
    task_asset="Sunshine-macOS-x86_64.dmg"
    task_sha="764b11674babac0cd838c2883359207a481c462f355ccbfd1ec91f6d44672101" ;;
  *) task_fail "Unsupported Mac architecture." ;;
esac

task_destination="/Applications/Sunshine.app"
if [[ -d "$task_destination" || -d "$HOME/Applications/Sunshine.app" ]]; then
  echo "Sunshine is already installed. Keeping the existing app and configuration."
  if [[ ! -d "$task_destination" ]]; then task_destination="$HOME/Applications/Sunshine.app"; fi
else
  task_temp="$(/usr/bin/mktemp -d /tmp/locallink-host.XXXXXX)"
  task_image="$task_temp/$task_asset"
  /usr/bin/curl --fail --location --retry 2 --proto '=https' \
    --output "$task_image" \
    "https://github.com/LizardByte/Sunshine/releases/download/v2026.914.233613/$task_asset"
  task_actual="$(/usr/bin/shasum -a 256 "$task_image" | /usr/bin/awk '{print $1}')"
  [[ "$task_actual" == "$task_sha" ]] || task_fail "Download checksum mismatch. Nothing was installed."
  task_volume="$task_temp/volume"
  /bin/mkdir -p "$task_volume"
  /usr/bin/hdiutil attach "$task_image" -readonly -nobrowse -mountpoint "$task_volume" -quiet
  [[ -d "$task_volume/Sunshine.app" ]] || task_fail "Sunshine.app was not found in the release image."
  /usr/bin/codesign --verify --deep --strict "$task_volume/Sunshine.app"
  if [[ ! -w /Applications ]]; then
    /bin/mkdir -p "$HOME/Applications"
    task_destination="$HOME/Applications/Sunshine.app"
  fi
  /usr/bin/ditto "$task_volume/Sunshine.app" "$task_destination"
  echo "Installed $task_destination"
fi

task_config="$HOME/.config/sunshine"
/bin/mkdir -p "$task_config"
if [[ ! -f "$task_config/sunshine.conf" ]]; then
  cat > "$task_config/sunshine.conf" <<'CONFIG'
# LocalLink: private streaming over Tailscale, no router port forwarding.
sunshine_name = Mac mini
upnp = disabled
# The admin dashboard is accessible only on the host (or through an SSH tunnel).
origin_web_ui_allowed = pc
CONFIG
  echo "Created an initial configuration. UPnP is disabled; the dashboard stays local."
else
  echo "Kept your existing Sunshine configuration. Review its network settings in the dashboard."
fi
if [[ ! -f "$task_config/apps.json" ]]; then
  cat > "$task_config/apps.json" <<'APPS'
{"env":{},"apps":[{"name":"Desktop","image-path":"desktop.png"}]}
APPS
fi

/usr/bin/open "$task_destination"
/usr/bin/open 'https://localhost:47990'
echo
echo "Finish on the Mac mini:"
echo "1. In Sunshine's dashboard, create a separate Sunshine admin login."
echo "2. In System Settings > Privacy & Security, allow Sunshine under:"
echo "   Screen & System Audio Recording, Accessibility, and any audio prompts it requests."
echo "3. Quit and reopen Sunshine after changing permissions."
echo "4. On the MacBook, open LocalLink, Check connection, then Pair this Mac."
echo "5. Enter the pairing PIN in Sunshine's PIN page, then click Open my Mac on the MacBook."
echo
echo "Keep the mini awake while streaming. Use Sunshine's login option or macOS Login Items"
echo "if you want it to start automatically when you sign in."
echo "If macOS blocks Sunshine, review the official download in Privacy & Security."
echo "This setup does not disable Gatekeeper, alter Apple permissions, or open router ports."
if [[ -t 0 ]]; then read -r -p "Press Return to close. " task_reply; fi
