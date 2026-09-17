<#
.SYNOPSIS
  Verifies a read-only U90 TWRP capture against a generated package manifest.

.DESCRIPTION
  Compares the recovery-visible boot, dtbo, all three vbmeta partitions,
  dynamic-partition evidence, and misc bootloader-message state with the
  expected immutable stock and generated package hashes. It only reads local
  files and never communicates with or changes the tablet.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RecoveryState,

    [Parameter(Mandatory = $true)]
    [string]$PackageDir,

    [string]$OutputPath = '',

    [switch]$RequireDynamicPartitionProof,

    [switch]$RequireClearBcb
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$statePath = (Resolve-Path -LiteralPath $RecoveryState -ErrorAction Stop).Path
$resolvedPackageDir = (Resolve-Path -LiteralPath $PackageDir -ErrorAction Stop).Path
$manifestPath = Join-Path $resolvedPackageDir 'PACKAGE-MANIFEST.txt'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "PACKAGE-MANIFEST.txt was not found: $manifestPath"
}

$state = Get-Content -LiteralPath $statePath -Raw
$manifest = Get-Content -LiteralPath $manifestPath -Raw

function Get-ManifestValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    $match = [regex]::Match($manifest, "(?m)^$([regex]::Escape($Key))=(?<value>[0-9a-f]{64})$")
    if (-not $match.Success) {
        throw "Missing or invalid $Key in $manifestPath"
    }
    return $match.Groups['value'].Value.ToLowerInvariant()
}

function Get-RecoveryProperty {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $match = [regex]::Match($state, "(?m)^$([regex]::Escape($Name))=(?<value>.*)$")
    if (-not $match.Success) {
        return $null
    }
    return $match.Groups['value'].Value.Trim()
}

function Get-PartitionHash {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Partition
    )

    $pattern = "(?im)^(?<hash>[0-9a-f]{64})\s+.+/$([regex]::Escape($Partition))\s*$"
    $matches = [regex]::Matches($state, $pattern)
    if ($matches.Count -eq 0) {
        return $null
    }
    return $matches[$matches.Count - 1].Groups['hash'].Value.ToLowerInvariant()
}

function Get-LogicalPartitionHash {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Partition
    )

    $pattern = "(?im)^(?<hash>[0-9a-f]{64})\s+/dev/block/mapper/$([regex]::Escape($Partition))\s*$"
    $matches = [regex]::Matches($state, $pattern)
    if ($matches.Count -eq 0) {
        return $null
    }
    return $matches[$matches.Count - 1].Groups['hash'].Value.ToLowerInvariant()
}

function Get-FilePrefixSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [int]$Length
    )

    $buffer = [byte[]]::new($Length)
    $read = 0
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        while ($read -lt $Length) {
            $count = $stream.Read($buffer, $read, $Length - $read)
            if ($count -le 0) {
                break
            }
            $read += $count
        }
    } finally {
        $stream.Dispose()
    }
    if ($read -ne $Length) {
        throw "Expected $Length bytes in $Path, read $read"
    }

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.Convert]::ToHexString($sha256.ComputeHash($buffer))).ToLowerInvariant()
    } finally {
        $sha256.Dispose()
    }
}

function Get-MiscBcbCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 32) {
        throw "Expected at least 32 bytes in misc BCB capture: $Path"
    }

    $commandLength = [Array]::IndexOf($bytes, [byte]0)
    if ($commandLength -lt 0 -or $commandLength -gt 32) {
        $commandLength = 32
    }
    return [System.Text.Encoding]::ASCII.GetString($bytes, 0, $commandLength).Trim()
}

if (-not $OutputPath) {
    $OutputPath = Join-Path (Split-Path -Parent $statePath) 'u90-recovery-verification.txt'
}

