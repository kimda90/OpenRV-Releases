# Package OpenRV _build\stage to dist\OpenRV-{Tag}-windows-x86_64.zip
# Archive root is the contents of stage (unzip gives app\, lib\, etc.).
# Usage: .\package_windows.ps1 -OpenRVRoot 'C:\OpenRV' -Tag 'v3.2.1' [-OutDir 'dist']
param(
    [Parameter(Mandatory = $true)]
    [string]$OpenRVRoot,
    [Parameter(Mandatory = $true)]
    [string]$Tag,
    [string]$OutDir = 'dist'
)

$ErrorActionPreference = 'Stop'

$stageDir = Join-Path $OpenRVRoot '_build\stage'
if (-not (Test-Path $stageDir)) {
    throw "Stage directory not found: $stageDir"
}
$rvExe = Join-Path $stageDir 'app\bin\rv.exe'
if (-not (Test-Path $rvExe)) {
    throw "Stage incomplete: $rvExe not found. Run the build first."
}

$archiveName = "OpenRV-$Tag-windows-x86_64.zip"
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$zipPath = Join-Path $OutDir $archiveName

if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zipFullPath = $zipPath
if (-not [System.IO.Path]::IsPathRooted($zipPath)) {
    $zipFullPath = Join-Path (Get-Location) $zipPath
}
$zip = [System.IO.Compression.ZipFile]::Open($zipFullPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    $stageFullPath = (Resolve-Path $stageDir).Path
    foreach ($f in Get-ChildItem -Path $stageDir -Recurse -File) {
        $rel = $f.FullName.Substring($stageFullPath.Length + 1).Replace('\', '/')
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $f.FullName, $rel, [System.IO.Compression.CompressionLevel]::Optimal)
    }
} finally {
    $zip.Dispose()
}

Write-Host "Created $zipPath"
