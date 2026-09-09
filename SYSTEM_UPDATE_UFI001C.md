# UFI001C system update guide

This guide updates an already migrated UFI001C to a CI-built OpenStick Debian
system while preserving the device's modem firmware, NV data, identity and
calibration.

## Safety rules

- Make and verify a complete backup before the first migration or recovery.
- Never copy `modemst1`, `modemst2`, `fsg`, `fsc`, `persist`, `sec`, `ssd` or
  other identity/calibration partitions from another device.
- A normal system update writes only `boot` and `rootfs`.
- Do not flash `gpt_both0.bin`, `aboot.mbn` or any firmware/NV image during a
  routine update.
- Keep the previous known-good `boot` and `rootfs` images until the new system
  has passed a physical cold-boot test.
- Do not use a partially downloaded, damaged or unverified image.

## CI artifacts

Run the **Build** workflow and download both artifacts:

- `openstick-debian`: `boot.bin`, `rootfs.bin` and the other release files;
- `linux-6.6-wcn36xx-build`: kernel image, build metadata and checksums.

The kernel metadata must report:

```text
kernel_tag=v6.6-msm8916
kernel_commit=038b2c46ae7ea7a027ef31628fa6b6751c0663b5
```

The wcn36xx change is a testable workaround for delayed firmware TX ACK
indications. Keep a verified 5.15 or unpatched 6.6 `boot`/`rootfs` pair ready
for rollback until Wi-Fi association and repeated cold boots have passed.

Verify the CI-generated hash list before flashing:

```sh
sha256sum -c SHA256SUMS
```

`boot.bin` and `rootfs.bin` are Android sparse images. Use Fastboot for the
normal update path; do not write sparse files as raw sectors with EDL.

## Normal update using Fastboot

Confirm that exactly one expected device is connected:

```sh
adb devices -l
adb reboot bootloader
fastboot devices
fastboot getvar product
```

Archive the command output and then flash **only** these partitions:

```sh
fastboot flash boot boot.bin
fastboot -S 200m flash rootfs rootfs.bin
```

Every command must finish with `OKAY`. If either command fails, do not reboot
and do not flash unrelated partitions. Save the full log and recover the
failed partition using the previous known-good image.

After both writes succeed:

```sh
fastboot reboot
```

Wait for USB/RNDIS enumeration. Then disconnect power for at least 15 seconds,
reconnect normally and verify a second, physical cold boot.

## Post-update verification

Run on the UFI001C through ADB or SSH:

```sh
uname -a
cat /usr/share/openstick-kernel/build-info.txt
findmnt /
ls /lib/modules
systemctl --failed --no-pager
systemctl is-active NetworkManager ModemManager msm-firmware-loader
dmesg | grep -Ei 'wcn36xx|wcnss|wlan0|TX ACK|Spurious'
nmcli device wifi list --rescan yes
nmcli connection up test
```

For the patched 6.6 test, specifically record whether either message appears:

```text
TX ACK indication timed out after 1000 ms
Spurious TX complete indication
```

Also verify the modem without modifying its provisioning:

```sh
mmcli -L
mmcli -m 0
mmcli -i 0
```

## Recovery through EDL

Use this only when Fastboot/ADB is unavailable. Verify the Qualcomm Sahara
serial number against the device's backup record before doing anything else.

The OpenStick GPT used by this builder has these board0 system ranges:

| Partition | LUN | Start LBA | End LBA | Size |
|---|---:|---:|---:|---:|
| `boot` | 0 | 217122 | 348193 | 64 MiB |
| `rootfs` | 0 | 348194 | 7569374 | about 3.44 GiB |

These numbers are recorded for the currently validated layout only. Read and
validate the device's current GPT before relying on them. Never use the old
Android GPT's partition LBAs after migration.

EDL recovery requires raw images, not Android sparse images. Convert a copy:

```sh
simg2img boot.bin boot.raw
simg2img rootfs.bin rootfs.raw
sha256sum boot.raw rootfs.raw
```

Before writing, confirm that each raw image is sector-aligned and no larger
than its target partition. Prefer short transactions (for example 16 MiB)
because this board's old Firehose programmer can time out on multi-gigabyte
continuous transfers. Stop immediately on any failed chunk.

After writing, read back the complete written ranges and compare SHA-256 with
the raw source images. Do **not** reset or boot until both comparisons match.

EDL recovery must not write:

- GPT;
- `sbl1`, `rpm`, `hyp`, `tz`, `aboot` or `cdt`;
- modem, NV, identity or calibration partitions;
- eMMC `boot0` or `boot1`.

Only after complete readback verification should Firehose reset be sent. A
final acceptance test always includes at least 15 seconds without power and a
normal cold boot without forcing EDL.

## Rollback

Rollback uses the same procedure and writes only the previously archived,
verified `boot` and `rootfs` pair. Kernel and modules must come from the same
build. Never combine a 6.6 `boot` image with a rootfs that contains only 6.12
modules, or vice versa.
