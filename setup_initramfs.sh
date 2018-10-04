#!/bin/bash
#
###############################################
# Script for setting up encrypted raspbian    #
# Based on this guide:                        #
# https://robpol86.com/raspberry_pi_luks.html #
###############################################
# shellcheck disable=SC1117


usage() {
    echo "$(basename "$0"):"
    echo "Encrypt raspbian root."
    echo ""
    echo "Usage:"
    echo "  $(basename "$0") <path_to_config_file>"
}

if [ -z "$1" ]; then
    usage
    exit
fi

CONFIG="$1"

if [ ! -f "$CONFIG" ]; then
    echo "Config file $CONFIG doesn't seem to exist."
    usage
    exit
fi


echo "This script will setup raspbian for encryption."
echo "------------------------------------------------------------"
echo "Scrip will do following: install necessary tools if absent,"
echo "install scripts, create initramfs image, configurate things,"
echo "and recommend reboot."
echo "------------------------------------------------------------"
echo "After reboot encryption will be done from initramfs by running /bin/encrypt_root.sh"
echo "------------------------------------------------------------"
echo "NOTE:"
echo "/boot partition must have enough free space for initramfs, about 30MB."
echo "Root partition must be resized to desired size BEFORE encryption."
echo ""
echo "Continue? [Y/n]"

read -r answer
case $answer in
[yY])
    ;;
[nN])
    exit 1
    ;;
*)
    ;;
esac

separator_line () {
    printf "\n*************************************************************\n\n"
}

##############################################################################
separator_line

echo "Install packages."
packages=(busybox cryptsetup initramfs-tools)

sudo apt-get install "${packages[*]}"

for package in ${packages[*]}; do
    if ! dpkg -l "$package" &> /dev/null; then
        echo "Package $package not installed, exiting..."
        exit 1
    fi
done

##############################################################################
separator_line

echo "Enable cryptsetup for initramfs in /etc/cryptsetup-initramfs/conf-hook:"

if ! grep -q '^CRYPTSETUP=y\s*$' /etc/cryptsetup-initramfs/conf-hook; then
    echo -n"Appending /etc/cryptsetup-initramfs/conf-hook:"
    echo "CRYPTSETUP=y" | sudo tee -a /etc/cryptsetup-initramfs/conf-hook
else
    echo "Cryptsetup seems to be already enabled."
fi

##############################################################################
separator_line

echo "Copy encrypt_root.sh script to /opt"
echo "encrypt_root.sh will be copied to, and run from  initramfs image"

cat "$CONFIG" scripts/encrypt_root.sh | sudo tee /opt/encrypt_root.sh &> /dev/null
sudo chmod 744 /opt/encrypt_root.sh 

##############################################################################
separator_line

echo "Install kernel postinstall script for rebuilding initramfs."
sudo install -v -m 744 scripts/initramfs-rebuild /etc/kernel/postinst.d/initramfs-rebuild

##############################################################################
separator_line

echo "Include additional tools in initramfs:"
sudo install -v -m 744 scripts/resize2fs /etc/initramfs-tools/hooks/resize2fs

##############################################################################
separator_line

echo "Creating initramfs:"
if ! sudo mkinitramfs -o /boot/initramfs.gz; then
    echo "Building initramfs seems to have failed. Maybe not enough space in /boot?"
    exit 1
fi

sudo lsinitramfs /boot/initramfs.gz | grep -P "sbin/(cryptsetup|resize2fs|fdisk|dd)"

sudo rm /etc/initramfs-tools/hooks/resize2fs

##############################################################################
separator_line

echo "Enable initramfs in /boot/config.txt:"
if ! grep -q "initramfs initramfs.gz followkernel" /boot/config.txt; then
    echo "initramfs initramfs.gz followkernel" | sudo tee -a /boot/config.txt
else
    echo "initramfs already enabled."
fi

##############################################################################
separator_line

echo "Make boot to quieter for encryption setup."
if ! grep -q "quiet" /boot/cmdline.txt; then
    sudo sed -i '1 s/$/ quiet/' /boot/cmdline.txt
else
    echo "quiet already enabled."
fi

##############################################################################
separator_line

echo "Enable break for booting to initramfs."
if ! grep -q "break" /boot/cmdline.txt; then
    sudo sed -i '1 s/$/ break/' /boot/cmdline.txt
else
    echo "break already enabled."
fi

##############################################################################
separator_line

echo "System should be ready for encryption."
echo "Continue by running /bin/encrypt_root.sh from initramfs."
echo ""
echo "Would you like to reboot to initramfs now? [y/N]:"

read -r answer
case $answer in
[yY])
    echo "Rebooting..."
    sleep 2
    sudo reboot
    ;;
*)
    echo "Done."
    exit 0
    ;;
esac
