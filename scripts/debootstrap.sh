#!/bin/sh -e

CHROOT=${CHROOT=$(pwd)/rootfs}
# Pin the release: "stable" silently moves to the next Debian on release day,
# which changes SONAME-versioned package names underneath the build.
RELEASE=${RELEASE=trixie}
HOST_NAME=${HOST_NAME=openstick-debian}
DEBOOTSTRAP_CACHE=${DEBOOTSTRAP_CACHE=$(pwd)/.cache/debootstrap}
BOOTSTRAP_HEARTBEAT_SECONDS=${BOOTSTRAP_HEARTBEAT_SECONDS=60}
BOOTSTRAP_DIAGNOSTICS=${BOOTSTRAP_DIAGNOSTICS=$(pwd)/build-logs}

# An x86_64 host can only execute the arm64 rootfs through qemu-user; a native
# arm64 host runs it directly. Empty means "no interpreter needed".
if [ "$(uname -m)" = "aarch64" ]; then
    QEMU_STATIC=
else
    QEMU_STATIC=qemu-aarch64-static
fi

bootstrap_heartbeat() {
    phase=$1
    bootstrap_pid=$2

    while kill -0 "${bootstrap_pid}" 2>/dev/null; do
        sleep "${BOOTSTRAP_HEARTBEAT_SECONDS}"
        kill -0 "${bootstrap_pid}" 2>/dev/null || break

        rootfs_size=$(du -sh "${CHROOT}" 2>/dev/null | cut -f1 || true)
        deb_count=$(find "${DEBOOTSTRAP_CACHE}" -type f -name '*.deb' 2>/dev/null | wc -l)
        printf '\n[debootstrap heartbeat] phase=%s elapsed=%ss rootfs=%s cached_debs=%s\n' \
            "${phase}" "$(( $(date +%s) - BOOTSTRAP_STARTED ))" \
            "${rootfs_size:-0}" "${deb_count}"

        if [ -f "${CHROOT}/debootstrap/debootstrap.log" ]; then
            echo '[debootstrap heartbeat] latest log entries:'
            tail -n 5 "${CHROOT}/debootstrap/debootstrap.log" || true
        fi

        echo '[debootstrap heartbeat] active bootstrap processes:'
        ps -eo pid,ppid,stat,etime,%cpu,%mem,cmd \
            | grep -E '[d]ebootstrap|[q]emu-aarch64|[d]pkg|[t]ar' || true
    done
}

run_bootstrap_stage() {
    phase=$1
    shift
    BOOTSTRAP_STARTED=$(date +%s)

    echo "Starting debootstrap ${phase} stage"
    "$@" &
    bootstrap_pid=$!
    bootstrap_heartbeat "${phase}" "${bootstrap_pid}" &
    heartbeat_pid=$!

    if wait "${bootstrap_pid}"; then
        bootstrap_status=0
    else
        bootstrap_status=$?
    fi
    kill "${heartbeat_pid}" 2>/dev/null || true
    wait "${heartbeat_pid}" 2>/dev/null || true

    echo "Finished debootstrap ${phase} stage in $(( $(date +%s) - BOOTSTRAP_STARTED ))s"
    return "${bootstrap_status}"
}

rm -rf ${CHROOT}
mkdir -p ${DEBOOTSTRAP_CACHE}
mkdir -p ${BOOTSTRAP_DIAGNOSTICS}

if [ -n "${QEMU_STATIC}" ]; then
    run_bootstrap_stage foreign \
        debootstrap --verbose --log-extra-deps --foreign --arch arm64 \
        --cache-dir=${DEBOOTSTRAP_CACHE} \
        --keyring /usr/share/keyrings/debian-archive-keyring.gpg ${RELEASE} ${CHROOT}

    cp $(which ${QEMU_STATIC}) ${CHROOT}/usr/bin

    run_bootstrap_stage second \
        chroot ${CHROOT} ${QEMU_STATIC} /bin/bash \
        /debootstrap/debootstrap --second-stage --keep-debootstrap-dir
else
    # Native arm64: unpack and configure in one stage. --keep-debootstrap-dir
    # preserves debootstrap.log for the diagnostics copy below, which the
    # foreign path gets from its second stage.
    run_bootstrap_stage native \
        debootstrap --verbose --log-extra-deps --arch arm64 \
        --keep-debootstrap-dir \
        --cache-dir=${DEBOOTSTRAP_CACHE} \
        --keyring /usr/share/keyrings/debian-archive-keyring.gpg ${RELEASE} ${CHROOT}
