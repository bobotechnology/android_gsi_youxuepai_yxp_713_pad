# U90 fastboot controlled-variable handoff (2026-09-17)

## Superseded

The variable behind the repeated return to fastboot is now identified and the
recipe is fixed. The stock U90 ramdisk first-stage init unconditionally execs
`/system/bin/init`, and the `sas-creator` A-only image used for P2 does not
contain that path. Packaging the raw system-as-root build product instead was
verified to boot Android 11 on the device. See
`docs/records/u90-a11-v313-sar-build-record.md`. Keep this document only as the record
of the P0-P4 controlled sequence; its "recommended next-agent sequence" below
is historical and no longer the plan.

## Scope

Device: Youxuepai U90 / `yxp_713_pad` / MT6779, non-A/B dynamic partitions.

This document records real-device results from a controlled fastboot sequence.
It is not a claim that the Android 11 GSI boots. The GSI has been proven to
return to fastboot under the tested conditions.

## Current state at handoff

- The device is currently reachable as `adb` serial `<device-serial>` in
  TWRP recovery, not in fastboot and not in Android:
  - `ro.twrp.version=3.7.1_12-0`
  - `ro.build.fingerprint=YOUXUEPAI/twrp_yxp_713_pad/yxp_713_pad:16.1.0/SP2A.220405.004/eng.runner.20260916.182117:eng/test-keys`
  - `ro.boot.verifiedbootstate=orange`
- No device partition was flashed after P3 below. Therefore, based on this
  session's actions, physical storage should still be:
  - stock `super` from the official firmware;
  - AVB-disabled `vbmeta`, `vbmeta_system`, and `vbmeta_vendor` from P1;
  - the last explicit BCB write was a 4 KiB zero write before P3 reboot.
- No Docker container or host packaging process remains running.
- The P4 local control package exists but is incomplete. **Do not flash it.**

## Device and partition facts

Fastboot observations before the controlled sequence:

```text
serial: <device-serial>
product: yxp_713_pad
unlocked: yes
is-userspace: no
slot-count: 0
partition-size:super: 0x200000000 (8 GiB)
partition-size:misc: 0x80000 (512 KiB)
```

Official firmware directory:

```text
<stock-firmware-dir>
```

Official stock `super.img`:

```text
size:    2425113828
sha256:  90a059555210e8567a8b588a00e9b3501925241ed946d54ff03b34c8d0ba88f3
format:  Android sparse (first bytes: 3A FF 26 ED)
```

The stock logical partition table is:

```text
product: 382234624 bytes, readonly, group main
system:  1476481024 bytes, readonly, group main
vendor:  582471680 bytes, readonly, group main
super:   8589934592 bytes
main:    8342470656 bytes
metadata size: 65536; metadata slots: 2
```

## Real-device controlled experiments

### P0: clear only the BCB

Input:

```text
<repo>\output\fastboot-controlled-20260917\misc-bcb-clear-first-4KiB.bin
```

The file was verified as 4096 bytes of zeroes:

```text
sha256: ad7facb2586fc6e966c004d7d1d16b024f5805ff7cb47c7a85dabd8b48892ca7
```

Only this command changed storage:

```text
fastboot -s <device-serial> flash misc <zero-4KiB-file>
fastboot -s <device-serial> reboot
```

Result: success. The device reached `adb device` at 2026-09-17 10:28:00 +08.
Read-only Android evidence:

```text
sys.boot_completed=1
ro.build.version.release=10
ro.build.fingerprint=YOUXUEPAI/full_yxp_713_pad/yxp_713_pad:10/QP1A.190711.020/mp1k61v164bspP3:user/release-keys
ro.boot.verifiedbootstate=orange
```

Interpretation: stale `misc`/BCB was a real confounder, but P0 tested the
stock `super`, not the GSI.

Evidence directory:

```text
<repo>\output\fastboot-controlled-20260917\p0-bcb-20260917-102738
```

### P1: change only the AVB set while retaining stock `super`

Flashed exactly these files to their matching partitions:

```text
vbmeta         <- vbmeta_u90_avb_disabled.img
vbmeta_system  <- vbmeta_system_u90_avb_disabled.img
vbmeta_vendor  <- vbmeta_vendor_u90_avb_disabled.img
```

Each image is 4096 bytes and has:

