# Android 11 GSI for the Youxuepai U90 (yxp_713_pad)

**English** | [简体中文](README.md)

[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

An Android 11 PHH/Treble GSI build recipe for the Youxuepai U90 (`yxp_713_pad`,
MT6779). It serves this one device only.

The vendor locks the touchscreen and the front camera behind private behaviour.
The kernel powers the Himax touchscreen only after `BOOT_Animation:END` appears
in `/proc/bootprof`, and the front camera sits on a lift motor driven through
`/dev/NOAH_MOTOR` that the stock stack raised on an app-launch broadcast. AOSP
does neither, so a generic GSI boots here with a dead touchscreen and no front
camera. This repository restores that behaviour, replacing only `super` and the
vbmeta images and keeping the stock `boot`, `dtbo`, kernel, and `vendor`. It
provides no root and contains no firmware or signing material.

## Status

Verified on hardware: touchscreen, front camera output (the physical front
camera is id 1), automatic lift, manual motor control, Fcitx5 Chinese input,
tablet UI, mainland validation endpoints, complete `super` packaging.

Not individually tested: the rear camera, and Wi-Fi, Bluetooth, audio, sensors.

## Requirements

| Item | Requirement |
| --- | --- |
| Device | Youxuepai U90 / `yxp_713_pad` (MT6779) |
| Partitions | Non-A/B dynamic partitions; `super` 8 GiB, `misc` 512 KiB |
| Bootloader | Unlocked, `ro.boot.verifiedbootstate=orange` |
| Recovery | TWRP 3.7.1_12-0 or later, device tree `61810b9` or later |
| Stock firmware | A package such as `P713mt6779_20221129_2216`; needed to package `super` and to roll back |

## Build and package

Everything runs locally in Docker. Syncing and compiling AOSP 11 does not fit a
GitHub-hosted runner's budget, so there is no CI here.

```powershell
# Build system
.\gsi\scripts\run-local-docker.ps1 -FrontSensorOrientation 90 -Jobs 12 -BuildName u90-a11-v5

# Package a complete super from the stock product and vendor
.\gsi\scripts\run-local-docker.ps1 `
  -Mode package `
  -BuildName u90-a11-v5 `
  -FirmwareDir C:\path\to\P713mt6779_20221129_2216 `
  -PackageName u90-a11-v5-package
```

`-Mode validate` checks the recipe only and takes seconds; `-Mode sync` fetches
the source and the Fcitx5 APK without compiling. Output lands in
`artifacts/local/`; see [gsi/README.md](gsi/README.md) for the inputs and the
artifact format.

When you need a proxy, create an untracked `.env` at the repository root:

```text
HTTP_PROXY=http://host.docker.internal:<port>
HTTPS_PROXY=http://host.docker.internal:<port>
```

## Flash

```bash
fastboot flash vbmeta         vbmeta_u90_avb_disabled.img
fastboot flash vbmeta_system  vbmeta_system_u90_avb_disabled.img
fastboot flash vbmeta_vendor  vbmeta_vendor_u90_avb_disabled.img
fastboot flash super          super_u90_gsi.sparse.img
fastboot reboot
```

Three rules: never `dd` the sparse image, never flash a vbmeta image to the
wrong partition, and change one variable at a time. The full procedure,
post-flash verification, and rollback are in [docs/FLASHING.md](docs/FLASHING.md).

## What the patches do

| Symptom | Root cause | Fix |
| --- | --- | --- |
| Touchscreen completely unresponsive | The kernel powers the Himax touchscreen only after `BOOT_Animation:END` appears in `/proc/bootprof`; the stock MTK SurfaceFlinger wrote that marker, AOSP does not | Write the marker from AOSP SurfaceFlinger |
| Front camera never appears | The front module sits on a lift motor that the stock stack raised on an app-launch broadcast | `CameraService` raises and retracts it through `/dev/NOAH_MOTOR` on front camera connect and disconnect |
| Front camera orientation wrong | The vendor HAL reports `270`; the module needs `90` | `ro.u90.camera.front.orientation` (default 90) overrides the metadata and the API1 camera info |
| Every GSI boot returns to fastboot | The `sas-creator` A-only output has no `/system/bin/init`, which the stock ramdisk first-stage init execs unconditionally | Export the raw system-as-root product, with no A-only conversion |
| Network connected but unreachable | NetworkStack validates against a Google endpoint, unreachable from mainland China | Point validation at reachable endpoints and replace the MCC 460 resource defaults |
| Chinese defaults missing | English locale, 60-second screen timeout, rotation locked | `zh-CN`, `Asia/Shanghai`, 24-hour time, auto-rotation, 5-minute timeout |
| UI is not tablet-shaped | Phone layout by default | `PRODUCT_CHARACTERISTICS := tablet`, with a Material palette and a `6 x 5` workspace |
| No Chinese input method | None bundled | Fcitx5 Android `0.1.3`, SHA-256 verified and installed as an ordinary system app (enable it once by hand) |

The motor protocol deserves a note. The driver subtracts `0x40c44d00` from the
whole command word and indexes a 17-entry jump table. That table holds one real
movement command, `0x40c44d01`, and takes the target as its argument (`1` top /
`2` retract / `3` selfie). The stock factory-test library sends the lower two
modes to `nr 2` and `nr 8`, which are empty stubs in this kernel: they return 0
and do nothing. After falling into that trap, `validate-recipe.sh` gained a guard
against regressing to it. The derivation is in
[docs/u90-vendor-gate-and-motor-design.md](docs/u90-vendor-gate-and-motor-design.md).

## Known issues

- The lift takes about 1.3 s and the hook runs at `connect()`, so the sensor
  opens while the motor has only just started and the first frames of a session
  may catch it mid-travel. The stock stack raised the lift earlier, on an
  app-launch broadcast; that heuristic is not reproduced here.
- No root. The `N` variant carries no `phh-su` and no root manager; patch a boot
  image yourself if you need one.
- `screencap` cannot capture hardware overlay layers, so screenshots come out
  black. That is not a display fault. A black front camera frame in dim light is
  likewise expected.
- If Launcher3 keeps an older data directory, an in-place upgrade may retain the
  old grid. Clear Launcher3 storage once and return to Home.

## Layout

```text
gsi/
├── config/u90-a11-v313.env     # pinned source revisions
├── patches/<tree>/NNNN-*.patch # device patches
├── scripts/                    # validate, patch, build, package
├── templates/                  # Fcitx5 staging and SELinux rules
├── tools/u90-motor/            # manual lift control tool
└── README.md                   # recipe details: baseline, artifacts, packaging
docs/
├── FLASHING.md                 # unlock, flash, first boot, verify, rollback
├── u90-vendor-gate-and-motor-design.md  # touch gate and lift design, kernel evidence
├── stock-firmware-baseline.md  # stock firmware, partition table, LK evidence
└── records/                    # build records and the controlled fastboot experiments
tools/                          # device state capture and comparison scripts
docker/  docker-compose.yml     # local build environment
```

## License and credits

Apache-2.0; see [LICENSE](LICENSE).

The build output also contains: [AOSP Android 11](https://source.android.com/)
`android-11.0.0_r48` (Apache-2.0); [PHH treble_experimentations](https://github.com/phhusson/treble_experimentations)
`v313` (no license declared upstream); and [Fcitx5 Android](https://github.com/fcitx5-android/fcitx5-android)
`0.1.3` (LGPL-2.1, downloaded from a pinned URL, verified, and bundled
unmodified). The stock `product` and `vendor` remain the vendor's and are not
distributed here. If you redistribute an image you built, those obligations are
yours.

The TWRP device tree
[bobotechnology/twrp_device_youxuepai_yxp_713_pad](https://github.com/bobotechnology/twrp_device_youxuepai_yxp_713_pad)
provides the corrected `super` partition geometry.
