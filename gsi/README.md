# U90 Android 11 GSI build recipe

A pinned build recipe. It does not contain an Android source checkout: a local
Docker build fetches the Android 11 source, applies the device patches, stages
the Fcitx5 APK, builds an ARM64 vanilla AB GSI, and exports the system-as-root
image. Package mode then combines that image with the stock `product` and
`vendor` into a complete `super`.

## Baseline

- PHH release manifest `v313`
- Android release `android-11.0.0_r48`
- Product `treble_arm64_bvN-userdebug` (rootless)
- Output `system-roar-arm64-vanilla-u90-front<orientation>.img.xz`

The pinned revisions are in `config/u90-a11-v313.env`. The build verifies the
release manifest SHA-256 and the source revisions before applying patches.

## What the patches change

**Chinese and settings defaults.** `zh-CN` as product and persistent default
locale, `Asia/Shanghai`, 24-hour time, auto-rotation enabled, and the default
display timeout raised from 60 seconds to 5 minutes. Density, navigation mode,
boot, vendor, and the kernel are untouched. The product characteristic is set to
`tablet` while density stays on the working vendor display configuration.

**Tablet UI.** A conservative Pixel/Material treatment: Google-blue framework
accent with matching light and dark SystemUI notification-shade palettes, a pale
Material-blue Launcher3 all-apps and folder surface, and a `6 x 5` workspace with
a six-icon dock for a 600dp-or-wider display. Resource and launcher-profile only.
If an existing Launcher3 data directory keeps an older grid after an in-place
update, clear Launcher3 storage once.

**Chinese input method.** The build downloads the official ARM64 Fcitx5 Android
`0.1.3` release, verifies its SHA-256, and installs it as the ordinary presigned
system app `U90Fcitx5`. Not privileged, not a root component. Android requires
the user to enable a third-party IME explicitly: **Settings > System > Languages
& input > On-screen keyboard > Manage on-screen keyboards**, then select it from
the keyboard switcher.

**Front camera orientation.** The vendor HAL reports camera `1` as front-facing
with sensor orientation `270`; the image sets
`ro.u90.camera.front.orientation=90` by default. `CameraProviderManager`
overrides only the matching front-facing camera metadata and API1 camera info,
and stays inactive unless that read-only property is present.
`-FrontSensorOrientation` accepts `0`, `90`, `180`, or `270`; `270` is the
no-change control value.

**Front camera lift.** `CameraService` raises the module on front camera connect
and retracts it on disconnect, through `/dev/NOAH_MOTOR` with `nr 1` and mode 3
or 2. The earlier revision of this patch used `nr 8` and `nr 2`, mirroring the
stock factory-test table; both are empty stubs that do nothing.

**Mainland network validation.** NetworkStack defaults use
`connect.rom.miui.com/generate_204` with
`connectivitycheck.platform.hicloud.com/generate_204` as the fallback, and the
patch replaces the MCC 460 resource defaults so a Chinese SIM cannot restore a
Google endpoint. This does not suppress SystemUI status icons: `!` or `X` still
means a real failed validation or a captive portal.

**Root.** The `N` variant has no `phh-su` binary, no `me.phh.superuser` manager,
and no bundled SuperSU or Magisk. The pinned PHH v313 base requires `userdebug`
because it sets `SELINUX_IGNORE_NEVERALLOWS := true`, which may permit
`adb root`, but no `su` binary is installed persistently.

## Local Docker mode

`scripts/run-local-docker.ps1` drives the build from Windows Docker Desktop. No
proxy is assumed; put one in an untracked `.env` at the repository root and
Compose interpolates it.

```text
HTTP_PROXY=http://host.docker.internal:<port>
HTTPS_PROXY=http://host.docker.internal:<port>
```

`-Proxy <url>` sets it for a single run when the shell environment does not
already define one, and `-NoProxy` clears inherited proxy variables.

The Compose file keeps the Android source, `out`, ccache, and the pinned manifest
cache in named volumes, so repeat builds are incremental. The recipe is mounted
read-only at `/recipe` and finished files are written to `artifacts/local`.

