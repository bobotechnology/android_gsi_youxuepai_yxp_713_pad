# U90 Android 11 GSI build recipe

This directory is a small, pinned build recipe. It does not contain an Android
source checkout. A local Docker build downloads the Android 11 source, applies
device-specific framework, Launcher3, and NetworkStack patches, stages a pinned
Fcitx5 input-method APK, builds an ARM64 vanilla AB GSI, and exports it as the
system-as-root image required by this device. Package mode then makes a complete
`super` package from that image and the known stock flash package.

## Baseline

- PHH release manifest: `v313`
- Android release: `android-11.0.0_r48`
- Product: `treble_arm64_bvN-userdebug` (rootless PHH-compatible build)
- Output: `system-roar-arm64-vanilla-u90-front<orientation>.img.xz`

The pinned revisions are in `config/u90-a11-v313.env`. The build validates the
release manifest SHA-256 and the source revisions before applying patches.

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

`-FrontSensorOrientation` accepts `0`, `90`, `180`, or `270`. `90` is the initial
180-degree correction candidate; `270` is the no-change control value.

## Root

The `N` product variant does not include PHH's `phh-su` binary or
`me.phh.superuser` manager. It does not bundle SuperSU or Magisk. The pinned
PHH v313 base requires a `userdebug` build because it sets
`SELINUX_IGNORE_NEVERALLOWS := true`; this may permit `adb root`, but it does
not install a root manager or a persistent `su` binary. Users who need app
root can patch and flash an appropriate boot image with Magisk separately.

## Local Docker mode

Windows Docker Desktop can run the same pinned build locally through
`gsi/scripts/run-local-docker.ps1`. No proxy is assumed. When the Android source
sync or the image build needs one, put it in an untracked `.env` file at the
repository root:

```text
HTTP_PROXY=http://host.docker.internal:<port>
HTTPS_PROXY=http://host.docker.internal:<port>
```

Docker Compose interpolates that file, so a local proxy never enters version
control. `-Proxy <url>` sets the value for a single run when the shell
environment does not already define one. `-NoProxy` clears inherited proxy
variables instead.

The Compose file keeps the large Android source, `out`, ccache, and pinned
manifest state in named volumes. The checked-out recipe is mounted read-only at
`/recipe`, and completed files are written to `artifacts/local`. Run
`-Mode validate` to validate only the image and recipe, `-Mode sync` to update
the persistent source cache, leave the mode at its default (`build`) for the
full compile and system-as-root export, or use `-Mode package` to make a
complete sparse `super` image from the stock firmware and a system-as-root
system image.

Build mode requires a fresh `-BuildName` and writes its exact exported image
as `artifacts/local/<BuildName>/system_gsi.img`, together with its checksums and
build provenance. It refuses to replace a nonempty build directory. Package
mode uses that exact image by default when given the same `-BuildName`; it never
selects a stale image implicitly. Package output similarly requires a fresh
`-PackageName` directory under `artifacts/local`.

Build mode expands the sparse `$PRODUCT_OUT/system.img` build product into the
raw system-as-root ext4 image with AOSP `simg2img`. No conversion, loop mount,
or extra privilege is involved, so the local service runs without
`privileged`. Package mode additionally mounts the selected stock firmware
directory read-only; it only reads `super.img` and the three stock vbmeta
images, and it never accesses a connected device.

## Mainland network validation

NetworkStack defaults use `connect.rom.miui.com/generate_204` for the HTTP and
HTTPS validation probes, with `connectivitycheck.platform.hicloud.com/generate_204`
as the fallback. The patch also replaces the MCC 460 resource defaults, so a
Chinese SIM cannot restore a Google validation endpoint.

This does not suppress SystemUI status icons. A `!` or `X` remains meaningful
for an actual failed validation or a captive portal, but should clear normally
when the selected endpoint returns HTTP 204.

## Build and artifacts

A build writes into `artifacts/local/<BuildName>/`:

- `system_gsi.img`, the raw system-as-root ext4 image, plus its `.sha256`;
- `system-roar-arm64-vanilla-u90-front<orientation>.img.xz`, the compressed form;
- `SHA256SUMS`, the resolved `source-manifest.xml`, and `build-info.txt`.

A build produces `system` only. It never generates or flashes `super`, and never
modifies `boot`, `vendor`, `dtbo`, or any `vbmeta` image. Packaging is a separate
`-Mode package` step.

`system_gsi.img` is already raw, which is what the packager consumes. Decompress
the `.xz` only when you intend to flash a system image directly:

```bash
xz -dk system-roar-arm64-vanilla-u90-front90.img.xz
```

## Complete super package

The package command is a separate step because it requires the local stock flash
package. It uses only the AOSP host tools
`simg2img`, `lpdump`, `lpunpack`, `lpmake`, and `avbtool`:

```powershell
# Build the source-fixed system image into a fresh named artifact directory.
.\gsi\scripts\run-local-docker.ps1 `
  -FrontSensorOrientation 90 `
  -BuildName u90-a11-sourcefixed-v5

# Uses ../P713mt6779_20221129_2216 and exactly the system_gsi.img emitted by
# the named build above.
.\gsi\scripts\run-local-docker.ps1 `
  -Mode package `
  -BuildName u90-a11-sourcefixed-v5 `
  -PackageName u90-a11-sourcefixed-v5-package

