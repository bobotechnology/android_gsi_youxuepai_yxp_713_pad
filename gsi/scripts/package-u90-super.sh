#!/usr/bin/env bash
set -euo pipefail

readonly SUPER_SIZE=8589934592
readonly MAIN_GROUP_SIZE=8342470656
readonly PRODUCT_SIZE=382234624
readonly VENDOR_SIZE=582471680
readonly METADATA_SIZE=65536
readonly METADATA_SLOTS=2
readonly DISABLED_VBMETA_FLAGS=3
readonly SCATTER_FILE_NAME=MT6779_Android_scatter.txt

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command is unavailable: $1"
}

usage() {
    cat <<'EOF'
usage: package-u90-super.sh \
  --firmware-dir <stock-firmware-dir> \
  --system-image <raw-ext4-system-image> \
  --output-dir <new-or-empty-output-dir>

Creates a complete U90 package containing:
  - super_u90_gsi.sparse.img: stock product/vendor plus the supplied GSI system
  - super_u90_gsi.raw.img: raw 8 GiB form for TWRP dd only
  - vbmeta_u90_avb_disabled.img: generated vbmeta with AVB flags 3
  - vbmeta_system_u90_avb_disabled.img: generated vbmeta_system with AVB flags 3
  - vbmeta_vendor_u90_avb_disabled.img: generated vbmeta_vendor with AVB flags 3

The system image must be a raw ext4 image in system-as-root layout. The
packager reads its logical-partition size with stat and requires the image to
contain /system/bin/init, because the stock U90 first-stage init execs that
path unconditionally.

Only AOSP simg2img, lpdump, lpunpack, lpmake, and avbtool are used for image
construction. The three AVB images are generated independently with the same
official avbtool command and must be flashed only to their matching partitions.
EOF
}

firmware_dir=''
system_image=''
output_dir=''

