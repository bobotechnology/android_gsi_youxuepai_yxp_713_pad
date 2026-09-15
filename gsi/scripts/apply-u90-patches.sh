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
        git -C "$checkout" apply --check --whitespace=error-all "$patch"
        git -C "$checkout" apply --whitespace=error-all "$patch"
    done
}

assert_revision "$SOURCE_ROOT/frameworks/av" "$FRAMEWORKS_AV_REV"
assert_revision "$SOURCE_ROOT/frameworks/base" "$FRAMEWORKS_BASE_REV"
assert_revision "$SOURCE_ROOT/device/phh/treble" "$DEVICE_PHH_TREBLE_REV"

apply_patchset "$SOURCE_ROOT/frameworks/av" "$GSI_ROOT/patches/frameworks-av"
apply_patchset "$SOURCE_ROOT/frameworks/base" "$GSI_ROOT/patches/frameworks-base"
apply_patchset "$SOURCE_ROOT/device/phh/treble" "$GSI_ROOT/patches/device-phh-treble"

git -C "$SOURCE_ROOT/frameworks/av" diff --check
git -C "$SOURCE_ROOT/frameworks/base" diff --check
git -C "$SOURCE_ROOT/device/phh/treble" diff --check
