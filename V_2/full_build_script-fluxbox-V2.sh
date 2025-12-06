#!/bin/bash

set -e
set -o pipefail

# Define Root Directory
ROOT_SCRIPT_DIR=$(pwd)

# Variables
#export USERNAME="user"
# sm6115
#KERNEL_REPO="https://github.com/sm6115-mainline/linux.git"
#KERNEL_VERSION=""
# mainline
KERNEL_REPO="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git"
KERNEL_VERSION="v6.18-rc6"
KERNEL_IMAGE_PATH="$ROOT_SCRIPT_DIR/linux/arch/arm64/boot/Image.gz"
deviceinfo_rootfs_image_sector_size="4096"
CONFIG_FILE="MGL.config"
ROOTFS_DIR="pro1x-fluxbox-rootfs"
BOOT_IMAGE_NAME="$ROOT_SCRIPT_DIR/boot.img"
VBMETA_IMAGE_NAME="$ROOT_SCRIPT_DIR/vbmeta.img"
ROOTFS_IMAGE_NAME="$ROOT_SCRIPT_DIR/rootfs.img"
ARCH="arm64"
DEBIAN_MIRROR="http://deb.debian.org/debian/"
DEBIAN_RELEASE="trixie"

# Define a directory for custom-built tools and initramfs components
BUILD_TOOLS_DIR="build_tools"
INITRAMFS_BUILD_DIR="custom_initramfs_staging"
CUSTOM_INITRD_IMG="$ROOT_SCRIPT_DIR/custom_initrd.img"

# Patches directory
PATCH_DIR="$ROOT_SCRIPT_DIR/patches"
INTEGRATION_SCRIPT="$PATCH_DIR/apply_patches.sh"
#INTEGRATION_SCRIPT="$PATCH_DIR/apply_patches-sm6115.sh"

# Device Tree Binary Paths
DTB_SOURCE_FILE="$ROOT_SCRIPT_DIR/linux/arch/arm64/boot/dts/qcom/sm6115-fxtec-pro1x.dtb"
CONCATENATED_KERNEL_DTB="$ROOT_SCRIPT_DIR/.Image.gz-dtb"

# build the custom initramfs on the host

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
    chmod +x "$INITRAMFS_BUILD_DIR/init"

    echo "Creating initramfs archive..."
    cd custom_initramfs_staging
    find . -print0 | cpio --null -oa --owner 0:0 | gzip -9 > "$CUSTOM_INITRD_IMG"
    cd "$ROOT_SCRIPT_DIR"
    rm -rf custom_initramfs_staging
    echo "Custom initramfs complete."
}

# MAIN SCRIPT STARTS

# 1. Install necessary host packages
echo "Installing necessary host packages..."
#sudo apt update
#sudo apt install -y git debootstrap qemu-user-static crossbuild-essential-arm64 flex bison binfmt-support zstd e2fsprogs libssl-dev python3 python3-protobuf protobuf-compiler curl unzip util-linux wget busybox device-tree-compiler python3-pip

# 2. Build the Linux kernel

if [ ! -f "$KERNEL_IMAGE_PATH" ]; then
    if [ ! -d "linux" ]; then
        echo "Downloading Linux kernel source $KERNEL_VERSION..."
        git clone $KERNEL_REPO linux
    fi
    cd linux
    git checkout $KERNEL_VERSION
    echo "Preparing kernel config..."
    if [ -f "../$CONFIG_FILE" ]; then
        cp "../$CONFIG_FILE" ".config"
        echo "patching Kernel..."
        bash "$INTEGRATION_SCRIPT" "$ROOT_SCRIPT_DIR/linux" "$PATCH_DIR"
        echo "Updating old config for new kernel version..."
        make ARCH=$ARCH CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
    else
        echo "Error: Kernel config file '$CONFIG_FILE' not found. This is a critical error."
        exit 1
    fi
    echo "Manually configuring required kernel options..."
    LOCALVERSION=$(awk -F'=' '/^CONFIG_LOCALVERSION=/{print $2}' .config | tr -d '"')
    if [ -n "$LOCALVERSION" ]; then
        KERNEL_VERSION="${KERNEL_VERSION}${LOCALVERSION}"
    fi

    echo "Building the Linux kernel, modules, and DTBs..."
    make ARCH=$ARCH CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc)
    make ARCH=$ARCH CROSS_COMPILE=aarch64-linux-gnu- modules
    cd ..