```text
sha256: fd1cac764ef971200a5b955631e12eaa6695d4c626fa1ea4685009723d60b604
avbtool: Algorithm NONE; Flags 3
```

Result: success. With the stock `super` unchanged, Android 10 reached `adb
device` at 2026-09-17 10:30:06 +08.

Interpretation: this three-image AVB-disabled set is not by itself the cause
of the fastboot return.

Evidence directory:

```text
<repo>\output\fastboot-controlled-20260917\p1-avb-20260917-102945
```

### P2: change only `super` to the source-fixed v5 GSI package

P2 retained P1's AVB state. It flashed only:

```text
<repo>\artifacts\local\u90-a11-sourcefixed-v5-package\super_u90_gsi.sparse.img
```

Verified input:

```text
size:   2640062048
sha256: 5e7380bd27144b402b3320ae06224698366c5e0592f0ee55dcd784b052c7d951
```

Official `fastboot` wrote all 21 sparse chunks successfully in 94.066 seconds,
then rebooted. The device returned to fastboot at 2026-09-17 10:32:58 +08.

### P2a: re-clear only the BCB while leaving the failed GSI `super` intact

Again wrote only the 4 KiB all-zero `misc` image, then rebooted. Result: the
device again returned to fastboot at 2026-09-17 10:33:46 +08.

Interpretation: P2 is not explained by an old/stale BCB alone. The current
GSI boot attempt either fails before Android, or rewrites a bootloader target
on every attempt. A post-failure `misc` and pstore capture is still required
to distinguish those subcases.

Evidence directories:

```text
<repo>\output\fastboot-controlled-20260917\p2-super-20260917-103054
<repo>\output\fastboot-controlled-20260917\p2a-bcb-after-gsi-20260917-103320
```

### P3: direct fastboot write of the official stock sparse `super`

This test used the exact official `super.img` above, retaining P1 AVB state.
It flashed all 19 sparse chunks successfully in 97.192 seconds, cleared the
first 4 KiB of `misc`, then rebooted.

Result: success. Android reached `adb device` at 2026-09-17 10:39:37 +08.

Interpretation: all of the following are now experimentally excluded as the
primary cause of P2:

1. official fastboot sparse transport/write path;
2. current fastboot bootloader operation;
3. stale BCB before the boot attempt;
4. the P1 AVB-disabled triple.

The P2 failure is consequently localized to the custom v5 `super`: either its
reconstructed dynamic-partition representation or the replacement GSI
`system` payload.

Evidence directory:

```text
<repo>\output\fastboot-controlled-20260917\p3-stock-super-fastboot-20260917-103738
```

## v5 package facts

Complete v5 package directory:

```text
<repo>\artifacts\local\u90-a11-sourcefixed-v5-package
```

Its manifest proves:

- `product` and `vendor` byte-identical to the stock logical partitions;
- the GSI logical `system` byte-identical to the supplied input image;
- logical names remain `product`, `system`, `vendor` in group `main`;
- the GSI system grows to 1684152320 bytes and moves the vendor extent;
- the AVB-disabled images are generated with official `avbtool` flags 3;
- the v5 image does not retain `/etc/init/twrp.rc` or `/bin/twrp.sh`;
- it rejects phh-su, Magisk, SuperUser and SuperSU at package time.

Static matching is useful but not sufficient: P2 is the runtime counterexample.

## P4 stock-system repack control: local artifact is incomplete

Goal of P4: distinguish `lpmake`/custom-super packaging from the Android 11
GSI payload by rebuilding a custom `super` with stock `product`, stock
`vendor`, and stock logical `system`.

Stock logical system extraction input:

```text
<repo>\artifacts\local\u90-stock-system-repack-control-input\system_stock.img
size:   1476481024
sha256: 578cafc5d5d9e5e6cc6712298bce5549f2272a5c96d00bc55dede445b997ea78
```

The extraction used the official Android host tools in the retained Docker
volume: `simg2img`, `lpunpack`, then copied `parts/system.img`. Important:
`lpunpack` did not create a nonexistent output directory; callers must create
the target directory first.

P4 directory:

```text
<repo>\artifacts\local\u90-stock-system-repack-control
```

Do **not** flash any file from it yet. It was interrupted/unfinished:

- `super_u90_gsi.sparse.img` exists:
  - size `2425113924`
  - sha256 `598938aeadbb7b0fac9d3a351ce94444f3c4315bc951234d0b3772e19e87a036`
