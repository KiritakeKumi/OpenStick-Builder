#!/bin/sh -e

apt update
apt install -y \
    android-sdk-libsparse-utils \
    autoconf \
    automake \
    bc \
    bison \
    cmake \
    debian-archive-keyring \
    debootstrap \
    device-tree-compiler \
    e2fsprogs \
    fdisk \
    flex \
    g++-aarch64-linux-gnu \
    gcc-aarch64-linux-gnu \
    gcc-arm-none-eabi \
    libtool \
    libssl-dev \
    kmod \
    make \
    pkg-config \
    python3-cryptography \
    python3-pyasn1-modules \
    python3-pycryptodome \
    patch \
    unzip \
    wget

# debootstrap's second stage and the chroot steps execute arm64 binaries, which
# an x86_64 host can only do through qemu-user. A native arm64 host runs them
# directly. The aarch64-linux-gnu toolchain above needs no equivalent switch:
# on arm64 those packages are thin aliases for the native compiler.
if [ "$(uname -m)" != "aarch64" ]; then
    apt install -y \
        binfmt-support \
        qemu-user-static
fi
