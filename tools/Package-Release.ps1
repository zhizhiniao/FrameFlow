param([string]$Version='0.3.0',[string]$RuntimeDirectory,[switch]$Publish)
$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw 'Version must be x.y.z' }
if (-not $RuntimeDirectory) { $RuntimeDirectory=Join-Path $project 'release\FrameFlow-Portable-v0.2.4' }
$destination=Join-Path $project ('release\FrameFlow-Portable-v'+$Version)
if (Test-Path -LiteralPath $destination) { throw 'Release folder already exists; do not overwrite a published version' }
[void][IO.Directory]::CreateDirectory($destination)
# Copy a known runtime only, never project directories, media or session data.
foreach ($name in @('browser','worker','ffmpeg','licenses','yt-dlp-plugins')) {
  if (-not (Test-Path -LiteralPath (Join-Path $RuntimeDirectory $name))) { throw ('Missing runtime: '+$name) }
  Copy-Item -LiteralPath (Join-Path $RuntimeDirectory $name) -Destination (Join-Path $destination $name) -Recurse
}
Copy-Item -LiteralPath (Join-Path $RuntimeDirectory 'yt-dlp.exe') -Destination $destination
& (Join-Path $PSScriptRoot 'Build-Wechat.ps1') -Destination $destination
Get-ChildItem -LiteralPath (Join-Path $project 'licenses') -File | Copy-Item -Destination (Join-Path $destination 'licenses') -Force
foreach ($folder in @('docs','assets')) { Copy-Item -LiteralPath (Join-Path $project $folder) -Destination (Join-Path $destination $folder) -Recurse }
@{version=$Version;repository='zhizhiniao/FrameFlow';channel='stable'} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $project 'app-version.json') -Encoding UTF8
foreach ($file in @('VideoDownloader.ps1','VideoDownloader.UI.ps1','VideoDownloader.Platforms.ps1','VideoDownloader.Queue.ps1','VideoDownloader.Wechat.ps1','VideoDownloader.Accounts.ps1','VideoDownloader.Settings.ps1','VideoDownloader.Library.ps1','VideoDownloader.Update.ps1','VideoDownloader.xaml','VideoDownloader.Runtime.cs','Update.Check.ps1','Update.Apply.ps1','app-version.json','FrameFlow.ico','README.md','THIRD-PARTY-NOTICES.md','LICENSE')) {
  Copy-Item -LiteralPath (Join-Path $project $file) -Destination $destination
}
[void][IO.Directory]::CreateDirectory((Join-Path $destination 'source'))
foreach ($file in @('wechat_capture.py','frameflow_worker.py','cookiecloud_client.py','browser_media.py','douyin_note.py','FrameFlow.Launcher.cs','requirements-build.txt')) { Copy-Item -LiteralPath (Join-Path $project $file) -Destination (Join-Path $destination 'source') }
$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
& $compiler /nologo /target:winexe /platform:x64 /reference:System.Windows.Forms.dll ('/win32icon:'+(Join-Path $project 'FrameFlow.ico')) ('/out:'+(Join-Path $destination 'FrameFlow.exe')) (Join-Path $project 'FrameFlow.Launcher.cs')
if ($LASTEXITCODE -ne 0) { throw 'Launcher build failed' }
$files=@(Get-ChildItem -LiteralPath $destination -Recurse -File | ForEach-Object { @{path=$_.FullName.Substring($destination.Length+1).Replace('\','/');bytes=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()} })
@{version=$Version;target='Windows 10/11 x64';files=$files} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $destination 'manifest.json') -Encoding UTF8
$zip=Join-Path $project ('release\FrameFlow-Portable-v'+$Version+'-Windows-x64.zip')
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($destination,$zip,[IO.Compression.CompressionLevel]::Fastest,$false)
$sum=Join-Path $project 'release\SHA256SUMS.txt'
((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()+'  '+[IO.Path]::GetFileName($zip)) | Set-Content -LiteralPath $sum -Encoding ascii
if ($Publish) {
  & gh release create ('v'+$Version) $zip $sum --repo zhizhiniao/FrameFlow --title ('帧流 FrameFlow '+$Version) --notes-file (Join-Path $project 'docs\RELEASE-NOTES.md') --latest
  if ($LASTEXITCODE -ne 0) { throw 'GitHub release failed' }
}
Write-Output $zip
