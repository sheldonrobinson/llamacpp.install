<#
.SYNOPSIS
    Build one or both Llama.C++ MSI packages with WiX 3.14.

.DESCRIPTION
    Compiles and links Product.wxs + UI.wxs into a signed (optional) MSI.
    Supports per-machine (default) and per-user variants.
    Pass -Silent to embed SILENT=1 so the MSI skips dialogs at runtime.

.PARAMETER Variant
    "machine"  - per-machine MSI  (default, installs to Program Files)
    "user"     - per-user   MSI  (installs to LocalAppData, no UAC)
    "both"     - build both variants

.PARAMETER Flavor
    "vulkan"   - per-machine MSI  (default, installs to Program Files)
    "cuda-13.3"  - per-user   MSI  (installs to LocalAppData, no UAC)
    "cuda-12.4"  - per-user   MSI  (installs to LocalAppData, no UAC)
    "hip"      - per-machine MSI  (default, installs to Program Files)
    "cpu"      - per-user   MSI  (installs to LocalAppData, no UAC)
    "all"      - build all flavors
	
.PARAMETER SourceDir
    Path to the folder containing llama.exe
    Defaults to ..\src\bin\Release relative to the installer folder.

.PARAMETER OutputDir
    Where to place the finished .msi files.
    Defaults to .\output relative to the installer folder.

.PARAMETER WixTargetsPath
    MSBuild will look for Wix.targets, WixTargetsPath property specifies the path to that file.
    Defaults to $(MSBuildExtensionsPath32)\Microsoft\WiX\v3.x\Wix.targets

.PARAMETER Sign
    Sign the MSI with signtool after linking.
    Requires CertThumbprint or a suitable certificate in the current user store.

.PARAMETER CertThumbprint
    SHA-1 thumbprint of a code-signing certificate in the current user store.

.PARAMETER TimestampUrl
    RFC-3161 timestamp server URL.
    Default: http://timestamp.digicert.com

.EXAMPLE
    # Basic build (per-machine, no signing)
    .\build.ps1

    # Build both variants pointing at a custom source directory
    .\build.ps1 -Variant both -SourceDir C:\myapp\bin\Release

    # Silent MSI (no UI dialogs)
    .\build.ps1 -Silent

    # Signed release build
    .\build.ps1 -Variant both -Sign -CertThumbprint AABBCCDDEEFF00112233445566778899AABBCCDD
