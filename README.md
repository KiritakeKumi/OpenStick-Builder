# OpenStick Image Builder
Image builder for MSM8916 based 4G modem dongles

This builder compiles the pinned MSM8916 Linux 6.6 source and postmarketOS configuration, and records source/config/patch checksums in every image. The known-good lk1st 18.1 (`99297666`) is retained.

On UFI001C it also marks `pm8916 l9` (`vddpa`, the WCN3620 transmit power amplifier supply) `regulator-always-on` in the built device tree. Without that the rail never comes up, and Wi-Fi scans at full signal but can never associate — see [Wi-Fi on UFI001C](#wi-fi-on-ufi001c).

> [!NOTE]
> This branch generates a `debian` image, use the [alpine branch](https://github.com/kinsamanka/OpenStick-Builder/tree/alpine) for an `alpine` image.

## Build Instructions
### Build locally
This has been tested to work on **Ubuntu 22.04**. Both x86_64 and arm64 hosts
are supported: the scripts detect the host architecture and only pull in
`qemu-user-static` when the arm64 rootfs has to be emulated.
- clone
  ```shell
  git clone --recurse-submodules https://github.com/kinsamanka/OpenStick-Builder.git
  cd OpenStick-Builder/
  ```
#### Quick
- build
  ```shell
  cd OpenStick-Builder/
  sudo ./build.sh
  ```
#### Detailed
- install dependencies
  ```shell
  sudo scripts/install_deps.sh
  ```
- build hyp and lk2nd

  these custom bootloader allows basic support for `extlinux.conf` file, similar to u-boot and depthcharge.
  ```shell
  sudo scripts/build_hyp_aboot.sh
  ```
- extract Qualcomm firmware

  extracts the bootloader and creates a new partition table that utilizes the full emmc space
  ```shell
  sudo scripts/extract_fw.sh
  ```
- create rootfs using debootstrap
  ```shell
  sudo scripts/debootstrap.sh
  ```

- build gadget-tools
  ```shell
  sudo scripts/build_gt.sh
  ```
- create images
  ```shell
  sudo scripts/build_images.sh
  ```

The generated firmware files will be stored under the `files` directory

### On the cloud using Github Actions

Every push to `main` builds on the native arm64 runner and publishes the result
as the rolling `latest` prerelease; pushing a `v*` tag publishes a release under
that tag's name. Both carry `boot.bin`, `rootfs.bin` and `SHA256SUMS`, so the
newest images are downloadable from the releases page without running anything.

To build a specific revision or compare build hosts:

1. Fork this repo
2. Run the [Build workflow](../../actions/workflows/build.yml)
   - click and run ***Run workflow***
   - pick the **Build host**:
     - `arm64` (default) — runs on the native `ubuntu-24.04-arm` runner, so `debootstrap` and the `chroot` steps execute at full speed
     - `x86_64` — runs on `ubuntu-latest` and bootstraps the arm64 rootfs through `qemu-user-static`
     - `both` — runs the two in parallel
   - once the workflow is done, click on the workflow summary and then download the `openstick-debian-<host>` artifact

Manual runs only produce artifacts; they never publish a release, because they
can be `x86_64`-only and are usually experiments.

## Wi-Fi on UFI001C

The WCN3620 iris takes four supplies. On this board none of their consumers ever
reaches `enable_count` 1, but `vddxo` (l7), `vdddig` (l5) and `vddrfa` (s3) are
held up anyway by unrelated consumers — eMMC `vqmmc`/`vmmc`, USB ULPI, the modem
PLL. `pm8916 l9` feeds `vddpa` and nothing else, so it alone stays `disabled`
with `num_users` 0.

The receive path is unaffected, so the symptom is misleading: `nmcli device wifi
list` shows APs at full signal, but every transmitted frame leaves without its
power amplifier and no AP ever acknowledges it. 802.11 open-system
authentication then times out against every BSSID, long before WPA is reached,
while `wcn36xx` logs `TX ACK indication timed out` and `Failed to flush hardware
tx queues`.

[`scripts/build_kernel.sh`](scripts/build_kernel.sh) fixes this by adding
`regulator-always-on` to the `l9` node of `msm8916-thwc-ufi001c.dtb` right after
`dtbs_install`, then reading the property back and failing the build if it did
not take. No other board's device tree is touched. The stick is bus powered, so
holding a 3.3 V rail costs nothing that matters here.

[`patches/linux/0001-wcn36xx-allow-slow-tx-ack.patch`](patches/linux/0001-wcn36xx-allow-slow-tx-ack.patch)
predates that finding and is kept only as a diagnostic: with the rail powered
its watchdog should never fire, so seeing its message again means the PA is
unpowered on that unit.

To check a running device — `l9` must read `enabled`, one user, 3.3 V:

```shell
for r in /sys/class/regulator/regulator.*; do
    [ "$(cat "$r/name")" = l9 ] || continue
    echo "$(cat "$r/state") $(cat "$r/microvolts") users=$(cat "$r/num_users")"
done
```

## Customizations
Edit [`scripts/setup.sh`](scripts/setup.sh) to add/remove packages. Note that this script is running inside the `chroot` environment.

## Firmware Installation
> [!WARNING]  
> The following commands can potentially brick your device, making it unbootable. Proceed with caution and at your own risk!

> [!IMPORTANT]  
> Make sure to perform a backup of the original firmware using the command `edl rf orig_fw.bin`

### Prerequisites
- [EDL](https://github.com/bkerler/edl)
- Android fastboot tool
  ```
  sudo apt install fastboot
  ```

### Steps
- Enter Qualcom EDL mode using this [guide](https://wiki.postmarketos.org/wiki/Zhihe_series_LTE_dongles_(generic-zhihe)#How_to_enter_flash_mode)
- Backup required partitions

  The following files are required from the original firmware:
  
     - `fsc.bin`
     - `fsg.bin`
     - `modem.bin`
     - `modemst1.bin`
     - `modemst2.bin`
     - `persist.bin`
     - `sec.bin`

  Skip this step if these files are already present
  ```shell
  for n in fsc fsg modem modemst1 modemst2 persist sec; do
      edl r ${n} ${n}.bin
  done
  ```
- Install `aboot`
  ```shell
  edl w aboot aboot.mbn
  ```
- Reboot to fastboot
  ```shell
  edl e boot
  edl reset
  ```
- Flash firmware
  ```shell
  fastboot flash partition gpt_both0.bin
  fastboot flash aboot aboot.mbn
  fastboot flash hyp hyp.mbn
  fastboot flash rpm rpm.mbn
  fastboot flash sbl1 sbl1.mbn
  fastboot flash tz tz.mbn
  fastboot flash boot boot.bin
  fastboot flash rootfs rootfs.bin
  ```
- Restore original partitions
  ```shell
  for n in fsc fsg modem modemst1 modemst2 persist sec; do
      fastboot flash ${n} ${n}.bin
  done
  ```
- Reboot
  ```shell
  fastboot reboot
  ```

## Post-Install
- Network configuration
  
  | wlan0 | |
  | ----- | ---- |
  | ssid | Openstick |
  | password | openstick |
  | ip addr | 192.168.4.1 |

  | usb0 | |
  | ----- | ---- |
  | ip addr | 192.168.5.1 |

- Default user
  
  | | |
  | ----- | ---- |
  | username | user |
  | password | 1 |
 
- [`configs/extlinux.conf`](configs/extlinux.conf) ships the **UFI001C** devicetree. If your device is a different board, modify `/boot/extlinux/extlinux.conf`
  ```shell
  sed -i 's/thwc-ufi001c/<BOARD>/' /boot/extlinux/extlinux.conf
  ```

  where `<BOARD>` is
     - `yiming-uz801v3` for **UZ801** boards
     - `thwc-uf896` for **UF896** boards
     - `jz01-45-v33` for **JZxxx** boards
     - `fy-mf800` for **MF800** boards

- To maximize the `rootfs` partition
  ```shell
  resize2fs /dev/disk/by-partlabel/rootfs
  ```

- To update or roll back the complete `boot` + `rootfs` pair, follow
  [`SYSTEM_UPDATE_UFI001C.md`](SYSTEM_UPDATE_UFI001C.md). Do not extract a
  different kernel package directly over a running system: the boot image and
  module tree must always come from the same CI build.
