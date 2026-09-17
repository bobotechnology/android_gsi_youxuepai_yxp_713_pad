<#
.SYNOPSIS
  Compares two read-only U90 TWRP recovery captures around one Android boot attempt.

.DESCRIPTION
  Use a verified capture taken before Reboot System and another capture taken
  after a failed boot returns to recovery. The script reads local capture files
  only. It never invokes adb, fastboot, reboot, flash, erase, mount, or any
  device-changing command.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BeforeRecoveryState,

    [Parameter(Mandatory = $true)]
    [string]$AfterRecoveryState,

    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$beforePath = (Resolve-Path -LiteralPath $BeforeRecoveryState -ErrorAction Stop).Path
$afterPath = (Resolve-Path -LiteralPath $AfterRecoveryState -ErrorAction Stop).Path
$beforeContent = Get-Content -LiteralPath $beforePath -Raw
$afterContent = Get-Content -LiteralPath $afterPath -Raw
$beforeDirectory = Split-Path -Parent $beforePath
$afterDirectory = Split-Path -Parent $afterPath

function Get-RecoveryProperty {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $pattern = '(?m)^' + [regex]::Escape($Name) + '=(?<value>.*)$'
    $matches = [regex]::Matches($Content, $pattern)
    if ($matches.Count -eq 0) {
        return $null
    }
    return $matches[$matches.Count - 1].Groups['value'].Value.Trim()
}

function Get-PartitionHash {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,

        [Parameter(Mandatory = $true)]
        [string]$Partition,

        [switch]$Logical
    )

    if ($Logical) {
        $pattern = '(?im)^(?<hash>[0-9a-f]{64})\s+/dev/block/mapper/' +
            [regex]::Escape($Partition) + '\s*$'
    } else {
        $pattern = '(?im)^(?<hash>[0-9a-f]{64})\s+.+/' +
            [regex]::Escape($Partition) + '\s*$'
    }
    $matches = [regex]::Matches($Content, $pattern)
    if ($matches.Count -eq 0) {
        return $null
    }
    return $matches[$matches.Count - 1].Groups['hash'].Value.ToLowerInvariant()
}

function Get-BcbInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CaptureDirectory
    )

    $path = Join-Path $CaptureDirectory 'misc-bcb-4KiB.bin'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{
            Path = $path
            Present = $false
            Command = $null
            Sha256 = $null
        }
    }

    $bytes = [System.IO.File]::ReadAllBytes($path)
    if ($bytes.Length -lt 32) {
        throw "misc BCB capture is shorter than 32 bytes: $path"
    }

    $commandLength = [Array]::IndexOf($bytes, [byte]0)
    if ($commandLength -lt 0 -or $commandLength -gt 32) {
        $commandLength = 32
    }
    return [pscustomobject]@{
        Path = $path
        Present = $true
        Command = [System.Text.Encoding]::ASCII.GetString($bytes, 0, $commandLength).Trim()
        Sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Get-SuperHeadHash {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CaptureDirectory
    )

    $path = Join-Path $CaptureDirectory 'super-head-1MiB.img'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Add-ValueComparison {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Lines,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [AllowNull()]
        [string]$Before,

        [AllowNull()]
        [string]$After,

        [string]$ChangedPrefix = 'ALERT'
    )

    if ([string]::IsNullOrEmpty($Before) -and [string]::IsNullOrEmpty($After)) {
        $Lines.Add("INFO $($Name): not captured in either state")
        return $false
    }
    if ($Before -eq $After) {
        $Lines.Add("PASS $($Name): unchanged ($Before)")
        return $false
    }
    $Lines.Add("$ChangedPrefix $($Name): before='$Before' after='$After'")
    return $true
}