else
    echo "Compiled kernel image found at $KERNEL_IMAGE_PATH. Skipping kernel build."
fi

# 3. Create and configure the root filesystem
if [ -d "$ROOTFS_DIR" ]; then
    echo "Root filesystem directory '$ROOTFS_DIR' already exists. Deleting it for a clean build."
    sudo umount -lR "$ROOTFS_DIR/dev" || true
    sudo umount -lR "$ROOTFS_DIR/sys" || true
    sudo umount -lR "$ROOTFS_DIR/proc" || true
    sudo umount -lR "$ROOTFS_DIR/run" || true
    sudo umount -lR "$ROOTFS_DIR/dev/pts" || true
    sudo rm -rf "$ROOTFS_DIR"
fi

echo "Creating base root filesystem with debootstrap --foreign..."
sudo debootstrap --arch=$ARCH --foreign --include=dbus,libpam-systemd "$DEBIAN_RELEASE" "$ROOTFS_DIR" "$DEBIAN_MIRROR"

echo "Installing kernel modules into the rootfs directory..."
sudo make -C linux ARCH=$ARCH CROSS_COMPILE=aarch64-linux-gnu- modules_install INSTALL_MOD_PATH="../$ROOTFS_DIR"

echo "Preparing chroot environment and running second-stage debootstrap..."
QEMU_BINARY=$(which qemu-aarch64-static)
if [ -z "$QEMU_BINARY" ]; then
    echo "Error: qemu-aarch64-static binary not found on host system."
    exit 1
fi
sudo cp "$QEMU_BINARY" "$ROOTFS_DIR/usr/bin/"
sudo chroot "$ROOTFS_DIR" /usr/bin/qemu-aarch64-static /bin/bash -c "/debootstrap/debootstrap --second-stage"

echo "Creating temporary script for chroot configuration..."
sudo cat <<EOT | sudo tee "$ROOTFS_DIR/chroot_setup.sh" > /dev/null
#!/bin/bash
set -e

# include contrib non-free and non-free-firmware
if [ -f /etc/apt/sources.list ]; then
  # add non-free & non-free-firmware if not present for the 'trixie' lines
  awk '
  /^deb / {
    if (\$0 ~ /non-free/ && \$0 ~ /non-free-firmware/) { print; next }
    if (\$0 ~ / main/ && \$0 !~ /non-free/) { sub(/ main/, " main contrib non-free non-free-firmware") }
  }
  { print }
  ' /etc/apt/sources.list > /etc/apt/sources.list.new && mv /etc/apt/sources.list.new /etc/apt/sources.list || true
fi

# Run apt update before installing packages
apt update

echo "Installing Core System, Fluxbox, and Utilities..."
DEBIAN_FRONTEND=noninteractive apt install -y \
    apt-transport-https \
    locales \
    sudo \
    keyboard-configuration \
    console-setup \
    upower \
    systemd \
    vim \
    onboard \
    mc \
    pcmanfm \
    lightdm \
    lightdm-gtk-greeter \
    fluxbox \
    xinit \
    xserver-xorg-core \
    xserver-xorg-input-libinput \
    xterm \
    qutebrowser \
    nitrogen \
    mpv \
    nm-tray \
    gnome-calls \
    libqmi-glib5 \
    modemmanager \
    modem-manager-gui \
    libdrm-tegra0 # For display/GPU

echo "Installing Multimedia and Networking..."
DEBIAN_FRONTEND=noninteractive apt install -y \
    network-manager \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad \
    gstreamer1.0-plugins-ugly \
    gstreamer1.0-libav

echo "Installing Application Management..."
DEBIAN_FRONTEND=noninteractive apt install -y \
    flatpak \
    gnome-software \
    gnome-software-plugin-flatpak

##########
# install firmware packages from non-free
DEBIAN_FRONTEND=noninteractive apt update
apt install -y firmware-qcom-soc firmware-linux || true
# fallback older package - add qcom-phone-utils
apt install -y qcom-phone-utils firmware-iwlwifi || true
#########

