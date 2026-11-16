param([string]$Destination, [switch]$SkipWorker)
$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
if (-not $Destination) { $Destination=Join-Path $project 'release\FrameFlow-Portable-v0.2.4' }
$dependencyRoot=if(Test-Path -LiteralPath (Join-Path $project 'yt-dlp.exe')){$project}else{Split-Path $project -Parent}
$python=Join-Path $project '.build-venv\Scripts\python.exe'
$Destination=[IO.Path]::GetFullPath($Destination)
if (-not $SkipWorker) {
  & $python -m PyInstaller --clean --noconfirm --onedir --name FrameFlow.Worker --distpath (Join-Path $project '.build\worker-dist') --workpath (Join-Path $project '.build\pyinstaller') --specpath (Join-Path $project '.build') --collect-all playwright --collect-all patchright (Join-Path $project 'frameflow_worker.py')
  if ($LASTEXITCODE -ne 0) { throw 'Worker build failed' }
}
New-Item -ItemType Directory -Force -Path $Destination | Out-Null
$pluginPath='yt-dlp-plugins\frameflow-vjshi\yt_dlp_plugins\extractor'
$pluginTarget=Join-Path $Destination $pluginPath
New-Item -ItemType Directory -Force -Path $pluginTarget | Out-Null
foreach ($file in @('vjshi.py','case-player.cjs')) {
  Copy-Item -LiteralPath (Join-Path (Join-Path $dependencyRoot $pluginPath) $file) -Destination $pluginTarget -Force
}
# Explicit allowlist. Never recurse across the working project or user's data folders.
foreach ($file in @('VideoDownloader.ps1','VideoDownloader.UI.ps1','VideoDownloader.Queue.ps1','VideoDownloader.Accounts.ps1','VideoDownloader.Settings.ps1','VideoDownloader.Library.ps1','VideoDownloader.xaml','VideoDownloader.Runtime.cs','yt-dlp.exe','FrameFlow.ico','README.md','便携版-验收记录.md','PORTABLE-使用说明.md','THIRD-PARTY-NOTICES.md')) {
  $sourceRoot=if($file -eq 'yt-dlp.exe'){$dependencyRoot}else{$project}
  Copy-Item -LiteralPath (Join-Path $sourceRoot $file) -Destination (Join-Path $Destination $file) -Force
}
New-Item -ItemType Directory -Force -Path (Join-Path $Destination 'ffmpeg\bin'),(Join-Path $Destination 'worker'),(Join-Path $Destination 'browser'),(Join-Path $Destination 'licenses'),(Join-Path $Destination 'source') | Out-Null
foreach ($file in @('ffmpeg.exe','ffprobe.exe')) { Copy-Item -LiteralPath (Join-Path $dependencyRoot ('ffmpeg\bin\'+$file)) -Destination (Join-Path $Destination 'ffmpeg\bin') -Force }
Get-ChildItem -LiteralPath (Join-Path $project '.build\worker-dist\FrameFlow.Worker') | Copy-Item -Destination (Join-Path $Destination 'worker') -Recurse -Force
$browser = & $python -c "from playwright.sync_api import sync_playwright`nwith sync_playwright() as p:`n print(p.chromium.executable_path)"
if (-not (Test-Path -LiteralPath $browser)) { throw 'Matching Chromium is missing; run .build-venv\Scripts\python -m playwright install chromium' }
Get-ChildItem -LiteralPath (Split-Path $browser -Parent) | Copy-Item -Destination (Join-Path $Destination 'browser') -Recurse -Force
$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
& $compiler /nologo /target:winexe /platform:x64 /reference:System.Windows.Forms.dll ('/win32icon:' + (Join-Path $project 'FrameFlow.ico')) ('/out:' + (Join-Path $Destination 'FrameFlow.exe')) (Join-Path $project 'FrameFlow.Launcher.cs')
if ($LASTEXITCODE -ne 0) { throw 'Launcher build failed' }
foreach ($file in @('frameflow_worker.py','cookiecloud_client.py','browser_media.py','douyin_note.py','FrameFlow.Launcher.cs')) { Copy-Item -LiteralPath (Join-Path $project $file) -Destination (Join-Path $Destination 'source') -Force }
Copy-Item -LiteralPath (Join-Path $dependencyRoot 'ffmpeg\ffmpeg-8.0-essentials_build\LICENSE') -Destination (Join-Path $Destination 'licenses\FFmpeg-GPL.txt') -Force
Copy-Item -LiteralPath (Join-Path $dependencyRoot 'ffmpeg\ffmpeg-8.0-essentials_build\README.txt') -Destination (Join-Path $Destination 'licenses\FFmpeg-build.txt') -Force
Get-ChildItem -LiteralPath (Join-Path $project 'licenses') -File | Copy-Item -Destination (Join-Path $Destination 'licenses') -Force
  $files = @(Get-ChildItem -LiteralPath $Destination -Recurse -File | Where-Object FullName -NE (Join-Path $Destination 'manifest.json') | ForEach-Object {
  @{path=$_.FullName.Substring($Destination.Length+1).Replace('\','/'); bytes=$_.Length; sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}
})
@{version='0.2.4-preview'; target='Windows 10/11 x64'; files=$files} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Destination 'manifest.json') -Encoding UTF8
Write-Output ('Portable folder: '+$Destination)
