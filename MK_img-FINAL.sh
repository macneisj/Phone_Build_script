#!/bin/bash

# make dts
# make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- dtbs -j$(nproc)


set -e
set -o pipefail

ROOT_SCRIPT_DIR=$(pwd)
KERNEL_IMAGE_PATH="$ROOT_SCRIPT_DIR/linux/arch/arm64/boot/Image.gz"
DTB_SOURCE_FILE="$ROOT_SCRIPT_DIR/linux/arch/arm64/boot/dts/qcom/sm6115-fxtec-pro1x.dtb"
CONCATENATED_KERNEL_DTB="$ROOT_SCRIPT_DIR/.Image.gz-dtb"
ROOTFS_DIR="pro1x-fluxbox-rootfs"
BOOT_IMAGE_NAME="$ROOT_SCRIPT_DIR/boot.img"
ROOTFS_IMAGE_NAME="$ROOT_SCRIPT_DIR/rootfs.img"
VBMETA_IMAGE_NAME="$ROOT_SCRIPT_DIR/vbmeta.img"
BUILD_TOOLS_DIR="build_tools"
ARCH="arm64"
deviceinfo_rootfs_image_sector_size="4096"
CUSTOM_INITRD_IMG="$ROOT_SCRIPT_DIR/custom_initrd.img"

#echo "Unmounting essential filesystems (robust PTY teardown)..."
#sudo umount -lR "$ROOTFS_DIR/dev" || true
#sudo umount -lR "$ROOTFS_DIR/sys" || true
#sudo umount -lR "$ROOTFS_DIR/proc" || true
#sudo umount -lR "$ROOTFS_DIR/run" || true

build_custom_initramfs() {
    echo "--- Building custom BusyBox-based initramfs ---"
    rm -rf custom_initramfs_staging
    mkdir -p custom_initramfs_staging/{bin,dev,proc,sys,mnt,newroot}
    cp /bin/busybox custom_initramfs_staging/bin/busybox
    cd custom_initramfs_staging/bin
    for tool in sh mount mkdir switch_root; do ln -sf busybox "$tool"; done
    cd "$ROOT_SCRIPT_DIR"

    cat <<'INIT_SCRIPT' > custom_initramfs_staging/init
#!/bin/sh
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
echo "Starting minimal initramfs (BusyBox)..."

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mkdir -p /dev/pts
mount -t devpts devpts /dev/pts

echo "Waiting for root partition: /dev/disk/by-partlabel/userdata"
ROOT_DEVICE="/dev/disk/by-partlabel/userdata"
TRIES=30
while [ $TRIES -gt 0 ]; do
    if [ -b "$ROOT_DEVICE" ]; then
        echo "Root device found on try $((31 - TRIES))!"
        sleep 2
        break
    fi
    sleep 0.5
    TRIES=$((TRIES - 1))
done

if [ ! -b "$ROOT_DEVICE" ]; then
    echo "Root device not found. Dropping to shell."
    ls -l /dev/disk/by-partlabel/
    /bin/sh
fi

mkdir /newroot
if ! mount -o rw,noatime,errors=remount-ro "$ROOT_DEVICE" /newroot; then
    echo "Failed to mount rootfs. Dropping to shell."
    /bin/sh
fi

echo "Switching root..."
cd /newroot
umount -l /sys || true
umount -l /proc || true
umount -l /dev/pts || true
exec /bin/switch_root /newroot /sbin/init
INIT_SCRIPT
    chmod +x custom_initramfs_staging/init

    echo "Creating initramfs archive..."
    cd custom_initramfs_staging
    find . -print0 | cpio --null -oa --owner 0:0 | gzip -9 > "$CUSTOM_INITRD_IMG"
    cd "$ROOT_SCRIPT_DIR"
    rm -rf custom_initramfs_staging
    echo "Custom initramfs complete."
}

# Start xterm and onboard
sudo mkdir -p $ROOTFS_DIR/home/user/.fluxbox
cat <<'FLUXBOX_STARTUP' | sudo tee  $ROOTFS_DIR/home/user/.fluxbox/startup >/dev/null
xterm -e onboard &
xrandr --output DSI-1 --scale .5x.5 &
xrandr --output DSI-0 --scale .5x.5 &
exec fluxbox
FLUXBOX_STARTUP

