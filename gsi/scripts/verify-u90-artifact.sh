#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
    echo "usage: $0 <product-out> <aonly-image> <artifact-dir> <orientation>" >&2
    exit 64
fi

readonly PRODUCT_OUT="$1"
readonly AONLY_IMAGE="$2"
readonly ARTIFACT_DIR="$3"
readonly ORIENTATION="$4"

if [[ ! "$ORIENTATION" =~ ^(0|90|180|270)$ ]]; then
    printf 'unsupported orientation: %s\n' "$ORIENTATION" >&2
    exit 1
fi

test -d "$PRODUCT_OUT"
test -s "$AONLY_IMAGE"
test -d "$ARTIFACT_DIR"

readonly PROP_FILE="$(find "$PRODUCT_OUT" -type f -path '*/etc/prop.default' -print -quit)"
readonly CAMERA_SERVICE="$(find "$PRODUCT_OUT" -type f -name libcameraservice.so -print -quit)"
readonly SYSTEM_TREE="$PRODUCT_OUT/system"

test -n "$PROP_FILE"
test -n "$CAMERA_SERVICE"
test -d "$SYSTEM_TREE"
grep -Fx "ro.u90.camera.front.orientation=$ORIENTATION" "$PROP_FILE"
grep -R -Fqx 'ro.product.locale=zh-CN' "$PRODUCT_OUT"
grep -R -Fqx 'persist.sys.locale=zh-CN' "$PRODUCT_OUT"
grep -R -Fqx 'persist.sys.timezone=Asia/Shanghai' "$PRODUCT_OUT"
grep -R -Fqx 'persist.sys.time_12_24=24' "$PRODUCT_OUT"
grep -R -Fqx 'ro.build.characteristics=tablet' "$PRODUCT_OUT"
grep -R -Fqx 'ro.debuggable=0' "$PRODUCT_OUT"
strings "$CAMERA_SERVICE" | grep -Fq 'U90 camera %s: overriding sensor orientation'

if find "$SYSTEM_TREE" -type f \( -name phh-su -o -iname '*superuser*.apk' \) -print -quit | grep -q .; then
    echo 'built system contains a PHH root component' >&2
    exit 1
fi

e2fsck -fn "$AONLY_IMAGE"
sha256sum "$AONLY_IMAGE" > "$ARTIFACT_DIR/$(basename "$AONLY_IMAGE").sha256"
