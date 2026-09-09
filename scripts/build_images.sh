#!/bin/sh -e

CHROOT=${CHROOT=$(pwd)/rootfs}

#package rootfs
rm -f rootfs.raw boot.raw
mkdir -p files mnt

# create boot
truncate -s 67108864 boot.raw
mkfs.ext2 boot.raw
mount boot.raw mnt
tar xf rootfs.tgz -C mnt ./boot --exclude='./boot/linux.efi' --strip-components=2
umount mnt

# create root img
# 3 GiB. The rootfs partition is the last one in the GPT and lk/aboot grows it
# to fill the eMMC (~3.44 GiB on a 3696 MiB card), but nothing resizes the
# filesystem on first boot, so the image size here is the final usable size.
# Keep it below the smallest supported card's rootfs partition.
truncate -s 3221225472 rootfs.raw
mkfs.ext4 rootfs.raw
mount rootfs.raw mnt
tar xpf rootfs.tgz -C mnt --exclude='./boot/*' --exclude='./root/*' --exclude='./dev/*'

# install gt
cp -a dist/* mnt

umount mnt

# Punch holes only for blocks marked free by the ext filesystem, then preserve
# those holes as Android sparse DONT_CARE chunks. Without this, img2simg encodes
# unused ext blocks as zero-filled FILL chunks and fastboot unnecessarily writes
# almost the full 3 GiB filesystem to eMMC.
e2fsck -fy -E discard rootfs.raw || [ $? -eq 1 ]
e2fsck -fy -E discard boot.raw || [ $? -eq 1 ]

# create sparse android images
img2simg -s rootfs.raw files/rootfs.bin
img2simg -s boot.raw files/boot.bin
