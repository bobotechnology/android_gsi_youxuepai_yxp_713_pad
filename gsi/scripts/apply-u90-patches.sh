#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly GSI_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly CONFIG="$GSI_ROOT/config/u90-a11-v313.env"

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <android-source-root>" >&2
    exit 64
fi

readonly SOURCE_ROOT="$(cd -- "$1" && pwd)"
source "$CONFIG"

assert_revision() {
    local checkout="$1"
    local expected="$2"
    local actual

    actual="$(git -C "$checkout" rev-parse HEAD)"
    if [[ "$actual" != "$expected" ]]; then
        printf 'revision mismatch for %s: expected %s, got %s\n' \
            "$checkout" "$expected" "$actual" >&2
        exit 1
    fi
}

apply_patchset() {
    local checkout="$1"
    local patch_dir="$2"
    local patch
    local -a patches

    shopt -s nullglob
    patches=("$patch_dir"/*.patch)
    shopt -u nullglob

    if [[ ${#patches[@]} -eq 0 ]]; then
        printf 'no patches found in %s\n' "$patch_dir" >&2
        exit 1
    fi

    for patch in "${patches[@]}"; do
        if git -C "$checkout" apply --check --whitespace=error-all "$patch" 2>/dev/null; then
            git -C "$checkout" apply --whitespace=error-all "$patch"
        elif git -C "$checkout" apply --reverse --check --whitespace=error-all "$patch" 2>/dev/null; then
            printf 'patch already applied: %s\n' "$(basename "$patch")"
        else
            printf 'patch neither applies nor matches the existing tree: %s\n' \
                "$patch" >&2
            git -C "$checkout" apply --check --whitespace=error-all "$patch" >&2 || true
            exit 1
        fi
    done
}

stage_fcitx5() {
    local apk="${U90_FCITX5_APK:-}"
    local actual_hash
    local app_dir
    local target_product

    if [[ -z "$apk" || ! -s "$apk" ]]; then
        echo 'U90_FCITX5_APK must point to the verified Fcitx5 APK' >&2
        exit 1
    fi

    actual_hash="$(sha256sum "$apk" | awk '{print $1}')"
    if [[ "$actual_hash" != "$FCITX5_APK_SHA256" ]]; then
        printf 'Fcitx5 APK SHA-256 mismatch: expected %s, got %s\n' \
            "$FCITX5_APK_SHA256" "$actual_hash" >&2
        exit 1
    fi

    app_dir="$SOURCE_ROOT/device/phh/treble/u90-fcitx5"
    target_product="$SOURCE_ROOT/device/phh/treble/${LUNCH_TARGET%-*}.mk"
    test -s "$target_product"
    test -s "$GSI_ROOT/templates/u90-fcitx5/Android.bp"
    test -s "$GSI_ROOT/templates/u90-fcitx5/u90-fcitx5.mk"

    install -d "$app_dir"
    install -m 0644 "$GSI_ROOT/templates/u90-fcitx5/Android.bp" "$app_dir/Android.bp"
    install -m 0644 "$GSI_ROOT/templates/u90-fcitx5/u90-fcitx5.mk" "$app_dir/u90-fcitx5.mk"
    install -m 0644 "$apk" "$app_dir/Fcitx5.apk"

    if ! grep -Fqx '$(call inherit-product, device/phh/treble/u90-fcitx5/u90-fcitx5.mk)' \
        "$target_product"; then
        printf '\n$(call inherit-product, device/phh/treble/u90-fcitx5/u90-fcitx5.mk)\n' \
            >> "$target_product"
    fi

    if ! grep -Fqx 'PRODUCT_LOCALES := zh_CN' "$target_product"; then
        printf '\nPRODUCT_LOCALES := zh_CN\n' >> "$target_product"
    fi
}

stage_u90_motor() {
    local tool_dir="$SOURCE_ROOT/device/phh/treble/u90-motor"
    local target_product="$SOURCE_ROOT/device/phh/treble/${LUNCH_TARGET%-*}.mk"

    test -s "$target_product"
    test -s "$GSI_ROOT/tools/u90-motor/Android.bp"
    test -s "$GSI_ROOT/tools/u90-motor/u90-motor.cpp"
    test -s "$GSI_ROOT/tools/u90-motor/u90-motor.mk"

    install -d "$tool_dir"
    install -m 0644 "$GSI_ROOT/tools/u90-motor/Android.bp" "$tool_dir/Android.bp"
    install -m 0644 "$GSI_ROOT/tools/u90-motor/u90-motor.cpp" "$tool_dir/u90-motor.cpp"
    install -m 0644 "$GSI_ROOT/tools/u90-motor/u90-motor.mk" "$tool_dir/u90-motor.mk"

    if ! grep -Fqx '$(call inherit-product, device/phh/treble/u90-motor/u90-motor.mk)' \
        "$target_product"; then
        printf '\n$(call inherit-product, device/phh/treble/u90-motor/u90-motor.mk)\n' \
            >> "$target_product"
    fi
}

stage_u90_sepolicy() {
    local policy_dir="$SOURCE_ROOT/device/phh/treble/sepolicy"
    local noah_motor_context='/dev/NOAH_MOTOR u:object_r:noah_motor_device:s0'

    test -d "$policy_dir"
    test -s "$policy_dir/file_contexts"
    test -s "$GSI_ROOT/templates/u90-sepolicy/noah_motor.te"

    install -m 0644 "$GSI_ROOT/templates/u90-sepolicy/noah_motor.te" \
        "$policy_dir/noah_motor.te"

    if ! grep -Fq "$noah_motor_context" "$policy_dir/file_contexts"; then
        printf '\n%s\n' "$noah_motor_context" >> "$policy_dir/file_contexts"
    fi
}

assert_revision "$SOURCE_ROOT/frameworks/av" "$FRAMEWORKS_AV_REV"
assert_revision "$SOURCE_ROOT/frameworks/base" "$FRAMEWORKS_BASE_REV"
assert_revision "$SOURCE_ROOT/frameworks/native" "$FRAMEWORKS_NATIVE_REV"
assert_revision "$SOURCE_ROOT/system/core" "$SYSTEM_CORE_REV"
assert_revision "$SOURCE_ROOT/device/phh/treble" "$DEVICE_PHH_TREBLE_REV"
assert_revision "$SOURCE_ROOT/packages/modules/NetworkStack" "$NETWORKSTACK_REV"
assert_revision "$SOURCE_ROOT/packages/apps/Launcher3" "$LAUNCHER3_REV"

apply_patchset "$SOURCE_ROOT/frameworks/av" "$GSI_ROOT/patches/frameworks-av"
apply_patchset "$SOURCE_ROOT/frameworks/base" "$GSI_ROOT/patches/frameworks-base"
apply_patchset "$SOURCE_ROOT/frameworks/native" "$GSI_ROOT/patches/frameworks-native"
apply_patchset "$SOURCE_ROOT/system/core" "$GSI_ROOT/patches/system-core"
apply_patchset "$SOURCE_ROOT/device/phh/treble" "$GSI_ROOT/patches/device-phh-treble"
apply_patchset "$SOURCE_ROOT/packages/modules/NetworkStack" \
    "$GSI_ROOT/patches/packages-modules-networkstack"
apply_patchset "$SOURCE_ROOT/packages/apps/Launcher3" \
    "$GSI_ROOT/patches/packages-apps-launcher3"

stage_fcitx5
stage_u90_motor
stage_u90_sepolicy

git -C "$SOURCE_ROOT/frameworks/av" diff --check
git -C "$SOURCE_ROOT/frameworks/base" diff --check
git -C "$SOURCE_ROOT/frameworks/native" diff --check
git -C "$SOURCE_ROOT/system/core" diff --check
git -C "$SOURCE_ROOT/device/phh/treble" diff --check
git -C "$SOURCE_ROOT/packages/modules/NetworkStack" diff --check
git -C "$SOURCE_ROOT/packages/apps/Launcher3" diff --check
