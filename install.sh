#!/bin/bash
# Install the custom EDID override for the Studio Display XDR.
# Usage: sudo ./install.sh [path-to-override-plist]
set -euo pipefail

VENDOR_ID=610          # 0x0610, Apple
PRODUCT_ID=ae42        # 0xae42, Studio Display XDR
SRC="${1:-$(dirname "$0")/build/DisplayProductID-$PRODUCT_ID}"
DEST_DIR="/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-$VENDOR_ID"
DEST="$DEST_DIR/DisplayProductID-$PRODUCT_ID"
BACKUP_DIR="$(cd "$(dirname "$0")" && pwd)/backups"

if [[ $EUID -ne 0 ]]; then
    echo "This must run as root. Try: sudo $0" >&2
    exit 1
fi

if [[ ! -f "$SRC" ]]; then
    echo "Override not found: $SRC" >&2
    echo "Build it first:  python3 apple_edid.py build --mode 5120x2880@86:1341.16" >&2
    exit 1
fi

plutil -lint "$SRC" >/dev/null || { echo "Not a valid plist: $SRC" >&2; exit 1; }

# SwitchResX's daemon rewrites this file whenever it applies settings, which
# would clobber the override. Warn loudly rather than fighting it.
if launchctl list 2>/dev/null | grep -q switchresx; then
    echo "WARNING: SwitchResX is still running."
    echo "         Its daemon owns the same override file and will overwrite this one."
    echo "         Uninstall SwitchResX (its prefpane has an uninstaller) before relying"
    echo "         on this override, or the change may silently revert."
    echo
    read -r -p "Continue anyway? [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

mkdir -p "$BACKUP_DIR"
if [[ -f "$DEST" ]]; then
    STAMP="$(date +%Y%m%d-%H%M%S)"
    cp -p "$DEST" "$BACKUP_DIR/DisplayProductID-$PRODUCT_ID.$STAMP"
    echo "Backed up existing override -> backups/DisplayProductID-$PRODUCT_ID.$STAMP"
fi

mkdir -p "$DEST_DIR"
install -m 644 -o root -g wheel "$SRC" "$DEST"
echo "Installed $DEST"
echo
echo "Timings now advertised to macOS:"
python3 "$(dirname "$0")/apple_edid.py" dump <(python3 -c "
import plistlib,sys; sys.stdout.buffer.write(plistlib.load(open('$DEST','rb'))['IODisplayEDID'])
") 2>/dev/null | grep -E '^\s+5120x2880|^block 6' || true
echo
echo "Reboot for this to take effect (an EDID override is only read when the"
echo "display is enumerated). Then pick 86 Hz in System Settings > Displays."
echo "To revert:  sudo ./uninstall.sh"