# Supply a decompressed system-as-root image from another build when needed.
.\gsi\scripts\run-local-docker.ps1 -Mode package `
  -FirmwareDir C:\path\to\P713mt6779_20221129_2216 `
  -SystemImage C:\path\to\system-roar-arm64-vanilla-u90.img `
  -PackageName u90-a11-external-system-package
```

The output directory is `artifacts/local/<PackageName>` and is intentionally
required to be new or empty. It contains:

- `super_u90_gsi.sparse.img`: stock `product` and `vendor`, byte-identical to
  the selected firmware, plus the exact supplied system image;
- `super_u90_gsi.raw.img`: the official `simg2img`-expanded 8 GiB form for a
  TWRP `dd` workflow only;
- `vbmeta_u90_avb_disabled.img`, `vbmeta_system_u90_avb_disabled.img`, and
  `vbmeta_vendor_u90_avb_disabled.img`: named 4 KiB images, each produced by
  AOSP `avbtool make_vbmeta_image --flags 3`; and
- `PACKAGE-MANIFEST.txt`: input hashes, output hashes, AVB metadata, lpdump
  output, and byte-identity verification results.
- `FLASH-PLAN.txt`: the four selected scatter rows, target offsets, immutable
  partition list, and expected stock boot/dtbo hashes.

Flash `vbmeta_u90_avb_disabled.img` only to **`vbmeta`**,
`vbmeta_system_u90_avb_disabled.img` only to **`vbmeta_system`**, and
`vbmeta_vendor_u90_avb_disabled.img` only to **`vbmeta_vendor`**. Flags `3`
disable hashtree and verification handling, so this four-image set is only for
a bootloader that is already unlocked (the device must remain unlocked). Flash
the sparse super and all three named vbmeta images through the stock scatter
workflow. Do **not** use `dd` on the sparse image: its leading bytes are an
Android sparse header. If TWRP must use `dd`, use only the generated raw 8 GiB
super image. Then collect recovery state before changing another variable. The
package script never auto-flashes anything. Verify the capture against the
generated package before rebooting to Android:

```powershell
.\tools\collect-u90-recovery-state.ps1 -FullLogicalHashes

.\tools\verify-u90-recovery-state.ps1 `
  -RecoveryState C:\path\to\recovery-state.txt `
  -PackageDir .\artifacts\local\u90-a11-sourcefixed-v5-package `
  -RequireDynamicPartitionProof
```

After the verifier passes, start the following read-only host-side collector
while the tablet is still in TWRP. Leave it running, choose Reboot System
manually in TWRP, and let it either complete its capture duration or observe
the adb transport disappearing. It saves every logcat buffer, properties, and
process snapshots without issuing any device-changing command:

    .\tools\capture-u90-runtime-reboot.ps1 -CaptureSeconds 420

The decisive output is reboot-signals.txt, together with logcat-all.txt.
Received sys.powerctl records can identify a process that explicitly asked
init to reboot. A critical-service loop, fatal init message, or the absence of
all of those before adb disappears are different evidence paths; do not
attribute another fastboot transition to AVB from the boot target alone.
Each snapshot summary also records mtkmal plus the persisted MTK IMS and EPDG
properties. PHH v313 can issue one ordinary reboot after sys.boot_completed
when mtkmal exists and either persisted property is 1; this must be separated
from AVB behavior and from a bootloader-targeted reboot.

If the attempt reaches fastboot or the runtime collector loses adb, do not
reflash first. Return to TWRP, collect a second full read-only state, and
compare it with the verified pre-boot capture:

    .\tools\collect-u90-recovery-state.ps1 -FullLogicalHashes
    .\tools\compare-u90-boot-attempt.ps1 -BeforeRecoveryState C:\path\to\before\recovery-state.txt -AfterRecoveryState C:\path\to\after\recovery-state.txt

The comparison proves whether the misc bootloader-message command appeared
during the attempt, whether boot/dtbo/vbmeta or logical partition hashes
changed, and whether the post-attempt persistent log records an explicit
bootloader reboot. Preserve both capture directories before changing images.

The retained v4 package is diagnostic-only: it includes PHH's legacy TWRP
auto-flash action, which only proceeds when `/cache/phh/flash` exists. Do not
use it as the final package. If it must be examined, its verifier requires
`phh_twrp_flash_trigger=absent`; if it reports present, do not boot Android.
Inspect the captured marker metadata, then clear only the stale trigger in the
TWRP terminal and collect/verify again:

    rm -f /cache/phh/flash
    sync

The source-fixed recipe removes the legacy rc and script through
`0002-u90-disable-legacy-twrp-autoflash.patch`. New builds are rejected by both
the GSI artifact verifier and super packager if either file remains. The PHH
busybox payload stays present because unrelated PHH compatibility scripts use
it; this is not a root manager.

The final proof also requires an empty misc bootloader-message command. It
does not clear that command automatically. If verification reports
`boot-fastboot`, `bootonce-bootloader`, or another nonempty command, do not
boot Android. The
stock scatter allocates 0x00080000 bytes to `misc`; after confirming the
capture, use the TWRP terminal to clear only its first 4 KiB, then collect
and verify again:

```sh
dd if=/dev/zero of=/dev/block/by-name/misc bs=4096 count=1
sync
```
