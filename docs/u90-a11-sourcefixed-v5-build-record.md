# U90 source-fixed v5 build and package record

## Superseded

This v5 path used the `sas-creator` A-only conversion and is superseded. Its
A-only output has no `/system/bin/init`, so the device panicked back to fastboot
on every boot and the artifact is not bootable. See
`docs/u90-a11-v313-sar-build-record.md` for the root cause and the validated
system-as-root build path.

This record covers the locally built Android 11 GSI and its complete dynamic
partition package. It is a build/package record only. It does not claim a
successful physical-device boot until the recovery and runtime evidence listed
below has been collected.

## Artifact identity

- Build directory: `artifacts/local/u90-a11-sourcefixed-v5`
- Complete package: `artifacts/local/u90-a11-sourcefixed-v5-package`
- Build product: `treble_arm64_bvN-userdebug`
- PHH baseline: `v313`, `device/phh/treble` commit
  `d0355b6dd57b4cba3d01a39866ad3552eba173e0`
- Front camera property: `ro.u90.camera.front.orientation=90`
- System SHA-256:
  `c353f8e234f4285a2d29c2923059868cbb0387277385d92b884a6277ca26ed77`
- Sparse super SHA-256:
  `5e7380bd27144b402b3320ae06224698366c5e0592f0ee55dcd784b052c7d951`
- Raw super SHA-256:
  `540a08014b62e0ccf02c8a6ad5610d7c5f0cb9967bb56897482dfab41738c03e`

The authoritative build metadata is `build-info.txt`; the authoritative package
input/output hashes and dynamic-partition proof are in `PACKAGE-MANIFEST.txt`.

## Verified package invariants

The local Docker packager completed with Android host `lpdump`, `lpmake`,
`lpunpack`, `simg2img`, and `avbtool` from the pinned Android source checkout.

- The raw super image is exactly `8589934592` bytes (8 GiB) and contains
  `product`, `system`, and `vendor` logical partitions.
- The packaged `system_gsi.img` SHA-256 is identical to the build input.
- Stock `product` and `vendor` were byte-compared after packaging.
- All three generated vbmeta images are 4096 bytes, use AVB algorithm `NONE`,
  and have flags `3`.
- `system_gsi.img` contains neither `/etc/init/twrp.rc` nor `/bin/twrp.sh`.
  The source patch removes PHH's legacy recovery auto-flash action while
  retaining `busybox_phh` for unrelated compatibility scripts.
- `system_gsi.img` contains no `phh-su`, Magisk, SuperUser, or SuperSU package.
- The package does not include a replacement `boot`, `dtbo`, kernel, recovery,
  preloader, or userdata image.

The selected SP Flash Tool rows and the exact TWRP raw-image warning are in
`FLASH-PLAN.txt`. Use `super_u90_gsi.sparse.img` only through the scatter
workflow. If TWRP `dd` is required, use only `super_u90_gsi.raw.img`.

## Stock immutable references

`PACKAGE-MANIFEST.txt` records these expected stock hashes for later recovery
verification:

- `boot.img`: `e4348ab68c37b6b1cd063e797d838b090a0f226ec930738e6d41e86154dd68d9`
- `dtbo-verified.img`: `15b9bc4d29df8cb4be0d20799563743bd5715c24ee329609673237da8b407a99`

The package itself cannot prove that a physical device still has these values.
That proof must come from a TWRP read-only capture after flashing.

## Historical misc BCB and AVB evidence

Two preserved historical misc captures begin with the Android bootloader-message
command `boot-fastboot`:

- `misc_bcb_before_gsi_20260915.bin`
  (`27621ff0ccbfbb8c4a5960798282107d43f9c1f135698ad90bd72047735ba300`)
- `misc_before_final_boot_20260915.bin`
  (`502408ef2705cab5d81839ffddeecf8971cb5741ab954329fa82bdf26b3b3caf`)

Both report `mediatek,amms` in the adjacent status field. The stock
`lk-verified.img` also contains the `boot-fastboot` target string. A nonempty
historical BCB is therefore a real fastboot confounder independent of the
contents of `system` or AVB. It must be captured and checked before each
one-variable boot attempt; do not infer AVB failure merely from reaching
fastboot.

Separately, a preserved kernel pstore record shows first-stage init returning
`VerificationDisabled`, skipping the top-level vbmeta hashtree for `/system`,
and disabling AVB hashtree handling for `/vendor`. This proves that an
AVB-disabled configuration reached those early-mount paths in that historical
boot. It is not a substitute for verifying the new package on the tablet.

## Historical v4 auto-flash hazard

The retained `u90-a11-final-avb3-v4-20260916` package is diagnostic-only, not
an alternative final package. Direct ext4 inspection found both
`/etc/init/twrp.rc` and `/bin/twrp.sh` in its system image. The old rc executes
the script, and the script tests for `/cache/phh/flash`, invokes
`busybox_phh dd` in its flash path, and issues ordinary `reboot` calls.

The source-fixed v5 system was inspected the same way and has neither file.
This proves that a stale legacy PHH marker could have caused a write/reboot
path in the older image. It does not, by itself, prove that the marker was the
actual cause on this tablet; the required recovery and runtime captures below
remain the physical-device proof.

## Verifier gate tests

The read-only verifier was exercised against two local fixtures before using it
on the tablet:

- `output/verification/bcb-verifier-real-capture-20260916` uses a real
  preserved 4 KiB historical misc capture. It accepts the matching immutable
  package hashes but rejects the `boot-fastboot` BCB command.
- `output/verification/sourcefixed-v5-verifier-synthetic-pass-20260916` is a
  synthetic local fixture assembled from this package manifest and the first
  MiB of the generated raw super image. It passes all fixed-partition, logical
  partition, super metadata, clear-BCB, and absent-trigger checks.

The second fixture tests verifier coverage only; it is explicitly not a
physical-device capture and cannot establish a successful boot.

## Required physical-device evidence

Before booting Android, enter TWRP with ADB enabled and collect a full state:

```powershell
.\tools\collect-u90-recovery-state.ps1 -FullLogicalHashes

.\tools\verify-u90-recovery-state.ps1 `
  -RecoveryState <capture-dir>\recovery-state.txt `
  -PackageDir .\artifacts\local\u90-a11-sourcefixed-v5-package `
  -RequireDynamicPartitionProof
```

The pre-boot capture must show the expected package hashes and an empty misc
bootloader-message command. If it does not, do not attribute a subsequent
fastboot transition to AVB and do not reflash another image yet.

After the verifier passes, start this host-side read-only collector, manually
choose **Reboot System** in TWRP, and preserve its output:

```powershell
.\tools\capture-u90-runtime-reboot.ps1 -CaptureSeconds 420
```

If Android returns to fastboot or ADB disappears, return to TWRP without
reflashing, collect a second full recovery state, and compare it with the
verified pre-boot state:

```powershell
.\tools\compare-u90-boot-attempt.ps1 `
  -BeforeRecoveryState <before-capture>\recovery-state.txt `
  -AfterRecoveryState <after-capture>\recovery-state.txt
```

Only that sequence can distinguish a misc BCB bootloader command, a runtime
ordinary reboot such as the MTK IMS path, an unexpected partition change, and
an AVB-related boot failure.
