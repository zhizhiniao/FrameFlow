# All queue transitions run on the WPF dispatcher. Workers own their logs and staging folders.
$script:tasks = [Collections.Generic.List[object]]::new()
$script:maxDownloads = 3
$script:loginTask = $null

function Update-Queue {
  $btnRetry.Visibility=if (@($script:tasks | Where-Object state -eq '失败').Count) { 'Visible' } else { 'Collapsed' }
  $active = @($script:tasks | Where-Object state -eq '下载中')
  $waiting = @($script:tasks | Where-Object { $_.state -in @('排队中','等待登录','登录中') })
  Set-Busy ($active.Count -gt 0 -or $waiting.Count -gt 0 -or $null -ne $script:loginProc)
  $finished=@($script:tasks | Where-Object { $_.state -in @('已完成','失败') })
  $queueList.ItemsSource = @($active) + @($waiting) + @($finished | Select-Object -Last 20)
  $queueList.Items.Refresh()
  $lblStatus.Text = if ($script:busy) { '进行中 {0} · 等待 {1}' -f $active.Count,$waiting.Count } else { '完成 {0} · 失败 {1}' -f @($finished | Where-Object state -eq '已完成').Count,@($finished | Where-Object state -eq '失败').Count }
  $lblProgress.Text = '最多同时下载 {0} 个任务，可继续添加链接。' -f $script:maxDownloads
  if (Get-Command Update-WechatDownloadStatus -ErrorAction SilentlyContinue) { Update-WechatDownloadStatus }
  $progress.Value = if ($active.Count) { ($active | Measure-Object percent -Average).Average } else { 0 }
}

