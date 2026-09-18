# U90 Stock Firmware Baseline

This document is an evidence log for the U90 (`yxp_713_pad`, MT6779)
compatibility investigation. It records only artifacts reproduced from the
stock flash package and the attached device, and each conclusion is scoped to
the evidence under it.

## Inputs

Source flash package:

```text
<stock-firmware-dir>
```

The package uses the eMMC scatter section. `super` is at `0x2c800000`, has a
physical partition size of `0x200000000` (8 GiB), and the package image is an
Android sparse image.

## Reproducible Stock Super Extraction

The stock `super.img` was copied only through official Android host tools in a
disposable Docker container:

```text
simg2img super.img super.raw.img
lpdump super.raw.img
lpunpack super.raw.img partitions
avbtool info_image --image partitions/<logical-partition>.img
```

Derived artifacts are retained in Docker volume `u90-gsi-state` at
`/w/stock-20221129`. The original flash package is mounted read-only.

| Item | Value |
| --- | ---: |
| Sparse `super.img` | 2,425,113,828 bytes |
| Expanded `super.raw.img` | 8,589,934,592 bytes |
| `product.img` | 382,234,624 bytes |
| `system.img` | 1,476,481,024 bytes |
| `vendor.img` | 582,471,680 bytes |

```text
super.raw.img  abd0ea3b51b61e28ca0a7ba4e8242fd8b182b95f60588894b4865bfcddcf80aa
product.img    8822bf0becf9c88ff96d880f941b32ca394f31886f9218c4351ffbfa07729852
system.img     578cafc5d5d9e5e6cc6712298bce5549f2272a5c96d00bc55dede445b997ea78
vendor.img     95208403b70c58ef214335bac9de71c476d2b27404b90571f6347e41de23c51b
```

The stock logical-partition layout is:

```text
product: super sectors 2048..748600
system:  super sectors 749568..3633320
vendor:  super sectors 3635200..4772840
group main maximum: 8342470656 bytes
```

The official Android 11 `unpack_bootimg.py` tool also reproduces the stock
boot-image layout without modifying it:

```text
boot header version: 2
kernel size: 10496909
ramdisk size: 800892
DTB size: 129147
OS version: 10.0.0
OS patch level: 2021-03
kernel cmdline: bootopt=64S3,32N2,64N2 buildvariant=userdebug
```

## Stock Platform Contract

`vendor/build.prop` and `vendor/default.prop` establish a Q-era vendor
contract:

```text
ro.product.first_api_level=29
ro.board.platform=mt6779
ro.vndk.version=29
vendor plat_sepolicy version=29.0
system ro.build.version.release=10
system ro.build.version.sdk=29
system ro.build.version.security_patch=2021-03-05
```

The stock `vendor/etc/fstab.mt6779` first-stage mounts the three logical
partitions as follows:

```text
system  /system  ext4 ro wait,,avb=vbmeta_system,logical,first_stage_mount,avb_keys=/avb/q-gsi.avbpubkey:/avb/r-gsi.avbpubkey:/avb/s-gsi.avbpubkey
vendor  /vendor  ext4 ro wait,,avb,logical,first_stage_mount
product /product ext4 ro wait,,avb,logical,first_stage_mount
```

The `wait` mount option means a first-stage failure can present as a later
watchdog reset rather than an immediate visible AVB error. The GSI key files
are in the stock boot ramdisk, rather than the vendor logical partition:

```text
q-gsi.avbpubkey  SHA-1 144820003f9d46c96e9090dcf0e4feb84ca84810
r-gsi.avbpubkey  SHA-1 e3cc565489737d7c5a54fff8337fe4279783c8ce
s-gsi.avbpubkey  SHA-1 152cb9d664a600bd37fa1ea6713816a4f3265243
```

The current local GSI `vbmeta_system` is signed by the AOSP test key
`de54aa1af52911063fc680e6cc1edaf3aa4d7b1d`, which does not match any of those
three boot-ramdisk GSI keys.

Android `first_stage_mount.cpp` explicitly handles a fstab entry with both
`avb_keys` and `avb`: it tries the standalone AVB footer with the preloaded
keys first, and falls back to the top-level AVB chain only if that fails. On
an unlocked device, `fs_mgr` may permit an unknown standalone key unless
`/metadata/gsi/avb_enforce` exists. The actual lock state and that metadata
marker must be observed on this device before treating the test-key mismatch
as the root cause.

## Stock AVB Chain

The original `vbmeta_system.img` is `SHA256_RSA2048`, key SHA-1
`fa41159a5d696abdef93176a07d0b0d001263f01`, with product and system hashtree
descriptors. It declares Android 10 and the `2021-03-05` patch level.