- `super_u90_gsi.raw.img` exists and is 8589934592 bytes.
- `PACKAGE-MANIFEST.txt` is truncated immediately after
  `super_sparse_sha256`; it lacks raw hash/size, lpdump verification, AVB
  verification blocks, and the generated flash plan.
- `FLASH-PLAN.txt` is absent.
- The packaging console emitted `Invalid sparse file format at header magic`
  three times before the run was interrupted. Its exact semantic meaning must
  be resolved before rebuilding or flashing P4.

This P4 output cannot serve as a controlled test until a clean package
completion produces the full manifest and flash plan.

## Context7 research status

The user explicitly requested Context7 lookup before further trial-and-error.
No Context7 MCP connector is configured in this Codex session. A browser lookup
was started at Context7's Android Core library:

```text
https://context7.com/websites/source_android_core
```

The navigation was interrupted before documentation was read. Treat the
following as mandatory research questions before any P4 rebuild or flash:

1. Exact AOSP `lpmake --sparse` output behavior and supported metadata-slot
   options for a non-A/B device with `metadata-slots=2`.
2. `simg2img` behavior when the input is already raw or when it prints
   `Invalid sparse file format at header magic`; determine exit code and
   whether a valid output is produced.
3. `lpunpack` target-directory creation requirement and slot selection
   semantics.
4. Required dynamic-partition metadata / block-device fields for an MTK
   Android 10 non-A/B `super` that is rebuilt with AOSP `lpmake`.
5. Whether the packaging script must preserve allocation alignment, first
   logical extent, and vendor start exactly rather than merely preserving
   names, sizes and group capacity.

Use official AOSP material through Context7 if indexed; do not infer flags
from trial output.

## Recommended next-agent sequence

1. Do not flash P4. First complete the Context7/AOSP tool-semantics review.
2. In TWRP, make a read-only capture before changing state:

   ```text
   adb -s <device-serial> shell getprop
   adb -s <device-serial> shell ls -al /sys/fs/pstore
   adb -s <device-serial> shell ls -al /dev/block/by-name
   ```

   If a GSI failure is reproduced later, capture first 4 KiB of `misc` and
   pstore before clearing BCB or rebooting:

   ```text
   dd if=/dev/block/by-name/misc of=/tmp/misc-after-gsi.bin bs=4096 count=1
   cp /sys/fs/pstore/* /tmp/ 2>/dev/null || true
   ```

3. Rebuild P4 in a fresh empty output directory only after resolving the
   official tool semantics. Require all of the following before flash:
   - full `PACKAGE-MANIFEST.txt` including raw/sparse hashes and both lpdump
     sections;
   - `FLASH-PLAN.txt`;
   - byte-identical product, system and vendor logical images;
   - a clean final process exit code of zero;
   - no unexplained sparse-format diagnostics.
4. Then enter fastboot deliberately from TWRP (`adb reboot bootloader` or the
   TWRP Reboot -> Bootloader UI), verify the same serial/product/unlocked
   state, and run one P4 control test:

   ```text
   fastboot -s <device-serial> flash super <validated-P4-sparse-super>
   fastboot -s <device-serial> flash misc <validated-4KiB-zero-file>
   fastboot -s <device-serial> reboot
   ```

   Do not flash `boot`, `dtbo`, `recovery`, `userdata`, or raw 8 GiB super
   through fastboot. Keep the already validated P1 AVB images unchanged.
5. Interpret P4 exactly once:
   - P4 boots: the custom lpmake/sparse representation is viable; investigate
     the Android 11 GSI system payload and obtain pstore/misc from a failed
     P2 boot.
   - P4 returns fastboot: the custom super construction is invalid for this
     bootloader despite static lpdump similarity; fix construction parameters
     before touching any GSI payload.
6. Immediate recovery path, if needed, is already proven:

   ```text
   fastboot -s <device-serial> flash super <stock-firmware-dir>\super.img
   fastboot -s <device-serial> flash misc <repo>\output\fastboot-controlled-20260917\misc-bcb-clear-first-4KiB.bin
   fastboot -s <device-serial> reboot
   ```

## Implementation note

The user prefers C++ over Python. No Python was used for image creation or
device control here. Image construction used official AOSP host binaries; the
Windows host only used PowerShell for orchestration and verification.
