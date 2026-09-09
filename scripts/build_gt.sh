#!/bin/sh -e

CHROOT=${CHROOT=$(pwd)/rootfs}
SRCDIR=$(pwd)/src

# See debootstrap.sh: only an x86_64 host needs qemu-user to run the chroot.
if [ "$(uname -m)" = "aarch64" ]; then
    QEMU_STATIC=
else
    QEMU_STATIC=qemu-aarch64-static
fi

# install gt dependencies
#
# libc6-dev is what makes ${CHROOT} a self-contained sysroot. An x86_64 host
# never needed it: the cross gcc resolves libc headers from
# /usr/aarch64-linux-gnu/include, which is a TOOL_INCLUDE_DIR and therefore not
# rewritten by --sysroot. On a native arm64 host the libc headers live in
# /usr/include, which --sysroot *does* redirect into ${CHROOT}, so without this
# the build fails on <dirent.h>. libconfig-dev does not pull it in.
# rootfs.tgz is already packed by this point, so nothing here reaches the image.
chroot ${CHROOT} ${QEMU_STATIC} /bin/sh \
    -c " apt update; apt install libc6-dev libconfig-dev -y"

# build and install gt
(
cd src/libusbgx/
autoreconf -i
)

mkdir -p build
(
cd build
PKG_CONFIG_PATH=${CHROOT}/usr/lib/aarch64-linux-gnu/pkgconfig \
    ${SRCDIR}/libusbgx/configure \
        --host aarch64-linux-gnu \
        --prefix=/usr \
        --with-sysroot=${CHROOT}
)
make -C build DESTDIR=$(pwd)/dist CFLAGS="--sysroot=${CHROOT}" install
make -C build CFLAGS="--sysroot=${CHROOT}" install
# The gt build below compiles with --sysroot=${CHROOT}, which on a native arm64
# host really does confine the header and pkg-config search to the chroot, so
# the libusbgx just installed into the host /usr would be invisible there.
# Install it into the chroot as well; on x86_64 the cross toolchain keeps
# finding the host copy and this is a no-op.
make -C build DESTDIR=${CHROOT} CFLAGS="--sysroot=${CHROOT}" install

rm -rf build/*
PKG_CONFIG_PATH=${CHROOT}/usr/lib/pkgconfig:${CHROOT}/usr/lib/aarch64-linux-gnu/pkgconfig \
    cmake -DCMAKE_INSTALL_PREFIX=/usr \
        -DCMAKE_CXX_COMPILER=aarch64-linux-gnu-g++ \
        -DCMAKE_C_COMPILER=aarch64-linux-gnu-gcc \
        -DCMAKE_C_FLAGS=-I$(pwd)/dist/usr/include \
        -DCMAKE_C_FLAGS=-L$(pwd)/dist/usr/lib \
        -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
        -DCMAKE_SYSROOT=${CHROOT} \
        -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
        -S ${SRCDIR}/gt/source \
        -B build

make -C build DESTDIR=$(pwd)/dist install

rm -rf dist/usr/share dist/usr/lib/cmake dist/usr/lib/pkgconfig \
    dist/usr/lib/*a dist/usr/bin/ga* dist/usr/bin/s* dist/usr/include

cp -a configs/templates dist/etc/gt
