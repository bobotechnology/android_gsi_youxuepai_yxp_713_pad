#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly GSI_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly RECIPE_ROOT="$(cd -- "$GSI_ROOT/.." && pwd)"
readonly CONFIG="$GSI_ROOT/config/u90-a11-v313.env"
readonly MODE="${1:-build}"
readonly WORK_ROOT="${U90_WORK_ROOT:-/work}"
readonly SOURCE_DIR="${U90_SOURCE_DIR:-$WORK_ROOT/android}"
readonly STATE_DIR="${U90_STATE_DIR:-$WORK_ROOT/state}"
readonly ARTIFACT_DIR="${U90_ARTIFACT_DIR:-/artifacts}"
readonly FRONT_SENSOR_ORIENTATION="${U90_FRONT_CAMERA_ORIENTATION:-90}"
readonly BUILD_JOBS="${U90_BUILD_JOBS:-$(nproc)}"
readonly CCACHE_DIR="${U90_CCACHE_DIR:-$WORK_ROOT/ccache}"
readonly CCACHE_MAXSIZE="${U90_CCACHE_MAXSIZE:-40G}"
readonly PACKAGE_FIRMWARE_DIR="${U90_PACKAGE_FIRMWARE_DIR:-/firmware}"
readonly PACKAGE_SYSTEM_IMAGE="${U90_PACKAGE_SYSTEM_IMAGE:-}"
readonly PACKAGE_OUTPUT_DIR="${U90_PACKAGE_OUTPUT_DIR:-$ARTIFACT_DIR/package}"

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command is unavailable: $1"
}

validate_orientation() {
    case "$FRONT_SENSOR_ORIENTATION" in
        0|90|180|270) ;;
        *) die "U90_FRONT_CAMERA_ORIENTATION must be 0, 90, 180, or 270" ;;
    esac
}

validate_build_jobs() {
    [[ "$BUILD_JOBS" =~ ^[1-9][0-9]*$ ]] || \
        die "U90_BUILD_JOBS must be a positive integer"
}

configure_git() {
    git config --global user.name 'U90 GSI build'
    git config --global user.email 'u90-gsi@local'
    git config --global --add safe.directory "$RECIPE_ROOT" >/dev/null 2>&1 || true
    git config --global --add safe.directory "$SOURCE_DIR" >/dev/null 2>&1 || true
}

