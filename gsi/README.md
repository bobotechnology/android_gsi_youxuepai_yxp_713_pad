# U90 Android 11 GSI build recipe

This directory is a small, pinned build recipe. It does not contain an Android
source checkout. The GitHub Actions runner downloads the Android 11 source,
applies the device-specific framework and NetworkStack patches, builds an ARM64 vanilla AB GSI, and converts it to
the A-only image required by this device.

## Baseline

- PHH release manifest: `v313`
- Android release: `android-11.0.0_r48`
- Product: `treble_arm64_bvS-userdebug`
- Output: `system-roar-arm64-aonly-vanilla-u90-front<orientation>.img.xz`

The pinned revisions are in `config/u90-a11-v313.env`. The workflow validates
the release manifest SHA-256 and the source revisions before applying patches.

## Chinese and settings defaults

The image uses `zh-CN` as the product and persistent default locale, with
`Asia/Shanghai` and 24-hour time. Existing user selections may still override
these persistent defaults after an in-place system-only upgrade.

For a new Settings database, the U90 patch enables auto-rotation and changes
the default display timeout from 60 seconds to 5 minutes. It intentionally
does not alter density, navigation mode, boot, vendor, or the kernel.

## Front camera patch

The vendor HAL reports camera ID `1` as front-facing with sensor orientation
`270`. The U90 image sets `ro.u90.camera.front.orientation=90` by default.
`CameraProviderManager` changes only the matching front-facing camera metadata
and API1 camera info. The patch is inactive unless that read-only property is
present in the built image.

The workflow accepts `0`, `90`, `180`, or `270` as a manual-dispatch input.
`90` is the initial 180-degree correction candidate; `270` is the no-change
control value.

## Mainland network validation

NetworkStack defaults use `connect.rom.miui.com/generate_204` for the HTTP and
HTTPS validation probes, with `connectivitycheck.platform.hicloud.com/generate_204`
as the fallback. The patch also replaces the MCC 460 resource defaults, so a
Chinese SIM cannot restore a Google validation endpoint.

This does not suppress SystemUI status icons. A `!` or `X` remains meaningful
for an actual failed validation or a captive portal, but should clear normally
when the selected endpoint returns HTTP 204.

## Build and artifacts

Run the `Build U90 Android 11 GSI` workflow manually. It uploads:

- the compressed A-only `system` image;
- SHA-256 checksums;
- the resolved source manifest;
- build metadata.

The workflow builds only `system`. It does not generate or flash `super`, and
does not modify `boot`, `vendor`, `dtbo`, or any `vbmeta` image.

Decompress the artifact before flashing:

```bash
xz -dk system-roar-arm64-aonly-vanilla-u90-front90.img.xz
```
