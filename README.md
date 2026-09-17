# Android 11 GSI for Youxuepai yxp_713_pad

Pinned Android 11 PHH/Treble GSI build recipe for the Youxuepai
`yxp_713_pad` device (sold as U90).

GitHub Actions builds only a `system` image. Local Docker package mode can
combine that system-as-root image with the stock `product` and `vendor`
partitions into a complete `super` package. It never flashes a device and
preserves the stock `boot`, `dtbo`, kernel, and `vendor` partitions. Its
explicit flash plan pairs the replacement `super` with three generated
AVB-flags-3 vbmeta images.

## Build

Run the `Build U90 Android 11 GSI` GitHub Actions workflow manually. The
workflow performs the Android source sync on the GitHub runner, applies the
device-specific patches, and uploads a compressed ARM64 system-as-root system
image with checksums and source provenance.

See `gsi/README.md` for the pinned source baseline, supported front-camera
orientation inputs, artifact format, and flashing scope.

## Local Docker build

The repository can also build locally with Docker Desktop. The Android source,
`out/`, ccache, and the pinned manifest cache are Docker named volumes, so
repeat builds are incremental. Only `artifacts/local` is bind-mounted back to
Windows; do not place the Android source on a `C:\` bind mount.

With Docker Desktop running, the Windows helper defaults to the verified local
Xray mixed proxy at `http://host.docker.internal:<port>`:

```powershell
powershell -ExecutionPolicy Bypass -File .\gsi\scripts\run-local-docker.ps1
```

Useful alternatives:

```powershell
# Validate the container recipe without synchronizing Android source.
.\gsi\scripts\run-local-docker.ps1 -Mode validate

# Fetch/update source and the pinned Fcitx5 APK, but do not compile.
.\gsi\scripts\run-local-docker.ps1 -Mode sync

# Build with a specific camera orientation and a CPU-job cap. BuildName must
# name a fresh artifact directory.
.\gsi\scripts\run-local-docker.ps1 `
  -FrontSensorOrientation 90 `
  -Jobs 12 `
  -BuildName u90-a11-sourcefixed-v5

# Package exactly the system_gsi.img from that named local build with the stock
# flash package that is next to this repository.
.\gsi\scripts\run-local-docker.ps1 `
  -Mode package `
  -BuildName u90-a11-sourcefixed-v5 `
  -PackageName u90-a11-sourcefixed-v5-package

# Or package a decompressed system-as-root image from a GitHub Actions artifact.
.\gsi\scripts\run-local-docker.ps1 `
  -Mode package `
  -SystemImage C:\path\to\system.img `
  -PackageName u90-a11-external-system-package
```

The build exports the unmodified system-as-root `$PRODUCT_OUT/system.img` with
`simg2img`, so no A-only conversion or loop mount is performed and the local
Compose service no longer needs `privileged`. `-Mode package` mounts the
selected stock firmware directory read-only and uses only the AOSP host tools
already built from the Android source tree. Its output is written to
`artifacts/local/<PackageName>`; it refuses to overwrite a nonempty output
directory. A build writes its exported image as
`artifacts/local/<BuildName>/system_gsi.img` and refuses to overwrite a nonempty
build directory. Package mode uses that exact image when `-SystemImage` is not
supplied. It creates a sparse `super` image, a raw 8 GiB `super` image for TWRP
`dd`, and three named 4 KiB verification-disabled AVB images for an
already-unlocked device. It does not flash any host or device partition. The
compressed artifact name no longer contains an `aonly` component; it is now
`system-roar-arm64-vanilla-u90-front<orientation>.img.xz`.

## Recovery compatibility

Dynamic-partition work must use TWRP device tree commit `61810b9` or later in
`bobotechnology/twrp_device_youxuepai_yxp_713_pad`. That commit corrects the
`super` partition size from the original MT6779 scatter file. GitHub Actions
does not produce a `super` image; local `-Mode package` does, after rechecking
the stock partition geometry with `lpdump`.