| Mode | Effect |
| --- | --- |
| `validate` | Checks the image and recipe only; no source sync |
| `sync` | Fetches/updates the source, manifest, and Fcitx5 APK; no compile |
| `build` (default) | Full compile and system-as-root export |
| `package` | Builds a complete sparse `super` from the stock firmware and a system image |

Build mode requires a fresh `-BuildName` and refuses to replace a nonempty
directory. Package mode uses that build's `system_gsi.img` when given the same
`-BuildName` and never selects a stale image implicitly; its `-PackageName`
directory must likewise be new or empty.

The exported image is the raw `$PRODUCT_OUT/system.img` expanded with
`simg2img` — no A-only conversion and no loop mount, so the service runs without
`privileged`. Package mode additionally mounts the selected stock firmware
directory read-only; it reads only `super.img` and the three stock vbmeta images
and never accesses a connected device.

## Build output

`artifacts/local/<BuildName>/` contains:

- `system_gsi.img`, the raw system-as-root ext4 image, plus its `.sha256`;
- `system-roar-arm64-vanilla-u90-front<orientation>.img.xz`, the compressed form;
- `SHA256SUMS`, `source-manifest.xml`, and `build-info.txt`.

A build produces `system` only. It never generates or flashes `super` and never
touches `boot`, `vendor`, `dtbo`, or any vbmeta image; packaging is a separate
step.

## Complete super package

Package mode uses only AOSP host tools: `simg2img`, `lpdump`, `lpunpack`,
`lpmake`, and `avbtool`. It requires the local stock flash package, which is why
it is separate from the build.

```powershell
.\gsi\scripts\run-local-docker.ps1 `
  -FrontSensorOrientation 90 `
  -BuildName u90-a11-v313-sar

.\gsi\scripts\run-local-docker.ps1 `
  -Mode package `
  -BuildName u90-a11-v313-sar `
  -PackageName u90-a11-v313-sar-package
```

`artifacts/local/<PackageName>/` contains:

- `super_u90_gsi.sparse.img`: stock `product` and `vendor`, byte-identical to the
  selected firmware, plus the supplied system image;
- `super_u90_gsi.raw.img`: the `simg2img`-expanded 8 GiB form, for a TWRP `dd`
  workflow only;
- `vbmeta_u90_avb_disabled.img`, `vbmeta_system_u90_avb_disabled.img`,
  `vbmeta_vendor_u90_avb_disabled.img`: 4 KiB images from
  `avbtool make_vbmeta_image --flags 3`;
- `PACKAGE-MANIFEST.txt` (input and output hashes, AVB metadata, lpdump output,
  byte-identity results) and `FLASH-PLAN.txt` (the selected scatter rows, target
  offsets, immutable partitions, expected stock boot/dtbo hashes).

Flags `3` disable hashtree and verification handling, so the four-image set is
only for an already-unlocked bootloader that stays unlocked. Flash each vbmeta
image to the partition named in its filename, and the sparse super through the
stock scatter workflow. Do not `dd` the sparse image; its leading bytes are an
Android sparse header. The package script never flashes anything.

Verify the flashed state before booting Android:

```powershell
.\tools\collect-u90-recovery-state.ps1 -FullLogicalHashes

.\tools\verify-u90-recovery-state.ps1 `
  -RecoveryState C:\path\to\recovery-state.txt `
  -PackageDir .\artifacts\local\u90-a11-v313-sar-package `
  -RequireDynamicPartitionProof
```

If the attempt reaches fastboot or the runtime collector loses adb, do not
reflash first. Collect a second read-only state in TWRP and compare it with the
verified pre-boot capture, then preserve both capture directories:

```powershell
.\tools\compare-u90-boot-attempt.ps1 `
  -BeforeRecoveryState C:\path\to\before\recovery-state.txt `
  -AfterRecoveryState C:\path\to\after\recovery-state.txt
```

The final proof requires an empty misc bootloader-message command. If the
verifier reports `boot-fastboot`, `bootonce-bootloader`, or any other nonempty
command, clear only the first 4 KiB of `misc` from the TWRP terminal, then
collect and verify again:

```sh
dd if=/dev/zero of=/dev/block/by-name/misc bs=4096 count=1
sync
```

See [stock-firmware-baseline.md](../docs/stock-firmware-baseline.md) for what
each capture proves and for the PHH-side reboot path that must be separated from
AVB behaviour.
