param([string]$Destination)
$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
$python=Join-Path $project '.build-venv\Scripts\python.exe'
& $python -m PyInstaller --noconfirm --clean --onefile --name FrameFlow.Wechat --distpath (Join-Path $project '.build\wechat-dist') --workpath (Join-Path $project '.build\wechat-pyinstaller') --specpath (Join-Path $project '.build') (Join-Path $project 'wechat_capture.py')
if ($LASTEXITCODE -ne 0) {throw 'WeChat capture engine build failed'}
if ($Destination) {
  [void][IO.Directory]::CreateDirectory((Join-Path $Destination 'wechat'))
  Copy-Item -LiteralPath (Join-Path $project '.build\wechat-dist\FrameFlow.Wechat.exe') -Destination (Join-Path $Destination 'wechat\FrameFlow.Wechat.exe') -Force
}
