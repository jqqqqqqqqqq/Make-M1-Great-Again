#!/bin/bash
# Remove the login agent that reapplies the virtual EDID.
# The EDID currently in effect is left alone; use `avedid revert` for that.
set -euo pipefail

LABEL="local.avedid"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true

if [[ -f "$PLIST" ]]; then
    rm -f "$PLIST"
    echo "Removed $PLIST"
else
    echo "Nothing to remove at $PLIST"
fi

echo
echo "The virtual EDID currently loaded is untouched — it will be gone after the"
echo "next reboot anyway. To drop it now:  ./build/avedid revert"
