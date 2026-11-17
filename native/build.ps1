# Builds Buddy's arm64 jniLibs on Windows.
# Prefers Git Bash + the Windows NDK (clang.exe). Falls back to WSL with a *Linux* NDK.
# Usage:
#   .\native\build.ps1
#   $env:ANDROID_NDK_HOME = 'C:\Android\ndk\27.2.12479018'; .\native\build.ps1

$ErrorActionPreference = 'Stop'

$NativeDir = $PSScriptRoot
$RepoRoot = Split-Path -Parent $NativeDir
$ProotMarker = Join-Path $RepoRoot 'third_party\proot\src\GNUmakefile'
$OutSo = Join-Path $RepoRoot 'app\src\main\jniLibs\arm64-v8a\libproot.so'

function Fail([string]$Message) {
    Write-Error $Message
    exit 1
}

function Resolve-NdkHome {
    if ($env:ANDROID_NDK_HOME -and (Test-Path -LiteralPath $env:ANDROID_NDK_HOME)) {
        return (Resolve-Path -LiteralPath $env:ANDROID_NDK_HOME).Path
    }
    $sdk = $env:ANDROID_HOME
    if (-not $sdk) { $sdk = $env:ANDROID_SDK_ROOT }
    if (-not $sdk) { $sdk = Join-Path $env:LOCALAPPDATA 'Android\Sdk' }
    $ndkRoot = Join-Path $sdk 'ndk'
    if (-not (Test-Path -LiteralPath $ndkRoot)) {
        Fail @"
Android NDK not found.
Install an NDK (e.g. 27.2.12479018) via Android Studio SDK Manager, or set ANDROID_NDK_HOME.
Looked under: $ndkRoot
"@
    }
    $latest = Get-ChildItem -LiteralPath $ndkRoot -Directory |
        Sort-Object Name -Descending |
        Select-Object -First 1
    if (-not $latest) {
        Fail "No NDK versions under $ndkRoot. Install one or set ANDROID_NDK_HOME."
    }
    return $latest.FullName
}

function Convert-ToWslPath([string]$WindowsPath) {
    $full = (Resolve-Path -LiteralPath $WindowsPath).Path
    $m = [regex]::Match($full, '^(?i)([A-Z]):\\(.*)$')
    if (-not $m.Success) {
        Fail "Cannot convert path to WSL form: $WindowsPath"
    }
    $drive = $m.Groups[1].Value.ToLowerInvariant()
    $rest = ($m.Groups[2].Value -replace '\\', '/')
    return "/mnt/$drive/$rest"
}

function Convert-ToGitBashPath([string]$WindowsPath) {
    $full = (Resolve-Path -LiteralPath $WindowsPath).Path
    $m = [regex]::Match($full, '^(?i)([A-Z]):\\(.*)$')
    if (-not $m.Success) {
        Fail "Cannot convert path to Git Bash form: $WindowsPath"
    }
    $drive = $m.Groups[1].Value.ToLowerInvariant()
    $rest = ($m.Groups[2].Value -replace '\\', '/')
    return "/$drive/$rest"
}

function Find-GitBash {
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Git\bin\bash.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Git\bin\bash.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe')
    )
    foreach ($p in $candidates) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    $cmd = Get-Command bash.exe -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source -match 'Git') { return $cmd.Source }
    return $null
}

if (-not (Test-Path -LiteralPath $ProotMarker)) {
    Write-Host 'third_party submodules missing; running git submodule update --init ...'
    Push-Location $RepoRoot
    try {
        & git submodule update --init
        if ($LASTEXITCODE -ne 0) { Fail 'git submodule update --init failed.' }
    } finally {
        Pop-Location
    }
    if (-not (Test-Path -LiteralPath $ProotMarker)) {
        Fail 'Submodules still missing after git submodule update --init.'
    }
}

$ndkHome = Resolve-NdkHome
$gitBash = Find-GitBash
$winClang = Join-Path $ndkHome 'toolchains\llvm\prebuilt\windows-x86_64\bin\clang.exe'

if ($gitBash -and (Test-Path -LiteralPath $winClang)) {
    $ndkUnix = Convert-ToGitBashPath $ndkHome
    $nativeUnix = Convert-ToGitBashPath $NativeDir
    Write-Host "ANDROID_NDK_HOME: $ndkHome"
    Write-Host "Building via Git Bash: $gitBash"
    $cmd = "export ANDROID_NDK_HOME='$ndkUnix'; cd '$nativeUnix' && bash ./build.sh"
    & $gitBash -lc $cmd
    if ($LASTEXITCODE -ne 0) {
        Fail "native/build.sh failed in Git Bash (exit $LASTEXITCODE)."
    }
} elseif (Get-Command wsl -ErrorAction SilentlyContinue) {
    # Windows NDK clang.exe cannot run inside WSL; need a Linux host NDK.
    $wslCheck = & wsl -e true 2>&1
    if ($LASTEXITCODE -ne 0) {
        Fail "WSL failed to start a distro. Fix WSL first, or install Git for Windows and retry."
    }
    Write-Host 'Git Bash / Windows NDK clang not usable; trying WSL with a Linux NDK ...'
    $nativeWsl = Convert-ToWslPath $NativeDir
    $cmd = @"
set -euo pipefail
if ! command -v make >/dev/null || ! command -v readelf >/dev/null; then
  echo 'WSL needs make and binutils (readelf). Example: sudo apt-get update && sudo apt-get install -y make binutils' >&2
  exit 1
fi
NDK=""
if [ -n "`${ANDROID_NDK_HOME:-}" ] && [ -x "`$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/clang" ]; then
  NDK=`$ANDROID_NDK_HOME
elif [ -d "`$HOME/Android/Sdk/ndk" ]; then
  NDK=`$(ls -d "`$HOME/Android/Sdk/ndk"/*/ 2>/dev/null | sort -V | tail -1 | sed 's:/*`$::')
fi
if [ -z "`$NDK" ] || [ ! -x "`$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/clang" ]; then
  echo 'WSL needs a Linux Android NDK (linux-x86_64 host prebuilt).' >&2
  echo 'Install Git for Windows (uses your Windows NDK), or in WSL install the NDK under ~/Android/Sdk/ndk.' >&2
  exit 1
fi
export ANDROID_NDK_HOME=`$NDK
cd '$nativeWsl'
bash ./build.sh
"@
    & wsl -e bash -lc $cmd
    if ($LASTEXITCODE -ne 0) {
        Fail "native/build.sh failed inside WSL (exit $LASTEXITCODE)."
    }
} else {
    Fail @"
Need Git for Windows (recommended) or WSL2 with a Linux NDK.
Install Git from https://git-scm.com/download/win, then re-run .\native\build.ps1
"@
}

if (-not (Test-Path -LiteralPath $OutSo)) {
    Fail "Build reported success but $OutSo is missing."
}

Write-Host "OK: jniLibs ready at $(Split-Path -Parent $OutSo)"
Get-ChildItem (Split-Path -Parent $OutSo) | ForEach-Object { Write-Host "  $($_.Name)" }