echo "ENABLE VIRTUAL KEYBOARD IN LIGHTDM GREETER"
mkdir -p /etc/lightdm/lightdm-gtk-greeter.conf.d/
cat <<'GREETER_CONF' > /etc/lightdm/lightdm-gtk-greeter.conf.d/90-onboard.conf
[greeter]
keyboard=onboard
GREETER_CONF

apt clean

echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen

echo 'pro1x-fluxbox' > /etc/hostname

echo "Creating user and resize service..."
useradd -m -s /bin/bash user
echo 'user:1234' | chpasswd
usermod -aG sudo,adm,cdrom,floppy,audio,video,plugdev,netdev,staff,users,games,input user
mkdir -p /usr/local/bin

# create resize-rootfs service (your existing service)
cat <<'RESIZE_SCRIPT' > /etc/systemd/system/resize-rootfs.service
[Unit]
Description=Resize rootfs partition
After=local-fs.target
DefaultDependencies=no
[Service]
Type=oneshot
ExecStart=/usr/local/bin/resize-rootfs.sh
[Install]
WantedBy=multi-user.target
RESIZE_SCRIPT

cat <<'RESIZE_SH' > /usr/local/bin/resize-rootfs.sh
#!/bin/bash
if [ -f /etc/resize-done ]; then
    exit 0
fi
resize2fs /dev/disk/by-partlabel/userdata || true
touch /etc/resize-done
RESIZE_SH
chmod +x /usr/local/bin/resize-rootfs.sh
systemctl enable resize-rootfs.service

# Fluxbox specific setup
echo "Creating Fluxbox configuration and autostart file for 'user'..."
mkdir -p /home/user/.fluxbox
chown -R user:user /home/user/.fluxbox

# Create the custom menu file (right-click desktop to access)
cat <<'FLUXBOX_MENU' > /home/user/.fluxbox/menu
[begin] (Pro 1X Test Menu)
    [exec] (Onboard) {onboard}
    [exec] (SCREEN) {xrandr --output DSI-1 --scale 2x2}
    [exec] (SCREEN) {xrandr --output DSI-0 --scale 2x2}
    [exec] (Terminal) {gnome-terminal}
    [exec] (File Manager) {portfolio-filemanager}
    [exec] (Web Browser) {epiphany-browser}
    [exec] (Wallpaper) {Nitrogen}
    [separator]
    [exec] (Media Player) {mpv}
    [exec] (Image Viewer) {eog}
    [separator]
    [exec] (Calls App) {calls}
    [exec] (Chat App) {chatty}
    [exec] (Settings) {gnome-tweaks}
    [exec] (Software) {gnome-software}
    [separator]
    [submenu] (System) {}
        [exec] (Reboot) {sudo reboot}
        [exec] (Shutdown) {sudo shutdown now}
    [end]
    [separator]
    [exit] (Exit Fluxbox)
[end]
FLUXBOX_MENU
chown user:user /home/user/.fluxbox/menu

# End Fluxbox specific setup

echo "Chroot setup complete."
EOT

# Chroot Section
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
sudo chroot "$ROOTFS_DIR" /usr/bin/qemu-aarch64-static /bin/bash /chroot_setup.sh

echo "Unmounting essential filesystems..."
sudo umount -lR "$ROOTFS_DIR/dev" || true
sudo umount -lR "$ROOTFS_DIR/sys" || true
sudo umount -lR "$ROOTFS_DIR/proc" || true
sudo umount -lR "$ROOTFS_DIR/run" || true

echo "Cleaning up temporary files on the host."
sudo rm "$ROOTFS_DIR/chroot_setup.sh"
sudo rm "$ROOTFS_DIR/usr/bin/qemu-aarch64-static"
sudo rm "$ROOTFS_DIR/etc/resolv.conf"

# End Chroot

# AUTO Login
# Create autologin override for tty1 and autostart to Fluxbox

sudo mkdir -p $ROOTFS_DIR/etc/systemd/system/getty@tty1.service.d
cat <<'EOF' | sudo tee $ROOTFS_DIR/etc/systemd/system/getty@tty1.service.d/override.conf >/dev/null
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin user --noclear %I $TERM
EOF

