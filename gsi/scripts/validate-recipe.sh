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
    FRAMEWORKS_NATIVE_REV \
    SYSTEM_CORE_REV \
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
    "$FRAMEWORKS_NATIVE_REV" \
    "$SYSTEM_CORE_REV" \
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
    "$GSI_ROOT/patches/frameworks-av/0002-u90-front-camera-motor-lift.patch" \
    "$GSI_ROOT/patches/frameworks-base/0001-u90-settings-defaults.patch" \
    "$GSI_ROOT/patches/frameworks-base/0002-u90-material-tablet-palette.patch" \
    "$GSI_ROOT/patches/device-phh-treble/0001-u90-front-camera-orientation-property.patch" \
    "$GSI_ROOT/patches/device-phh-treble/0002-u90-disable-legacy-twrp-autoflash.patch" \
    "$GSI_ROOT/patches/frameworks-native/0001-u90-vendor-input-gate.patch" \
    "$GSI_ROOT/patches/system-core/0001-u90-noah-motor-ueventd.patch" \
    "$GSI_ROOT/patches/packages-modules-networkstack/0001-yxp-713-pad-mainland-captive-portal-endpoints.patch" \
    "$GSI_ROOT/patches/packages-apps-launcher3/0001-u90-tablet-material-layout.patch" \
    "$GSI_ROOT/templates/u90-fcitx5/Android.bp" \
    "$GSI_ROOT/templates/u90-fcitx5/u90-fcitx5.mk" \
    "$GSI_ROOT/templates/u90-sepolicy/noah_motor.te" \
    "$GSI_ROOT/tools/u90-motor/Android.bp" \
    "$GSI_ROOT/tools/u90-motor/u90-motor.cpp" \
    "$GSI_ROOT/tools/u90-motor/u90-motor.mk" \
    "$GSI_ROOT/scripts/package-u90-super.sh"; do
    test -s "$patch"
done

bash -n "$GSI_ROOT/scripts/package-u90-super.sh"
bash -n "$GSI_ROOT/scripts/build-local-docker.sh"
bash -n "$GSI_ROOT/scripts/apply-u90-patches.sh"

grep -Fq 'reset_patched_trees' "$GSI_ROOT/scripts/build-local-docker.sh"
grep -Fq 'git -C "$SOURCE_DIR/$checkout" checkout -- .' \
    "$GSI_ROOT/scripts/build-local-docker.sh"

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
grep -Fq '/proc/bootprof' \
    "$GSI_ROOT/patches/frameworks-native/0001-u90-vendor-input-gate.patch"
grep -Fq 'BOOT_Animation:END' \
    "$GSI_ROOT/patches/frameworks-native/0001-u90-vendor-input-gate.patch"
grep -Fq 'surfaceflinger' \
    "$GSI_ROOT/patches/frameworks-native/0001-u90-vendor-input-gate.patch"
grep -Fq 'PRODUCT_LOCALES := zh_CN' "$GSI_ROOT/scripts/apply-u90-patches.sh"
grep -Fq 'connect.rom.miui.com/generate_204' \
    "$GSI_ROOT/patches/packages-modules-networkstack/0001-yxp-713-pad-mainland-captive-portal-endpoints.patch"
grep -Fq '6_by_5' \
    "$GSI_ROOT/patches/packages-apps-launcher3/0001-u90-tablet-material-layout.patch"
grep -Fq 'android_app_import' "$GSI_ROOT/templates/u90-fcitx5/Android.bp"
grep -Fq '/dev/NOAH_MOTOR' \
    "$GSI_ROOT/patches/system-core/0001-u90-noah-motor-ueventd.patch"
grep -Fq '0666   root       root' \
    "$GSI_ROOT/patches/system-core/0001-u90-noah-motor-ueventd.patch"
grep -Fq 'dev_type' "$GSI_ROOT/templates/u90-sepolicy/noah_motor.te"
grep -Fq 'allow cameraserver noah_motor_device:chr_file rw_file_perms' \
    "$GSI_ROOT/templates/u90-sepolicy/noah_motor.te"
grep -Fq '/dev/NOAH_MOTOR u:object_r:noah_motor_device:s0' \
    "$GSI_ROOT/scripts/apply-u90-patches.sh"
grep -Fq 'u90FrontCameraLift' \
    "$GSI_ROOT/patches/frameworks-av/0002-u90-front-camera-motor-lift.patch"
grep -Fq 'u90FrontCameraLift(true)' \
    "$GSI_ROOT/patches/frameworks-av/0002-u90-front-camera-motor-lift.patch"
grep -Fq 'u90FrontCameraLift(false)' \
    "$GSI_ROOT/patches/frameworks-av/0002-u90-front-camera-motor-lift.patch"
grep -Fq 'cameraId == kU90FrontCameraId' \
    "$GSI_ROOT/patches/frameworks-av/0002-u90-front-camera-motor-lift.patch"
grep -Fq 'mCameraIdStr == kU90FrontCameraId' \
    "$GSI_ROOT/patches/frameworks-av/0002-u90-front-camera-motor-lift.patch"
grep -Fq 'kU90MotorRequestMove = 0x40c44d01' \
    "$GSI_ROOT/patches/frameworks-av/0002-u90-front-camera-motor-lift.patch"
grep -Fq 'kU90MotorModeSelfie = 3' \
    "$GSI_ROOT/patches/frameworks-av/0002-u90-front-camera-motor-lift.patch"
grep -Fq 'kU90MotorModeBottom = 2' \
    "$GSI_ROOT/patches/frameworks-av/0002-u90-front-camera-motor-lift.patch"
# The stub request numbers must not come back: nr 2 and nr 8 are empty in the
# driver and silently return success without moving anything.
if grep -Eq '0x40c44d(02|08)' \
    "$GSI_ROOT/patches/frameworks-av/0002-u90-front-camera-motor-lift.patch"; then
    echo 'the motor patch uses a driver stub request (nr 2 or nr 8) for movement' >&2
    exit 1
fi
grep -Fq '/dev/NOAH_MOTOR' "$GSI_ROOT/tools/u90-motor/u90-motor.cpp"
grep -Fq 'kRequestMove = 0x40c44d01' "$GSI_ROOT/tools/u90-motor/u90-motor.cpp"
grep -Fq 'position_selfie' "$GSI_ROOT/tools/u90-motor/u90-motor.cpp"
# Same guard for the tool.
if grep -Eq '0x40c44d(02|08)' "$GSI_ROOT/tools/u90-motor/u90-motor.cpp"; then
    echo 'u90-motor uses a driver stub request (nr 2 or nr 8) for movement' >&2
    exit 1
fi
grep -Fq 'PRODUCT_PACKAGES += u90-motor' "$GSI_ROOT/tools/u90-motor/u90-motor.mk"
grep -Fq 'stage_u90_motor' "$GSI_ROOT/scripts/apply-u90-patches.sh"
grep -Fq 'stage_u90_sepolicy' "$GSI_ROOT/scripts/apply-u90-patches.sh"
