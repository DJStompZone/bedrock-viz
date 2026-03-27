<#
.SYNOPSIS
Builds bedrock-viz on Windows with sane defaults and fallback handling.

.DESCRIPTION
Clones or updates the bedrock-viz repository, applies required patches idempotently,
verifies required build tools, locates vcpkg, installs required dependencies if missing,
then configures and builds using CMake with a Visual Studio generator.

The script prefers Visual Studio 2022 and falls back to Visual Studio 2019 if needed.
Separate build directories are used for each generator attempt to avoid CMake cache weirdness.

.PARAMETER RepoUrl
Git URL for the repository to clone.

.PARAMETER RepoDir
Directory name for the local repository checkout.

.PARAMETER VcpkgRoot
Path to the vcpkg root directory. If omitted, the script attempts to discover it automatically.

.PARAMETER Configuration
Build configuration to use. Usually Debug or Release.

.PARAMETER SkipDependencyInstall
Skips vcpkg dependency installation checks.

.PARAMETER SkipClone
Skips cloning the repository if it does not already exist locally.

.PARAMETER ForcePatch
Attempts to apply patches even if the script thinks they may already be applied.

.EXAMPLE
.\build.ps1

.EXAMPLE
.\build.ps1 -VcpkgRoot C:\src\vcpkg -Configuration Release

.NOTES
Author: DJ Stomp <85457381+DJStompZone@users.noreply.github.com>
License: GPL-2.0
GitHub: https://github.com/DJStompZone/bedrock-viz
#>

[CmdletBinding()]
param(
    [string]$RepoUrl = "https://github.com/djstompzone/bedrock-viz.git",
    [string]$RepoDir = "bedrock-viz",
    [string]$VcpkgRoot,
    [ValidateSet("Debug", "Release", "RelWithDebInfo", "MinSizeRel")]
    [string]$Configuration = "Release",
    [switch]$SkipDependencyInstall,
    [switch]$SkipClone,
    [switch]$ForcePatch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:PatchFiles = @(
    "patches/leveldb-1.22.patch",
    "patches/pugixml-disable-install.patch"
)

$script:VcpkgPackages = @(
    "libpng:x64-windows",
    "zlib:x64-windows",
    "boost-program-options:x64-windows"
)

$script:GeneratorCandidates = @(
    @{
        Name = "Visual Studio 17 2022"
        BuildDir = "build-vs2022"
    },
    @{
        Name = "Visual Studio 16 2019"
        BuildDir = "build-vs2019"
    }
)

function Write-Info {
    param([string]$Message)
    Write-Host "[*] $Message"
}

function Write-Ok {
    param([string]$Message)
    Write-Host "[+] $Message" -ForegroundColor Green
}

function Write-WarnMsg {
    param([string]$Message)
    Write-Warning $Message
}

function Write-Fail {
    param([string]$Message)
    Write-Host "[X] $Message" -ForegroundColor Red
}

function Test-CommandExists {
    param([Parameter(Mandatory = $true)][string]$Name)
    return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter()][string[]]$ArgumentList = @(),
        [Parameter()][string]$WorkingDirectory = (Get-Location).Path,
        [switch]$AllowFailure
    )

    Write-Info ("Running: {0} {1}" -f $FilePath, ($ArgumentList -join " "))
    Push-Location $WorkingDirectory
    try {
        & $FilePath @ArgumentList
        $exitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    if (-not $AllowFailure -and $exitCode -ne 0) {
        throw "Bruh. Command failed with exit code $exitCode: $FilePath $($ArgumentList -join ' ')"
    }

    return $exitCode
}

function Get-ScriptRootSafe {
    if ($PSScriptRoot) {
        return $PSScriptRoot
    }

    return (Get-Location).Path
}