# create .bash_profile and .xinitrc in rootfs (so autologin starts X)
sudo mkdir -p $ROOTFS_DIR/home/user
cat <<'EOF' | sudo tee $ROOTFS_DIR/home/user/.bash_profile >/dev/null
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    startx
fi
EOF

# Guess
cat <<'EOF' | sudo tee $ROOTFS_DIR/home/user/.xinitrc >/dev/null
#!/bin/bash
xterm onboard &
xrandr --output DSI-1 --scale .5x.5 &
xrandr --output DSI-0 --scale .5x.5 &
exec startfluxbox
EOF

# Does the display-manager conflict?
sudo rm -f $ROOTFS_DIR/etc/systemd/system/display-manager.service

echo "Auto-login setup complete."
# End Auto Login

# Start xterm and onboard
sudo mkdir -p $ROOTFS_DIR/home/user/.fluxbox
cat <<'FLUXBOX_STARTUP' | sudo tee  $ROOTFS_DIR/home/user/.fluxbox/startup >/dev/null
xterm &
onboard &
exec fluxbox
FLUXBOX_STARTUP

# Copy skel
sudo cp -r $ROOTFS_DIR/etc/skel/. $ROOTFS_DIR/home/user/ || true

# Set Permissions
sudo chown 1000:1000 $ROOTFS_DIR/home/user/.fluxbox/startup
sudo chmod 755 $ROOTFS_DIR/home/user/.fluxbox
#sudo chmod +x $ROOTFS_DIR/home/user/.fluxbox/startup
sudo chown 1000:1000 $ROOTFS_DIR/home/user/.xinitrc
chmod 600 $ROOTFS_DIR/home/user/.xinitrc
#sudo chmod +x $ROOTFS_DIR/home/user/.xinitrc
sudo chown -R 1000:1000 $ROOTFS_DIR/home/user
sudo mkdir -p $ROOTFS_DIR/home/user/.local/share/xorg
sudo touch $ROOTFS_DIR/home/user/.Xauthority
sudo chown -R 1000:1000 $ROOTFS_DIR/home/user
sudo chmod 700 $ROOTFS_DIR/home/user
sudo chmod 755 $ROOTFS_DIR/home/user/.local
sudo chmod 600 $ROOTFS_DIR/home/user/.Xauthority

# Create resize-rootfs symlink
sudo mkdir -p "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants"
if [ -f "$ROOTFS_DIR/etc/systemd/system/resize-rootfs.service" ]; then
  # create a relative symlink so systemd on device will see it enabled
  sudo ln -sf ../resize-rootfs.service "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants/resize-rootfs.service"
fi

