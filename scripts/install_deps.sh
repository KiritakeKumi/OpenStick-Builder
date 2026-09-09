#!/bin/sh -e

apt update
apt install -y \
    android-sdk-libsparse-utils \
    autoconf \
    automake \
    bc \
    binfmt-support \
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
    qemu-user-static \
    unzip \
    wget 