function Resolve-VcpkgRoot {
    param([string]$RequestedPath)

    $candidates = New-Object System.Collections.Generic.List[string]

    if ($RequestedPath) {
        $candidates.Add($RequestedPath)
    }

    if ($env:VCPKG_ROOT) {
        $candidates.Add($env:VCPKG_ROOT)
    }

    $commonCandidates = @(
        (Join-Path $HOME "vcpkg"),
        "C:\vcpkg",
        (Join-Path (Get-ScriptRootSafe) "vcpkg")
    )

    foreach ($candidate in $commonCandidates) {
        $candidates.Add($candidate)
    }

    foreach ($candidate in $candidates | Select-Object -Unique) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $normalized = [System.IO.Path]::GetFullPath($candidate)
            $vcpkgExe = Join-Path $normalized "vcpkg.exe"
            $toolchain = Join-Path $normalized "scripts\buildsystems\vcpkg.cmake"

            if ((Test-Path $vcpkgExe) -and (Test-Path $toolchain)) {
                return $normalized
            }
        }
    }

    throw "Uh oh... Could not locate vcpkg. Pass -VcpkgRoot or set VCPKG_ROOT."
}

function Test-VcpkgPackageInstalled {
    param(
        [Parameter(Mandatory = $true)][string]$VcpkgExe,
        [Parameter(Mandatory = $true)][string]$PackageName
    )

    $output = & $VcpkgExe list 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to query vcpkg package list."
    }

    foreach ($line in $output) {
        if ($line -match "^\Q$PackageName\E\s") {
            return $true
        }
    }

    return $false
}

function Install-VcpkgDependencies {
    param(
        [Parameter(Mandatory = $true)][string]$VcpkgRoot,
        [Parameter(Mandatory = $true)][string[]]$Packages
    )

    $vcpkgExe = Join-Path $VcpkgRoot "vcpkg.exe"
    $bootstrapBat = Join-Path $VcpkgRoot "bootstrap-vcpkg.bat"

    if (-not (Test-Path $vcpkgExe)) {
        if (-not (Test-Path $bootstrapBat)) {
            throw "Dang! vcpkg.exe is missing and bootstrap-vcpkg.bat was not found at $VcpkgRoot"
        }

        Write-Info "Bootstrapping vcpkg, buckle up..."
        Invoke-ExternalCommand -FilePath $bootstrapBat -WorkingDirectory $VcpkgRoot
    }

    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($package in $Packages) {
        if (-not (Test-VcpkgPackageInstalled -VcpkgExe $vcpkgExe -PackageName $package)) {
            $missing.Add($package)
        }
    }

    if ($missing.Count -eq 0) {
        Write-Ok "Sweet! All required vcpkg packages are already installed"
        return
    }

    Write-Info ("Installing missing vcpkg packages: {0}" -f ($missing -join ", "))
    Invoke-ExternalCommand -FilePath $vcpkgExe -ArgumentList @("install") + $missing.ToArray() -WorkingDirectory $VcpkgRoot
}

function Ensure-CoreAutocrlfLf {
    Write-Info "Setting git line-ending config for this build flow"
    Invoke-ExternalCommand -FilePath "git" -ArgumentList @("config", "--global", "core.autocrlf", "false")
    Invoke-ExternalCommand -FilePath "git" -ArgumentList @("config", "--global", "core.eol", "lf")
}

function Ensure-Repository {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Directory,
        [switch]$NoClone
    )

    if (Test-Path (Join-Path $Directory ".git")) {
        Write-Ok "Repository already exists: $Directory"
        return
    }

    if ($NoClone) {
        throw "Repository does not exist and -SkipClone was provided."
    }

    Write-Info "Cloning repository"
    Invoke-ExternalCommand -FilePath "git" -ArgumentList @("clone", "--recursive", $Url, $Directory)
}

function Apply-PatchIfNeeded {
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$PatchPath,
        [switch]$AlwaysTry
    )

    $fullPatchPath = Join-Path $RepoPath $PatchPath
    if (-not (Test-Path $fullPatchPath)) {
        throw "Patch file not found: $fullPatchPath"
    }

    if ($AlwaysTry) {
        Write-Info "Force-applying patch $PatchPath"
        Invoke-ExternalCommand -FilePath "git" -ArgumentList @("apply", "-p0", $PatchPath) -WorkingDirectory $RepoPath
        return
    }

    $checkExit = Invoke-ExternalCommand -FilePath "git" -ArgumentList @("apply", "--check", "-p0", $PatchPath) -WorkingDirectory $RepoPath -AllowFailure
    if ($checkExit -eq 0) {
        Write-Info "Applying patch $PatchPath"
        Invoke-ExternalCommand -FilePath "git" -ArgumentList @("apply", "-p0", $PatchPath) -WorkingDirectory $RepoPath
        return
    }

    $reverseCheckExit = Invoke-ExternalCommand -FilePath "git" -ArgumentList @("apply", "--reverse", "--check", "-p0", $PatchPath) -WorkingDirectory $RepoPath -AllowFailure
    if ($reverseCheckExit -eq 0) {
        Write-Ok "Skipping patch $PatchPath because it already appears to be applied"
        return
    }

    throw "Could not apply patch cleanly: $PatchPath"
}

