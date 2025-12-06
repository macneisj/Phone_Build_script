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

# Adjust these to the paths where you saved the driver sources
SRC_AW_DIR="$PATCH_DIR/aw9523"
SRC_GT_DIR="$PATCH_DIR/gt1x_v1_6_revised"

echo "1. Applying display-regression-6.18-all-dts.patch"
patch -d "$KERNEL_DIR" -p1 < "$PATCH_DIR/display-regression-6.18-all-dts.patch"

echo "3. Applying display-fixes-v618-v2.patch"
patch -d "$KERNEL_DIR" -p1 < "$PATCH_DIR/display-regression-6.18-all-dtsi.patch"

#mkdir -p $KERNEL_DIR/drivers/input/touchscreen/goodix_gt1x
#cp $PATCH_DIR/gt1x_v1_6_revised/gt1x*.c $KERNEL_DIR/drivers/input/touchscreen/goodix_gt1x/
#cp $PATCH_DIR/gt1x_v1_6_revised/gt1x_generic.h $KERNEL_DIR/drivers/input/touchscreen/goodix_gt1x/
# 1. Copy the new C driver source file
#mkdir -p $KERNEL_DIR/drivers/input/touchscreen/goodix
#cp $PATCH_DIR/gt1x_v1_6_revised/gt1x*.c $KERNEL_DIR/drivers/input/touchscreen/goodix/
#cp $PATCH_DIR/gt1x_v1_6_revised/gt1x_generic.h $KERNEL_DIR/drivers/input/touchscreen/goodix/

#cat $PATCH_DIR/sm6115-regression.dtsi >  $KERNEL_DIR/arch/arm64/boot/dts/qcom/sm6115.dtsi
#cat $PATCH_DIR/sm6115-fxtec-pro1x-regression.dts >  $KERNEL_DIR/arch/arm64/boot/dts/qcom/sm6115-fxtec-#pro1x.dts

# Keyboard (AW9523B)
#DEST_AW="$KERNEL_DIR/drivers/input/keyboard/aw9523b_pro1x"
#if [ -d "$SRC_AW_DIR" ]; then
#  mkdir -p "$DEST_AW"
#  echo "Copying AW9523B sources from $SRC_AW_DIR -> $DEST_AW"
#  cp -v "$SRC_AW_DIR"/* "$DEST_AW/" || true
#else
#  echo "Warning: source AW9523 dir not found: $SRC_AW_DIR"
#fi

# Touchscreen (Goodix GT1x)
#DEST_GT="$KERNEL_DIR/drivers/input/touchscreen/goodix"
#if [ -d "$SRC_GT_DIR" ]; then
#  mkdir -p "$DEST_GT"
#  echo "Copying GT1x sources from $SRC_GT_DIR -> $DEST_GT"
#  cp -v "$SRC_GT_DIR"/* "$DEST_GT/" || true
#else
#  echo "Warning: source GT1x dir not found: $SRC_GT_DIR"
#fi

#echo "Done. Please review $DEST_AW to confirm files present."
#drivers/input/keyboard/aw9523b_pro1x/aw9523b.c
#drivers/input/touchscreen/goodix/gt1x.c