The original top-level `vbmeta.img` is `SHA256_RSA2048`, key SHA-1
`cdbb77177f731920bbe0a0f94f84d9038ae0617d`, and chains `recovery`,
`vbmeta_system`, `vbmeta_vendor`, and `boot`. It also hashes `dtbo`.

Therefore, a replacement `vbmeta_system` signed with a different key cannot
be assumed to be equivalent to the stock chain merely because the device is
unlocked. First-stage handling of the inline system footer and top-level chain
must be validated separately.

## Observed AVB-Disabled GSI Boot

The captured September 15, 2026 GSI experiment provides a decisive boundary
condition. Its recovery properties report `ro.boot.verifiedbootstate=orange`.
The persisted kernel console records all of the following during first stage:

```text
[libfs_mgr]Created logical partition product on device /dev/block/dm-0
[libfs_mgr]Created logical partition system on device /dev/block/dm-1
[libfs_avb]Returning avb_handle with status: VerificationDisabled
Top-level vbmeta is disabled, skip Hashtree setup for /system
```

That boot mounted the GSI system and reached normal Android init, SELinux
policy compilation, VNDK detection, and PHH compatibility setup. Its later
shutdown is a clean `init` request for `reboot bootloader`, preceded by SysRq
shutdown messages; it is not an early AVB failure, dm-verity failure, or kernel
panic. The log also contains `magiskinit`, so that historical experiment used
a Magisk-patched boot image. The first-stage AVB result still occurs before the
captured second-stage Magisk setup, but this is not yet proof that the final
pair works with an untouched stock boot image.

A later read-only recovery capture resolves the ambiguity in that earlier
experiment. Its partition mapping identifies `sdc6` as `vbmeta`, `sdc7` as
`vbmeta_system`, and `sdc8` as `vbmeta_vendor`; all three are the same 4 KiB
image with SHA-256
`fd1cac764ef971200a5b955631e12eaa6695d4c626fa1ea4685009723d60b604`,
`Algorithm: NONE`, and `Flags: 3`. That hash is the output of the official
command:

```text
avbtool make_vbmeta_image --flags 3 --padding_size 4096
```

The same capture retains the unmodified stock `boot`, and its first 1 MiB of
`super` is byte-identical to the locally generated raw super. The final package
therefore deliberately reproduces this observed state: it generates three
separately named, byte-identical AVB-flags-3 images and directs each one to its
matching `vbmeta`, `vbmeta_system`, or `vbmeta_vendor` partition. This does not
prove every later Android runtime issue is solved, but it removes the stale
stock child-vbmeta chain as a remaining variable. The bootloader must stay
unlocked.

The historical manual file `output/device-dump/super_head_1MiB.img` is
1,048,656 bytes, not exactly 1 MiB: its first 1,048,576 bytes are the raw
super prefix and its final 80 bytes are `dd` diagnostics. Only the first 1 MiB
may be compared; its SHA-256 is
`493229b572dfb6dda3ead61439a3cc2531bc09cdd88c8f5f9bd2c3ffe3e104cf` and
matches the generated raw super. The current collection tool redirects `dd`
diagnostics before base64 encoding, writes the exact
`super-head-1MiB.img`, and the verifier checks its size-independent 1 MiB
prefix.

## Observed Misc Bootloader Command

TWRP maps `/misc` to `/dev/block/sdc2`. There are two distinct captured
nonempty bootloader-message commands:

```text
misc_before_final_boot_20260915.bin
  SHA-256 502408ef2705cab5d81839ffddeecf8971cb5741ab954329fa82bdf26b3b3caf
  command boot-fastboot

output/device-dump/clean/u90/sdc2.bin
  SHA-256 8ac9baa0ce2f52dda6debef8f8ffb4fcd8e85d44bf05882dbcb552dd06b46881
  command bootonce-bootloader

output/device-dump/clean/u90/misc_after.bin
  SHA-256 ad7facb2586fc6e966c004d7d1d16b024f5805ff7cb47c7a85dabd8b48892ca7
  command <empty>
```

The stock `lk-verified.img` independently contains the literal
`boot-fastboot` at file offset `0x0008d74c`, followed by the diagnostic
`[%s] Set misc partition to 0x%08x (%d bytes in %lu ms)\n` and the related
`boot-recovery` literal. This establishes `boot-fastboot` as an LK-known
misc boot-mode request, not a malformed dynamic-partition header or an AVB
error string. Static strings alone do not identify the caller that wrote it.

Separately, the successful GSI boot console records `init` completing a
`reboot bootloader` sequence before the kernel prints
`Restarting system with command 'bootloader'`. Together, these artifacts
prove that at least one historical transition into fastboot was an explicit
bootloader path, not an early AVB rejection. A test that reaches fastboot with
either nonempty command still present in `/misc` cannot be used to diagnose
the GSI `super` or AVB images. The original caller remains unknown.

