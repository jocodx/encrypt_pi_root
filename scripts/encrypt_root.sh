#!/bin/sh
#
###################################################################
# Initramfs Script for encrypting root partition in place         #
# source: https://robpol86.com/raspberry_pi_luks.html             #
###################################################################
# shellcheck disable=SC1117

# dd command version. Busybox one doesn't support status=progress
DD="/sbin/dd status=progress"
#DD="dd"

yes_no_question () {
    while true; do
        echo "$1"
        read -r answer
        case $answer in
        [yY])
            return 0
            ;;
        [nN])
            return 1
            ;;
        *)
            continue
            ;;
        esac
    done
}

continue_prompt () {
    if yes_no_question "Continue? [Y/n]"; then
        printf "Continuing...\n\n"
        return 0
    else
        printf "Setup aborted, system might be in unbootable state. Fix it manually.\n\n"
        exit 1
    fi
}

separator_line () {
    printf "\n*************************************************************\n\n"
}

print_cmd () {
    printf "\n-\n"
    printf "cmd: %s\n" "$1"
    printf "\n\n"
}

rescue_shell() {
    echo "Something went wrong. Dropping to a shell."
    exec sh
}

###############################################################################
echo ""
echo ""
echo "    ______                            __ ";
echo "   / ____/___  ____________  ______  / /_";
echo "  / __/ / __ \\/ ___/ ___/ / / / __ \\/ __/";
echo " / /___/ / / / /__/ /  / /_/ / /_/ / /_  ";
echo "/_____/_/ /_/\\___/_/   \\__, / .___/\\__/  ";
echo "                      /____/_/           ";
echo "         ____   __  __            __  __    _                  __";
echo "  ____ _/ / /  / /_/ /_  ___     / /_/ /_  (_)___  ____ ______/ /";
echo " / __ \\/ / /  / __/ __ \\/ _ \\   / __/ __ \\/ / __ \\/ __ \\/ ___/ / ";
echo "/ /_/ / / /  / /_/ / / /  __/  / /_/ / / / / / / / /_/ (__  )_/  ";
echo "\\__,_/_/_/   \\__/_/ /_/\\___/   \\__/_/ /_/_/_/ /_/\\__, /____(_)   ";
echo "                                                /____/           ";
echo ""
echo ""
echo ""
###############################################################################
separator_line

echo "Check $ROOTPART for errors."
print_cmd "e2fsck -f $ROOTPART"

e2fsck -f "$ROOTPART" || rescue_shell

###############################################################################
separator_line

echo "Shrink root partitions file system."
print_cmd "resize2fs -fM $ROOTPART"

resize2fs -fM "$ROOTPART" || rescue_shell

###############################################################################
separator_line

BLOCK_COUNT=$(dumpe2fs -h "$ROOTPART" | awk '/Block count:/ {print $3}')
BLOCK_SIZE=$(dumpe2fs -h "$ROOTPART" | awk '/Block size:/ {print $3}')
printf "\nShrinked %s block size: %s, block count: %s\n" "$ROOTPART" "$BLOCK_SIZE" "$BLOCK_COUNT"

###############################################################################
separator_line

if [ "$HASHING" = "n" ]; then
    printf "Skipping calculating hash for %s...\n" "$ROOTPART"
else
    printf "Calculating checksum for %s...\n\n" "$ROOTPART"
    SHA1A=$($DD bs="$BLOCK_SIZE" count="$BLOCK_COUNT" if="$ROOTPART" | sha1sum)
    printf "\nSHA1 checksum for %s: %s\n" "$ROOTPART" "$SHA1A"
fi

###############################################################################
separator_line

#fdisk -l /dev/sda  # Make sure /dev/sda is your USB drive. If not check dmesg.
printf "Copy data from %s to %s\n" "$ROOTPART" "$USBDEV"
print_cmd "$DD bs=$BLOCK_SIZE count=$BLOCK_COUNT if=$ROOTPART of=$USBDEV".

$DD bs="$BLOCK_SIZE" count="$BLOCK_COUNT" if="$ROOTPART" of="$USBDEV"
sync

if [ "$HASHING" = "n" ]; then
    printf "\nSkipping calculating hash for copied data in %s...\n" "$USBDEV"
else
    printf "\nCalculating checksum for copied data in %s...\n\n" "$USBDEV"
    SHA1B=$($DD bs="$BLOCK_SIZE" count="$BLOCK_COUNT" if="$USBDEV" | sha1sum)
    printf "\nSHA1 checksum for %s: %s\n" "$ROOTPART" "$SHA1B"

    if [ "$SHA1A" = "$SHA1B" ]; then
        printf "SHA1 checksums match!\n"
    else
        if yes_no_question "SHA1 checksums don't match, abort setup? [Y/n]"; then
            printf "Aborting...\n"
            exit 1
        fi
    fi
fi

###############################################################################
separator_line

printf "Encrypting %s\n\n" "$ROOTPART"
printf "cryptsetup options:\n"
printf "    cipher: %s\n" "$CRYPTCIPHER"
printf "    key-size: %s\n" "$CRYPTKEYSIZE"
printf "    hash: %s\n" "$CRYPTHASH"
printf "    iter-time: %s\n" "$CRYPTITERTIME"

