#!/bin/sh -e

# Reproducible MSM8916 Linux 6.6 build with the UFI001C wcn36xx fix.
KERNEL_TAG=v6.6-msm8916
KERNEL_COMMIT=038b2c46ae7ea7a027ef31628fa6b6751c0663b5
KERNEL_SOURCE_URL=https://github.com/msm8916-mainline/linux/archive/refs/tags/${KERNEL_TAG}.tar.gz
KERNEL_SOURCE_SHA512=5fbbdf333412667e0a0e38dcc7e83f640bd5a1e0b07e1c7786ff3e18f17b9cdec088936263d68986b3869ee305cfcecdf22970134ca8fb8d2a2769874a5a4676
PMAPORTS_COMMIT=b2ec188d30f6408585d44e7f6473142e4c052a18
KERNEL_CONFIG_SHA512=68201ecab6958dd09502c8160437281f6b5178934c2929454237b8814ffd54944d3457d735c813987a2147f1ae57e0b87d77d195353c62b10d8fef93c0769ef4

BUILD_ROOT=${KERNEL_BUILD_ROOT=$(pwd)/.cache/kernel-6.6-wcn36xx}
OUTPUT=${KERNEL_OUTPUT=$(pwd)/kernel-out}
SOURCE_ARCHIVE=${BUILD_ROOT}/${KERNEL_TAG}.tar.gz
SOURCE_DIR=${BUILD_ROOT}/linux-6.6-msm8916
CONFIG_FILE=${BUILD_ROOT}/config.aarch64
PMAPORTS_GIT=${BUILD_ROOT}/pmaports.git
PATCH_DIR=$(pwd)/patches/linux

mkdir -p "${BUILD_ROOT}" "${OUTPUT}"

download_and_verify() {
    url=$1
    output=$2
    checksum=$3

    if [ ! -f "${output}" ] || ! echo "${checksum}  ${output}" | sha512sum -c -; then
        rm -f "${output}"
        # codeload.github.com throttles unauthenticated archive downloads from
        # shared CI address ranges with HTTP 429, which wget does not retry by
        # default. A token raises the limit from per-IP to per-user; the bytes
        # served are identical either way, so the checksum below still applies.
        set --
        if [ -n "${GITHUB_TOKEN}" ]; then
            set -- --header="Authorization: Bearer ${GITHUB_TOKEN}"
        fi
        wget --https-only --tries=5 --timeout=30 --retry-connrefused \
            --retry-on-http-error=429,500,502,503,504 --waitretry=30 \
            "$@" -O "${output}" "${url}"
        echo "${checksum}  ${output}" | sha512sum -c -
    fi
}

download_and_verify "${KERNEL_SOURCE_URL}" "${SOURCE_ARCHIVE}" "${KERNEL_SOURCE_SHA512}"

# GitLab's web/raw endpoint may require JavaScript. Fetch the exact commit
# through Git instead, then extract only the pinned configuration blob.
if [ ! -d "${PMAPORTS_GIT}" ]; then
    git init --bare "${PMAPORTS_GIT}"
fi
if ! git --git-dir="${PMAPORTS_GIT}" cat-file -e "${PMAPORTS_COMMIT}^{commit}" 2>/dev/null; then
    git --git-dir="${PMAPORTS_GIT}" fetch --depth=1 \
        https://gitlab.postmarketos.org/postmarketOS/pmaports.git \
        "${PMAPORTS_COMMIT}"
fi
git --git-dir="${PMAPORTS_GIT}" show \
    "${PMAPORTS_COMMIT}:device/community/linux-postmarketos-qcom-msm8916/config-postmarketos-qcom-msm8916.aarch64" \
    > "${CONFIG_FILE}"
echo "${KERNEL_CONFIG_SHA512}  ${CONFIG_FILE}" | sha512sum -c -

rm -rf "${SOURCE_DIR}"
tar xzf "${SOURCE_ARCHIVE}" -C "${BUILD_ROOT}"

actual_commit=$(git ls-remote https://github.com/msm8916-mainline/linux.git "${KERNEL_TAG}^{}" | awk '{print $1}')
if [ "${actual_commit}" != "${KERNEL_COMMIT}" ]; then
    echo "build_kernel.sh: ${KERNEL_TAG} resolved to unexpected commit ${actual_commit}" >&2
    exit 1
fi

for patch in "${PATCH_DIR}"/*.patch; do
    echo "Applying ${patch}"
    patch -d "${SOURCE_DIR}" -p1 --forward < "${patch}"
done

cp "${CONFIG_FILE}" "${SOURCE_DIR}/.config"

# Make version metadata deterministic and identify the patched test kernel.
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export KBUILD_BUILD_TIMESTAMP='2024-05-30 12:49:51 +0000'
export KBUILD_BUILD_USER=openstick
export KBUILD_BUILD_HOST=github-actions
export KBUILD_BUILD_VERSION=6

make -C "${SOURCE_DIR}" olddefconfig
make -C "${SOURCE_DIR}" -j"$(nproc)" Image.gz modules dtbs

rm -rf "${OUTPUT}"
mkdir -p "${OUTPUT}/boot" "${OUTPUT}/usr/share/openstick-kernel"
install -m 0644 "${SOURCE_DIR}/arch/arm64/boot/Image.gz" "${OUTPUT}/boot/vmlinuz"
make -C "${SOURCE_DIR}" modules_install \
    INSTALL_MOD_PATH="${OUTPUT}" INSTALL_MOD_STRIP=1
make -C "${SOURCE_DIR}" dtbs_install \
    INSTALL_DTBS_PATH="${OUTPUT}/boot/dtbs"
rm -f "${OUTPUT}"/lib/modules/*/build "${OUTPUT}"/lib/modules/*/source

kernel_release=$(cat "${SOURCE_DIR}/include/config/kernel.release")
case "${kernel_release}" in
    6.6.0-msm8916) ;;
    *)
        echo "build_kernel.sh: unexpected kernel release ${kernel_release}" >&2
        exit 1
        ;;
esac
[ -f "${OUTPUT}/lib/modules/${kernel_release}/kernel/drivers/net/wireless/ath/wcn36xx/wcn36xx.ko" ]
[ -f "${OUTPUT}/boot/dtbs/qcom/msm8916-thwc-ufi001c.dtb" ] || \
    echo "WARNING: custom UFI001C DTB will be installed later by debootstrap.sh"
cat > "${OUTPUT}/usr/share/openstick-kernel/build-info.txt" << EOF
kernel_tag=${KERNEL_TAG}
kernel_commit=${KERNEL_COMMIT}
kernel_release=${kernel_release}
pmaports_commit=${PMAPORTS_COMMIT}
source_sha512=${KERNEL_SOURCE_SHA512}
config_sha512=${KERNEL_CONFIG_SHA512}
EOF

(cd "${PATCH_DIR}" && sha256sum *.patch) \
    > "${OUTPUT}/usr/share/openstick-kernel/patches.sha256"

(cd "${OUTPUT}" && find . -type f ! -name SHA256SUMS -print0 | \
    sort -z | xargs -0 sha256sum) \
    > "${OUTPUT}/usr/share/openstick-kernel/SHA256SUMS"

echo "Built ${kernel_release} from ${KERNEL_COMMIT}"
sha256sum "${OUTPUT}/boot/vmlinuz"
