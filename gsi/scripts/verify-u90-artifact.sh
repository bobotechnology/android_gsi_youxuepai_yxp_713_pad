#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly GSI_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly CONFIG="$GSI_ROOT/config/u90-a11-v313.env"

source "$CONFIG"

if [[ $# -ne 4 ]]; then
    echo "usage: $0 <product-out> <system-image> <artifact-dir> <orientation>" >&2
    exit 64
fi

readonly PRODUCT_OUT="$1"
readonly SYSTEM_IMAGE="$2"
readonly ARTIFACT_DIR="$3"
readonly ORIENTATION="$4"

if [[ ! "$ORIENTATION" =~ ^(0|90|180|270)$ ]]; then
    printf 'unsupported orientation: %s\n' "$ORIENTATION" >&2
    exit 1
fi

test -d "$PRODUCT_OUT"
test -s "$SYSTEM_IMAGE"
test -d "$ARTIFACT_DIR"

readonly PROP_FILE="$(find "$PRODUCT_OUT" -type f -path '*/etc/prop.default' -print -quit)"
readonly CAMERA_SERVICE="$(find "$PRODUCT_OUT" -type f -name libcameraservice.so -print -quit)"
readonly SYSTEM_TREE="$PRODUCT_OUT/system"
readonly SYSTEM_BUILD_PROP="$SYSTEM_TREE/build.prop"
readonly PRODUCT_BUILD_PROP="$SYSTEM_TREE/product/build.prop"
readonly FCITX5_APK="$(find "$SYSTEM_TREE" -type f -path '*U90Fcitx5*' -name '*.apk' -print -quit)"
readonly FCITX5_ZIP_ENTRIES="$(mktemp)"

trap 'rm -f "$FCITX5_ZIP_ENTRIES"' EXIT

test -n "$PROP_FILE"
test -n "$CAMERA_SERVICE"
test -d "$SYSTEM_TREE"
test -s "$SYSTEM_BUILD_PROP"
test -s "$PRODUCT_BUILD_PROP"
test -n "$FCITX5_APK"
grep -Fx "ro.u90.camera.front.orientation=$ORIENTATION" "$PROP_FILE"
grep -Fx 'ro.product.locale=zh-CN' "$SYSTEM_BUILD_PROP"
grep -Fx 'persist.sys.locale=zh-CN' "$PROP_FILE"
grep -Fx 'persist.sys.timezone=Asia/Shanghai' "$PROP_FILE"
grep -Fx 'persist.sys.time_12_24=24' "$PROP_FILE"
grep -Fx 'ro.build.characteristics=tablet' "$PRODUCT_BUILD_PROP"
grep -aFq 'U90 camera %s: overriding sensor orientation' "$CAMERA_SERVICE"

if [[ "$FCITX5_APK" != "$SYSTEM_TREE/app/"* ]]; then
    echo 'Fcitx5 must be installed as an unprivileged system app' >&2
    exit 1
fi

# android_app_import zipaligns a presigned APK, changing its archive hash. The
# staged source APK is checked before the build; validate the installed payload instead.
unzip -tqq "$FCITX5_APK"
unzip -Z1 "$FCITX5_APK" > "$FCITX5_ZIP_ENTRIES"
grep -Fxq 'AndroidManifest.xml' "$FCITX5_ZIP_ENTRIES"
grep -Fxq 'lib/arm64-v8a/libFcitx5Core.so' "$FCITX5_ZIP_ENTRIES"

if [[ -n "$(find "$SYSTEM_TREE" -type f \( -name phh-su -o -iname '*superuser*.apk' \) -print -quit)" ]]; then
    echo 'built system contains a PHH root component' >&2
    exit 1
fi

command -v debugfs >/dev/null

for phh_su_path in /bin/phh-su /xbin/phh-su /system/bin/phh-su /system/xbin/phh-su; do
    if debugfs -R "stat $phh_su_path" "$SYSTEM_IMAGE" 2>/dev/null | grep -q '^Inode:'; then
        echo "system image contains phh-su at $phh_su_path" >&2
        exit 1
    fi
done

for legacy_twrp_path in /etc/init/twrp.rc /bin/twrp.sh /system/etc/init/twrp.rc /system/bin/twrp.sh; do
    if debugfs -R "stat $legacy_twrp_path" "$SYSTEM_IMAGE" 2>/dev/null | \
        grep -q '^Inode:'; then
        echo "system image retains legacy PHH TWRP auto-flash file: $legacy_twrp_path" >&2
        exit 1
    fi
done

for app_dir in /app /priv-app /system/app /system/priv-app; do
    if debugfs -R "ls -p $app_dir" "$SYSTEM_IMAGE" 2>/dev/null | \
        grep -Eiq '(superuser|magisk)'; then
        echo "system image contains a root-management package under $app_dir" >&2
        exit 1
    fi
done

# The stock U90 ramdisk first-stage init unconditionally execs
# /system/bin/init; a missing file panics back to fastboot.
if ! debugfs -R 'stat /system/bin/init' "$SYSTEM_IMAGE" 2>/dev/null | grep -q '^Inode:'; then
    echo 'system image does not contain /system/bin/init' >&2
    echo 'the U90 first-stage init execs /system/bin/init unconditionally, so the device would panic to fastboot' >&2
    exit 1
fi

e2fsck -fn "$SYSTEM_IMAGE"
sha256sum "$SYSTEM_IMAGE" > "$ARTIFACT_DIR/$(basename "$SYSTEM_IMAGE").sha256"