for i in 1 2 3 4; do
    if [ $i = 4 ]; then rescue_shell; fi
    cryptsetup -v --cipher "$CRYPTCIPHER" --key-size "$CRYPTKEYSIZE"\
                    --hash "$CRYPTHASH" --iter-time "$CRYPTITERTIME"\
                    --verify-passphrase luksFormat "$ROOTPART" && break
done

###############################################################################
separator_line

printf "Unlock new encrypted %s partition as /dev/mapper/%s.\n" "$ROOTPART" "$MAPPERNAME"

for i in 1 2 3 4; do
    if [ $i = 4 ]; then rescue_shell; fi
    cryptsetup luksOpen "$ROOTPART" "$MAPPERNAME" || break
done

printf "\nCopy data from %s back to encrypted partition %s.\n" "$USBDEV" "/dev/mapper/$MAPPERNAME"
printf "Copying...\n"
$DD bs="$BLOCK_SIZE" count="$BLOCK_COUNT" if="$USBDEV" of=/dev/mapper/"$MAPPERNAME"

if [ "$HASHING" = "n" ]; then
    printf "\nSkipping calculating hash for copied data in %s...\n" "/dev/mapper/$MAPPERNAME"
else
    printf "\nCalculating checksum for copied data in %s...\n\n" "/dev/mapper/$MAPPERNAME"
    SHA1C=$($DD bs="$BLOCK_SIZE" count="$BLOCK_COUNT" if=/dev/mapper/"$MAPPERNAME" | sha1sum)
    printf "\nSHA1 checksum for %s: %s\n" "/dev/mapper/$MAPPERNAME" "$SHA1C"

    if [ "$SHA1A" = "$SHA1C" ]; then
        printf "SHA1 checksums match!\n"
        printf "Original data successfully copied to the encrypted partition.\n"
    else
        if yes_no_question "SHA1 checksums don't match, abort setup? [Y/n]"; then
            printf "Aborting...\n"
            exit 1
        fi
    fi
fi

###############################################################################
separator_line

printf "Check encrypted partition for errors.\n"
print_cmd "e2fsck -f /dev/mapper/$MAPPERNAME"

e2fsck -f /dev/mapper/"$MAPPERNAME" || rescue_shell

###############################################################################
separator_line

printf "Expand encrypted partition to full size.\n"
print_cmd "resize2fs -f /dev/mapper/$MAPPERNAME"

resize2fs -f /dev/mapper/"$MAPPERNAME" || rescue_shell

###############################################################################
separator_line

printf "Mount encrypted partition as /mnt and /dev/mmcblk0p1 as /mnt/boot "
printf "for config file editing.\n" 
printf "Mount also /proc /dev and /sys for generating initramfs in chroot.\n"

set -x
mkdir /mnt
mount /dev/mapper/"$MAPPERNAME" /mnt
mount /dev/mmcblk0p1 /mnt/boot
mount -t proc /proc /mnt/proc
mount --rbind /dev /mnt/dev
mount --rbind /sys /mnt/sys
set +x

###############################################################################
separator_line

printf "Setup /boot/cmdline.txt, /et/fstab, and /etc/crypttab for encrypted root.\n"

if ! grep -q "cryptdevice" /mnt/boot/cmdline.txt; then
    set -x
    sed -i 's/$/ cryptdevice=\/dev\/mmcblk0p2:'"$MAPPERNAME"'/' /mnt/boot/cmdline.txt
    set +x
else
    echo "Cryptdevice already set."
fi

if ! grep -q "quiet" /mnt/boot/cmdline.txt; then
    set -x
    sed -i 's/$/ quiet' /mnt/boot/cmdline.txt
    set +x
fi

set -x
sed -i 's/root=\S\+/root=\/dev\/mapper\/'"$MAPPERNAME"'/' /mnt/boot/cmdline.txt
sed -i 's/ break / /' /mnt/boot/cmdline.txt
sed -i 's/ quiet/ /' /mnt/boot/cmdline.txt
sed -i 's;\S\+\s\+/\s;/dev/mapper/'"$MAPPERNAME"' /;' /mnt/etc/fstab
set +x

if ! grep -q "$MAPPERNAME" /mnt/etc/crypttab; then
    set -x
    echo "$MAPPERNAME  /dev/mmcblk0p2  none    luks" | tee -a /mnt/etc/crypttab
    set +x
else
    echo "/etc/crypttab already set."
fi

###############################################################################
separator_line

printf "Update initramfs image in chroot environment.\n"
print_cmd "chroot /mnt /bin/bash -c 'mkinitramfs -o /boot/iniramfs.gz'"

chroot /mnt /bin/bash -c 'mkinitramfs -o /boot/initramfs.gz'

###############################################################################
separator_line

if yes_no_question "Reboot? [Y/n]"; then
    printf "Rebooting...\n"
    sleep 2
    /bin/reboot
else
    printf "Returning to initramfs shell. Reboot manually.\n"
    exit
fi

