<#
.SYNOPSIS
  Captures read-only Android runtime evidence for a U90 GSI boot attempt.

.DESCRIPTION
  Start this script while the tablet is still in TWRP, then choose Reboot
  System manually after the recovery-state verifier has passed. The script
  waits for Android adbd, streams all logcat buffers, and takes read-only
  process/property snapshots. It never invokes reboot, setprop, root, flash,
  erase, mount, or any device-writing command.
#>
[CmdletBinding()]
param(
    [string]$OutputRoot = '',

    [string]$AdbPath = '',

    [string]$Serial = '',

    [ValidateRange(30, 1800)]
    [int]$WaitForAndroidSeconds = 600,

    [ValidateRange(30, 1800)]
    [int]$CaptureSeconds = 420,

    [ValidateRange(2, 120)]
    [int]$SnapshotIntervalSeconds = 10,

    [ValidateRange(5, 120)]
    [int]$DisconnectGraceSeconds = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$workspaceRoot = Split-Path -Parent $repositoryRoot

function Resolve-AdbPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RequestedPath
    )

    if ($RequestedPath) {
        if (-not (Test-Path -LiteralPath $RequestedPath -PathType Leaf)) {
            throw "adb.exe was not found: $RequestedPath"
        }
        return (Resolve-Path -LiteralPath $RequestedPath -ErrorAction Stop).Path
    }

    $candidates = @(
        (Join-Path $workspaceRoot 'platform-tools\adb.exe'),
        (Join-Path $repositoryRoot 'platform-tools\adb.exe')
    )
    if ($env:LOCALAPPDATA) {
        $candidates += Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
    }

    $candidate = $candidates | Where-Object {
        Test-Path -LiteralPath $_ -PathType Leaf
    } | Select-Object -First 1
    if ($candidate) {
        return (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path
    }

    $command = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    throw 'adb.exe was not found. Install Android platform-tools or place it beside the workspace.'
}

$adb = Resolve-AdbPath -RequestedPath $AdbPath
$script:LastAdbDevices = @()

function Get-OnlineSerials {
    $result = @(& $adb devices -l 2>&1)
    $exitCode = $LASTEXITCODE
    $script:LastAdbDevices = @($result | ForEach-Object { "$_" })
    if ($exitCode -ne 0) {
        return @()
    }

    $online = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $script:LastAdbDevices) {
        if ($line -match '^(?<serial>\S+)\s+device(?:\s|$)') {
            $online.Add($matches['serial'])
        }
    }
    return @($online.ToArray())
}

function Select-TargetSerial {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$OnlineSerials
    )

    if ($Serial) {
        if ($OnlineSerials -contains $Serial) {
            return $Serial
        }
        return ''
    }

    if ($OnlineSerials.Count -eq 1) {
        return $OnlineSerials[0]
    }
    if ($OnlineSerials.Count -gt 1) {
        throw "Multiple adb devices are online. Re-run with -Serial. Online serials: $($OnlineSerials -join ', ')"
    }
    return ''
}

function Get-RuntimeProbe {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetSerial
    )

    $shellCommand = 'printf "bootmode="; getprop ro.bootmode; printf "\ntwrp="; getprop ro.twrp.version; printf "\ntwrp_boot="; getprop ro.twrp.boot; printf "\nboot_completed="; getprop sys.boot_completed; printf "\nmtkmal="; if [ -e /vendor/bin/mtkmal ]; then echo present; else echo absent; fi; printf "mtk_ims_support="; getprop persist.mtk_ims_support; printf "\nmtk_epdg_support="; getprop persist.mtk_epdg_support; printf "\nrelease="; getprop ro.build.version.release; printf "\nfingerprint="; getprop ro.build.fingerprint'
    $result = @(& $adb -s $TargetSerial shell $shellCommand 2>&1)
    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    $properties = @{}
    foreach ($line in $result) {
        if ($line -match '^(?<name>bootmode|twrp|twrp_boot|boot_completed|mtkmal|mtk_ims_support|mtk_epdg_support|release|fingerprint)=(?<value>.*)$') {
            $properties[$matches['name']] = $matches['value'].Trim()
        }
    }

    $bootMode = if ($properties.ContainsKey('bootmode')) { $properties['bootmode'] } else { '' }
    $twrpVersion = if ($properties.ContainsKey('twrp')) { $properties['twrp'] } else { '' }
    $twrpBoot = if ($properties.ContainsKey('twrp_boot')) { $properties['twrp_boot'] } else { '' }
    $bootCompleted = if ($properties.ContainsKey('boot_completed')) { $properties['boot_completed'] } else { '' }
    $mtkmal = if ($properties.ContainsKey('mtkmal')) { $properties['mtkmal'] } else { '' }
    $mtkImsSupport = if ($properties.ContainsKey('mtk_ims_support')) { $properties['mtk_ims_support'] } else { '' }
    $mtkEpdgSupport = if ($properties.ContainsKey('mtk_epdg_support')) { $properties['mtk_epdg_support'] } else { '' }
    return [pscustomobject]@{
        Raw = ($result -join [Environment]::NewLine)
        BootMode = $bootMode
        TwrpVersion = $twrpVersion
        TwrpBoot = $twrpBoot
        BootCompleted = $bootCompleted
        Mtkmal = $mtkmal
        MtkImsSupport = $mtkImsSupport
        MtkEpdgSupport = $mtkEpdgSupport
        IsRecovery = (
            $bootMode -eq 'recovery' -or
            $twrpBoot -eq '1' -or
            -not [string]::IsNullOrWhiteSpace($twrpVersion)
        )
    }
}