The final recovery collector saves the first 4 KiB of `misc` as
`misc-bcb-4KiB.bin`; final verification refuses any nonempty command before
Android boot. If it reports `boot-fastboot`, `bootonce-bootloader`, or any
other nonempty command, clear only that 4 KiB bootloader-message area in the
TWRP terminal with
`dd if=/dev/zero of=/dev/block/by-name/misc bs=4096 count=1`, run `sync`, and
collect again. The stock scatter confirms that `misc` is a 0x00080000-byte
partition at 0x2008000, so this does not rewrite any dynamic partition.

The unpacked stock ramdisk and firmware declarative configuration files were
also searched for sys.powerctl, reboot bootloader, boot-fastboot, and
bootonce-bootloader. No init rc, shell, property, configuration, or text file
contains such an action. This rules out a visible declarative stock-init rule
that unconditionally requests bootloader mode, but it does not rule out a
native process, recovery action, or a caller outside the retained files.

## PHH TWRP Auto-Flash Trigger

The retained v4 GSI package contains PHH's legacy TWRP installation helper. Its
/etc/init/twrp.rc runs /system/bin/twrp.sh at post-fs. That script exits
immediately when /cache/phh/flash is absent. When that marker exists, it
consumes /cache/phh/block.map, writes a system payload, runs sync, and calls
reboot.

The captured historical GSI console shows /system/bin/twrp.sh starting at
about 9.081 seconds and exiting with status 0 roughly 6 ms later. That timing
is consistent with the marker being absent, so it is not evidence that the
historical reboot was caused by the helper. It does establish a separate
test-contamination path: a stale TWRP marker can alter system storage and
request a reboot before normal Android behavior is observed. If /misc also
contains a fastboot command, that normal reboot can still land in fastboot.

The recovery collector now records
phh_twrp_flash_trigger=present|absent and hashes marker metadata without
executing it. Final verification requires absent. If it reports present, do
not boot Android; inspect the capture, then manually remove only
/cache/phh/flash in TWRP, run sync, and collect/verify again.

The source recipe now removes the two copy rules for the helper rc and script
through 0002-u90-disable-legacy-twrp-autoflash.patch. It deliberately retains
busybox_phh because the PHH OTA and rw-system compatibility scripts reference
that binary. The artifact verifier and super packager reject a future system
image if either legacy helper file remains, so a rebuilt package can no longer
consume /cache/phh/flash and rewrite system during boot.

## MTK IMS One-Time Reboot Candidate

The pinned PHH v313 phh-on-boot service starts only after
sys.boot_completed=1. Its source checks for /vendor/bin/mtkmal and, when
either persist.mtk_ims_support or persist.mtk_epdg_support is 1, sets both
properties to 0 and calls a normal reboot. The stock super image contains
the mtkmal name and the persisted EPDG property string, which establishes
vendor support for this branch but not that the live device satisfies its
conditions.

This is a plausible one-time Android runtime reboot on this MT6779 device,
not an early AVB failure. If misc contains a boot-fastboot command at that
moment, the ordinary reboot can still land in fastboot. The runtime collector
therefore records the live mtkmal presence and both persisted properties in
every snapshot summary. Do not disable this compatibility branch without
first capturing those live values.

## Decoded PMSG Boundary

The two retained pmsg-ramoops-0 captures are byte-identical
(SHA-256 c6cbba45b6d83fb9db7908db1a887c708ac2fef03127fc9c1d38c3ececdba2da).
The local C++ parser decodes 606 records, all of which are the same
HidlServiceManagement wait for hwservicemanager.ready. It finds no
sys.powerctl, reboot, bootloader, critical, or fatal record. Their displayed
timestamps are from a device clock that is not independently correlated with
the final GSI attempt. This retained pmsg fragment therefore cannot identify
the source of a fastboot transition or prove a current hwservicemanager fault;
the separate console capture showing hwservicemanager.ready remains the
stronger boot-specific evidence.

## VINTF and SELinux Compatibility Check

The stock vendor manifest is `target-level="4"` (Android 10 / Q). The Android
11 GSI carries framework compatibility matrices through level 5, including
level 4. This does not prove complete runtime compatibility, but it rules out
the simple claim that the GSI lacks a Q-level framework matrix.

The vendor reports `plat_sepolicy_vers.txt` as `29.0`. The GSI contains both
`/etc/selinux/mapping/29.0.cil` and `29.0.compat.cil`. Therefore, the initial
SELinux mapping inputs exist; a runtime compilation or policy denial still
requires logs before it can be blamed.