#######################################################################################
# 3.a Install Proprietary Firmware Blobs
#echo "Downloading and installing proprietary firmware blobs..."
#FIRMWARE_COMMIT="6c1ef5bce85750688f789bc6e232ca8237b24713"
#FIRMWARE_REPO="https://github.com/sm6115-mainline/firmware-fxtec-qx1050"
#FIRMWARE_TAR="$FIRMWARE_REPO/archive/$FIRMWARE_COMMIT.tar.gz"
#FIRMWARE_DIR="firmware-fxtec-qx1050-$FIRMWARE_COMMIT"
#
#if [ ! -f "$FIRMWARE_DIR.tar.gz" ]; then
#    wget -q --show-progress "$FIRMWARE_TAR" -O "$FIRMWARE_DIR.tar.gz"
#fi
#
#echo "Extracting firmware..."
#tar -xzf "$FIRMWARE_DIR.tar.gz"
#
#FIRMWARE_SOURCE_PATH="$FIRMWARE_DIR/lib/firmware/qcom/sm6115/Fxtec/QX1050"
#FIRMWARE_TARGET_PATH="$ROOTFS_DIR/lib/firmware/qcom/sm6115/Fxtec/QX1050"
#
#echo "Copying firmware into $FIRMWARE_TARGET_PATH..."
#sudo mkdir -p "$FIRMWARE_TARGET_PATH"
#sudo cp -a "$FIRMWARE_SOURCE_PATH/." "$FIRMWARE_TARGET_PATH"
#
#rm -rf "$FIRMWARE_DIR" "$FIRMWARE_DIR.tar.gz"
########################################################################################
#
# 3.b Fix for Missing A630 GPU Firmware
#echo "Surgically adding missing a630_sqe.fw to /lib/firmware/qcom/..."
#
#QCOM_FW_TARGET_PATH="$ROOTFS_DIR/lib/firmware/qcom"
#TEMP_DIR="/tmp/QX1050"
#sudo mkdir -p $ROOTFS_DIR/lib/firmware/qcom
#
# 1. Clone the repository to a temporary directory
#echo "Cloning the zstas/fxtec-pro1x-firmware repository..."
#rm -rf "$TEMP_DIR" # Clean up any previous attempts
#git clone --depth 1 https://github.com/zstas/fxtec-pro1x-firmware.git "$TEMP_DIR"
#
# 2. Use sudo to copy the specific missing file from the clone into the rootfs target
# CORRECTION: The file is likely in the root of the clone, not /qcom/
#echo "Copying a630_sqe.fw into $QCOM_FW_TARGET_PATH with elevated permissions..."
#sudo mv "$TEMP_DIR/a630_sqe.fw" "$QCOM_FW_TARGET_PATH/"
#sudo mkdir -p $ROOTFS_DIR/lib/firmware/qcom/sm6115/Fxtec/QX1050/
#sudo cp -fr "$TEMP_DIR" $ROOTFS_DIR/lib/firmware/qcom/sm6115/Fxtec/
########################################################################################
#
# 3. Clean up
#echo "Cleaning up temporary clone..."
#rm -rf "$TEMP_DIR"
#
# Verification
#echo "--- Verification of a630_sqe.fw ---"
#ls -l "$QCOM_FW_TARGET_PATH/a630_sqe.fw"
#

# Firmware moved to dts location for fxtec pro1x - correct debian non-free-firmware
sudo mkdir -p $ROOTFS_DIR/lib/firmware/qcom/sm6115/Fxtec/QX1050/
sudo mv $ROOTFS_DIR/lib/firmware/qcom/qrb4210/a610_zap.mbn \
    $ROOTFS_DIR/lib/firmware/qcom/sm6115/Fxtec/QX1050/ || true

# Fix systemd-logind and resize-rootfs startup timing
echo "--- Replacing systemd logind/resize-rootfs timing rules ---"
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

# 4. Build mkbootimg from source
echo "Building mkbootimg from source..."
mkdir -p "$BUILD_TOOLS_DIR"
if [ ! -f "$BUILD_TOOLS_DIR/mkbootimg" ]; then
    git clone https://github.com/osm0sis/mkbootimg.git "$BUILD_TOOLS_DIR/mkbootimg_src"
    cd "$BUILD_TOOLS_DIR/mkbootimg_src"
    sed -i 's/-Werror//g' libmincrypt/Makefile
    make
    cp mkbootimg "../mkbootimg"
    cp unpackbootimg "../unpackbootimg"
    cd "$ROOT_SCRIPT_DIR"
fi
if [ ! -f "$BUILD_TOOLS_DIR/mkbootimg" ]; then
    echo "Error: mkbootimg executable not found."
    exit 1
fi

# 5. Build avbtool from source
echo "Building avbtool from source..."
mkdir -p "$BUILD_TOOLS_DIR"
if [ ! -f "$BUILD_TOOLS_DIR/avbtool.py" ]; then
    git clone https://android.googlesource.com/platform/external/avb "$BUILD_TOOLS_DIR/avbtool_src"
    chmod +x "$BUILD_TOOLS_DIR/avbtool_src/avbtool.py"
    cp "$BUILD_TOOLS_DIR/avbtool_src/avbtool.py" "$BUILD_TOOLS_DIR/"
    cd "$ROOT_SCRIPT_DIR"
fi

# 6. Create the rootfs image on the host
echo "Creating rootfs image..."
SIZE_MB=$(sudo du -sh --block-size=1M "$ROOTFS_DIR" | cut -f1 | sed 's/M//')
SIZE=$((SIZE_MB * 2))

# absolute path $ROOTFS_IMAGE_NAME
truncate -s ${SIZE}M "$ROOTFS_IMAGE_NAME"

