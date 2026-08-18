#!/bin/bash
# Remove the custom EDID override, restoring the most recent backup if present.
# Usage: sudo ./uninstall.sh [--purge]
#   --purge  delete the override outright instead of restoring a backup
set -euo pipefail

VENDOR_ID=610
PRODUCT_ID=ae42
DEST="/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-$VENDOR_ID/DisplayProductID-$PRODUCT_ID"
BACKUP_DIR="$(cd "$(dirname "$0")" && pwd)/backups"

if [[ $EUID -ne 0 ]]; then
    echo "This must run as root. Try: sudo $0" >&2
    exit 1
fi

if [[ ! -f "$DEST" ]]; then
    echo "No override installed at $DEST - nothing to do."
    exit 0
fi

LATEST=""
if [[ -d "$BACKUP_DIR" ]]; then
    LATEST="$(ls -1t "$BACKUP_DIR"/DisplayProductID-$PRODUCT_ID.* 2>/dev/null | head -1 || true)"
fi

if [[ "${1:-}" != "--purge" && -n "$LATEST" ]]; then
    install -m 644 -o root -g wheel "$LATEST" "$DEST"
    echo "Restored $(basename "$LATEST") -> $DEST"
else
    rm -f "$DEST"
    rmdir "$(dirname "$DEST")" 2>/dev/null || true
    echo "Removed $DEST"
    echo "macOS will fall back to the display's built-in EDID."
fi

echo "Reboot to apply."
