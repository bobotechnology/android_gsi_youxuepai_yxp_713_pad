[CmdletBinding()]
param(
    [ValidateSet('validate', 'sync', 'build', 'package')]
    [string]$Mode = 'build',

    [ValidateSet('0', '90', '180', '270')]
    [string]$FrontSensorOrientation = '90',

    [ValidateRange(0, 128)]
    [int]$Jobs = 0,

    [string]$Proxy = 'http://host.docker.internal:<port>',

    [string]$FirmwareDir = '',

    [string]$SystemImage = '',

    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')]
    [string]$PackageName = 'u90-a11-sourcefixed-v5-package',

    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')]
    [string]$BuildName = 'u90-a11-sourcefixed-v5',

    [switch]$NoProxy,

    [switch]$NoCache
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Docker {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    & docker @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "docker $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
}

function Test-DockerImage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Image
    )

    & docker image inspect $Image *> $null
    return $LASTEXITCODE -eq 0
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw 'Docker Desktop CLI was not found in PATH.'
}

if ($NoProxy) {
    $env:HTTP_PROXY = ''
    $env:HTTPS_PROXY = ''
    $env:ALL_PROXY = ''
    $env:NO_PROXY = ''
} else {
    if (-not $env:HTTP_PROXY) { $env:HTTP_PROXY = $Proxy }
    if (-not $env:HTTPS_PROXY) { $env:HTTPS_PROXY = $env:HTTP_PROXY }
    if (-not $env:ALL_PROXY) { $env:ALL_PROXY = $env:HTTP_PROXY }
    if (-not $env:NO_PROXY) { $env:NO_PROXY = 'localhost,127.0.0.1,::1' }
}

$env:U90_FRONT_CAMERA_ORIENTATION = $FrontSensorOrientation
if ($Jobs -gt 0) {
    $env:U90_BUILD_JOBS = "$Jobs"
} else {
    $env:U90_BUILD_JOBS = ''
}

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$artifactRoot = Join-Path $repositoryRoot 'artifacts\local'
$buildArtifactDirectory = Join-Path $artifactRoot $BuildName
if ($Mode -eq 'build' -and (Test-Path -LiteralPath $buildArtifactDirectory -PathType Container)) {
    $existingBuildArtifact = Get-ChildItem -LiteralPath $buildArtifactDirectory -Force |
        Select-Object -First 1
    if ($null -ne $existingBuildArtifact) {
        throw "Refusing to overwrite a nonempty build artifact directory: $buildArtifactDirectory. Choose a new -BuildName."
    }
}

Push-Location $repositoryRoot
try {
    Invoke-Docker -Arguments @('version', '--format', 'client={{.Client.Version}} server={{.Server.Version}}')
    Invoke-Docker -Arguments @('compose', 'version')

    if ($NoCache -or $Mode -ne 'package' -or -not (Test-DockerImage -Image 'u90-gsi-builder:android11-v313')) {
        $buildArguments = @('compose', 'build')
        if ($NoCache) {
            $buildArguments += '--no-cache'
        }
        $buildArguments += 'u90-gsi'
        Invoke-Docker -Arguments $buildArguments
    }

    $runArguments = @('compose', 'run', '--rm')
    if ($Mode -eq 'build') {
        $runArguments += @('--env', ('U90_ARTIFACT_DIR=/artifacts/' + $BuildName))
    }
    if ($Mode -eq 'package') {
        $runArguments += @('--env', ('U90_PACKAGE_OUTPUT_DIR=/artifacts/' + $PackageName))
        if (-not $FirmwareDir) {
            $FirmwareDir = Join-Path (Split-Path -Parent $repositoryRoot) 'P713mt6779_20221129_2216'
        }
        $resolvedFirmwareDir = (Resolve-Path -LiteralPath $FirmwareDir -ErrorAction Stop).Path
        if (-not (Test-Path -LiteralPath (Join-Path $resolvedFirmwareDir 'super.img') -PathType Leaf)) {
            throw "super.img was not found in firmware directory: $resolvedFirmwareDir"
        }
        foreach ($name in 'vbmeta.img', 'vbmeta_system.img', 'vbmeta_vendor.img') {
            if (-not (Test-Path -LiteralPath (Join-Path $resolvedFirmwareDir $name) -PathType Leaf)) {
                throw "$name was not found in firmware directory: $resolvedFirmwareDir"
            }
        }
        $runArguments += @('--volume', ($resolvedFirmwareDir + ':/firmware:ro'))

        if (-not $SystemImage) {
            $defaultSystemImage = Join-Path $buildArtifactDirectory 'system_gsi.img'
            if (Test-Path -LiteralPath $defaultSystemImage -PathType Leaf) {
                $SystemImage = $defaultSystemImage
            }
        }

        if ($SystemImage) {
            $resolvedSystemImage = (Resolve-Path -LiteralPath $SystemImage -ErrorAction Stop).Path
            if (-not (Test-Path -LiteralPath $resolvedSystemImage -PathType Leaf)) {
                throw "system image was not found: $resolvedSystemImage"
            }
            $runArguments += @('--volume', ($resolvedSystemImage + ':/input/system.img:ro'))
            $runArguments += @('--env', 'U90_PACKAGE_SYSTEM_IMAGE=/input/system.img')
        }
    }
    $runArguments += @('u90-gsi', $Mode)
    Invoke-Docker -Arguments $runArguments
} finally {
    Pop-Location
}