function Write-ReadOnlySnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetSerial,

        [Parameter(Mandatory = $true)]
        [int]$Index,

        [Parameter(Mandatory = $true)]
        [string]$Directory
    )

    $prefix = '{0:D3}-{1}' -f $Index, (Get-Date -Format 'yyyyMMdd-HHmmss')
    $probe = Get-RuntimeProbe -TargetSerial $TargetSerial
    if ($null -eq $probe) {
        "adb runtime probe failed at $(Get-Date -Format o)" |
            Set-Content -LiteralPath (Join-Path $Directory "$prefix-probe.txt") -Encoding utf8
        return $false
    }

    $probe.Raw |
        Set-Content -LiteralPath (Join-Path $Directory "$prefix-probe.txt") -Encoding utf8

    $getprop = @(& $adb -s $TargetSerial shell getprop 2>&1)
    $getpropExit = $LASTEXITCODE
    $getprop |
        Set-Content -LiteralPath (Join-Path $Directory "$prefix-getprop.txt") -Encoding utf8

    $processes = @(& $adb -s $TargetSerial shell 'ps -A -o USER,PID,PPID,S,NAME,ARGS 2>/dev/null || ps -A' 2>&1)
    $processesExit = $LASTEXITCODE
    $processes |
        Set-Content -LiteralPath (Join-Path $Directory "$prefix-ps.txt") -Encoding utf8

    @(
        "captured_at=$(Get-Date -Format o)"
        "probe_bootmode=$($probe.BootMode)"
        "probe_twrp_version=$($probe.TwrpVersion)"
        "probe_twrp_boot=$($probe.TwrpBoot)"
        "probe_boot_completed=$($probe.BootCompleted)"
        "probe_mtkmal=$($probe.Mtkmal)"
        "probe_mtk_ims_support=$($probe.MtkImsSupport)"
        "probe_mtk_epdg_support=$($probe.MtkEpdgSupport)"
        "getprop_exit_code=$getpropExit"
        "ps_exit_code=$processesExit"
    ) | Set-Content -LiteralPath (Join-Path $Directory "$prefix-summary.txt") -Encoding ascii

    return (-not $probe.IsRecovery)
}