$checks = @(
    [pscustomobject]@{
        Name = 'boot remains stock'
        Partition = 'boot'
        Expected = Get-ManifestValue -Key 'stock_boot_sha256'
    },
    [pscustomobject]@{
        Name = 'dtbo remains stock'
        Partition = 'dtbo'
        Expected = Get-ManifestValue -Key 'stock_dtbo_sha256'
    },
    [pscustomobject]@{
        Name = 'vbmeta is generated flags=3 image'
        Partition = 'vbmeta'
        Expected = Get-ManifestValue -Key 'vbmeta_u90_avb_disabled_sha256'
    },
    [pscustomobject]@{
        Name = 'vbmeta_system is generated flags=3 image'
        Partition = 'vbmeta_system'
        Expected = Get-ManifestValue -Key 'vbmeta_system_u90_avb_disabled_sha256'
    },
    [pscustomobject]@{
        Name = 'vbmeta_vendor is generated flags=3 image'
        Partition = 'vbmeta_vendor'
        Expected = Get-ManifestValue -Key 'vbmeta_vendor_u90_avb_disabled_sha256'
    }
)

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("recovery_state=$statePath")
$lines.Add("package_manifest=$manifestPath")
$lines.Add('')

$failed = $false
foreach ($check in $checks) {
    $actual = Get-PartitionHash -Partition $check.Partition
    if (-not $actual) {
        $failed = $true
        $lines.Add("FAIL $($check.Name): no SHA-256 for $($check.Partition) in recovery capture")
        continue
    }
    if ($actual -ne $check.Expected) {
        $failed = $true
        $lines.Add("FAIL $($check.Name): expected $($check.Expected), observed $actual")
        continue
    }
    $lines.Add("PASS $($check.Name): $actual")
}

if ($RequireDynamicPartitionProof) {
    $logicalChecks = @(
        [pscustomobject]@{
            Name = 'logical product matches packaged stock product'
            Partition = 'product'
            Expected = Get-ManifestValue -Key 'product_logical_sha256'
        },
        [pscustomobject]@{
            Name = 'logical system matches packaged GSI system'
            Partition = 'system'
            Expected = Get-ManifestValue -Key 'system_logical_sha256'
        },
        [pscustomobject]@{
            Name = 'logical vendor matches packaged stock vendor'
            Partition = 'vendor'
            Expected = Get-ManifestValue -Key 'vendor_logical_sha256'
        }
    )

    foreach ($check in $logicalChecks) {
        $actual = Get-LogicalPartitionHash -Partition $check.Partition
        if (-not $actual) {
            $failed = $true
            $lines.Add("FAIL $($check.Name): no SHA-256 for /dev/block/mapper/$($check.Partition) in recovery capture")
            continue
        }
        if ($actual -ne $check.Expected) {
            $failed = $true
            $lines.Add("FAIL $($check.Name): expected $($check.Expected), observed $actual")
            continue
        }
        $lines.Add("PASS $($check.Name): $actual")
    }

    $superHeadPath = Join-Path (Split-Path -Parent $statePath) 'super-head-1MiB.img'
    $rawSuperPath = Join-Path $resolvedPackageDir 'super_u90_gsi.raw.img'
    if (-not (Test-Path -LiteralPath $superHeadPath -PathType Leaf)) {
        $failed = $true
        $lines.Add("FAIL super metadata matches packaged raw super: capture is missing $superHeadPath")
    } elseif (-not (Test-Path -LiteralPath $rawSuperPath -PathType Leaf)) {
        $failed = $true
        $lines.Add("FAIL super metadata matches packaged raw super: package is missing $rawSuperPath")
    } else {
        $capturedHeadLength = (Get-Item -LiteralPath $superHeadPath).Length
        if ($capturedHeadLength -lt 1048576) {
            $failed = $true
            $lines.Add("FAIL super metadata matches packaged raw super: capture is only $capturedHeadLength bytes")
        } else {
            $actual = Get-FilePrefixSha256 -Path $superHeadPath -Length 1048576
            $expected = Get-FilePrefixSha256 -Path $rawSuperPath -Length 1048576
            if ($capturedHeadLength -gt 1048576) {
                $lines.Add("WARN super metadata capture has $($capturedHeadLength - 1048576) trailing bytes; compared only the raw 1 MiB prefix")
            }
            if ($actual -ne $expected) {
                $failed = $true
                $lines.Add("FAIL super metadata matches packaged raw super: expected $expected, observed $actual")
            } else {
                $lines.Add("PASS super metadata matches packaged raw super: $actual")
            }
        }
    }
} else {
    $lines.Add('INFO dynamic-partition proof was not required; use -RequireDynamicPartitionProof for a final flash verification')
}

