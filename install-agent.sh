#!/bin/bash
# Install a per-user launch agent that keeps the virtual EDID in place.
#
# A virtual EDID is runtime state. It does not survive a reboot, and the panel
# also drops back to its real EDID on sleep/wake and hot-plug, so a run-once
# login item is not enough — the agent runs `avedid watch`, which stays resident
# and reinstalls it whenever it disappears. This is why SwitchResX ships a
# daemon rather than a login item.
#
# Usage: ./install-agent.sh [path-to-edid.bin] [refresh-hz]
set -euo pipefail

LABEL="local.avedid"
REPO="$(cd "$(dirname "$0")" && pwd)"
BIN="$REPO/build/avedid"
EDID="${1:-$REPO/build/patched.bin}"
HZ="${2:-86}"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [[ $EUID -eq 0 ]]; then
    echo "Do not run this with sudo. IOAVServiceSetVirtualEDIDMode works as your" >&2
    echo "own user, so this belongs in ~/Library/LaunchAgents, not a root daemon." >&2
    exit 1
fi

[[ -x "$BIN" ]] || { echo "Build it first:  swiftc -O -o build/avedid avedid.swift" >&2; exit 1; }

# Resolve to an absolute path — launchd has no working directory to speak of.
EDID="$(cd "$(dirname "$EDID")" && pwd)/$(basename "$EDID")"
[[ -f "$EDID" ]] || { echo "EDID not found: $EDID" >&2; exit 1; }

# Refuse to install an agent around an EDID the tool itself rejects.
"$BIN" apply "$EDID" --dry-run >/dev/null || {
    echo "Refusing to install: $EDID did not pass validation." >&2
    exit 1
}

mkdir -p "$HOME/Library/LaunchAgents"

# --delay gives the display time to finish enumerating after login; without it
# the AV service may not be there yet. --skip-if-modifiers is the escape hatch:
# because the agent is resident, holding Shift at login is the only way to stop
# it reapplying a timing that blacks out the display. KeepAlive restarts it if it
# ever dies, but SuccessfulExit=false means a modifier-held exit(0) stays exited.
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
        <string>watch</string>
        <string>$EDID</string>
        <string>--yes</string>
        <string>--skip-if-modifiers</string>
        <string>--restore-hz</string>
        <string>$HZ</string>
        <string>--delay</string>
        <string>5</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardOutPath</key>
    <string>/tmp/avedid.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/avedid.log</string>
</dict>
</plist>
PLIST_EOF

plutil -lint "$PLIST" >/dev/null

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST"

echo "Installed $PLIST"
echo "  binary: $BIN"
echo "  edid:   $EDID"
echo "  hz:     $HZ"
echo
echo "It is loaded now and stays resident, reinstalling the EDID after login,"
echo "sleep/wake and hot-plug, then reselecting ${HZ} Hz."
echo "Hold Shift or Option while logging in to skip it."
echo "Log:      tail -f /tmp/avedid.log"
echo "Remove:   ./uninstall-agent.sh"
