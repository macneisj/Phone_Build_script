#!/bin/bash
# Flashing Instructions

# 1. Create a zeroed 4KB file. This is the fix to satisfy the ABL's DTBO check.
#dd if=/dev/zero of=zero.bin bs=4096 count=1

# 2. Flash dtbo
echo "Flashing erase/zeroed file to DTBO slots..."
# fastboot flash dtbo_a zero.bin
# fastboot flash dtbo_b zero.bin
fastboot erase dtbo

# 3. Flash V0 boot image (which contains the DTB inside) to BOTH boot slots
echo "Flashing V0 boot.img to both A/B slots..."
fastboot flash boot_a boot.img
fastboot flash boot_b boot.img

# 4. Flash the rootfs
echo "Flashing rootfs..."
fastboot flash userdata rootfs.img

# 6. Flash the vbmeta to both vbmeta slots
echo "Flashing vbmeta to both A/B slots..."
fastboot flash vbmeta_a vbmeta.img
fastboot flash vbmeta_b vbmeta.img
#fastboot erase vbmeta

# 7. Reboot the device to test the new system
echo "Rebooting device... Please WAIT!"
fastboot reboot
