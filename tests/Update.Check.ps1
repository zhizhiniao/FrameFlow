$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
. (Join-Path $project 'Update.Check.ps1') -LibraryOnly
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('FrameFlow-Update-Test-'+[guid]::NewGuid().ToString('N'))
$stage=Join-Path $fixture 'stage'; $target=Join-Path $fixture 'target'
[void][IO.Directory]::CreateDirectory($stage); [void][IO.Directory]::CreateDirectory($target)
function Assert($condition,$message) { if (-not $condition) { throw $message } }
Assert ((Get-UpdateVersion 'v0.10.0') -gt (Get-UpdateVersion '0.9.9')) 'Semantic comparison failed'
foreach ($bad in @('../escape','C:\escape','file:stream','/root','..\escape')) {
  $rejected=$false; try { $null=Get-UpdatePath $stage $bad } catch { $rejected=$true }; Assert $rejected ('Unsafe path accepted: '+$bad)
}
foreach ($file in @('FrameFlow.exe','VideoDownloader.ps1','app-version.json')) { Set-Content -LiteralPath (Join-Path $stage $file) -Value 'new' -Encoding UTF8; Set-Content -LiteralPath (Join-Path $target $file) -Value 'old' -Encoding UTF8 }
'{"version":"0.3.1"}' | Set-Content -LiteralPath (Join-Path $stage 'app-version.json') -Encoding UTF8
foreach ($file in @('Update.Apply.ps1','Update.Check.ps1')) { Copy-Item -LiteralPath (Join-Path $project $file) -Destination $stage; Copy-Item -LiteralPath (Join-Path $project $file) -Destination $target }
$files=@(Get-ChildItem -LiteralPath $stage -File | Sort-Object Name | ForEach-Object { @{path=$_.Name;bytes=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName).Hash} })
@{files=$files} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'manifest.json') -Encoding UTF8
$null=Confirm-UpdateFiles $stage
Set-Content -LiteralPath (Join-Path $target 'my-video.mp4') -Value 'keep'
& (Join-Path $project 'Update.Apply.ps1') -Stage $stage -Target $target -NoRestart
Assert ((Get-Content -LiteralPath (Join-Path $target 'FrameFlow.exe') -Raw).Trim() -eq 'new') 'Install did not apply'
Assert ((Get-Content -LiteralPath (Join-Path $target 'my-video.mp4') -Raw).Trim() -eq 'keep') 'User file changed'
Set-Content -LiteralPath (Join-Path $target 'FrameFlow.exe') -Value 'old'
$locked=[IO.File]::Open((Join-Path $target 'VideoDownloader.ps1'),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
$failed=$false
try { & (Join-Path $project 'Update.Apply.ps1') -Stage $stage -Target $target -NoRestart } catch { $failed=$true } finally { $locked.Dispose() }
Assert $failed 'Locked target did not fail'
Assert ((Get-Content -LiteralPath (Join-Path $target 'FrameFlow.exe') -Raw).Trim() -eq 'old') 'Rollback did not restore old launcher'
Add-Content -LiteralPath (Join-Path $stage 'FrameFlow.exe') -Value 'corrupt'
$rejected=$false; try { $null=Confirm-UpdateFiles $stage } catch { $rejected=$true }; Assert $rejected 'Corrupt package was accepted'
Write-Output 'PASS: semantic versions, 5 unsafe paths, manifest hashes, install, user-file preservation, locked-file rollback, corrupted package rejection.'
