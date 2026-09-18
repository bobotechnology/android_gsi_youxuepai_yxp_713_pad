# Changelog

All notable changes to this build recipe are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

No release tag exists yet, so every entry is still under `Unreleased`. The
commit hashes refer to this repository and are listed so each claim can be
checked against the commit that made it.

## [Unreleased]

### Added

- Pinned Android 11 PHH/Treble `v313` build recipe for the Youxuepai U90
  (`yxp_713_pad`, MT6779): the release manifest, per-tree source revisions, and
  the device patch set. (`38a90ba`)
- Chinese and settings defaults: `zh-CN` product and persistent locale,
  `Asia/Shanghai`, 24-hour time, auto-rotation enabled, and the default display
  timeout raised from 60 seconds to 5 minutes. (`38a90ba`)
- Front-camera sensor orientation override through
  `ro.u90.camera.front.orientation`, applied to both the camera metadata and the
  API1 camera info, and only to a front-facing camera. (`38a90ba`)
- Mainland captive-portal validation endpoints for NetworkStack, including the
  MCC 460 resource defaults, so a Chinese SIM cannot restore a Google endpoint.
  (`cf83e2d`)
- `PRODUCT_CHARACTERISTICS := tablet`. (`da37f93`)
- Tablet UI: a Material-blue framework default accent with matching SystemUI
  notification-shade palettes, plus a `6 x 5` Launcher3 workspace with a
  six-icon dock. (`d9926a0`)
- Pinned Fcitx5 Android `0.1.3`, verified by SHA-256 and staged as the
  presigned, non-privileged system app `U90Fcitx5`. (`d9926a0`)
- Vendor input gate: AOSP SurfaceFlinger now writes the `BOOT_Animation:END`
  bootprof marker that the stock kernel waits for before it unmutes the Himax
  touchscreen. (`86e8511`)
- Front camera lift: `CameraService` raises and retracts the module through
  `/dev/NOAH_MOTOR` on front-camera connect and disconnect. (`86e8511`)
- `u90-motor`, a manual bring-up tool for the lift, carrying the
  reverse-engineered `0x40c44d01` request and its mode argument. (`86e8511`)
- SELinux rule permitting `cameraserver` to use the `noah_motor_device`
  character device. (`86e8511`)
- `validate-recipe.sh` guards that reject a return to the empty-stub motor
  requests `nr 2` and `nr 8`. (`86e8511`)

### Changed

- Build the raw system-as-root product image instead of converting to A-only
  with `sas-creator`. The A-only output has no `/system/bin/init`, which the
  stock ramdisk first-stage init execs unconditionally, so every packaged
  `super` panicked back to fastboot. (`3dbc904`)
- Target the rootless PHH-compatible `treble_arm64_bvN-userdebug` product.
  (`cc9f18b`, `241745c`, `44bb69e`)
- Generate the PHH products inside the device directory and build through the
  AOSP wrapper. (`f1239e7`, `33aea0c`)
- Skip unused FOSS app generation for the vanilla GSI. (`81d5cf1`)
- Install `xmlstarlet` for FOSS generation. (`83a66a7`)
- The local Docker helper assumes no proxy. Local proxy overrides belong in an
  untracked `.env` file instead of a hardcoded default.
- Move the investigation and build records to `docs/records/`, leaving the
  long-lived references in `docs/`.
- License the recipe under Apache-2.0 and add the repository metadata files
  (`CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`, issue and pull
  request templates) plus `docs/FLASHING.md`.
- Build locally only. The `Build U90 Android 11 GSI` workflow has been removed:
  across its 12 GitHub-hosted runs it never completed, and the last attempt was
  cancelled at exactly the 360-minute job limit, because syncing and compiling
  AOSP 11 does not fit a GitHub-hosted runner's time and disk budget. The local
  Docker path already covers source sync, patching, build verification, and
  packaging, so nothing was lost; `validate-recipe.sh` still runs on every local
  build.

### Removed

- The legacy PHH TWRP auto-flash rc and script, which only ran when
  `/cache/phh/flash` existed. Both the artifact verifier and the packager now
  reject a build that still contains them. (`3dbc904`)
- The `sas-creator` and `vendor_vndk` pins. (`3dbc904`)