# Set Permissions
sudo chown 1000:1000 $ROOTFS_DIR/home/user/.fluxbox/startup
sudo chmod 755 $ROOTFS_DIR/home/user/.fluxbox
sudo chmod +x $ROOTFS_DIR/home/user/.fluxbox/startup

# Fix systemd-logind and resize-rootfs startup timing
echo "systemd logind/resize-rootfs timing rules"
sudo mkdir -p $ROOTFS_DIR/etc/systemd/system/systemd-logind.service.d/
sudo mkdir -p $ROOTFS_DIR/etc/systemd/system/resize-rootfs.service.d/

cat <<'EOF' | sudo tee $ROOTFS_DIR/etc/systemd/system/systemd-logind.service.d/fix.conf >/dev/null
[Unit]
After=local-fs.target default.target
Requires=local-fs.target
[Service]
ExecStartPre=/bin/bash -c 'for i in $(seq 1 10); do mount | grep "on / type" | grep -q rw && exit 0; sleep 1; done; exit 0'
EOF

cat <<'EOF' | sudo tee $ROOTFS_DIR/etc/systemd/system/resize-rootfs.service.d/fix.conf >/dev/null
[Unit]
After=multi-user.target local-fs.target
Requires=local-fs.target
[Service]
ExecStartPre=/bin/bash -c 'for i in $(seq 1 15); do [ -b /dev/disk/by-partlabel/userdata ] && exit 0; sleep 1; done; exit 0'
EOF

# Chroot Section add remove to test

sudo cp "/usr/bin/qemu-aarch64-static" "$ROOTFS_DIR/usr/bin/"
sudo cp "/etc/resolv.conf" "$ROOTFS_DIR/etc/"

echo "Mounting essential filesystems for chroot..."
sudo mkdir -p "$ROOTFS_DIR/dev/pts"
sudo mount --rbind /dev "$ROOTFS_DIR/dev"
sudo mount --rbind /sys "$ROOTFS_DIR/sys"
sudo mount --rbind /proc "$ROOTFS_DIR/proc"
sudo mount --rbind /run "$ROOTFS_DIR/run"
sudo mount --make-slave "$ROOTFS_DIR/dev"
sudo mount --make-slave "$ROOTFS_DIR/sys"
sudo mount --make-slave "$ROOTFS_DIR/proc"
sudo mount --make-slave "$ROOTFS_DIR/run"
sudo mount -t devpts devpts "$ROOTFS_DIR/dev/pts" -o newinstance,ptmxmode=0666,mode=0620,gid=5

echo "nameserver 8.8.8.8" | sudo tee "$ROOTFS_DIR/etc/resolv.conf"

echo "Entering chroot to configure the rootfs..."
sudo chroot "$ROOTFS_DIR" apt install -y firmware-iwlwifi firmware-qcom-soc firmware-linux qcom-phone-utils

echo "Unmounting essential filesystems..."
sudo umount -lR "$ROOTFS_DIR/dev" || true
sudo umount -lR "$ROOTFS_DIR/sys" || true
sudo umount -lR "$ROOTFS_DIR/proc" || true
sudo umount -lR "$ROOTFS_DIR/run" || true

echo "Cleaning up temporary files on the host."
sudo rm "$ROOTFS_DIR/usr/bin/qemu-aarch64-static"
sudo rm "$ROOTFS_DIR/etc/resolv.conf"

# End Chroot

# Firmware moved to dts location for fxtec pro1x - correct debian non-free-firmware
sudo mkdir -p $ROOTFS_DIR/lib/firmware/qcom/sm6115/Fxtec/QX1050/
sudo mv $ROOTFS_DIR/lib/firmware/qcom/qrb4210/a610_zap.mbn \
    $ROOTFS_DIR/lib/firmware/qcom/sm6115/Fxtec/QX1050/ || true

