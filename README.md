# Android 11 GSI for Youxuepai yxp_713_pad

Pinned Android 11 PHH/Treble GSI build recipe for the Youxuepai
`yxp_713_pad` device (sold as U90).

This repository builds only a `system` image. It deliberately does not build,
flash, or replace `super`, `boot`, `vendor`, `dtbo`, or `vbmeta`.

## Build

Run the `Build U90 Android 11 GSI` GitHub Actions workflow manually. The
workflow performs the Android source sync on the GitHub runner, applies the
device-specific patches, and uploads a compressed ARM64 A-only system image
with checksums and source provenance.

See `gsi/README.md` for the pinned source baseline, supported front-camera
orientation inputs, artifact format, and flashing scope.

## Recovery compatibility

Dynamic-partition work must use TWRP device tree commit `61810b9` or later in
`bobotechnology/twrp_device_youxuepai_yxp_713_pad`. That commit corrects the
`super` partition size from the original MT6779 scatter file. This GSI recipe
does not produce a `super` image.