$requireClearBcb = $RequireDynamicPartitionProof -or $RequireClearBcb
if ($requireClearBcb) {
    $miscBcbPath = Join-Path (Split-Path -Parent $statePath) 'misc-bcb-4KiB.bin'
    if (-not (Test-Path -LiteralPath $miscBcbPath -PathType Leaf)) {
        $failed = $true
        $lines.Add("FAIL misc BCB is clear: capture is missing $miscBcbPath")
    } else {
        $miscBcbCommand = Get-MiscBcbCommand -Path $miscBcbPath
        if ($miscBcbCommand) {
            $failed = $true
            switch ($miscBcbCommand) {
                'boot-fastboot' {
                    $lines.Add("FAIL misc BCB is clear: command is 'boot-fastboot' (the stock LK recognizes this as a fastboot request; do not boot Android)")
                }
                'bootonce-bootloader' {
                    $lines.Add("FAIL misc BCB is clear: command is 'bootonce-bootloader' (an explicit bootloader request; do not boot Android)")
                }
                default {
                    $lines.Add("FAIL misc BCB is clear: command is '$miscBcbCommand' (do not boot Android)")
                }
            }
        } else {
            $lines.Add('PASS misc BCB command is clear')
        }
    }
}

if ($RequireDynamicPartitionProof) {
    $phhTwrpFlashTrigger = Get-RecoveryProperty -Name 'phh_twrp_flash_trigger'
    if ($phhTwrpFlashTrigger -eq 'absent') {
        $lines.Add('PASS PHH TWRP auto-flash trigger is absent')
    } elseif ($phhTwrpFlashTrigger -eq 'present') {
        $failed = $true
        $lines.Add('FAIL PHH TWRP auto-flash trigger is present at /cache/phh/flash; do not boot Android because the GSI can rewrite system and reboot')
    } else {
        $failed = $true
        $lines.Add("FAIL PHH TWRP auto-flash trigger: expected 'absent', observed '$phhTwrpFlashTrigger'")
    }
}

$verifiedBootState = Get-RecoveryProperty -Name 'ro.boot.verifiedbootstate'
$flashLocked = Get-RecoveryProperty -Name 'ro.boot.flash.locked'
if ($verifiedBootState -eq 'orange') {
    $lines.Add('PASS ro.boot.verifiedbootstate=orange')
} else {
    $failed = $true
    $lines.Add("FAIL ro.boot.verifiedbootstate: expected orange, observed '$verifiedBootState'")
}

if ($flashLocked -eq '0') {
    $lines.Add('PASS ro.boot.flash.locked=0')
} elseif ($null -eq $flashLocked -or $flashLocked -eq '') {
    $lines.Add('WARN ro.boot.flash.locked is unavailable in this recovery capture')
} else {
    $failed = $true
    $lines.Add("FAIL ro.boot.flash.locked: expected 0, observed '$flashLocked'")
}

if ($state -match 'Returning avb_handle with status: VerificationDisabled') {
    $lines.Add('INFO persisted log contains AVB VerificationDisabled')
}

$lines | Set-Content -LiteralPath $OutputPath -Encoding utf8
$lines | ForEach-Object { Write-Host $_ }
Write-Host "Verification report: $OutputPath"

if ($failed) {
    exit 1
}