## Direct Vendor HAL Dependency Check

The 41 ELF executables under stock `vendor/bin/hw` were extracted read-only
with `debugfs` and inspected with `readelf`. Their direct `DT_NEEDED` set has
141 unique SONAMEs. Comparing it against stock vendor libraries, GSI system
libraries, and the GSI flattened APEX libraries resolves 140 names. The one
remaining name is `libavservices_minijail_vendor.so`; its location still needs
to be traced before it is classified as missing. This substantially weakens
the broad "all Android 10 vendor libraries are absent from the Android 11
GSI" hypothesis, while leaving room for transitive or symbol-level failures.

## Root-Manager Boundary

The `treble_arm64_bvN` output does not contain `/system/bin/phh-su`, a
SuperUser APK, or Magisk artifacts. It does contain the PHH internal
`resetprop_phh` helper and its `phhsu_daemon` SELinux domain. That helper is
used by `apex-setup.rc` to set the detected VNDK version before linkerconfig
is regenerated. It is not a user-facing root manager, and removing it without
an equivalent VNDK-property mechanism would be an independent boot-risking
change. Keep the current no-`phh-su` / no-SuperUser contract while retaining
the compatibility helper unless a replacement is separately validated.

`gsi/scripts/verify-u90-artifact.sh` now checks the exported system-as-root
ext4 image, not only the pre-export system tree, for `phh-su` and
root-management package names under both the legacy `/bin`, `/xbin`, `/app`,
and `/priv-app` paths and the system-as-root `/system/bin`, `/system/xbin`,
`/system/app`, and `/system/priv-app` equivalents. It also requires
`/system/bin/init`, because the stock U90 first-stage init execs that path
unconditionally and a missing file panics back to fastboot.

The current `system_gsi.img` passes the complete verifier, including the
tablet, Chinese locale, Fcitx5, camera-orientation, root-manager,
`/system/bin/init`, and `e2fsck -fn` checks.

## Runtime Baseline

On September 16, 2026, the connected device enumerated as normal Android MTP:

```text
USB\VID_0E8D&PID_2008\<device-serial>
Class=WPD
FriendlyName=Youxuepai
Status=OK
```

No `adb` or `fastboot` transport was active at that time. This establishes a
healthy stock-boot baseline without changing device state.

## radare2 Baseline

Local `r2` is available at:

```text
<radare2-exe>
radare2 6.2.0
```

Static string analysis of `lk-verified.img` finds AVB 2.0 / `libavb` code,
including `avb_slot_verify`, vbmeta error paths, `boot-fastboot`, and watchdog
strings. This proves only that LK contains those code paths. It does not prove
which branch executes for this unlocked device. The prior claim that LK has no
AVB implementation is not supported and must not be used as a premise.

The stock boot image exposes `console=ttyS0,921600n1`, making UART the most
direct way to distinguish first-stage mount failure from an init watchdog.

## Next Evidence Steps

1. Run `tools/collect-u90-recovery-state.ps1` while the device is already in
   TWRP. It is read-only and records boot lock/AVB state, hashes for boot,
   dtbo, and vbmeta partitions, the `/metadata/gsi/avb_enforce` marker,
   logical-device mappings, a 1 MiB raw-super metadata capture, recovery
   commands, a binary misc BCB capture, and complete persisted logs. Use
   `-FullLogicalHashes` during the final test to hash the mounted product,
   system, and vendor logical partitions.
2. When testing a complete package, change only the generated `super` and all
   three generated AVB-flags-3 vbmeta partitions, then collect the resulting
   recovery state before changing another partition. Run
   `verify-u90-recovery-state.ps1 -RequireDynamicPartitionProof` against that
   capture before attempting Android boot; it also requires an empty misc
   bootloader-message command.
3. Before selecting Reboot System in TWRP, start
   tools/capture-u90-runtime-reboot.ps1 on the host. It waits for Android adb,
   then captures all logcat buffers plus read-only property/process snapshots.
   If the device returns to fastboot, preserve reboot-signals.txt and
   logcat-all.txt; a Received sys.powerctl line identifies an explicit init
   reboot request, while critical-service/fatal messages distinguish an init
   fallback from an AVB-stage failure.
4. If that boot attempt returns to fastboot or loses adb, enter TWRP without
   reflashing, run the same full collector again, and compare the verified
   pre-boot and post-attempt captures with
   tools/compare-u90-boot-attempt.ps1. A newly nonempty misc command is an
   independent LK fastboot cause; unchanged partitions plus a new persistent
   reboot signal instead point to Android or init.
5. Compare DT_NEEDED and exported SONAMEs for vendor HALs against the GSI only
   if the package pair reaches Android init and still exposes a runtime fault.
