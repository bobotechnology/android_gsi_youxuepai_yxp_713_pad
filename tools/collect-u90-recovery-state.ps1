<#
.SYNOPSIS
  Collects read-only U90 recovery and AVB evidence through TWRP adb.

.DESCRIPTION
  Does not reboot, flash, erase, or mount any device filesystem read-write.
  Run it only while the tablet is already in TWRP recovery with adb enabled.
#>
[CmdletBinding()]
param(
    [string]$OutputRoot = '',

    [string]$AdbPath = '',

    [switch]$FullLogicalHashes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$workspaceRoot = Split-Path -Parent $repositoryRoot
$adb = $null
if ($AdbPath) {
    if (-not (Test-Path -LiteralPath $AdbPath -PathType Leaf)) {
        throw "adb.exe was not found: $AdbPath"
    }
    $adb = (Resolve-Path -LiteralPath $AdbPath -ErrorAction Stop).Path
} else {
    $adbCandidates = @(
        (Join-Path $workspaceRoot 'platform-tools\adb.exe'),
        (Join-Path $repositoryRoot 'platform-tools\adb.exe')
    )
    if ($env:LOCALAPPDATA) {
        $adbCandidates += Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
    }
    $adb = $adbCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
}
if (-not $adb) {
    $adbCommand = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($adbCommand) {
        $adb = $adbCommand.Source
    }
}
if (-not $adb) {
    throw 'adb.exe was not found. Install Android platform-tools or place it beside the workspace.'
}

if (-not $OutputRoot) {
    $OutputRoot = Join-Path $workspaceRoot 'output\device-state'
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outputDir = Join-Path $OutputRoot "recovery-$timestamp"
New-Item -ItemType Directory -Path $outputDir -ErrorAction Stop | Out-Null

function Invoke-Adb {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $result = & $adb @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "adb $($Arguments -join ' ') failed with exit code $LASTEXITCODE`n$result"
    }
    return $result
}

$devices = Invoke-Adb -Arguments @('devices', '-l')
$devices | Set-Content -LiteralPath (Join-Path $outputDir 'adb-devices.txt') -Encoding ascii
if (-not ($devices -match '(?m)^\S+\s+recovery(?:\s|$)')) {
    throw "No adb recovery transport is available. Put the tablet in TWRP first. Output: $outputDir"
}

$remoteScript = @'
echo '=== identity ==='
for property in \
    ro.product.vendor.device \
    ro.boot.flash.locked \
    ro.boot.verifiedbootstate \
    ro.boot.veritymode \
    ro.boot.vbmeta.device_state \
    ro.boot.vbmeta.digest \
    ro.boot.vbmeta.hash_alg \
    ro.boot.slot_suffix; do
    printf '%s=' "$property"
    getprop "$property"
done

echo '=== cmdline ==='
cat /proc/cmdline

echo '=== metadata AVB enforcement ==='
for path in /metadata /metadata/gsi /metadata/gsi/avb_enforce; do
    if [ -e "$path" ]; then
        ls -ld "$path"
    else
        echo "MISSING $path"
    fi
done

echo '=== mounts ==='
mount

echo '=== logical partitions ==='
ls -l /dev/block/mapper 2>/dev/null || true
dmsetup ls 2>/dev/null || true
for name in super system vendor product vbmeta vbmeta_system vbmeta_vendor boot misc metadata; do
    path=/dev/block/by-name/$name
    if [ -e "$path" ]; then
        printf '%s -> ' "$name"
        readlink -f "$path" 2>/dev/null || echo "$path"
        blockdev --getsize64 "$path" 2>/dev/null || true
    fi
done

echo '=== fstab ==='
cat /vendor/etc/fstab.mt6779 2>/dev/null || true

echo '=== fixed partition SHA-256 ==='
if command -v sha256sum >/dev/null 2>&1; then
    for name in boot dtbo vbmeta vbmeta_system vbmeta_vendor; do
        path=/dev/block/by-name/$name
        if [ -r "$path" ]; then
            sha256sum "$path"
        fi
    done
else
    echo 'UNAVAILABLE'
fi

echo '=== recovery commands ==='
for path in /cache/recovery/command /cache/recovery/last_log /cache/recovery/log; do
    if [ -f "$path" ]; then
        echo "--- $path ---"
        cat "$path" 2>/dev/null || true
    fi
done

echo '=== PHH TWRP auto-flash trigger ==='
if [ -e /cache/phh/flash ]; then
    echo 'phh_twrp_flash_trigger=present'
else
    echo 'phh_twrp_flash_trigger=absent'
fi
for path in /cache/phh/flash /cache/phh/block.map /cache/phh/logs; do
    if [ -e "$path" ]; then
        echo "--- $path ---"
        ls -ld "$path" 2>/dev/null || true
        if [ -f "$path" ] && command -v sha256sum >/dev/null 2>&1; then
            sha256sum "$path" 2>/dev/null || true
        fi
    else
        echo "MISSING $path"
    fi
done

echo '=== misc BCB ==='
echo 'captured separately as misc-bcb-4KiB.bin'

echo '=== persistent logs ==='
ls -la /sys/fs/pstore 2>/dev/null || true
for path in /sys/fs/pstore/* /proc/last_kmsg; do
    if [ -f "$path" ]; then
        echo "--- $path ($(wc -c < "$path") bytes) ---"
        cat "$path" 2>/dev/null || true
        echo
    fi
done
'@

$state = Invoke-Adb -Arguments @('shell', $remoteScript)
$superHeadBase64 = Invoke-Adb -Arguments @('shell', 'dd if=/dev/block/by-name/super bs=1048576 count=1 2>/dev/null | base64')
$superHeadBytes = [Convert]::FromBase64String(($superHeadBase64 -join ''))
if ($superHeadBytes.Length -ne 1048576) {
    throw "Unexpected super metadata capture size: $($superHeadBytes.Length)"
}
$superHeadPath = Join-Path $outputDir 'super-head-1MiB.img'
[System.IO.File]::WriteAllBytes($superHeadPath, $superHeadBytes)
$state += '=== super metadata capture ==='
$state += "super_head_1MiB_sha256=$((Get-FileHash -Algorithm SHA256 -LiteralPath $superHeadPath).Hash.ToLowerInvariant())"

$miscBcbBase64 = Invoke-Adb -Arguments @('shell', 'dd if=/dev/block/by-name/misc bs=4096 count=1 2>/dev/null | base64')
$miscBcbBytes = [Convert]::FromBase64String(($miscBcbBase64 -join ''))
if ($miscBcbBytes.Length -ne 4096) {
    throw "Unexpected misc BCB capture size: $($miscBcbBytes.Length)"
}
$miscBcbPath = Join-Path $outputDir 'misc-bcb-4KiB.bin'
[System.IO.File]::WriteAllBytes($miscBcbPath, $miscBcbBytes)
$commandLength = [Array]::IndexOf($miscBcbBytes, [byte]0)
if ($commandLength -lt 0 -or $commandLength -gt 32) {
    $commandLength = 32
}
$miscBcbCommand = [System.Text.Encoding]::ASCII.GetString($miscBcbBytes, 0, $commandLength).Trim()
$state += '=== misc BCB capture ==='
$state += "misc_bcb_command=$miscBcbCommand"
$state += "misc_bcb_sha256=$((Get-FileHash -Algorithm SHA256 -LiteralPath $miscBcbPath).Hash.ToLowerInvariant())"

if ($FullLogicalHashes) {
    $state += '=== full logical partition SHA-256 ==='
    $logicalHashes = Invoke-Adb -Arguments @('shell', 'for name in product system vendor; do path=/dev/block/mapper/$name; if [ -r "$path" ]; then sha256sum "$path"; else echo "MISSING $path"; fi; done')
    $state += $logicalHashes
}

$state | Set-Content -LiteralPath (Join-Path $outputDir 'recovery-state.txt') -Encoding utf8

Write-Host "Collected read-only recovery state: $outputDir"