mkfs.ext4 -L rootfs -b "$deviceinfo_rootfs_image_sector_size" "$ROOTFS_IMAGE_NAME"

sudo mkdir -p /mnt
sudo mount -o loop "$ROOTFS_IMAGE_NAME" /mnt
sudo cp -a "$ROOTFS_DIR/"* /mnt/
sudo umount /mnt

# 7. Create custom initramfs
build_custom_initramfs

# 8. Create the boot image on the host
echo "Step 8: Creating boot image with Header V0 (DTB concatenated)"

# INITRAMFS_PATH is CUSTOM_INITRD_IMG
INITRAMFS_PATH="$CUSTOM_INITRD_IMG"
if [ ! -f "$INITRAMFS_PATH" ] || [ ! -s "$INITRAMFS_PATH" ]; then
    echo "Error: Custom initramfs not found or is empty. Aborting."
    exit 1
fi

# 8a. Concatenate Kernel and DTB
echo "Concatenating kernel Image.gz and DTB into $CONCATENATED_KERNEL_DTB..."
# KERNEL_IMAGE_PATH and DTB_SOURCE_FILE are absolute paths.
if [ ! -f "$DTB_SOURCE_FILE" ]; then
    echo "Error: DTB file not found at $DTB_SOURCE_FILE. Did the kernel build complete successfully?"
    exit 1
fi
cat "$KERNEL_IMAGE_PATH" "$DTB_SOURCE_FILE" > "$CONCATENATED_KERNEL_DTB"

# 8b. Define Header V0 parameters
BASE_OFFSET="0x00000000"
KERNEL_OFFSET="0x00008000"
RAMDISK_OFFSET="0x01000000"
PAGESIZE="4096"
TAGS_OFFSET="0x00000100"
# DTB is loaded as the 'second' image in Header V0
SECOND_OFFSET="0x00f00000"


# fixed to use device path /dev/sda13 and rootwait
#CMDLINE="root=/dev/sda13 earlycon=msm_geni_serial,0x4a90000 console=ttyMSM0,115200n8 console=tty0 loglevel=7"
CMDLINE="root=/dev/sda13 rootwait rw earlycon=msm_geni_serial,0x4a90000 console=ttyMSM0,115200n8 console=tty0 loglevel=7"


echo "Executing mkbootimg with Header V0 parameters:"
"$BUILD_TOOLS_DIR/mkbootimg" \
    --kernel "$CONCATENATED_KERNEL_DTB" \
    --ramdisk "$INITRAMFS_PATH" \
    --pagesize "$PAGESIZE" \
    --base "$BASE_OFFSET" \
    --kernel_offset "$KERNEL_OFFSET" \
    --ramdisk_offset "$RAMDISK_OFFSET" \
    --second_offset "$SECOND_OFFSET" \
    --tags_offset "$TAGS_OFFSET" \
    --cmdline "$CMDLINE" \
    --output "$BOOT_IMAGE_NAME"

# 9. Create vbmeta.img -- only to remove (could delete)
echo "Creating simplified vbmeta placeholder image..."

# VBMETA_IMAGE_NAME
python3 "$BUILD_TOOLS_DIR/avbtool.py" make_vbmeta_image \
    --output "$VBMETA_IMAGE_NAME" \
    --padding 4096 \
    --flags 2

if [ ! -s "$VBMETA_IMAGE_NAME" ]; then
    echo "Error: The vbmeta.img file was not created or is empty."
    exit 1
fi

echo "Build complete. Files created: $BOOT_IMAGE_NAME, $ROOTFS_IMAGE_NAME, and $VBMETA_IMAGE_NAME"

# Final Flashing Instructions
echo
echo "FLASHING STEPS"
echo "1. Reboot your device into the **Bootloader** (Fastboot) mode."
echo "2. Run the following commands on your host PC:"
echo "fastboot erase dtbo"
echo "fastboot flash boot $BOOT_IMAGE_NAME"
echo "fastboot flash userdata $ROOTFS_IMAGE_NAME"
echo "fastboot flash vbmeta $VBMETA_IMAGE_NAME"
echo "fastboot reboot"
echo
echo "or use ./flash.sh"
echo "END FLASHING"