function Get-CMakeGenerators {
    $output = & cmake --help 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to query CMake generators."
    }

    return $output
}

function Test-CMakeGeneratorAvailable {
    param([Parameter(Mandatory = $true)][string]$GeneratorName)

    $helpText = Get-CMakeGenerators
    return ($helpText -join "`n") -match [regex]::Escape($GeneratorName)
}

function Configure-And-Build {
    param(
        [Parameter(Mandatory = $true)][string]$SourceDir,
        [Parameter(Mandatory = $true)][string]$BuildDir,
        [Parameter(Mandatory = $true)][string]$Generator,
        [Parameter(Mandatory = $true)][string]$ToolchainFile,
        [Parameter(Mandatory = $true)][string]$Config
    )

    if (-not (Test-CMakeGeneratorAvailable -GeneratorName $Generator)) {
        throw "OMG CMake generator not available: $Generator"
    }

    $fullBuildDir = Join-Path $SourceDir $BuildDir
    if (-not (Test-Path $fullBuildDir)) {
        New-Item -ItemType Directory -Path $fullBuildDir | Out-Null
    }

    $configureArgs = @(
        "-S", $SourceDir,
        "-B", $fullBuildDir,
        "-G", $Generator,
        "-A", "x64",
        "-DCMAKE_TOOLCHAIN_FILE=$ToolchainFile"
    )

    Write-Info "Configuring with generator: $Generator"
    Invoke-ExternalCommand -FilePath "cmake" -ArgumentList $configureArgs

    $buildArgs = @(
        "--build", $fullBuildDir,
        "--config", $Config
    )

    Write-Info "Building with generator: $Generator"
    Invoke-ExternalCommand -FilePath "cmake" -ArgumentList $buildArgs
}

function Assert-Prerequisites {
    $requiredCommands = @("git", "cmake")
    foreach ($cmd in $requiredCommands) {
        if (-not (Test-CommandExists -Name $cmd)) {
            throw "Oh snap! Required command not found in PATH: $cmd"
        }
    }
}

function Main {
    Assert-Prerequisites

    $resolvedVcpkgRoot = Resolve-VcpkgRoot -RequestedPath $VcpkgRoot
    $toolchainFile = Join-Path $resolvedVcpkgRoot "scripts\buildsystems\vcpkg.cmake"

    Write-Ok "Using vcpkg root: $resolvedVcpkgRoot"

    if (-not $SkipDependencyInstall) {
        Install-VcpkgDependencies -VcpkgRoot $resolvedVcpkgRoot -Packages $script:VcpkgPackages
    } else {
        Write-WarnMsg "Skipping dependency installation checks"
    }

    Ensure-CoreAutocrlfLf
    Ensure-Repository -Url $RepoUrl -Directory $RepoDir -NoClone:$SkipClone

    $repoPath = [System.IO.Path]::GetFullPath($RepoDir)

    foreach ($patch in $script:PatchFiles) {
        Apply-PatchIfNeeded -RepoPath $repoPath -PatchPath $patch -AlwaysTry:$ForcePatch
    }

    $lastErrorMessage = $null

    foreach ($candidate in $script:GeneratorCandidates) {
        $generator = $candidate.Name
        $buildDir = $candidate.BuildDir

        try {
            Configure-And-Build -SourceDir $repoPath -BuildDir $buildDir -Generator $generator -ToolchainFile $toolchainFile -Config $Configuration
            Write-Ok "Build succeeded with $generator"
            return
        } catch {
            $lastErrorMessage = $_.Exception.Message
            Write-WarnMsg "Build attempt failed with $generator: $lastErrorMessage"
        }
    }

    throw "All build attempts failed. Last error: $lastErrorMessage"
}

Main