prepare_artifact_dir() {
    case "$ARTIFACT_DIR" in
        /artifacts|/artifacts/*) ;;
        *) die "U90_ARTIFACT_DIR must stay under /artifacts" ;;
    esac

    if [[ -d "$ARTIFACT_DIR" ]] && \
        [[ -n "$(find "$ARTIFACT_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
        die "build artifact directory must be empty: $ARTIFACT_DIR"
    fi

    install -d "$ARTIFACT_DIR"
}

prepare_pinned_manifest() {
    local manifest_dir="$STATE_DIR/manifest"
    local raw_manifest="$manifest_dir/release-manifest.xml"
    local prepared_manifest="$manifest_dir/manifest.xml"
    local release_marker="$manifest_dir/release-manifest.sha256"

    if [[ -s "$raw_manifest" && -s "$prepared_manifest" && -s "$release_marker" ]] &&
        [[ "$(<"$release_marker")" == "$RELEASE_MANIFEST_SHA256" ]] &&
        printf '%s  %s\n' "$RELEASE_MANIFEST_SHA256" "$raw_manifest" | sha256sum -c - >/dev/null &&
        git -C "$manifest_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 &&
        git -C "$manifest_dir" diff --quiet; then
        return
    fi

    rm -rf "$manifest_dir"
    install -d "$manifest_dir"
    curl --fail --location --retry 3 \
        "$RELEASE_MANIFEST_URL" \
        -o "$raw_manifest"
    printf '%s  %s\n' "$RELEASE_MANIFEST_SHA256" "$raw_manifest" | \
        sha256sum -c -
    sed \
        's#<remote name="aosp" fetch="\.\." review="https://android-review.googlesource.com/"/>#<remote name="aosp" fetch="https://android.googlesource.com/" review="https://android-review.googlesource.com/"/>#' \
        "$raw_manifest" > "$prepared_manifest"
    printf '%s\n' "$RELEASE_MANIFEST_SHA256" > "$release_marker"
    git -C "$manifest_dir" init -q
    git -C "$manifest_dir" config user.name 'U90 GSI build'
    git -C "$manifest_dir" config user.email 'u90-gsi@local'
    git -C "$manifest_dir" add release-manifest.xml manifest.xml release-manifest.sha256
    git -C "$manifest_dir" commit -qm 'Pinned PHH v313 manifest'
}

fetch_fcitx5() {
    local apk="$STATE_DIR/downloads/$FCITX5_APK_NAME"
    local temporary_apk="$apk.tmp"
    local actual_hash=''

    install -d "$STATE_DIR/downloads"
    if [[ -s "$apk" ]]; then
        actual_hash="$(sha256sum "$apk" | awk '{print $1}')"
    fi
    if [[ "$actual_hash" != "$FCITX5_APK_SHA256" ]]; then
        rm -f "$temporary_apk"
        curl --fail --location --retry 3 "$FCITX5_APK_URL" -o "$temporary_apk"
        printf '%s  %s\n' "$FCITX5_APK_SHA256" "$temporary_apk" | sha256sum -c -
        mv -f "$temporary_apk" "$apk"
    fi

    printf '%s  %s\n' "$FCITX5_APK_SHA256" "$apk" | sha256sum -c -
    unzip -Z1 "$apk" | grep -Fx 'AndroidManifest.xml' >/dev/null
    unzip -Z1 "$apk" | grep -E '^lib/arm64-v8a/' >/dev/null
    export U90_FCITX5_APK="$apk"
}

sync_android_source() {
    local source_manifest_revision=''
    local state_manifest_revision

    install -d "$SOURCE_DIR"
    state_manifest_revision="$(git -C "$STATE_DIR/manifest" rev-parse HEAD)"
    if [[ -d "$SOURCE_DIR/.repo/manifests" ]]; then
        source_manifest_revision="$(git -C "$SOURCE_DIR/.repo/manifests" rev-parse HEAD 2>/dev/null || true)"
    fi

    if [[ "$source_manifest_revision" != "$state_manifest_revision" ]]; then
        if [[ -d "$SOURCE_DIR/.repo" ]]; then
            rm -rf "$SOURCE_DIR/.repo/manifests" "$SOURCE_DIR/.repo/manifests.git"
            rm -f "$SOURCE_DIR/.repo/manifest.xml"
        fi
        (
            cd "$SOURCE_DIR"
            repo init --depth=1 --partial-clone --clone-filter=blob:limit=10M \
                --groups="$REPO_GROUPS" \
                -u "file://$STATE_DIR/manifest" \
                -m manifest.xml
        )
    else
        printf 'repo client already matches the pinned manifest.\n'
    fi

    (
        cd "$SOURCE_DIR"
        repo sync -c --no-tags --no-clone-bundle --optimized-fetch --prune \
            -j"$REPO_SYNC_JOBS"
        repo status
    )
}

# The recipe owns every tree it patches. Reset them to their pinned revisions
# before applying the patch sets: apply-u90-patches.sh is idempotent for a given
# patch, but a rebuild that follows an edit to a patch would otherwise either
# abort with "patch neither applies nor matches the existing tree" or apply the
# new hunks on top of the previous version's hunks.
reset_patched_trees() {
    local checkout

    for checkout in \
        frameworks/av \
        frameworks/base \
        frameworks/native \
        system/core \
        device/phh/treble \
        packages/modules/NetworkStack \
        packages/apps/Launcher3; do
        test -d "$SOURCE_DIR/$checkout" || die "patched checkout is missing: $checkout"
        git -C "$SOURCE_DIR/$checkout" checkout -- .
    done
}

prepare_android_source() {
    test -d "$SOURCE_DIR/.repo" || die 'Android source has not been synced'
    reset_patched_trees
    git -C "$SOURCE_DIR/device/phh/treble" clean -fdx
    (
        cd "$SOURCE_DIR/device/phh/treble"
        bash generate.sh
    )
    test -s "$SOURCE_DIR/device/phh/treble/AndroidProducts.mk"
    test -s "$SOURCE_DIR/device/phh/treble/treble_arm64_bvN.mk"
    rm -f "$SOURCE_DIR/vendor/gapps/interfaces/wifi_ext/Android.bp"
    bash "$GSI_ROOT/scripts/apply-u90-patches.sh" "$SOURCE_DIR"
    (
        cd "$SOURCE_DIR"
        repo manifest -r > "$ARTIFACT_DIR/source-manifest.xml"
    )
    git -C "$SOURCE_DIR/frameworks/av" diff --check
    git -C "$SOURCE_DIR/frameworks/base" diff --check
    git -C "$SOURCE_DIR/device/phh/treble" diff --check
    git -C "$SOURCE_DIR/packages/modules/NetworkStack" diff --check
    git -C "$SOURCE_DIR/packages/apps/Launcher3" diff --check
}

write_build_info() {
    local recipe_revision

    recipe_revision="$(git -c safe.directory="$RECIPE_ROOT" -C "$RECIPE_ROOT" \
        rev-parse HEAD 2>/dev/null || printf 'unknown')"
    {
        printf 'build_mode=local-docker\n'
        printf 'docker_image=%s\n' "${U90_DOCKER_IMAGE:-unknown}"
        printf 'recipe_revision=%s\n' "$recipe_revision"
        printf 'treble_release=%s\n' "$TREBLE_RELEASE"
        printf 'frameworks_av_rev=%s\n' "$FRAMEWORKS_AV_REV"
        printf 'frameworks_base_rev=%s\n' "$FRAMEWORKS_BASE_REV"
        printf 'device_phh_treble_rev=%s\n' "$DEVICE_PHH_TREBLE_REV"
        printf 'networkstack_rev=%s\n' "$NETWORKSTACK_REV"
        printf 'launcher3_rev=%s\n' "$LAUNCHER3_REV"
        printf 'system_image_layout=sar\n'
        printf 'fcitx5_version=%s\n' "$FCITX5_VERSION"
        printf 'fcitx5_apk_sha256=%s\n' "$FCITX5_APK_SHA256"
        printf 'fcitx5_ime_component=%s\n' "$FCITX5_IME_COMPONENT"
        printf 'front_sensor_orientation=%s\n' "$FRONT_SENSOR_ORIENTATION"
        printf 'lunch_target=%s\n' "$LUNCH_TARGET"
        printf 'build_jobs=%s\n' "$BUILD_JOBS"
    } > "$ARTIFACT_DIR/build-info.txt"
}

configure_android_host_tools() {
    local host_bin="$SOURCE_DIR/out/host/linux-x86/bin"
    local host_lib="$SOURCE_DIR/out/host/linux-x86/lib64"
    local tool=''

    for tool in avbtool lpdump lpmake lpunpack simg2img; do
        [[ -x "$host_bin/$tool" ]] || die "Android host tool is unavailable: $host_bin/$tool"
    done

    export U90_ANDROID_HOST_BIN="$host_bin"
    export U90_ANDROID_HOST_LIB="$host_lib"
}

build_system_image() {
    export U90_FRONT_CAMERA_ORIENTATION="$FRONT_SENSOR_ORIENTATION"
    export USE_CCACHE=1
    export CCACHE_DIR
    export CCACHE_COMPILERCHECK=content
    ccache -M "$CCACHE_MAXSIZE"
    (
        cd "$SOURCE_DIR"
        export LC_ALL=C
        # Android's envsetup probes optional shell variables such as ZSH_VERSION.
        set +u
        source build/envsetup.sh
        lunch "$LUNCH_TARGET"
        m -j"$BUILD_JOBS" systemimage
        test -s "$PRODUCT_OUT/system.img"
    )
}

export_system_image() {
    local built_system="$SOURCE_DIR/$PRODUCT_OUT/system.img"
    local raw_output="$ARTIFACT_DIR/system_gsi.img"
    local xz_output="$ARTIFACT_DIR/system-roar-arm64-vanilla-u90-front${FRONT_SENSOR_ORIENTATION}.img.xz"

    configure_android_host_tools
    export PATH="$U90_ANDROID_HOST_BIN:$PATH"
    export LD_LIBRARY_PATH="$U90_ANDROID_HOST_LIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

    # $PRODUCT_OUT/system.img is the system-as-root image and is sparse. The
    # packager and its stat-based logical-partition size need the raw ext4 form.
    test -s "$built_system"
    simg2img "$built_system" "$raw_output"
    test -s "$raw_output"
    sha256sum "$raw_output" > "$ARTIFACT_DIR/system_gsi.img.sha256"
    xz --threads=0 --check=crc64 -9e -c "$raw_output" > "$xz_output"
    sha256sum "$built_system" > "$ARTIFACT_DIR/system-ab.img.sha256"
}

verify_artifacts() {
    local system_image="$ARTIFACT_DIR/system_gsi.img"

    bash "$GSI_ROOT/scripts/verify-u90-artifact.sh" \
        "$SOURCE_DIR/$PRODUCT_OUT" \
        "$system_image" \
        "$ARTIFACT_DIR" \
        "$FRONT_SENSOR_ORIENTATION"
    (
        cd "$ARTIFACT_DIR"
        sha256sum -- * > SHA256SUMS
    )
}

package_complete_super() {
    case "$PACKAGE_OUTPUT_DIR" in
        /artifacts|/artifacts/*) ;;
        *) die 'U90_PACKAGE_OUTPUT_DIR must stay under /artifacts' ;;
    esac

    [[ -n "$PACKAGE_SYSTEM_IMAGE" ]] || \
        die 'U90_PACKAGE_SYSTEM_IMAGE must name the raw system-as-root system image to package'

    configure_android_host_tools
    bash "$GSI_ROOT/scripts/package-u90-super.sh" \
        --firmware-dir "$PACKAGE_FIRMWARE_DIR" \
        --system-image "$PACKAGE_SYSTEM_IMAGE" \
        --output-dir "$PACKAGE_OUTPUT_DIR"
}

main() {
    source "$CONFIG"
    require_command ccache
    require_command curl
    require_command e2fsck
    require_command git
    require_command repo
    require_command unzip
    require_command xz
    configure_git
    bash "$GSI_ROOT/scripts/validate-recipe.sh"
    validate_orientation
    validate_build_jobs

    case "$MODE" in
        validate)
            printf 'U90 local Docker recipe validation passed.\n'
            ;;
        sync)
            prepare_pinned_manifest
            fetch_fcitx5
            sync_android_source
            ;;
        build)
            [[ "$EUID" -eq 0 ]] || die 'the local Docker build must run as root'
            prepare_artifact_dir
            prepare_pinned_manifest
            fetch_fcitx5
            sync_android_source
            prepare_android_source
            write_build_info
            build_system_image
            export_system_image
            verify_artifacts
            ccache --show-stats
            printf 'Artifacts written to %s\n' "$ARTIFACT_DIR"
            ;;
        package)
            package_complete_super
            ;;
        *)
            die "usage: $0 [validate|sync|build|package]"
            ;;
    esac
}

main "$@"