#>
[CmdletBinding()]
param(
    [ValidateSet("machine","user","both")]
    [string]$Variant      = "both",
	[ValidateSet("cpu","vulkan","sycl","hip-radeon","cuda-12.4","cuda-13.3", "all")]
	[string]$Flavor       = "all",

    [string]$SourceDir    = (Join-Path $PSScriptRoot "..\bin\Release"),
    [string]$OutputDir    = (Join-Path $PSScriptRoot "output"),
    [string]$WixTargetsPath       = "C:\Program Files\Microsoft Visual Studio\2022\Community\MSBuild\WixToolset\7.0\Imports\WixToolset.targets",

    [switch]$Sign,
    [string]$CertThumbprint = "",
    [string]$TimestampUrl   = "http://timestamp.digicert.com"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
$null = New-Item -ItemType Directory -Force -Path $OutputDir

$WixProj  = Join-Path $PSScriptRoot "installer.wixproj"
$srcDir  = $PSScriptRoot
$iconDir = Join-Path $PSScriptRoot "icons"

# ---------------------------------------------------------------------------
# Determine product version
#   1. Read FileVersion from llama-server.exe   (preferred)
#   2. Fall back to version.txt          (used during development)
# ---------------------------------------------------------------------------

$vFile   = Join-Path $PSScriptRoot "version.txt"
$version = if (Test-Path $vFile) { (Get-Content $vFile -Raw).Trim() } else { "b0" }
$stagingDir  = (Join-Path $PSScriptRoot "..\staging")					# Temporary staging folder

Write-Host ""
Write-Host "=======================================" -ForegroundColor Cyan
Write-Host "  LlaMA.C++ MSI Builder" -ForegroundColor Cyan
Write-Host "  Version   : $version" -ForegroundColor Cyan
Write-Host "  Variant   : $Variant" -ForegroundColor Cyan
Write-Host "  OutputDir : $OutputDir" -ForegroundColor Cyan
Write-Host "=======================================" -ForegroundColor Cyan
Write-Host ""


# --------------------------------------------------------------------------
# Download and Extract function
# --------------------------------------------------------------------------
function Download-Extract {
	# --- CONFIGURATION ---
	 param(
		[string]$zipUrl,   		# URL of the ZIP file
		[string]$zipFileName,
		[string]$stagingPath,   # Temporary staging folder
		[string]$targetFolder  # Final destination
	)

	try {
		# Ensure staging directory exists  (clean if exists)
		if (Test-Path $stagingPath) { Remove-Item $stagingPath -Recurse -Force }
		New-Item -Path $stagingPath -ItemType Directory -Force | Out-Null

		# Download ZIP
		$zipFilePath = Join-Path $stagingPath $zipFileName
		Write-Host "Downloading ZIP from $zipUrl ..."
		Invoke-WebRequest -Uri $zipUrl -OutFile $zipFilePath -UseBasicParsing

		if (-not (Test-Path $zipFilePath)) {
			throw "Download failed. ZIP file not found."
		}
		
		# Ensure target extract folder exists (clean if exists)
		if (Test-Path $targetFolder) { Remove-Item $targetFolder -Recurse -Force }
		New-Item -Path $targetFolder -ItemType Directory -Force | Out-Null

		# Extract entire ZIP
		Write-Host "Extracting ZIP to target folder..."
		Expand-Archive -Path $zipFilePath -DestinationPath $targetFolder -Force

		Write-Host "Extraction complete."
		
		Write-Host "Clean-up staging folder..."
		Remove-Item $stagingPath -Recurse -Force

	} catch {
		Write-Error "Error: $_"
	}
}

# --------------------------------------------------------------------------
# Download and Extract function
# --------------------------------------------------------------------------
function Download-Cuda {
	# --- CONFIGURATION ---
	 param(
		[string]$zipUrl,   		# URL of the ZIP file
		[string]$zipFileName,
		[string]$stagingPath,   # Temporary staging folder
		[string]$targetFolder  # Final destination
	)

	try {
		# Ensure staging directory exists  (clean if exists)
		if (Test-Path $stagingPath) { Remove-Item $stagingPath -Recurse -Force }
		New-Item -Path $stagingPath -ItemType Directory -Force | Out-Null

		# Download ZIP
		$zipFilePath = Join-Path $stagingPath $zipFileName
		Write-Host "Downloading ZIP from $zipUrl ..."
		Invoke-WebRequest -Uri $zipUrl -OutFile $zipFilePath -UseBasicParsing

		if (-not (Test-Path $zipFilePath)) {
			throw "Download failed. ZIP file not found."
		}

		# Extract entire ZIP
		Write-Host "Extracting ZIP to target folder..."
		Expand-Archive -Path $zipFilePath -DestinationPath $targetFolder -Force

		Write-Host "Extraction complete."
		
		Write-Host "Clean-up staging folder..."
		Remove-Item $stagingPath -Recurse -Force

	} catch {
		Write-Error "Error: $_"
	}
}

# ---------------------------------------------------------------------------
# Build function
# ---------------------------------------------------------------------------
function Invoke-WixBuild {
    param(
		[string]$WixProject,   # Path to installer.wixproj
        [string]$BuildType,    # BuildType - Machine, User
		[string]$prefix,
        [string]$Flavor,       # Flavor - cpu, vulkan, hip-radeon, cuda-12.4, cuda-13.3
		[string]$ProductVersion,
		[string]$SourceRoot,
		[string]$OutputDir
    )

	# Ensure staging directory exists  (clean if exists)
	if (Test-Path $OutputDir) { Remove-Item $OutputDir -Recurse -Force }
	New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
	$fileName = "{0}-{1}-{2}.msi" -f $prefix, $Flavor, $ProductVersion
	$OutputMsi = Join-Path $OutputDir $fileName
	$semVer    = "0.0.{0}.0" -f $ProductVersion.TrimStart("b")
	$Scope	   = "per{0}" -f $BuildType
	# $srcDir    = Join-Path $OutputDir $fileName
	
	$BuildDir = Join-Path $OutputDir "build"
	if (Test-Path $BuildDir) { Remove-Item $BuildDir -Recurse -Force }
	New-Item -Path $BuildDir -ItemType Directory -Force | Out-Null
	
	Write-Host "[dotnet] Compiling $(Split-Path $WixProject -Leaf) ..." -ForegroundColor DarkCyan
	
	$SourceDir = Join-Path $SourceRoot $Flavor
	$ProductWxs 	= Join-Path $PSScriptRoot "Product.wxs"
	
	Write-Host "[wix] Compiling $(Split-Path $ProductWxs -Leaf) ..." -ForegroundColor DarkCyan
	wix build -arch "x64" -outputtype "Package" -culture "en-US" -b $SourceDir -out $OutputMsi `
			  -intermediatefolder $BuildDir -src $ProductWxs -ext WixToolset.Util.wixext -ext WixToolset.UI.wixext `
			  -d BuildType=$BuildType -d SemVersion=$semVer -d ProductVersion=$ProductVersion -d SourceDir=$SourceDir `
			  -d SourceRoot=$SourceRoot -d Flavor=$Flavor -d Scope=$Scope

    Write-Host "[ok]     $OutputMsi" -ForegroundColor Green
    return $OutputMsi
}

# ---------------------------------------------------------------------------
# Signing helper
# ---------------------------------------------------------------------------
function Invoke-Sign {
    param([string]$MsiPath)
    if (-not $Sign) { return }

    # Auto-locate signtool.exe from Windows SDK
    $st = ""
    if (Test-Path "C:\Program Files (x86)\Windows Kits\10\bin") {
        $st = Get-ChildItem "C:\Program Files (x86)\Windows Kits\10\bin" `
                            -Recurse -Filter "signtool.exe" |
              Where-Object { $_.FullName -match 'x64' } |
              Sort-Object FullName -Descending |
              Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $st) { throw "signtool.exe not found. Install the Windows SDK." }

    $signArgs = @("sign", "/fd", "SHA256", "/tr", $TimestampUrl, "/td", "SHA256")
    if ($CertThumbprint) {
        $signArgs += @("/sha1", $CertThumbprint)
    } else {
        $signArgs += "/a"   # auto-select best available certificate
    }
    $signArgs += $MsiPath

    Write-Host "[sign]   Signing $(Split-Path $MsiPath -Leaf) ..." -ForegroundColor DarkCyan
    & $st @signArgs
    if ($LASTEXITCODE -ne 0) { throw "signtool.exe failed with exit code $LASTEXITCODE" }
    Write-Host "[ok]     Signed: $MsiPath" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Dispatch builds
# ---------------------------------------------------------------------------
$built = @()
$flavors = @("cpu", "vulkan", "sycl", "hip-radeon", "cuda-12.4", "cuda-13.3")
$cudarts = @("cuda-12.4", "cuda-13.3")

try {
    # Validate input: ensure it's a list of strings
    if (-not $flavors -or -not ($flavors -is [System.Collections.IEnumerable])) {
        throw "Input is not a valid list."
    }
	
	$ghRepo  = "ggml-org/llama.cpp"

    foreach ($flavor in $flavors) {
        if (-not ($flavor -is [string])) {
            Write-Warning "Skipping non-string flavor: $flavor"
            continue
        }
		$fileName       = "llama-{0}-bin-win-{1}-x64.zip" -f $version, $flavor
		$downloadUrl    = "https://github.com/{0}/releases/download/{1}/{2}" -f $ghRepo, $version, $fileName  # URL of the ZIP file
		$targetFolder   = Join-Path $SourceDir $flavor			# Temporary staging folder
		
		Download-Extract -zipUrl $downloadURL `
						 -zipFileName $fileName `
						 -stagingPath $stagingDir `
						 -targetFolder $targetFolder 

        # Perform some action on each string
        Write-Output "Extracted $downloadUrl to $targetFolder"
    }
	
	
	foreach($cuda in $cudarts) {
		$fileName       = "cudart-llama-bin-win-{0}-x64.zip" -f $cuda
		$downloadUrl    = "https://github.com/{0}/releases/download/{1}/{2}" -f $ghRepo, $version, $fileName # URL of the ZIP file
		$targetFolder   = Join-Path $SourceDir $cuda
		
		Download-Cuda -zipUrl $downloadURL `
					  -zipFileName $fileName `
					  -stagingPath $stagingDir `
					  -targetFolder $targetFolder 
					  
		# Perform some action on each string
        Write-Output "Extracted $downloadUrl to $targetFolder"
	}
}
catch {
    Write-Error "Error while processing list: $_"
}

if ($Variant -in "machine","both") {
	if (-not (Test-Path $SourceDir)) {
		throw "SourceDir not found: $SourceDir`nNot created, or pass -SourceDir."
	}
	foreach ($flavor in $flavors) {

		$OutputFolder = Join-Path $OutputDir "Machine" $flavor
		$fileName = "llamacpp-superuser-{0}-{1}.msi" -f $flavor, $version
		$msi = Join-Path $OutputFolder $fileName

		Invoke-WixBuild -WixProject (Join-Path $srcDir "installer.wixproj") `
						-BuildType  "Machine" `
						-prefix     "llamacpp-superuser" `
						-Flavor     $flavor `
						-ProductVersion $version `
						-SourceRoot $SourceDir `
						-OutputDir  $OutputFolder 
		
		Invoke-Sign $msi
		$built += $msi
	}
}

if ($Variant -in "user","both") {
	if (-not (Test-Path $SourceDir)) {
		throw "SourceDir not found: $SourceDir`nNot created, or pass -SourceDir."
	}
	foreach ($flavor in $flavors) {

		$OutputFolder = Join-Path $OutputDir "User" $flavor
		$fileName = "llamacpp-enduser-{0}-{1}.msi" -f  $flavor, $version
		$msi = Join-Path $OutputFolder $fileName

		Invoke-WixBuild -WixProject (Join-Path $srcDir "installer.wixproj") `
						-BuildType  "User" `
						-prefix     "llamacpp-enduser" `
						-Flavor     $flavor `
						-ProductVersion $version `
						-SourceRoot $SourceDir `
						-OutputDir  $OutputFolder 
		
		Invoke-Sign $msi
		$built += $msi
	}
}

Write-Host ""
Write-Host "Build complete.  Output files:" -ForegroundColor Cyan
$built | ForEach-Object { Write-Host "  $_" -ForegroundColor White }
Write-Host ""
