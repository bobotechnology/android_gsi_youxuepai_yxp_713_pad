#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly GSI_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly CONFIG="$GSI_ROOT/config/u90-a11-v313.env"

source "$CONFIG"

for variable in \
    TREBLE_RELEASE \
    RELEASE_MANIFEST_URL \
    RELEASE_MANIFEST_SHA256 \
    FRAMEWORKS_AV_REV \
    FRAMEWORKS_BASE_REV \
    DEVICE_PHH_TREBLE_REV \
    NETWORKSTACK_REV \
    LAUNCHER3_REV \
    LUNCH_TARGET \
    PRODUCT_OUT \
    REPO_GROUPS \
    REPO_SYNC_JOBS \
    FCITX5_VERSION \
    FCITX5_APK_NAME \
    FCITX5_APK_URL \
    FCITX5_APK_SHA256 \
    FCITX5_PACKAGE_NAME \
    FCITX5_IME_COMPONENT; do
    if [[ -z "${!variable:-}" ]]; then
        printf 'missing %s in %s\n' "$variable" "$CONFIG" >&2
        exit 1
    fi
done

for hash in "$RELEASE_MANIFEST_SHA256" "$FCITX5_APK_SHA256"; do
    if [[ ! "$hash" =~ ^[0-9a-f]{64}$ ]]; then
        echo 'pinned hashes must be lowercase SHA-256' >&2
        exit 1
    fi
done

if [[ "$FCITX5_APK_URL" != https://github.com/fcitx5-android/fcitx5-android/releases/download/* ]]; then
    echo 'FCITX5_APK_URL must use the official Fcitx5 Android release location' >&2
    exit 1
fi

if [[ "$FCITX5_APK_NAME" == */* ]]; then
    echo 'FCITX5_APK_NAME must be a file name' >&2
    exit 1
fi

if [[ "$LUNCH_TARGET" != 'treble_arm64_bvN-userdebug' ]]; then
    echo 'LUNCH_TARGET must select the rootless ARM64 vanilla AB product' >&2
    exit 1
fi

for revision in \
    "$FRAMEWORKS_AV_REV" \
    "$FRAMEWORKS_BASE_REV" \
    "$DEVICE_PHH_TREBLE_REV" \
    "$NETWORKSTACK_REV" \
    "$LAUNCHER3_REV"; do
    if [[ ! "$revision" =~ ^[0-9a-f]{40}$ ]]; then
        printf 'invalid pinned revision: %s\n' "$revision" >&2
        exit 1
    fi
done

for patch in \
    "$GSI_ROOT/patches/frameworks-av/0001-u90-front-camera-orientation-override.patch" \
    "$GSI_ROOT/patches/frameworks-base/0001-u90-settings-defaults.patch" \
    "$GSI_ROOT/patches/frameworks-base/0002-u90-material-tablet-palette.patch" \
    "$GSI_ROOT/patches/device-phh-treble/0001-u90-front-camera-orientation-property.patch" \
    "$GSI_ROOT/patches/device-phh-treble/0002-u90-disable-legacy-twrp-autoflash.patch" \
    "$GSI_ROOT/patches/packages-modules-networkstack/0001-yxp-713-pad-mainland-captive-portal-endpoints.patch" \
    "$GSI_ROOT/patches/packages-apps-launcher3/0001-u90-tablet-material-layout.patch" \
    "$GSI_ROOT/templates/u90-fcitx5/Android.bp" \
    "$GSI_ROOT/templates/u90-fcitx5/u90-fcitx5.mk" \
    "$GSI_ROOT/scripts/package-u90-super.sh"; do
    test -s "$patch"
done

bash -n "$GSI_ROOT/scripts/package-u90-super.sh"

grep -Fq 'ro.u90.camera.front.orientation' \
    "$GSI_ROOT/patches/frameworks-av/0001-u90-front-camera-orientation-override.patch"
grep -Fq 'def_accelerometer_rotation' \
    "$GSI_ROOT/patches/frameworks-base/0001-u90-settings-defaults.patch"
grep -Fq 'accent_material_light' \
    "$GSI_ROOT/patches/frameworks-base/0002-u90-material-tablet-palette.patch"
grep -Fq 'U90_FRONT_CAMERA_ORIENTATION' \
    "$GSI_ROOT/patches/device-phh-treble/0001-u90-front-camera-orientation-property.patch"
grep -Fq 'PRODUCT_CHARACTERISTICS := tablet' \
    "$GSI_ROOT/patches/device-phh-treble/0001-u90-front-camera-orientation-property.patch"
grep -Fq 'twrp/twrp.rc:system/etc/init/twrp.rc' \
    "$GSI_ROOT/patches/device-phh-treble/0002-u90-disable-legacy-twrp-autoflash.patch"
grep -Fq 'twrp/twrp.sh:system/bin/twrp.sh' \
    "$GSI_ROOT/patches/device-phh-treble/0002-u90-disable-legacy-twrp-autoflash.patch"
grep -Fq 'PRODUCT_LOCALES := zh_CN' "$GSI_ROOT/scripts/apply-u90-patches.sh"
grep -Fq 'connect.rom.miui.com/generate_204' \
    "$GSI_ROOT/patches/packages-modules-networkstack/0001-yxp-713-pad-mainland-captive-portal-endpoints.patch"
grep -Fq '6_by_5' \
    "$GSI_ROOT/patches/packages-apps-launcher3/0001-u90-tablet-material-layout.patch"
grep -Fq 'android_app_import' "$GSI_ROOT/templates/u90-fcitx5/Android.bp"
