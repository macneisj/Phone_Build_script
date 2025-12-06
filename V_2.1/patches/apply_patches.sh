#!/bin/bash

# Exit on error
set -euo pipefail

echo $(pwd)
KERNEL_DIR="../linux"
PATCH_DIR="../patches"

echo "--- Keypad Integration Starting ---"
echo "Kernel Dir: $KERNEL_DIR"
echo "Patch Dir:  $PATCH_DIR"

if [ ! -d "$KERNEL_DIR" ] || [ ! -d "$PATCH_DIR" ]; then
    echo "Error: KERNEL_DIR or PATCH_DIR not found. Aborting integration."
    exit 1
fi

#
echo "1. Applying TOUCH_MOUSE_Boot-wtf-6.18.patch"
patch -d "$KERNEL_DIR" -p1 < "$PATCH_DIR/TOUCH_MOUSE_Boot-wtf-6.18.patch"