echo "Building mkbootimg..."
mkdir -p "$BUILD_TOOLS_DIR"
if [ ! -f "$BUILD_TOOLS_DIR/mkbootimg" ]; then
    git clone https://github.com/osm0sis/mkbootimg.git "$BUILD_TOOLS_DIR/mkbootimg_src"
    cd "$BUILD_TOOLS_DIR/mkbootimg_src"
    sed -i 's/-Werror//g' libmincrypt/Makefile
    make
    cp mkbootimg ../mkbootimg
    cp unpackbootimg ../unpackbootimg
    cd "$ROOT_SCRIPT_DIR"
fi

echo "Building avbtool..."
mkdir -p "$BUILD_TOOLS_DIR"
if [ ! -f "$BUILD_TOOLS_DIR/avbtool.py" ]; then
    git clone https://android.googlesource.com/platform/external/avb "$BUILD_TOOLS_DIR/avbtool_src"
    chmod +x "$BUILD_TOOLS_DIR/avbtool_src/avbtool.py"
    cp "$BUILD_TOOLS_DIR/avbtool_src/avbtool.py" "$BUILD_TOOLS_DIR/"
fi

echo "Creating rootfs image..."
SIZE_MB=$(sudo du -sh --block-size=1M "$ROOTFS_DIR" | cut -f1 | sed 's/M//')
SIZE=$((SIZE_MB * 2))
truncate -s ${SIZE}M "$ROOTFS_IMAGE_NAME"
mkfs.ext4 -L rootfs -b "$deviceinfo_rootfs_image_sector_size" "$ROOTFS_IMAGE_NAME"

sudo mkdir -p /mnt
sudo mount -o loop "$ROOTFS_IMAGE_NAME" /mnt
sudo cp -a "$ROOTFS_DIR/"* /mnt/
sudo umount /mnt

build_custom_initramfs

echo "Creating boot image"
cat "$KERNEL_IMAGE_PATH" "$DTB_SOURCE_FILE" > "$CONCATENATED_KERNEL_DTB"

BASE_OFFSET="0x00000000"
KERNEL_OFFSET="0x00008000"
RAMDISK_OFFSET="0x01000000"
PAGESIZE="4096"
TAGS_OFFSET="0x00000100"
SECOND_OFFSET="0x00f00000"

# tried modprobe.blacklist=msm_drm text nomodeset systemd.unit=multi-user.target
#CMDLINE="root=/dev/sda13 rootwait rw earlycon=msm_geni_serial,0x4a90000 console=ttyMSM0,115200n8 console=tty0 loglevel=7"
#CMDLINE="root=/dev/sda13 rootwait rw root=/dev/sda13 rootwait rw earlycon=msm_geni_serial,0x4a90000 console=ttyMSM0,115200n8 console=tty0 loglevel=7 systemd.unit=multi-user.target"
CMDLINE="root=/dev/sda13 rootwait rw earlycon=msm_geni_serial,0x4a90000 console=ttyMSM0,115200n8 console=tty0 loglevel=7"

"$BUILD_TOOLS_DIR/mkbootimg" \
    --kernel "$CONCATENATED_KERNEL_DTB" \
    --ramdisk "$CUSTOM_INITRD_IMG" \
    --pagesize "$PAGESIZE" \
    --base "$BASE_OFFSET" \
    --kernel_offset "$KERNEL_OFFSET" \
    --ramdisk_offset "$RAMDISK_OFFSET" \
    --second_offset "$SECOND_OFFSET" \
    --tags_offset "$TAGS_OFFSET" \
    --cmdline "$CMDLINE" \
    --output "$BOOT_IMAGE_NAME"

echo "Creating vbmeta image..."
python3 "$BUILD_TOOLS_DIR/avbtool.py" make_vbmeta_image \
    --output "$VBMETA_IMAGE_NAME" \
    --padding 4096 \
    --flags 2

echo
echo "fastboot erase dtbo"
echo "fastboot flash boot $BOOT_IMAGE_NAME"
echo "fastboot flash userdata $ROOTFS_IMAGE_NAME"
echo "fastboot flash vbmeta $VBMETA_IMAGE_NAME"
echo "fastboot reboot"
echo
