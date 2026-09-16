# U90 Android 11 GSI build recipe

This directory is a small, pinned build recipe. It does not contain an Android
source checkout. The GitHub Actions runner downloads the Android 11 source,
applies device-specific framework, Launcher3, and NetworkStack patches, stages
a pinned Fcitx5 input-method APK, builds an ARM64 vanilla AB GSI, and converts
it to the A-only image required by this device.

## Baseline

- PHH release manifest: `v313`
- Android release: `android-11.0.0_r48`
- Product: `treble_arm64_bvN-userdebug` (rootless PHH-compatible build)
- Output: `system-roar-arm64-aonly-vanilla-u90-front<orientation>.img.xz`

The pinned revisions are in `config/u90-a11-v313.env`. The workflow validates
the release manifest SHA-256 and the source revisions before applying patches.

## Chinese and settings defaults

The image uses `zh-CN` as the product and persistent default locale, with
`Asia/Shanghai` and 24-hour time. Existing user selections may still override
these persistent defaults after an in-place system-only upgrade.

For a new Settings database, the U90 patch enables auto-rotation and changes
the default display timeout from 60 seconds to 5 minutes. It intentionally
does not alter density, navigation mode, boot, vendor, or the kernel. The
product characteristic is explicitly set to `tablet`; density remains under
the working vendor display configuration so the existing touch and orientation
behavior is preserved.

## Tablet UI

The U90 patch keeps the working vendor display and input configuration intact,
but gives the stock Android 11 UI a conservative Pixel/Material treatment:

- the framework default accent is Google blue, with a matching light and dark
  SystemUI notification-shade palette;
- Launcher3 uses a pale Material-blue all-apps and folder surface in light mode
  and a cooler blue-gray surface in dark mode;
- a `6 x 5` workspace with a six-icon dock is selected for a 600dp-or-wider
  tablet display.

The changes are resource and launcher-profile only. They do not alter SystemUI
network-validation state, navigation behavior, density, touch handling,
rotation, the kernel, or any vendor partition. If an existing Launcher3 data
directory keeps an older grid after an in-place update, clear Launcher3 storage
once from Settings and return to Home to create the new tablet layout.

## Chinese input method

The build downloads the official ARM64 Fcitx5 Android `0.1.3` release, verifies
its SHA-256 before staging, and installs it as the ordinary presigned system
app `U90Fcitx5`. It is not privileged and is not a root component. The bundled
Fcitx5 app contains Chinese input support; its IME component is
`org.fcitx.fcitx5.android/.input.FcitxInputMethodService`.

Android requires the user to explicitly enable a third-party IME. After first
boot, open **Settings > System > Languages & input > On-screen keyboard >
Manage on-screen keyboards**, enable Fcitx5, then select it from the keyboard
switcher. This intentional first-use step avoids silently replacing an input
method without user consent.

## Front camera patch

The vendor HAL reports camera ID `1` as front-facing with sensor orientation
`270`. The U90 image sets `ro.u90.camera.front.orientation=90` by default.
`CameraProviderManager` changes only the matching front-facing camera metadata
and API1 camera info. The patch is inactive unless that read-only property is
present in the built image.

The workflow accepts `0`, `90`, `180`, or `270` as a manual-dispatch input.
`90` is the initial 180-degree correction candidate; `270` is the no-change
control value.

## Root

The `N` product variant does not include PHH's `phh-su` binary or
`me.phh.superuser` manager. It does not bundle SuperSU or Magisk. The pinned
PHH v313 base requires a `userdebug` build because it sets
`SELINUX_IGNORE_NEVERALLOWS := true`; this may permit `adb root`, but it does
not install a root manager or a persistent `su` binary. Users who need app
root can patch and flash an appropriate boot image with Magisk separately.

## Runner modes

Manual workflow dispatch exposes two runner inputs in addition to camera
orientation:

- `github-hosted` is the default. Use `runner_labels` as
  `["ubuntu-22.04"]` and keep `timeout_minutes` at `360`.
- For a persistent Linux server, choose `self-hosted`, set `runner_labels` to
  `["self-hosted","linux","x64","u90-gsi"]`, and use
  `timeout_minutes` `1440` for the first full build. The runner must have the
  `u90-gsi` label and passwordless `sudo` for the A-only conversion step.

On self-hosted mode the workflow does not run hosted-runner disk cleanup, does
not clean the recipe checkout, and preserves `android/.repo`, `android/out`,
and ccache for incremental syncs and builds. Set `install_dependencies` to
`false` only after the server has been provisioned with the listed Ubuntu build
dependencies and the repo tool can be downloaded by the runner account.

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
