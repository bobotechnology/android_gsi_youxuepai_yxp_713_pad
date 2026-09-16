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
    SAS_CREATOR_URL \
    SAS_CREATOR_REV \
    VENDOR_VNDK_URL \
    VENDOR_VNDK_REV \
    LUNCH_TARGET \
    PRODUCT_OUT \
    REPO_GROUPS \
    REPO_SYNC_JOBS; do
    if [[ -z "${!variable:-}" ]]; then
        printf 'missing %s in %s\n' "$variable" "$CONFIG" >&2
        exit 1
    fi
done

if [[ ! "$RELEASE_MANIFEST_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
    echo 'RELEASE_MANIFEST_SHA256 must be lowercase SHA-256' >&2
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
    "$SAS_CREATOR_REV" \
    "$VENDOR_VNDK_REV"; do
    if [[ ! "$revision" =~ ^[0-9a-f]{40}$ ]]; then
        printf 'invalid pinned revision: %s\n' "$revision" >&2
        exit 1
    fi
done

for patch in \
    "$GSI_ROOT/patches/frameworks-av/0001-u90-front-camera-orientation-override.patch" \
    "$GSI_ROOT/patches/frameworks-base/0001-u90-settings-defaults.patch" \
    "$GSI_ROOT/patches/device-phh-treble/0001-u90-front-camera-orientation-property.patch" \
    "$GSI_ROOT/patches/packages-modules-networkstack/0001-yxp-713-pad-mainland-captive-portal-endpoints.patch"; do
    test -s "$patch"
done

grep -Fq 'ro.u90.camera.front.orientation' \
    "$GSI_ROOT/patches/frameworks-av/0001-u90-front-camera-orientation-override.patch"
grep -Fq 'def_accelerometer_rotation' \
    "$GSI_ROOT/patches/frameworks-base/0001-u90-settings-defaults.patch"
grep -Fq 'U90_FRONT_CAMERA_ORIENTATION' \
    "$GSI_ROOT/patches/device-phh-treble/0001-u90-front-camera-orientation-property.patch"
grep -Fq 'PRODUCT_CHARACTERISTICS := tablet' \
    "$GSI_ROOT/patches/device-phh-treble/0001-u90-front-camera-orientation-property.patch"
grep -Fq 'connect.rom.miui.com/generate_204' \
    "$GSI_ROOT/patches/packages-modules-networkstack/0001-yxp-713-pad-mainland-captive-portal-endpoints.patch"
