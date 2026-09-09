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

Every push to `main` publishes the natively built arm64 images as the rolling
`latest` prerelease; a `v*` tag publishes a release under its own name. Both
carry `boot.bin`, `rootfs.bin` and `SHA256SUMS`.

To build a specific revision instead, run the **Build** workflow manually and
download its artifacts:

- `openstick-debian-<host>`: `boot.bin`, `rootfs.bin` and the other release
  files;
- `linux-6.6-wcn36xx-build-<host>`: kernel image, the patched UFI001C DTB,
  build metadata and checksums.

`<host>` is `arm64` or `x86_64` depending on the build host chosen; the images
are identical in function, only the runner that produced them differs.

The kernel metadata must report:

```text
kernel_tag=v6.6-msm8916
kernel_commit=038b2c46ae7ea7a027ef31628fa6b6751c0663b5
```

Verify the CI-generated hash list before flashing:

```sh
sha256sum -c SHA256SUMS
```

`boot.bin` and `rootfs.bin` are Android sparse images. Use Fastboot for the
normal update path; do not write sparse files as raw sectors with EDL.

## What fixes Wi-Fi in this build

`scripts/build_kernel.sh` marks `pm8916 l9` `regulator-always-on` in
`msm8916-thwc-ufi001c.dtb` after `dtbs_install`. That rail feeds `vddpa`, the
WCN3620 transmit power amplifier, and nothing else, so without the change it
stays disabled with zero users while the iris' other three supplies are held up
incidentally by the eMMC and USB consumers. The radio then receives at full
signal and scans normally, but no AP ever acknowledges a transmitted frame:
802.11 open-system authentication times out against every BSSID, long before
WPA is reached, and `wcn36xx` logs `TX ACK indication timed out`.

`patches/linux/0001-wcn36xx-allow-slow-tx-ack.patch` predates that finding. It
raises the TX ACK watchdog and logs the timeout; with the rail powered it should
never fire, so it is now diagnostic rather than a workaround. Its message
appearing again means the PA is unpowered on that unit.

The images are unaffected on other boards: only the UFI001C DTB is touched.

### Verification status

Verified on board1 (serial `0A86678F`) on 2026-09-09, by patching the DTB in
place on the running system and rebooting:

- `l9` went from `disabled`/`num_users=0` to `enabled`, one user, 3300000 µV;
- `wlan0` reached `authenticated` then `associated`, and DHCP returned
  `172.16.0.164/16` via `172.16.10.254`;
- `nmcli` reported `wlan0:wifi:connected:test`; ping to `223.5.5.5` and
  `119.29.29.29` both 0% loss.

Before the change, `l9` stayed disabled through 22 s of live authentication
attempts and across a full WCNSS remoteproc `stop`/`start`, which is what rules
out an init-order race and makes the always-on marking the right fix rather than
a retry.

The `fdtput` node path and the `fdtget` read-back check were exercised against
the exact DTB this builder produces. What has **not** been confirmed yet is a
full CI run carrying the change end to end — the first published build is the
one to spot-check with the `l9` command under *Post-update verification*.

Known-harmless noise that remains after the fix:

```text
wcn36xx: ERROR hal_enter_bmps response failed err=1
wcn36xx: ERROR Can not enter BMPS!
cfg80211: failed to load regulatory.db
```

Power-save entry fails and the connection is unaffected; `regulatory.db` is
absent because `wireless-regdb` is not installed, and the world domain does not
set NO-IR on channels 1-11. `iw` and `rfkill` are also not installed.

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

Confirm the transmit power amplifier rail came up. `l9` must read `enabled`
with at least one user at 3.3 V:

```sh
for r in /sys/class/regulator/regulator.*; do
    [ "$(cat "$r/name")" = l9 ] || continue
    echo "$(cat "$r/state") $(cat "$r/microvolts") users=$(cat "$r/num_users")"
done
```

Expected: `enabled 3300000 users=1`. A `disabled` `l9` means the running `boot`
image still carries an unpatched DTB; scanning will work and association will
not.

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