while [[ $# -gt 0 ]]; do
    case "$1" in
        --firmware-dir)
            [[ $# -ge 2 ]] || die 'missing value for --firmware-dir'
            firmware_dir="$2"
            shift 2
            ;;
        --system-image)
            [[ $# -ge 2 ]] || die 'missing value for --system-image'
            system_image="$2"
            shift 2
            ;;
        --output-dir)
            [[ $# -ge 2 ]] || die 'missing value for --output-dir'
            output_dir="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

[[ -n "$firmware_dir" ]] || die '--firmware-dir is required'
[[ -n "$system_image" ]] || die '--system-image is required'
[[ -n "$output_dir" ]] || die '--output-dir is required'
[[ -d "$firmware_dir" ]] || die "firmware directory does not exist: $firmware_dir"
[[ -s "$firmware_dir/super.img" ]] || die "missing stock super image: $firmware_dir/super.img"
[[ -s "$firmware_dir/vbmeta.img" ]] || die "missing stock vbmeta image: $firmware_dir/vbmeta.img"
[[ -s "$firmware_dir/vbmeta_system.img" ]] || die "missing stock vbmeta_system image: $firmware_dir/vbmeta_system.img"
[[ -s "$firmware_dir/vbmeta_vendor.img" ]] || die "missing stock vbmeta_vendor image: $firmware_dir/vbmeta_vendor.img"
[[ -s "$firmware_dir/boot.img" ]] || die "missing stock boot image: $firmware_dir/boot.img"
[[ -s "$firmware_dir/dtbo-verified.img" ]] || die "missing stock dtbo image: $firmware_dir/dtbo-verified.img"
[[ -s "$firmware_dir/$SCATTER_FILE_NAME" ]] || die "missing stock scatter file: $firmware_dir/$SCATTER_FILE_NAME"
[[ -s "$system_image" ]] || die "system image does not exist: $system_image"

if [[ -n "${U90_ANDROID_HOST_BIN:-}" ]]; then
    export PATH="$U90_ANDROID_HOST_BIN:$PATH"
fi
if [[ -n "${U90_ANDROID_HOST_LIB:-}" ]]; then
    export LD_LIBRARY_PATH="$U90_ANDROID_HOST_LIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

for command in avbtool cmp debugfs lpdump lpmake lpunpack simg2img; do
    require_command "$command"
done

if [[ -e "$output_dir" && ! -d "$output_dir" ]]; then
    die "output path is not a directory: $output_dir"
fi
if [[ -d "$output_dir" ]] && [[ -n "$(find "$output_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    die "output directory must be empty: $output_dir"
fi
mkdir -p "$output_dir"

assert_root_manager_absent() {
    local image="$1"
    local app_dir=''

    for path in /bin/phh-su /xbin/phh-su /system/bin/phh-su /system/xbin/phh-su; do
        if debugfs -R "stat $path" "$image" 2>/dev/null | grep -q '^Inode:'; then
            die "system image contains phh-su at $path"
        fi
    done

    for app_dir in /app /priv-app /system/app /system/priv-app; do
        if debugfs -R "ls -p $app_dir" "$image" 2>/dev/null | grep -Eiq '(superuser|supersu|magisk)'; then
            die "system image contains a root-management package under $app_dir"
        fi
    done
}

assert_legacy_twrp_autoflash_absent() {
    local image="$1"
    local path=''

    for path in /etc/init/twrp.rc /bin/twrp.sh /system/etc/init/twrp.rc /system/bin/twrp.sh; do
        if debugfs -R "stat $path" "$image" 2>/dev/null | grep -q '^Inode:'; then
            die "system image retains legacy PHH TWRP auto-flash file: $path"
        fi
    done
}

assert_sar_init_present() {
    local image="$1"

    # The stock U90 ramdisk first-stage init unconditionally execs
    # /system/bin/init; a missing file panics back to fastboot.
    if ! debugfs -R 'stat /system/bin/init' "$image" 2>/dev/null | grep -q '^Inode:'; then
        die "system image does not contain /system/bin/init; the U90 first-stage init execs that path unconditionally and would panic to fastboot"
    fi
}

assert_root_manager_absent "$system_image"
assert_legacy_twrp_autoflash_absent "$system_image"
assert_sar_init_present "$system_image"

get_scatter_value() {
    local partition="$1"
    local field="$2"

    awk -v partition="$partition" -v field="$field" '
        $1 == "partition_name:" {
            if (found) {
                exit
            }
            found = ($2 == partition)
            next
        }
        found && $1 == field {
            print $2
            exit
        }
    ' "$firmware_dir/$SCATTER_FILE_NAME"
}

verify_scatter_partition() {
    local partition="$1"
    local expected_start="$2"
    local expected_size="$3"
    local actual_start=''
    local actual_size=''
    local actual_region=''
    local actual_storage=''

    actual_start="$(get_scatter_value "$partition" 'linear_start_addr:')"
    actual_size="$(get_scatter_value "$partition" 'partition_size:')"
    actual_region="$(get_scatter_value "$partition" 'region:')"
    actual_storage="$(get_scatter_value "$partition" 'storage:')"
    [[ "$actual_start" == "$expected_start" ]] || die "unexpected $partition scatter start: $actual_start"
    [[ "$actual_size" == "$expected_size" ]] || die "unexpected $partition scatter size: $actual_size"
    [[ "$actual_region" == 'EMMC_USER' ]] || die "unexpected $partition scatter region: $actual_region"
    [[ "$actual_storage" == 'HW_STORAGE_EMMC' ]] || die "unexpected $partition scatter storage: $actual_storage"
}

verify_scatter_partition super 0x2c800000 0x200000000
verify_scatter_partition misc 0x2008000 0x80000
verify_scatter_partition vbmeta 0x3608000 0x800000
verify_scatter_partition vbmeta_system 0x3e08000 0x800000
verify_scatter_partition vbmeta_vendor 0x4608000 0x800000

scatter_super_start="$(get_scatter_value super 'linear_start_addr:')"
scatter_misc_start="$(get_scatter_value misc 'linear_start_addr:')"
scatter_vbmeta_start="$(get_scatter_value vbmeta 'linear_start_addr:')"
scatter_vbmeta_system_start="$(get_scatter_value vbmeta_system 'linear_start_addr:')"
scatter_vbmeta_vendor_start="$(get_scatter_value vbmeta_vendor 'linear_start_addr:')"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

stock_raw="$tmpdir/stock-super.raw.img"
stock_parts="$tmpdir/stock-parts"
stock_vbmeta="$tmpdir/stock-vbmeta.img"
verify_parts="$tmpdir/verify-parts"
disabled_vbmeta="$output_dir/vbmeta_u90_avb_disabled.img"
disabled_vbmeta_system="$output_dir/vbmeta_system_u90_avb_disabled.img"
disabled_vbmeta_vendor="$output_dir/vbmeta_vendor_u90_avb_disabled.img"
super_image="$output_dir/super_u90_gsi.sparse.img"
raw_super_image="$output_dir/super_u90_gsi.raw.img"
packaged_system="$output_dir/system_gsi.img"

make_disabled_vbmeta() {
    local image="$1"
    local info="$2"

    avbtool make_vbmeta_image \
        --flags "$DISABLED_VBMETA_FLAGS" \
        --padding_size 4096 \
        --output "$image"

    [[ "$(stat -c %s "$image")" == '4096' ]] || die "unexpected disabled vbmeta size: $image"
    avbtool info_image --image "$image" > "$info"
    grep -Eq '^Algorithm:[[:space:]]+NONE$' "$info" || die "disabled vbmeta is unexpectedly signed: $image"
    grep -Eq '^Flags:[[:space:]]+3$' "$info" || die "disabled vbmeta flags are incorrect: $image"
}

simg2img "$firmware_dir/super.img" "$stock_raw"
lpdump "$stock_raw" > "$tmpdir/stock-lpdump.txt"
grep -Fq "Size: $SUPER_SIZE bytes" "$tmpdir/stock-lpdump.txt" || die 'unexpected stock super size'
grep -Fq "Maximum size: $MAIN_GROUP_SIZE bytes" "$tmpdir/stock-lpdump.txt" || die 'unexpected stock main group size'

mkdir "$stock_parts"
lpunpack "$stock_raw" "$stock_parts"

[[ "$(stat -c %s "$stock_parts/product.img")" == "$PRODUCT_SIZE" ]] || die 'unexpected stock product size'
[[ "$(stat -c %s "$stock_parts/vendor.img")" == "$VENDOR_SIZE" ]] || die 'unexpected stock vendor size'

stock_product_sha256="$(sha256sum "$stock_parts/product.img" | awk '{print $1}')"
stock_vendor_sha256="$(sha256sum "$stock_parts/vendor.img" | awk '{print $1}')"
input_system_sha256="$(sha256sum "$system_image" | awk '{print $1}')"

system_size="$(stat -c %s "$system_image")"
if (( PRODUCT_SIZE + system_size + VENDOR_SIZE > MAIN_GROUP_SIZE )); then
    die "logical partitions exceed main group: $((PRODUCT_SIZE + system_size + VENDOR_SIZE)) > $MAIN_GROUP_SIZE"
fi

lpmake \
    --metadata-size "$METADATA_SIZE" \
    --metadata-slots "$METADATA_SLOTS" \
    --device "super:$SUPER_SIZE" \
    --group "main:$MAIN_GROUP_SIZE" \
    --partition "product:readonly:$PRODUCT_SIZE:main" \
    --image "product=$stock_parts/product.img" \
    --partition "system:readonly:$system_size:main" \
    --image "system=$system_image" \
    --partition "vendor:readonly:$VENDOR_SIZE:main" \
    --image "vendor=$stock_parts/vendor.img" \
    --sparse \
    --output "$super_image"

make_disabled_vbmeta "$disabled_vbmeta" "$tmpdir/disabled-vbmeta-avb.txt"
make_disabled_vbmeta "$disabled_vbmeta_system" "$tmpdir/disabled-vbmeta-system-avb.txt"
make_disabled_vbmeta "$disabled_vbmeta_vendor" "$tmpdir/disabled-vbmeta-vendor-avb.txt"
cmp -s "$disabled_vbmeta" "$disabled_vbmeta_system" || die 'generated vbmeta images unexpectedly differ'
cmp -s "$disabled_vbmeta" "$disabled_vbmeta_vendor" || die 'generated vbmeta images unexpectedly differ'

cp --reflink=auto "$system_image" "$packaged_system"
cmp -s "$system_image" "$packaged_system" || die 'packaged system copy differs from the input image'

simg2img "$super_image" "$raw_super_image"
[[ "$(stat -c %s "$raw_super_image")" == "$SUPER_SIZE" ]] || die 'unexpected raw super size'
lpdump "$raw_super_image" > "$tmpdir/verify-lpdump.txt"
mkdir "$verify_parts"
lpunpack "$raw_super_image" "$verify_parts"

cmp -s "$stock_parts/product.img" "$verify_parts/product.img" || die 'product partition changed during packaging'
cmp -s "$stock_parts/vendor.img" "$verify_parts/vendor.img" || die 'vendor partition changed during packaging'
cmp -s "$system_image" "$verify_parts/system.img" || die 'system partition changed during packaging'

cp "$firmware_dir/vbmeta.img" "$stock_vbmeta"
avbtool info_image --image "$stock_vbmeta" > "$tmpdir/stock-vbmeta-avb.txt"

{
    printf 'stock_super_sha256=%s\n' "$(sha256sum "$firmware_dir/super.img" | awk '{print $1}')"
    printf 'stock_vbmeta_sha256=%s\n' "$(sha256sum "$firmware_dir/vbmeta.img" | awk '{print $1}')"
    printf 'stock_vbmeta_system_sha256=%s\n' "$(sha256sum "$firmware_dir/vbmeta_system.img" | awk '{print $1}')"
    printf 'stock_vbmeta_vendor_sha256=%s\n' "$(sha256sum "$firmware_dir/vbmeta_vendor.img" | awk '{print $1}')"
    printf 'stock_boot_sha256=%s\n' "$(sha256sum "$firmware_dir/boot.img" | awk '{print $1}')"
    printf 'stock_dtbo_sha256=%s\n' "$(sha256sum "$firmware_dir/dtbo-verified.img" | awk '{print $1}')"
    printf 'stock_scatter_file=%s\n' "$SCATTER_FILE_NAME"
    printf 'stock_scatter_sha256=%s\n' "$(sha256sum "$firmware_dir/$SCATTER_FILE_NAME" | awk '{print $1}')"
    printf 'scatter_super_start=%s\n' "$scatter_super_start"
    printf 'scatter_misc_start=%s\n' "$scatter_misc_start"
    printf 'scatter_vbmeta_start=%s\n' "$scatter_vbmeta_start"
    printf 'scatter_vbmeta_system_start=%s\n' "$scatter_vbmeta_system_start"
    printf 'scatter_vbmeta_vendor_start=%s\n' "$scatter_vbmeta_vendor_start"
    printf 'stock_product_sha256=%s\n' "$stock_product_sha256"
    printf 'stock_vendor_sha256=%s\n' "$stock_vendor_sha256"
    printf 'input_system_sha256=%s\n' "$input_system_sha256"
    printf 'system_gsi_sha256=%s\n' "$input_system_sha256"
    printf 'system_layout=sar\n'
    printf 'product_logical_sha256=%s\n' "$stock_product_sha256"
    printf 'system_logical_sha256=%s\n' "$input_system_sha256"
    printf 'vendor_logical_sha256=%s\n' "$stock_vendor_sha256"
    printf 'super_sparse_sha256=%s\n' "$(sha256sum "$super_image" | awk '{print $1}')"
    printf 'super_raw_sha256=%s\n' "$(sha256sum "$raw_super_image" | awk '{print $1}')"
    printf 'super_raw_size=%s\n' "$(stat -c %s "$raw_super_image")"
    printf 'vbmeta_u90_avb_disabled_sha256=%s\n' "$(sha256sum "$disabled_vbmeta" | awk '{print $1}')"
    printf 'vbmeta_system_u90_avb_disabled_sha256=%s\n' "$(sha256sum "$disabled_vbmeta_system" | awk '{print $1}')"
    printf 'vbmeta_vendor_u90_avb_disabled_sha256=%s\n' "$(sha256sum "$disabled_vbmeta_vendor" | awk '{print $1}')"
    printf 'vbmeta_u90_avb_disabled_target_partition=vbmeta\n'
    printf 'vbmeta_system_u90_avb_disabled_target_partition=vbmeta_system\n'
    printf 'vbmeta_vendor_u90_avb_disabled_target_partition=vbmeta_vendor\n'
    printf 'vbmeta_u90_avb_disabled_flags=%s\n' "$DISABLED_VBMETA_FLAGS"
    printf 'vbmeta_system_u90_avb_disabled_flags=%s\n' "$DISABLED_VBMETA_FLAGS"
    printf 'vbmeta_vendor_u90_avb_disabled_flags=%s\n' "$DISABLED_VBMETA_FLAGS"
    printf 'system_logical_size=%s\n' "$system_size"
    printf 'product_vendor_verification=identical\n'
    printf 'system_verification=identical\n'
    printf 'legacy_phh_twrp_autoflash=absent\n'
    printf '\n[stock-lpdump]\n'
    cat "$tmpdir/stock-lpdump.txt"
    printf '\n[packaged-lpdump]\n'
    cat "$tmpdir/verify-lpdump.txt"
    printf '\n[stock-vbmeta-avb]\n'
    cat "$tmpdir/stock-vbmeta-avb.txt"
    printf '\n[disabled-vbmeta-avb]\n'
    cat "$tmpdir/disabled-vbmeta-avb.txt"
    printf '\n[disabled-vbmeta-system-avb]\n'
    cat "$tmpdir/disabled-vbmeta-system-avb.txt"
    printf '\n[disabled-vbmeta-vendor-avb]\n'
    cat "$tmpdir/disabled-vbmeta-vendor-avb.txt"
} > "$output_dir/PACKAGE-MANIFEST.txt"

cat > "$output_dir/FLASH-PLAN.txt" <<EOF
U90 complete GSI flash plan

Use the stock P713mt6779_20221129_2216 scatter in Download Only mode.
The bootloader must remain unlocked. Do not use Format All + Download.

Select exactly these four rows:
  super   -> super_u90_gsi.sparse.img
  vbmeta  -> vbmeta_u90_avb_disabled.img
  vbmeta_system -> vbmeta_system_u90_avb_disabled.img
  vbmeta_vendor -> vbmeta_vendor_u90_avb_disabled.img

The sparse super payload is for the SP Flash Tool scatter workflow. Never use
dd with super_u90_gsi.sparse.img: its first 4 KiB is an Android sparse header,
not logical-partition metadata. If flashing through TWRP dd, use only
super_u90_gsi.raw.img (the expanded 8 GiB form).

Leave these rows and their stock contents unchanged:
  preloader, lk, boot, recovery, dtbo, userdata

Scatter targets for the selected rows:
  super   at $scatter_super_start, partition size 0x200000000
  vbmeta  at $scatter_vbmeta_start, partition size 0x00800000
  vbmeta_system at $scatter_vbmeta_system_start, partition size 0x00800000
  vbmeta_vendor at $scatter_vbmeta_vendor_start, partition size 0x00800000

Each named vbmeta payload has AVB flags 3 (hashtree and verification disabled).
Flash every file only to its matching scatter row. Keep the device unlocked
after flashing this four-image set.

Before rebooting to Android, collect a full read-only TWRP proof from the
repository root:
  .\tools\collect-u90-recovery-state.ps1 -FullLogicalHashes

Then verify the capture before changing another partition or booting Android:
  .\tools\verify-u90-recovery-state.ps1 -RecoveryState <capture-dir>\recovery-state.txt -PackageDir <this-package-dir> -RequireDynamicPartitionProof

After the verifier passes, keep this read-only collector running on the host
while manually selecting Reboot System in TWRP:
  .\tools\capture-u90-runtime-reboot.ps1 -CaptureSeconds 420

It captures all Android logcat buffers and read-only process/property snapshots.
If the tablet returns to fastboot, preserve reboot-signals.txt and
logcat-all.txt before changing any image.

If the attempt returns to fastboot or loses adb, do not reflash first. Return
to TWRP, collect another full recovery state, and compare it with the
verified pre-boot capture:
  .\tools\collect-u90-recovery-state.ps1 -FullLogicalHashes
  .\tools\compare-u90-boot-attempt.ps1 -BeforeRecoveryState <before-capture>\recovery-state.txt -AfterRecoveryState <after-capture>\recovery-state.txt

The comparison identifies a BCB command newly written during the attempt,
unexpected partition changes, and explicit bootloader-reboot evidence in
persistent logs. Preserve both capture directories before changing any image.

This package script rejects any system image that retains PHH's legacy TWRP
auto-flash rc or script. The manifest records
legacy_phh_twrp_autoflash=absent. The unrelated busybox_phh payload remains
because other PHH compatibility scripts use it.

The recovery collector still records phh_twrp_flash_trigger. Keep it absent
for a clean transition from older test images; a newly packaged system does
not include the legacy handler that would execute that marker.

If verification reports a nonempty misc BCB command such as boot-fastboot or
bootonce-bootloader, do not boot Android. The stock scatter maps misc to
$scatter_misc_start with a size of 0x00080000. In the TWRP terminal, clear only
the 4 KiB Android bootloader-message area, then collect and verify again:
  dd if=/dev/zero of=/dev/block/by-name/misc bs=4096 count=1
  sync

Package verification:
  super SHA-256:  $(sha256sum "$super_image" | awk '{print $1}')
  raw super SHA-256: $(sha256sum "$raw_super_image" | awk '{print $1}')
  vbmeta SHA-256: $(sha256sum "$disabled_vbmeta" | awk '{print $1}')
  vbmeta_system SHA-256: $(sha256sum "$disabled_vbmeta_system" | awk '{print $1}')
  vbmeta_vendor SHA-256: $(sha256sum "$disabled_vbmeta_vendor" | awk '{print $1}')
  stock boot SHA-256 expected after the test: $(sha256sum "$firmware_dir/boot.img" | awk '{print $1}')
  stock dtbo SHA-256 expected after the test: $(sha256sum "$firmware_dir/dtbo-verified.img" | awk '{print $1}')
EOF

printf 'complete package: %s\n' "$output_dir"
