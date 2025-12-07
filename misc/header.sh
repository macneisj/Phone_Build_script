#!/bin/bash
#
set -e

PMOS_BOOT_IMAGE="boot.img"

OUTPUT_DIR="pmos_extracted_test_files"
HEADER_FILE="$OUTPUT_DIR/$PMOS_BOOT_IMAGE.img_hdr"
BUILD_TOOLS_DIR="../build_tools" # Assuming unpackbootimg is here

if [ ! -f "$PMOS_BOOT_IMAGE" ]; then
    echo "ERROR: PMOS_BOOT_IMAGE not found at $PMOS_BOOT_IMAGE."
    echo "Please ensure the file is in the same directory, or update the path."
    exit 1
fi

echo "1. Preparing extraction directory..."
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

echo "2. Unpacking the working PMOS boot image ($PMOS_BOOT_IMAGE)..."

$BUILD_TOOLS_DIR/unpackbootimg --output "$OUTPUT_DIR" -i "$PMOS_BOOT_IMAGE"

if [ -f "$HEADER_FILE" ]; then
    echo "*****************************************************"
    cat "$HEADER_FILE"
    echo "*****************************************************"
else
    echo "WARNING: Could not find standard header file. Please review the output above for parameters."
fi