fi

if [ -f "${CHROOT}/debootstrap/debootstrap.log" ]; then
    cp "${CHROOT}/debootstrap/debootstrap.log" \
        "${BOOTSTRAP_DIAGNOSTICS}/debootstrap.log"
fi
rm -rf "${CHROOT}/debootstrap"

cat << EOF > ${CHROOT}/etc/apt/sources.list
deb http://deb.debian.org/debian ${RELEASE} main contrib non-free-firmware
deb http://deb.debian.org/debian-security/ ${RELEASE}-security main contrib non-free-firmware
deb http://deb.debian.org/debian ${RELEASE}-updates main contrib non-free-firmware
EOF

mount -t proc proc ${CHROOT}/proc/
mount -t sysfs sys ${CHROOT}/sys/
mount -o bind /dev/ ${CHROOT}/dev/
mount -o bind /dev/pts/ ${CHROOT}/dev/pts/
mount -o bind /run ${CHROOT}/run/

cp scripts/setup.sh ${CHROOT}
chroot ${CHROOT} ${QEMU_STATIC} /bin/sh -c /setup.sh

# cleanup
for a in proc sys dev/pts dev run; do
    umount ${CHROOT}/${a}
done;

rm -f ${CHROOT}/setup.sh
echo -n > ${CHROOT}/root/.bash_history

echo ${HOST_NAME} > ${CHROOT}/etc/hostname
sed -i "/localhost/ s/$/ ${HOST_NAME}/" ${CHROOT}/etc/hosts

# setup systemd services
cp -a configs/system/* ${CHROOT}/etc/systemd/system

cp -a scripts/msm-firmware-loader.sh ${CHROOT}/usr/sbin

# setup NetworkManager
cp configs/*.nmconnection ${CHROOT}/etc/NetworkManager/system-connections
chmod 0600 ${CHROOT}/etc/NetworkManager/system-connections/*
sed -i '/\[main\]/a dns=dnsmasq' ${CHROOT}/etc/NetworkManager/NetworkManager.conf

# enable autoconnect for usb0
cat << EOF > ${CHROOT}/etc/udev/rules.d/99-nm-usb0.rules
SUBSYSTEM=="net", ACTION=="add|change|move", ENV{DEVTYPE}=="gadget", ENV{NM_UNMANAGED}="0"
EOF

# Install the complete, matching kernel and module tree produced by
# scripts/build_kernel.sh. Do not mix modules from another kernel release.
KERNEL_OUTPUT=${KERNEL_OUTPUT=$(pwd)/kernel-out}
if [ ! -f "${KERNEL_OUTPUT}/boot/vmlinuz" ] || \
   [ ! -f "${KERNEL_OUTPUT}/usr/share/openstick-kernel/build-info.txt" ]; then
    echo "debootstrap.sh: missing patched kernel output; run scripts/build_kernel.sh first" >&2
    exit 1
fi

# Debian 13 uses merged-usr: /lib is a symlink to /usr/lib. Copying the
# complete kernel output tree with cp -a would try to replace that symlink
# with kernel-out/lib and fail. Install each payload into its canonical
# destination instead.
mkdir -p "${CHROOT}/boot" \
    "${CHROOT}/usr/lib/modules" \
    "${CHROOT}/usr/share/openstick-kernel"
cp -a "${KERNEL_OUTPUT}/boot/." "${CHROOT}/boot/"
cp -a "${KERNEL_OUTPUT}/lib/modules/." "${CHROOT}/usr/lib/modules/"
cp -a "${KERNEL_OUTPUT}/usr/share/openstick-kernel/." \
    "${CHROOT}/usr/share/openstick-kernel/"

mkdir -p ${CHROOT}/boot/extlinux
cp configs/extlinux.conf ${CHROOT}/boot/extlinux

# copy custom dtb's
cp dtbs/* ${CHROOT}/boot/dtbs/qcom

# create missing directory
mkdir -p ${CHROOT}/lib/firmware/msm-firmware-loader

# update fstab
printf '%s\n' \
    'PARTUUID=80780b1d-0fe1-27d3-23e4-9244e62f8c46 /boot ext2 defaults 0 2' \
    > ${CHROOT}/etc/fstab

# backup rootfs
tar cpzf rootfs.tgz --exclude="usr/bin/qemu-aarch64-static" -C rootfs .
