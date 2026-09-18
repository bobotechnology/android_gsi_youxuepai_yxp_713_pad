# Android 11 GSI for the Youxuepai U90 (yxp_713_pad)

**English** | [简体中文](README.md)

[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
![Android](https://img.shields.io/badge/Android-11-green.svg)
![Device](https://img.shields.io/badge/device-yxp__713__pad%20%2F%20MT6779-lightgrey.svg)

A pinned Android 11 PHH/Treble GSI build recipe for the Youxuepai U90
(`yxp_713_pad`, MT6779).

This device gates its touchscreen and its front camera on private stock
behaviour. Flashing a generic GSI onto it produces a system with a dead
touchscreen and a front camera that never appears. This repository restores that
behaviour while leaving the stock `boot`, `dtbo`, kernel, and `vendor` in place.

## What this is

- A **reproducible build recipe** pinned to PHH `v313` / `android-11.0.0_r48`,
  with a revision for every source tree. The build verifies the release manifest
  by SHA-256 before it syncs anything.
- A **device-specific patch set** against `frameworks/*`, `system/core`, and
  `device/phh/treble`. Every patch exists because of something observed on the
  device.
- A **local packaging toolchain** that combines the built `system` with the stock
  `product` and `vendor` into a complete `super`, plus the matching vbmeta images
  and a flash plan.

## What this is not

- **Not a generic GSI framework.** It serves `yxp_713_pad` only. Nearly every
  value in this repository — partition geometry, camera id, motor protocol,
  bootprof marker — was measured on this device and loses its basis without it.
- **Not a firmware package.** No stock images, no partition dumps, no signing
  material.
- **No root.** The build targets the `N` variant and bundles no `phh-su`, Magisk,
  or root manager.
- **No kernel or `vendor` changes.** Only `super` and the vbmeta images are
  replaced.

## Status

| Feature | State | Notes |
| --- | --- | --- |
| Touchscreen | Verified | Requires the bootprof gate patch; otherwise completely unresponsive |
| Front camera (camera id 1) | Verified | The physical front camera is id 1, not id 0 |
| Front camera lift | Verified | Raises when a front camera session starts, retracts on disconnect |
| Manual motor control | Verified | `u90-motor` with `status`, `up`, `ar`, `down`, `stop` |
| Chinese input method | Verified | Fcitx5; must be enabled once by hand |
| Tablet UI | Verified | Tablet characteristic, Material palette, `6 x 5` workspace |
| Mainland network validation | Verified | Validation endpoints replaced with reachable ones |
| Complete `super` packaging | Verified | Byte-identity checks against stock `product`/`vendor` |
| Rear camera | Unverified | Not specifically tested |
| Wi-Fi / Bluetooth / audio / sensors | Unverified | Not individually tested |
| Root | Not provided | Patch and flash a boot image yourself if you need it |

## Compatibility and requirements

| Item | Requirement |
| --- | --- |
| Device | Youxuepai U90 / `yxp_713_pad` |
| SoC | MediaTek MT6779 |
| Partitions | Non-A/B dynamic partitions; `super` is 8 GiB, `misc` is 512 KiB |
| Bootloader | Must be unlocked, `ro.boot.verifiedbootstate=orange` |
| Recovery | TWRP 3.7.1_12-0 or later, with device tree `61810b9` or later |
| Stock firmware | A package such as `P713mt6779_20221129_2216`; required to package `super` and to roll back |

## Quick start

There is no online CI. Syncing and compiling AOSP 11 exceeds the time and disk
budget of a GitHub-hosted runner, so building, packaging, and verification all
run locally in Docker.

### 1. Build the `system` image

```powershell
.\gsi\scripts\run-local-docker.ps1 -FrontSensorOrientation 90 -Jobs 12 -BuildName u90-a11-v5
```

The output lands in `artifacts/local/u90-a11-v5/`, and `system_gsi.img` is the
image the next step consumes.

### 2. Package `super` locally

`super` needs the stock `product` and `vendor` you supply yourself:

```powershell
.\gsi\scripts\run-local-docker.ps1 `
  -Mode package `
  -BuildName u90-a11-v5 `
  -FirmwareDir C:\path\to\P713mt6779_20221129_2216 `
  -PackageName u90-a11-v5-package
```

### 3. Flash

```bash
fastboot flash vbmeta         vbmeta_u90_avb_disabled.img
fastboot flash vbmeta_system  vbmeta_system_u90_avb_disabled.img
fastboot flash vbmeta_vendor  vbmeta_vendor_u90_avb_disabled.img
fastboot flash super          super_u90_gsi.sparse.img
fastboot reboot
```

The full procedure, post-flash verification, and rollback live in
**[docs/FLASHING.md](docs/FLASHING.md)**. Three rules from it up front: **never
`dd` the sparse image**, **never flash a vbmeta image to the wrong partition**,
and **change one variable at a time**.

## Local build options

The Android source, `out/`, ccache, and the manifest cache live in Docker named
volumes, so repeat builds are incremental. Besides the full build above, three
modes are available:

```powershell
# Validate the container recipe without syncing Android source; takes seconds
.\gsi\scripts\run-local-docker.ps1 -Mode validate

# Sync the source, manifest, and Fcitx5 APK without compiling
.\gsi\scripts\run-local-docker.ps1 -Mode sync

# Package super only
.\gsi\scripts\run-local-docker.ps1 `
  -Mode package `
  -BuildName u90-a11-v5 `
  -PackageName u90-a11-v5-package
```

No proxy is assumed. When you need one, create an untracked `.env` at the
repository root:

```text
HTTP_PROXY=http://host.docker.internal:<port>
HTTPS_PROXY=http://host.docker.internal:<port>
```

Alternatively pass `-Proxy <url>` for one run, or `-NoProxy` for direct access.
Do not place the Android source on a `C:\` bind mount; only `artifacts/local` is
mounted back to Windows.

See [gsi/README.md](gsi/README.md) for the inputs and the artifact format.

## Stock behaviour this recipe restores

| Symptom | Root cause | What this repository does |
| --- | --- | --- |
| Touchscreen completely unresponsive | The kernel powers the Himax touchscreen only after `BOOT_Animation:END` appears in `/proc/bootprof`. The stock MediaTek SurfaceFlinger wrote that marker; AOSP never does | Write the marker from AOSP SurfaceFlinger (`frameworks/native` patch) |
| Front camera never appears | The front module sits on a lift that the stock stack raised on an app-launch broadcast | `CameraService` raises and retracts the lift through `/dev/NOAH_MOTOR` on front camera connect and disconnect (`frameworks/av` patch) |
| Front camera orientation wrong | The vendor HAL reports `270`; the module needs `90` | `ro.u90.camera.front.orientation` (`90` by default) overrides the metadata and the API1 camera info |
| Every GSI boot returns to fastboot | The `sas-creator` A-only output has no `/system/bin/init`, which the stock ramdisk first-stage init execs unconditionally | Export the raw system-as-root product directly, with no A-only conversion |
| Network shows connected but unreachable | NetworkStack validates against a Google endpoint that is unreachable from mainland China | Point validation at reachable endpoints and replace the MCC 460 resource defaults |
| Chinese defaults missing | English locale, 60-second screen timeout, rotation locked | `zh-CN`, `Asia/Shanghai`, 24-hour time, auto-rotation, 5-minute timeout |
| UI is not tablet-shaped | Phone layout by default | `PRODUCT_CHARACTERISTICS := tablet` plus a Material palette and a `6 x 5` workspace |
| No Chinese input method | None bundled | Pin Fcitx5 Android `0.1.3`, verify its SHA-256, and install it as a presigned system app |

The motor protocol deserves a note of its own. The driver subtracts `0x40c44d00`
from the whole command word and indexes a 17-entry jump table. That table holds
exactly **one** real movement command, `0x40c44d01`, and takes the target as its
argument (`1` top / `2` bottom / `3` selfie). The `nr 2` and `nr 8` requests that
the stock factory-test library uses for the lower two modes are empty stubs: they
return 0 and do nothing. That stub trap cost this project the most time, and
`validate-recipe.sh` now guards against a regression to it. The derivation is in
[docs/u90-vendor-gate-and-motor-design.md](docs/u90-vendor-gate-and-motor-design.md).

## Known limitations

- **The first frames of a front camera session may catch the module mid-travel.**
  The lift takes about 1.3 s, and the hook runs at `connect()`, so the sensor
  opens while the motor has only just started. The stock stack avoided this by
  raising the lift on an app-launch broadcast; that heuristic is not reproduced
  here.
- **No root.** The `N` variant carries neither `phh-su` nor a root manager. The
  pinned base requires `userdebug` (PHH `v313` sets
  `SELINUX_IGNORE_NEVERALLOWS := true`), so `adb root` may work, but no `su`
  binary is installed persistently.
- **`screencap` cannot capture hardware overlay layers**, so screenshots come out
  black. That is not a display fault.
- **A black front camera frame in dim light is expected**, not a failure.
- If Launcher3 keeps an older data directory, an in-place upgrade may retain the
  old grid. Clear Launcher3 storage once and return to Home.

## Repository layout

```text
.
├── .github/
│   ├── ISSUE_TEMPLATE/            # bug and feature request forms
│   └── PULL_REQUEST_TEMPLATE.md
├── docker/Dockerfile              # local build image
├── docker-compose.yml             # source/out/ccache on named volumes
├── docs/
│   ├── FLASHING.md                # flashing and rollback
│   ├── stock-firmware-baseline.md # stock firmware and partition geometry evidence
│   ├── u90-vendor-gate-and-motor-design.md
│   └── records/                   # investigation records
├── gsi/
│   ├── config/u90-a11-v313.env    # pinned source revisions
│   ├── patches/<tree>/NNNN-*.patch
│   ├── scripts/                   # validate, patch, build, package
│   ├── templates/                 # Fcitx5 staging and SELinux rules
│   ├── tools/u90-motor/           # manual lift control tool
│   └── README.md                  # recipe details
└── tools/                         # device state capture and comparison scripts
```

## Documentation

| Document | Contents |
| --- | --- |
| [docs/FLASHING.md](docs/FLASHING.md) | Unlock, flash, first boot, post-flash verification, rollback |
| [gsi/README.md](gsi/README.md) | Baseline, patch list, artifact format, packaging |
| [docs/u90-vendor-gate-and-motor-design.md](docs/u90-vendor-gate-and-motor-design.md) | Touch gate and lift design, kernel reverse-engineering evidence, verification ladder |
| [docs/stock-firmware-baseline.md](docs/stock-firmware-baseline.md) | Stock firmware package, partition table, and LK evidence |
| [docs/records/](docs/records/) | Build records and the controlled fastboot experiments, including failed attempts |
| [CHANGELOG.md](CHANGELOG.md) | Change history |
| [CONTRIBUTING.md](CONTRIBUTING.md) | How to contribute, and the scope boundary |

## Third-party components and licensing

This repository is licensed under **Apache-2.0**; see [LICENSE](LICENSE).

The build output contains the following third-party components:

| Component | License | Notes |
| --- | --- | --- |
| AOSP Android 11 (`android-11.0.0_r48`) | Apache-2.0 | The patches apply to it |
| PHH treble_experimentations `v313` | **Not declared** upstream | Only the published manifest and patch targets are referenced; no code is copied, but the output contains PHH components |
| Fcitx5 Android `0.1.3` | LGPL-2.1 | Downloaded from a pinned URL, verified by SHA-256, and bundled **unmodified** as a presigned system app |
| Stock `product` / `vendor` | Vendor proprietary | **Not distributed here**; supply your own firmware package when packaging |

If you redistribute an image you built, the LGPL and PHH obligations — including
license notices and source availability — are yours to satisfy.

## Credits

- [phhusson/treble_experimentations](https://github.com/phhusson/treble_experimentations) — the GSI and patch trees this recipe builds on
- [fcitx5-android](https://github.com/fcitx5-android/fcitx5-android) — the Chinese input method
- TWRP device tree [bobotechnology/twrp_device_youxuepai_yxp_713_pad](https://github.com/bobotechnology/twrp_device_youxuepai_yxp_713_pad) — the corrected `super` partition geometry