function Add-AfterSignal {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Lines,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Pattern
    )

    $beforeSeen = [regex]::IsMatch($beforeContent, $Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $afterSeen = [regex]::IsMatch($afterContent, $Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($afterSeen -and -not $beforeSeen) {
        $Lines.Add("EVIDENCE $($Name): present only after the boot attempt")
        return $true
    }
    if ($afterSeen) {
        $Lines.Add("INFO $($Name): present in both captures")
        return $false
    }
    $Lines.Add("INFO $($Name): not found in post-attempt capture")
    return $false
}

if (-not $OutputPath) {
    $OutputPath = Join-Path $afterDirectory 'u90-boot-attempt-comparison.txt'
}

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("before_recovery_state=$beforePath")
$lines.Add("after_recovery_state=$afterPath")
$lines.Add('read_only_local_comparison=true')
$lines.Add('')

$beforeBcb = Get-BcbInfo -CaptureDirectory $beforeDirectory
$afterBcb = Get-BcbInfo -CaptureDirectory $afterDirectory
$bcbChanged = $false
if (-not $beforeBcb.Present -or -not $afterBcb.Present) {
    $lines.Add("INFO misc BCB comparison: missing before or after binary capture")
} elseif ($beforeBcb.Command -eq $afterBcb.Command) {
    $lines.Add("PASS misc BCB command: unchanged ('$($beforeBcb.Command)')")
} elseif ($afterBcb.Command) {
    $bcbChanged = $true
    $lines.Add("EVIDENCE misc BCB command changed: before='$($beforeBcb.Command)' after='$($afterBcb.Command)'")
    $lines.Add('EVIDENCE a nonempty post-attempt BCB can independently direct stock LK to fastboot; do not attribute that fastboot result to AVB')
} else {
    $lines.Add("INFO misc BCB command was cleared: before='$($beforeBcb.Command)' after=empty")
}

$lines.Add('')
$lines.Add('=== immutable partition comparison ===')
$partitionChanged = $false
foreach ($partition in @('boot', 'dtbo', 'vbmeta', 'vbmeta_system', 'vbmeta_vendor')) {
    $beforeHash = Get-PartitionHash -Content $beforeContent -Partition $partition
    $afterHash = Get-PartitionHash -Content $afterContent -Partition $partition
    if (Add-ValueComparison -Lines $lines -Name $partition -Before $beforeHash -After $afterHash) {
        $partitionChanged = $true
    }
}

$lines.Add('')
$lines.Add('=== dynamic partition comparison ===')
$beforeSuperHash = Get-SuperHeadHash -CaptureDirectory $beforeDirectory
$afterSuperHash = Get-SuperHeadHash -CaptureDirectory $afterDirectory
$superChanged = Add-ValueComparison -Lines $lines -Name 'super first 1 MiB' -Before $beforeSuperHash -After $afterSuperHash
foreach ($partition in @('product', 'system', 'vendor')) {
    $beforeHash = Get-PartitionHash -Content $beforeContent -Partition $partition -Logical
    $afterHash = Get-PartitionHash -Content $afterContent -Partition $partition -Logical
    [void](Add-ValueComparison -Lines $lines -Name "logical $partition" -Before $beforeHash -After $afterHash)
}

$lines.Add('')
$lines.Add('=== trigger and persistent-log evidence ===')
$beforeTrigger = Get-RecoveryProperty -Content $beforeContent -Name 'phh_twrp_flash_trigger'
$afterTrigger = Get-RecoveryProperty -Content $afterContent -Name 'phh_twrp_flash_trigger'
[void](Add-ValueComparison -Lines $lines -Name 'phh_twrp_flash_trigger' -Before $beforeTrigger -After $afterTrigger -ChangedPrefix 'EVIDENCE')
$explicitReboot = Add-AfterSignal -Lines $lines -Name 'explicit bootloader reboot' -Pattern 'Received sys\.powerctl.*bootloader|reboot[, ]+bootloader|Restarting system with command ''bootloader'''
[void](Add-AfterSignal -Lines $lines -Name 'init critical-service failure' -Pattern 'critical (service|process)|critical service.*exited')
[void](Add-AfterSignal -Lines $lines -Name 'kernel panic' -Pattern 'Kernel panic|panic:')
[void](Add-AfterSignal -Lines $lines -Name 'AVB or dm-verity failure' -Pattern 'avb.*(fail|error)|verification failed|dm-verity')

$lines.Add('')
$lines.Add('=== interpretation ===')
if ($bcbChanged) {
    $lines.Add('RESULT the post-attempt misc BCB is a confounding fastboot cause. Clear the BCB, repeat the same one-variable test, and preserve both captures.')
} elseif ($explicitReboot) {
    $lines.Add('RESULT persistent logs support an explicit bootloader reboot after Android or init started. This is not an early AVB-only conclusion.')
} elseif ($partitionChanged -or $superChanged) {
    $lines.Add('RESULT a supposedly immutable or super metadata item changed during the attempt. Stop and identify the writer before repeating the boot.')
} else {
    $lines.Add('RESULT no post-attempt BCB change or explicit bootloader signal was found in these two captures. Correlate runtime logcat and UART/pstore before changing images.')
}

$lines | Set-Content -LiteralPath $OutputPath -Encoding utf8
$lines | ForEach-Object { Write-Host $_ }
Write-Host "Boot-attempt comparison: $OutputPath"