if (-not $OutputRoot) {
    $OutputRoot = Join-Path $workspaceRoot 'output\device-state'
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outputDir = Join-Path $OutputRoot "runtime-reboot-$timestamp"
$snapshotsDir = Join-Path $outputDir 'snapshots'
New-Item -ItemType Directory -Path $snapshotsDir -ErrorAction Stop | Out-Null

$startedAt = Get-Date
$selectedSerial = ''
$logcatProcess = $null
$captureReason = 'not-started'
$snapshotCount = 0
$disconnectStartedAt = $null

try {
    $waitDeadline = $startedAt.AddSeconds($WaitForAndroidSeconds)
    while ((Get-Date) -lt $waitDeadline) {
        $onlineSerials = @(Get-OnlineSerials)
        $candidateSerial = Select-TargetSerial -OnlineSerials $onlineSerials
        $script:LastAdbDevices |
            Set-Content -LiteralPath (Join-Path $outputDir 'adb-devices-latest.txt') -Encoding ascii

        if (-not $candidateSerial) {
            Start-Sleep -Seconds 1
            continue
        }

        $probe = Get-RuntimeProbe -TargetSerial $candidateSerial
        if ($null -eq $probe) {
            Start-Sleep -Seconds 1
            continue
        }

        $probe.Raw |
            Set-Content -LiteralPath (Join-Path $outputDir 'first-adb-probe.txt') -Encoding utf8
        if ($probe.IsRecovery) {
            Start-Sleep -Seconds 1
            continue
        }

        $selectedSerial = $candidateSerial
        break
    }

    if (-not $selectedSerial) {
        throw "Android adb did not become available within $WaitForAndroidSeconds seconds. The last adb state is in $outputDir"
    }

    $logcatPath = Join-Path $outputDir 'logcat-all.txt'
    $logcatErrorPath = Join-Path $outputDir 'logcat-all.stderr.txt'
    $startProcessParameters = @{
        FilePath = $adb
        ArgumentList = @('-s', $selectedSerial, 'logcat', '-b', 'all', '-v', 'threadtime')
        RedirectStandardOutput = $logcatPath
        RedirectStandardError = $logcatErrorPath
        NoNewWindow = $true
        PassThru = $true
    }
    $logcatProcess = Start-Process @startProcessParameters

    @(
        "capture_started=$(Get-Date -Format o)"
        "serial=$selectedSerial"
        "adb=$adb"
        "capture_seconds=$CaptureSeconds"
        "snapshot_interval_seconds=$SnapshotIntervalSeconds"
        "disconnect_grace_seconds=$DisconnectGraceSeconds"
        'read_only_device_commands=getprop, ps, logcat'
    ) | Set-Content -LiteralPath (Join-Path $outputDir 'capture-metadata.txt') -Encoding ascii

    $captureDeadline = (Get-Date).AddSeconds($CaptureSeconds)
    while ((Get-Date) -lt $captureDeadline) {
        $snapshotCount++
        $isRuntime = Write-ReadOnlySnapshot -TargetSerial $selectedSerial -Index $snapshotCount -Directory $snapshotsDir
        if (-not $isRuntime) {
            if ($null -eq $disconnectStartedAt) {
                $disconnectStartedAt = Get-Date
            }
            if (((Get-Date) - $disconnectStartedAt).TotalSeconds -ge $DisconnectGraceSeconds) {
                $captureReason = 'adb-disconnected-or-recovery-after-runtime'
                break
            }
        } else {
            $disconnectStartedAt = $null
        }

        Start-Sleep -Seconds $SnapshotIntervalSeconds
    }

    if ($captureReason -eq 'not-started') {
        $captureReason = 'capture-duration-elapsed'
    }
} finally {
    if ($null -ne $logcatProcess -and -not $logcatProcess.HasExited) {
        Stop-Process -Id $logcatProcess.Id -Force
        $logcatProcess.WaitForExit()
    }

    $signalPath = Join-Path $outputDir 'reboot-signals.txt'
    $logcatPath = Join-Path $outputDir 'logcat-all.txt'
    if (Test-Path -LiteralPath $logcatPath -PathType Leaf) {
        $patterns = @(
            'Received sys\.powerctl',
            'sys\.powerctl',
            'reboot,bootloader',
            'reboot bootloader',
            'Restarting system with command',
            'critical service',
            'critical process',
            'phh_on_boot',
            'mtkmal',
            'Fatal signal',
            'FATAL EXCEPTION',
            'init:.*(reboot|critical)'
        )
        Select-String -LiteralPath $logcatPath -Pattern $patterns |
            ForEach-Object { '{0}:{1}: {2}' -f $_.Path, $_.LineNumber, $_.Line } |
            Set-Content -LiteralPath $signalPath -Encoding utf8
    } else {
        'logcat did not start before capture ended' |
            Set-Content -LiteralPath $signalPath -Encoding utf8
    }

    @(
        "capture_started=$($startedAt.ToString('o'))"
        "capture_ended=$(Get-Date -Format o)"
        "serial=$selectedSerial"
        "snapshot_count=$snapshotCount"
        "end_reason=$captureReason"
    ) | Set-Content -LiteralPath (Join-Path $outputDir 'capture-result.txt') -Encoding ascii
}

Write-Host "Captured Android runtime evidence: $outputDir"
Write-Host "Inspect reboot-signals.txt and logcat-all.txt before changing any image."
