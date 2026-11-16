param([string]$CurrentVersion, [string]$DataDirectory, [switch]$LibraryOnly)
$ErrorActionPreference='Stop'
function Get-UpdateVersion([string]$Tag) {
  if ($Tag -notmatch '^v?(\d+\.\d+\.\d+)$') { throw 'Unsupported stable version' }
  return [version]$Matches[1]
}
function Get-UpdatePath([string]$Base, [string]$Relative) {
  if ([string]::IsNullOrWhiteSpace($Relative) -or $Relative -match '(^[/\\]|:|(^|[/\\])\.\.([/\\]|$))') { throw 'Unsafe package path' }
  $prefix=[IO.Path]::GetFullPath($Base).TrimEnd('\')+'\'
  $full=[IO.Path]::GetFullPath((Join-Path $Base $Relative))
  if (-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Package escaped destination' }
  return $full
}
function Confirm-UpdateFiles([string]$Stage) {
  $manifest=Get-Content -LiteralPath (Join-Path $Stage 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  if (-not $manifest.files -or $manifest.files.Count -gt 100000) { throw 'Invalid package manifest' }
  $seen=@{}
  foreach ($entry in $manifest.files) {
    $file=Get-UpdatePath $Stage $entry.path
    if ($seen.ContainsKey($file)) { throw 'Duplicate manifest path' }; $seen[$file]=$true
    if ($entry.sha256 -notmatch '^[0-9a-fA-F]{64}$' -or -not (Test-Path -LiteralPath $file -PathType Leaf)) { throw 'Missing or invalid package file' }
    $item=Get-Item -LiteralPath $file
    if ($item.Length -ne $entry.bytes -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ine $entry.sha256) { throw ('Package hash mismatch: '+$entry.path) }
  }
  foreach ($required in @('FrameFlow.exe','VideoDownloader.ps1','Update.Apply.ps1','Update.Check.ps1','app-version.json')) {
    if (-not $seen.ContainsKey((Get-UpdatePath $Stage $required))) { throw ('Missing required component: '+$required) }
  }
  return $manifest
}
function Expand-UpdatePackage([string]$Zip, [string]$Stage) {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $archive=[IO.Compression.ZipFile]::OpenRead($Zip)
  try {
    $seen=@{}; [long]$total=0
    foreach ($entry in $archive.Entries) {
      $dest=Get-UpdatePath $Stage $entry.FullName
      if ($seen.ContainsKey($dest)) { throw 'Duplicate ZIP entry' }; $seen[$dest]=$true
      if ((($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { throw 'Symbolic links are not allowed' }
      $total+=$entry.Length
      if ($total -gt 4GB -or $seen.Count -gt 100000) { throw 'Package expansion limit exceeded' }
    }
    foreach ($entry in $archive.Entries) {
      $dest=Get-UpdatePath $Stage $entry.FullName
      if (-not $entry.Name) { [void][IO.Directory]::CreateDirectory($dest); continue }
      [void][IO.Directory]::CreateDirectory((Split-Path $dest -Parent))
      [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$dest,$false)
    }
  } finally { $archive.Dispose() }
}
if ($LibraryOnly) { return }
try {
  [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
  $release=Invoke-RestMethod -Uri 'https://api.github.com/repos/zhizhiniao/FrameFlow/releases/latest' -Headers @{'User-Agent'='FrameFlow-Updater';Accept='application/vnd.github+json'} -TimeoutSec 30
  $version=Get-UpdateVersion $release.tag_name
  if ($release.draft -or $release.prerelease -or $version -le (Get-UpdateVersion $CurrentVersion)) { [pscustomobject]@{status='Current'}; return }
  $name='FrameFlow-Portable-v'+$version.ToString()+'-Windows-x64.zip'
  $assets=@($release.assets | Where-Object name -eq $name)
  if ($assets.Count -ne 1) { throw 'Release package is not ready yet' }; $asset=$assets[0]
  $expected='https://github.com/zhizhiniao/FrameFlow/releases/download/v'+$version.ToString()+'/'+$name
  if ($asset.browser_download_url -cne $expected -or $asset.digest -notmatch '^sha256:([a-fA-F0-9]{64})$') { throw 'Release URL or SHA256 metadata is invalid' }
  $hash=$Matches[1]
  if ($asset.size -le 0 -or $asset.size -gt 2GB) { throw 'Release package size is invalid' }
  $cache=Join-Path $DataDirectory ('updates\'+$version.ToString())
  $stage=Join-Path $cache 'stage'
  $ready=Join-Path $cache 'ready.json'
  if (Test-Path -LiteralPath $ready) {
    $cached=Get-Content -LiteralPath $ready -Raw | ConvertFrom-Json
    if ($cached.sha256 -eq $hash) { $stage=$cached.stage; $null=Confirm-UpdateFiles $stage; [pscustomobject]@{status='Ready';version=$version.ToString();stage=$stage}; return }
  }
  # A unique staging directory means interrupted downloads never become installable.
  $cache=Join-Path $DataDirectory ('updates\'+$version.ToString()+'-'+[guid]::NewGuid().ToString('N'))
  $stage=Join-Path $cache 'stage'; [void][IO.Directory]::CreateDirectory($stage)
  $zip=Join-Path $cache 'package.zip.partial'
  Invoke-WebRequest -UseBasicParsing -Uri $expected -OutFile $zip -TimeoutSec 900
  if ((Get-Item -LiteralPath $zip).Length -ne $asset.size -or (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ine $hash) { throw 'Downloaded package SHA256 mismatch' }
  Expand-UpdatePackage $zip $stage
  $null=Confirm-UpdateFiles $stage
  if ((Get-Content -LiteralPath (Join-Path $stage 'app-version.json') -Raw | ConvertFrom-Json).version -ne $version.ToString()) { throw 'Package version mismatch' }
  $index=Join-Path $DataDirectory ('updates\'+$version.ToString()); [void][IO.Directory]::CreateDirectory($index)
  @{sha256=$hash;stage=$stage;version=$version.ToString()} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $index 'ready.json') -Encoding UTF8
  [pscustomobject]@{status='Ready';version=$version.ToString();stage=$stage}
} catch { [pscustomobject]@{status='Error';message=$_.Exception.Message} }
