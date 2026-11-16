$script:appVersion=(Get-Content -LiteralPath (Join-Path $root 'app-version.json') -Raw | ConvertFrom-Json).version
$updateButton=$form.FindName('btnUpdate'); $updateStatus=$form.FindName('lblUpdateStatus')
$updateStatus.Text='v'+$script:appVersion
$script:updateJob=$null; $script:updateReady=$null
$script:nextUpdateCheck=[DateTime]::UtcNow.AddSeconds(12)
function Start-UpdateCheck {
  if ($script:updateJob) { return }
  $updateStatus.Text='正在后台检查并准备更新…'
  $script:updateJob=Start-Job -FilePath (Join-Path $root 'Update.Check.ps1') -ArgumentList $script:appVersion,$dataDir
}
$updateButton.Add_Click({
  if (-not $script:updateReady) { Start-UpdateCheck; return }
  if ($script:busy -or ($script:loginProc -and -not $script:loginProc.HasExited)) { $updateStatus.Text='请等待当前下载或登录结束后更新'; return }
  $stage=$script:updateReady.stage
  $helper=Join-Path (Split-Path $stage -Parent) 'Apply-Update.ps1'
  Copy-Item -LiteralPath (Join-Path $stage 'Update.Apply.ps1') -Destination $helper -Force
  $parentId=0
  try {
    $parent=(Get-CimInstance Win32_Process -Filter ('ProcessId='+$PID)).ParentProcessId
    if ((Get-Process -Id $parent).Path -ieq (Join-Path $root 'FrameFlow.exe')) { $parentId=$parent }
  } catch {}
  $args='-NoLogo -NoProfile -ExecutionPolicy Bypass -File '+(Quote-Arg $helper)+' -Stage '+(Quote-Arg $stage)+' -Target '+(Quote-Arg $root)+' -WaitProcessId '+$PID+' -LauncherProcessId '+$parentId
  Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $args -WorkingDirectory (Split-Path $helper -Parent) -WindowStyle Hidden
  $form.Close()
})
$script:updateTimer=[Windows.Threading.DispatcherTimer]::new()
$script:updateTimer.Interval=[TimeSpan]::FromSeconds(3)
$script:updateTimer.Add_Tick({
  if ($script:updateJob -and $script:updateJob.State -in @('Completed','Failed','Stopped')) {
    $result=@(Receive-Job $script:updateJob -ErrorAction SilentlyContinue) | Select-Object -Last 1
    Remove-Job $script:updateJob -Force; $script:updateJob=$null
    if ($result.status -eq 'Ready') {
      $script:updateReady=$result; $updateButton.Content='更新并重启'; $updateStatus.Text='新版 v'+$result.version+' 已准备好'
      $script:nextUpdateCheck=[DateTime]::MaxValue
    } elseif ($result.status -eq 'Current') {
      $updateStatus.Text='v'+$script:appVersion+' · 已是最新'; $script:nextUpdateCheck=[DateTime]::UtcNow.AddHours(4)
    } else {
      $updateStatus.Text='更新暂不可用，稍后自动重试'; $updateStatus.ToolTip=$result.message
      $script:nextUpdateCheck=[DateTime]::UtcNow.AddMinutes(15)
    }
  }
  if (-not $script:updateReady -and -not $script:updateJob -and [DateTime]::UtcNow -ge $script:nextUpdateCheck) { Start-UpdateCheck }
})
$form.Add_Closed({ $script:updateTimer.Stop(); if ($script:updateJob) { Stop-Job $script:updateJob; Remove-Job $script:updateJob -Force } })
if (-not $SelfTest -and -not $QueueTest) { $script:updateTimer.Start() }
