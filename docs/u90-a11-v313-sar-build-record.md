# U90 Android 11 v313 system-as-root build record

This record fixes the bootable build path for the U90 (`yxp_713_pad`) Android 11
GSI in the pipeline. It replaces the earlier `sas-creator` A-only conversion,
which produced a non-bootable image.

## Root cause

The stock U90 `boot.img` ramdisk first-stage init unconditionally executes
`execv("/system/bin/init")`. When that path is missing, first-stage init panics
and the bootloader falls back to fastboot.

The previous pipeline ran the freshly built AB product through
`phhusson/sas-creator`, which repacked it as an A-only image `s.img`. That
artifact has no `/init` and no `/system/bin/init`; its root directory contains
`bin/`, `etc/`, and `framework/` directly. Flashing it therefore hit the
unconditional exec and returned to fastboot on every boot (the P2 behaviour).
The evidence for that run is
`output/fastboot-controlled-20260917/p2-super-20260917-103054`.

The fix is to stop converting. The unmodified build product
`$PRODUCT_OUT/system.img` is already system-as-root: its root contains
`init -> /system/bin/init`, and `/system/bin/init` really exists. That image is
the one the packager must consume.

## Verified on hardware

The same-source system-as-root system image was packed into a `super` package
and flashed in a single controlled run. The device booted Android 11 and stayed
up:

- `sys.boot_completed=1`
- `ro.build.version.sdk=30`
- `ro.build.version.release=11`
- `/` is mounted from `/dev/block/dm-1` (the logical `system` partition)
- `ro.boot.verifiedbootstate=orange`

The decisive run directory is
`output/fastboot-controlled-20260917/p5-flash-20260917162825`. The stock repack
baseline that separates "Android 10 stock boots" from any GSI claim is
`output/fastboot-controlled-20260917/p4-resume-20260917-134550`.

## Key hashes

- Raw system-as-root image: `1516843008` bytes,
  SHA-256 `583c3f597978659eb05d2e91155bb0c7b326ea247d38c4aea3596dff09e6961f`
- Sparse super: `2441184752` bytes,
  SHA-256 `bcf84a6221d38850a0282f1df328b6bafddc9941214e511ad61cd79f492084f9`
- Raw super (8 GiB): SHA-256
  `302ee9920da8b26ddccd150bca6e4f74ad176d1288e4e2a9f4432e51eeff329a`

## Pipeline changes

- `gsi/scripts/build-local-docker.sh` no longer clones `sas-creator`/`vendor_vndk`
  or runs a loop mount. `export_system_image` expands
  `$PRODUCT_OUT/system.img` to the raw `artifacts/.../system_gsi.img` with
  `simg2img`, compresses it as
  `system-roar-arm64-vanilla-u90-front<orientation>.img.xz`, and records the
  raw-system SHA-256. `system_image_layout=sar` is written to `build-info.txt`.
- `gsi/config/u90-a11-v313.env` and `gsi/scripts/validate-recipe.sh` no longer
  pin the removed repositories.
- `gsi/scripts/verify-u90-artifact.sh` and `gsi/scripts/package-u90-super.sh`
  now cover both SAR (`/system/...`) and legacy (`/bin/...`) layouts, and both
  hard-fail when `/system/bin/init` is absent, naming the first-stage-init exec.
- `docker-compose.yml` drops `privileged: true`; the loop mount was its only
  reason.
- The GitHub workflow exports the system-as-root image directly and uploads it
  as `u90-a11-v313-sar-front<orientation>-<run>`.

## Reproducing from scratch

```powershell
docker compose build

# Fetch the pinned source, manifest, and Fcitx5 APK only.
.\gsi\scripts\run-local-docker.ps1 -Mode sync

# Full compile and system-as-root export into a fresh artifact directory.
.\gsi\scripts\run-local-docker.ps1 -Mode build `
  -BuildName u90-a11-v313-sar -FrontSensorOrientation 90

# Package that exact system_gsi.img with the stock flash package.
.\gsi\scripts\run-local-docker.ps1 -Mode package `
  -BuildName u90-a11-v313-sar `
  -PackageName u90-a11-v313-sar-package
```

Expected build outputs under `artifacts/local/u90-a11-v313-sar`:

- `system_gsi.img` (raw system-as-root ext4) and `system_gsi.img.sha256`
- `system-roar-arm64-vanilla-u90-front90.img.xz`
- `system-ab.img.sha256`, `build-info.txt`, `source-manifest.xml`, `SHA256SUMS`

Expected package outputs under `artifacts/local/u90-a11-v313-sar-package`:

- `super_u90_gsi.sparse.img` and `super_u90_gsi.raw.img`
- `vbmeta_u90_avb_disabled.img`, `vbmeta_system_u90_avb_disabled.img`,
  `vbmeta_vendor_u90_avb_disabled.img`
- `PACKAGE-MANIFEST.txt` (includes `system_layout=sar`) and `FLASH-PLAN.txt`