function Add-DownloadTask([string]$text) {
  foreach ($match in [regex]::Matches($text, 'https?://[^\s<>"'']+')) {
    $r = Resolve-Tuwen $match.Value
    if (-not $r) { $r = Resolve-Url $match.Value }
    if (-not $r) { continue }
    if (@($script:tasks | Where-Object { $_.url -eq $r[1] -and $_.state -in @('排队中','下载中','等待登录','登录中') }).Count) { continue }
    $id = [guid]::NewGuid().ToString('N')
    $script:tasks.Add([pscustomobject]@{
      id=$id; url=$r[1]; platform=$r[0]; state='排队中'; percent=0; retries=0; proc=$null; logPos=0
      label=('{0} · {1}' -f $r[0], ([uri]$r[1]).GetLeftPart([UriPartial]::Path)); detail='等待开始'
      logFile=(Join-Path $dataDir ('tasks\'+$id+'.log')); staging=(Join-Path $outDir ('.frameflow-tasks\'+$id))
    })
  }
  Start-QueuedDownloads
  Update-Queue
  $script:dlTimer.Start()
}

function Start-QueuedDownloads {
  if ($script:loginProc) { return }
  foreach ($task in @($script:tasks | Where-Object state -eq '排队中')) {
    $active = @($script:tasks | Where-Object state -eq '下载中')
    if ($active.Count -ge $script:maxDownloads) { break }
    $platformId = $platformIds[$task.platform]
    # Chromium persistent profiles cannot be opened by two workers at once.
    if ($platformId -in @('douyin','xhs','bilibili','wxchannels') -and @($active | Where-Object { $platformIds[$_.platform] -eq $platformId }).Count) { continue }
    try {
      [void][IO.Directory]::CreateDirectory($task.staging)
      [void][IO.Directory]::CreateDirectory((Split-Path $task.logFile))
      $task.logPos=0
      if ($task.platform -eq '微信视频号') {
        $task.proc=Start-WechatEngine @('save','--manifest',$task.manifest,'--output',$task.staging) $task.logFile
      } else { $task.proc = Invoke-Download $task.platform $task.url $task.logFile $task.staging }
      $task.state = '下载中'; $task.detail='正在解析链接'
    } catch { $task.state='失败'; $task.detail='启动失败，请展开日志'; Log ('[任务 '+$task.id.Substring(0,6)+'] '+$_.Exception.Message) }
  }
  # Login uses a single browser window; drain active workers before changing shared credentials.
  if (-not @($script:tasks | Where-Object state -eq '下载中').Count) {
    $waiting = $script:tasks | Where-Object state -eq '等待登录' | Select-Object -First 1
    if ($waiting) {
      $script:loginTask=$waiting; $waiting.state='登录中'
      Set-Busy $false
      Start-PlatformLogin $platformIds[$waiting.platform]
      if (-not $script:loginProc) { Complete-QueueLogin $false }
    }
  }
}

function Complete-QueueLogin([bool]$success) {
  if ($script:loginTask) {
    $task=$script:loginTask; $script:loginTask=$null
    $task.state=if ($success) { '排队中' } else { '失败' }
    $task.detail=if ($success) { '登录完成，等待重试' } else { '登录未完成，请重新添加链接' }
  }
  Update-Queue
}

function Read-TaskLog($task) {
  if (-not (Test-Path -LiteralPath $task.logFile)) { return }
  try {
    $stream=[IO.FileStream]::new($task.logFile,'Open','Read','ReadWrite')
    $reader=[IO.StreamReader]::new($stream,[Text.UTF8Encoding]::new($false))
    try { $content=$reader.ReadToEnd() } finally { $reader.Dispose() }
    if ($content.Length -gt $task.logPos) {
      $next=$content.Substring($task.logPos); $task.logPos=$content.Length
      $txtLog.AppendText(('[任务 '+$task.id.Substring(0,6)+'] ')+$next)
      $matchesFound=[regex]::Matches($content,'\[download\]\s+([\d.]+)%([^\r\n]*)')
      if ($matchesFound.Count) {
        $last=$matchesFound[$matchesFound.Count-1]
        $task.percent=[Math]::Min(100,[double]::Parse($last.Groups[1].Value,[Globalization.CultureInfo]::InvariantCulture))
        $task.detail=$last.Value.Replace('[download]','').Trim()
      }
    }
  } catch { }
}

function Complete-TaskFiles($task) {
  # Never infer ownership by scanning changes in a shared output directory.
  $outputRoot=[IO.Path]::GetFullPath($outDir).TrimEnd('\')+'\'
  $stagingRoot=[IO.Path]::GetFullPath($task.staging).TrimEnd('\')+'\'
  if (-not $stagingRoot.StartsWith($outputRoot,[StringComparison]::OrdinalIgnoreCase)) { throw 'Staging path escaped output directory' }
  $files=@(Get-ChildItem -LiteralPath $task.staging -Force)
  if (-not $files.Count) { throw 'Worker returned success without any output' }
  $platformFolder=Join-Path $outDir (Get-PlatformFolder $task.platform)
  [void][IO.Directory]::CreateDirectory($platformFolder)
  foreach ($file in $files) {
    $destination=Join-Path $platformFolder $file.Name
    if (Test-Path -LiteralPath $destination) {
      $destination=Join-Path $platformFolder ($file.BaseName+'-'+$task.id+$file.Extension)
    }
    if (-not [IO.Path]::GetFullPath($destination).StartsWith($outputRoot,[StringComparison]::OrdinalIgnoreCase)) { throw 'Destination escaped output directory' }
    Move-Item -LiteralPath $file.FullName -Destination $destination -ErrorAction Stop
    if (-not $file.PSIsContainer -and $mediaExts -contains $file.Extension.ToLowerInvariant()) {
      $script:history = @($script:history | Where-Object { $null -ne $_ }) + @([pscustomobject]@{
        file=(Get-LibraryRelativePath $destination); url=($task.url -replace '(?i)([?&](?:xsec_token|access_token|token|signature|sessionid|auth)=)[^&]*','$1[redacted]')
        platform=$task.platform; title=$file.BaseName; time=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); size=$file.Length
      })
    }
  }
  Save-History $script:history
  [IO.Directory]::Delete($task.staging) # Empty only; partial/failed files are retained.
}

function Poll-Download {
  foreach ($task in @($script:tasks | Where-Object state -eq '下载中')) {
    Read-TaskLog $task
    if (-not $task.proc.HasExited) { continue }
    $task.proc.WaitForExit(); Read-TaskLog $task
    $code=$task.proc.ExitCode; $task.proc.Dispose(); $task.proc=$null
    if ($code -eq 0) {
      try { Complete-TaskFiles $task; $task.state='已完成'; $task.percent=100; $task.detail='已保存'; Refresh-History }
      catch { $task.state='失败'; $task.detail='文件整理失败，产物保留在 '+$task.staging; Log $_.Exception.Message }
    } elseif ($code -eq 10 -and $task.retries -lt 1 -and $platformIds[$task.platform] -in @('youtube','twitter','tiktok','douyin','xhs','bilibili','instagram')) {
      $task.retries++; $task.state='等待登录'; $task.detail='其他下载结束后自动登录'
    } else {
      $task.state='失败'; $task.detail=if ($task.platform -eq '微信视频号') { '请保持播放，重新抓取并确认封面后再下载' } elseif ($code -eq 12) { 'B 站请求受限，请在平台登录中更新登录态，稍后重试' } elseif ($code -eq 11) { '请在 Cookie 设置中登录 / 更新，然后重试失败任务' } else { '请查看日志后重新添加链接' }
      $txtLog.Visibility='Visible'; $btnLogs.Content='收起日志'
    }
  }
  Start-QueuedDownloads
  Update-Queue
  if (-not $script:busy) { $script:dlTimer.Stop(); Update-Accounts }
}

function Retry-FailedTasks {
  foreach ($task in @($script:tasks | Where-Object state -eq '失败')) {
    if (@($script:tasks | Where-Object { $_.url -eq $task.url -and $_.state -in @('排队中','下载中','等待登录','登录中') }).Count) { continue }
    $task.state='排队中'; $task.detail='等待重试'; $task.retries=0; $task.percent=0
  }
  Start-QueuedDownloads; Update-Queue; $script:dlTimer.Start()
}
