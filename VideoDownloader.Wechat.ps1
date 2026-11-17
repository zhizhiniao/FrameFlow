# The optional GPL capture engine runs in a separate process. No system proxy changes.
$script:wechatProc=$null
$script:wechatSession=$null
$script:wechatStateTime=0
$script:wechatCandidatesData=@()
$script:wechatMode=$false
$script:wechatResultsView=$false
$script:wechatLastState=$null
$script:wechatPulse=0

function Update-WechatCaptureStatus {
  $state=$script:wechatLastState
  $count=$script:wechatCandidatesData.Count
  $running=$script:wechatProc -and -not $script:wechatProc.HasExited
  if ($running) {
    if (Test-Path -LiteralPath (Join-Path $script:wechatSession 'stop')) {$text='正在停止抓取…'}
    elseif ($state.phase -eq 'baseline') {$text='正在准备，请稍候…'}
    elseif ($state.phase -eq 'preview') {$text='正在生成封面，请稍候…'}
    elseif ($state.message -like '*未发现*') {$text='请打开微信并播放视频。'}
    elseif ($state.message -like '*无法读取*') {$text='微信权限不匹配，请检查运行权限。'}
    elseif ($count) {$text='抓取中 · 已找到 '+$count+' 条视频'}
    else {$hints=@('正在抓取，请稍候…','等待新播放的视频…','还在抓取中，请稍候…');$text=$hints[[int]([math]::Floor($script:wechatPulse/3)%3)]}
  } elseif ($state.phase -eq 'error') {$text='抓取失败，请重试。'}
  elseif ($count) {$text='已停止 · '+$count+' 条视频'}
  else {$text='尚未开始'}
  $lblWechatState.Text=$text
  $lblWechatState.ToolTip=if($state.phase -eq 'error'){$state.message}else{$null}
}

function Set-WechatResultsView([bool]$capture) {
  $script:wechatResultsView=$capture
  foreach ($item in @($libraryToolbar,$libraryContent,$libraryActions,$lblCount)) {$item.Visibility=if($capture){'Collapsed'}else{'Visible'}}
  foreach ($item in @($captureHint,$captureContent,$captureSelectionHint,$lblWechatCount)) {$item.Visibility=if($capture){'Visible'}else{'Collapsed'}}
  $brush=[Windows.Media.BrushConverter]::new()
  $btnLibraryView.Foreground=$brush.ConvertFromString($(if($capture){'#b0aaa0'}else{'#d97757'}))
  $btnCaptureView.Foreground=$brush.ConvertFromString($(if($capture){'#d97757'}else{'#b0aaa0'}))
}

function Update-WechatDownloadStatus {
  $refresh=$false
  foreach ($row in @($wechatCandidates.Items)) {
    $rowTask=$script:tasks | Where-Object url -EQ ('wxchannels:'+$row.Id) | Select-Object -Last 1
    $rowStatus=if($rowTask){$rowTask.state}elseif(@($script:history | Where-Object url -EQ ('wxchannels:'+$row.Id)).Count){'已保存'}else{'待下载'}
    if ($row.Status -ne $rowStatus) {$row.Status=$rowStatus;$refresh=$true}
  }
  if($refresh){$wechatCandidates.Items.Refresh()}
  $chosen=$wechatCandidates.SelectedItem
  if (-not $chosen) {
    $lblWechatSelection.Text='未选择视频'
    $lblWechatDownloadState.Text=''
    $btnWechatDownload.IsEnabled=$false
    $btnWechatDownload.Content='下载所选视频'
    $wechatDownloadProgress.Visibility='Collapsed'
    return
  }
  $lblWechatSelection.Text=$chosen.Label
  $task=$script:tasks | Where-Object url -EQ ('wxchannels:'+$chosen.Id) | Select-Object -Last 1
  if ($task) {
    $lblWechatDownloadState.Text=if($task.state -eq '已完成'){'已保存'}elseif($task.state -eq '下载中' -and $task.percent -ge 92){'正在校验…'}elseif($task.state -eq '下载中'){'下载中 · '+[math]::Round($task.percent)+'%'}elseif($task.state -eq '失败'){'下载失败，请重新抓取。'}else{$task.state}
    $btnWechatDownload.IsEnabled=$task.state -eq '失败'
    $btnWechatDownload.Content=if($task.state -eq '已完成'){'已保存'}elseif($task.state -in @('排队中','下载中')){'下载中…'}else{'下载所选视频'}
    $wechatDownloadProgress.Value=$task.percent
    $wechatDownloadProgress.Visibility=if($task.state -in @('排队中','下载中')){'Visible'}else{'Collapsed'}
  } elseif (@($script:history | Where-Object url -EQ ('wxchannels:'+$chosen.Id)).Count) {
    $lblWechatDownloadState.Text='已保存'
    $btnWechatDownload.IsEnabled=$false
    $btnWechatDownload.Content='已保存'
    $wechatDownloadProgress.Visibility='Collapsed'
  } else {
    $lblWechatDownloadState.Text=''
    $btnWechatDownload.IsEnabled=$true
    $btnWechatDownload.Content='下载所选视频'
    $wechatDownloadProgress.Visibility='Collapsed'
  }
}

function Start-WechatEngine([string[]]$arguments,[string]$logFile) {
  $engine=Join-Path $runtimeRoot 'wechat\FrameFlow.Wechat.exe'
  if (-not (Test-Path -LiteralPath $engine)) { $engine=Join-Path $root '.build\wechat-dist\FrameFlow.Wechat.exe' }
  if (-not (Test-Path -LiteralPath $engine)) { throw '微信视频号组件缺失，请使用完整开发预览包。' }
  $all=@($arguments)+@('--ffmpeg',(Join-Path $ffbin 'ffmpeg.exe'),'--ffprobe',(Join-Path $ffbin 'ffprobe.exe'))
  return [FrameflowProcess]::Start($engine,(($all | ForEach-Object {Quote-Arg $_}) -join ' '),$logFile)
}

function Stop-WechatCapture {
  if ($script:wechatProc -and -not $script:wechatProc.HasExited) {
    [IO.File]::WriteAllText((Join-Path $script:wechatSession 'stop'),'stop')
    $lblWechatState.Text='正在停止抓取…已有下载继续。'
  }
  $btnWechatStop.IsEnabled=$false
}

function Set-DownloadMode([bool]$wechat) {
  $script:wechatMode=$wechat
  $linkDownloadPanel.Visibility=if($wechat){'Collapsed'}else{'Visible'}
  $wechatPanel.Visibility=if($wechat){'Visible'}else{'Collapsed'}
  $queueStatusPanel.Visibility=if($wechat){'Collapsed'}else{'Visible'}
  $btnWechatMode.Background=[Windows.Media.BrushConverter]::new().ConvertFromString($(if($wechat){'#46382F'}else{'#34332F'}))
  $btnLinkMode.Background=[Windows.Media.BrushConverter]::new().ConvertFromString($(if($wechat){'#34332F'}else{'#46382F'}))
  $btnGo.IsDefault=-not $wechat
  if ($wechat) { $platformFilter.SelectedValue='微信视频号' }
  Set-WechatResultsView $wechat
  if (-not $wechat) { Stop-WechatCapture }
}

function Start-WechatCapture {
  if ($script:wechatProc -and -not $script:wechatProc.HasExited) { return }
  try {
    $script:wechatSession=Join-Path $dataDir ('wechat\sessions\'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($script:wechatSession)
    $script:wechatStateTime=0
    $script:wechatLastState=$null
    $script:wechatPulse=0
    $script:wechatCandidatesData=@()
    $wechatCandidates.ItemsSource=@()
    $btnWechatDownload.IsEnabled=$false
    $script:wechatProc=Start-WechatEngine @('watch','--session',$script:wechatSession) (Join-Path $script:wechatSession 'capture.log')
    $btnWechatCapture.IsEnabled=$false
    $btnWechatCapture.Content='抓取中…'
    $btnWechatStop.IsEnabled=$true
    $lblWechatState.Text='正在准备，请稍候…'
    $script:wechatTimer.Start()
  } catch { $lblWechatState.Text=$_.Exception.Message; $btnWechatCapture.IsEnabled=$true; $btnWechatCapture.Content='开始抓取' }
}

function Update-WechatCandidates {
  $selectedId=if($wechatCandidates.SelectedItem){$wechatCandidates.SelectedItem.Id}else{$null}
  $rows=@()
  foreach ($item in $script:wechatCandidatesData) {
    $existing=$script:tasks | Where-Object { $_.url -eq ('wxchannels:'+$item.id) } | Select-Object -Last 1
    $bitmap=$null
    try {
      $bitmap=[Windows.Media.Imaging.BitmapImage]::new()
      $bitmap.BeginInit(); $bitmap.CacheOption=[Windows.Media.Imaging.BitmapCacheOption]::OnLoad
      $bitmap.UriSource=[Uri]::new([string]$item.cover); $bitmap.DecodePixelWidth=320
      $bitmap.EndInit(); $bitmap.Freeze()
    } catch {}
    $rows+= [pscustomobject]@{Id=[string]$item.id; Label=[string]$item.label; Image=$bitmap; Manifest=[string]$item.manifest; Status=$(if($existing){[string]$existing.state}else{'核对封面后选择下载'})}
  }
  $wechatCandidates.ItemsSource=$rows
  $lblWechatCount.Text=('{0} 条候选' -f $rows.Count)
  $wechatEmptyState.Visibility=if($rows.Count){'Collapsed'}else{'Visible'}
  if ($selectedId) { $wechatCandidates.SelectedItem=$rows | Where-Object Id -EQ $selectedId | Select-Object -First 1 }
  Update-WechatDownloadStatus
}

function Poll-WechatCapture {
  if (-not $script:wechatSession) { return }
  $path=Join-Path $script:wechatSession 'state.json'
  if (Test-Path -LiteralPath $path) {
    try {
      $state=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($state.updated -ne $script:wechatStateTime) {
        $script:wechatStateTime=$state.updated
        $script:wechatLastState=$state
        $script:wechatCandidatesData=@($state.candidates)
        Update-WechatCandidates
      }
    } catch {}
  }
  if ($script:wechatProc -and $script:wechatProc.HasExited) {
    $script:wechatProc.Dispose(); $script:wechatProc=$null
    $btnWechatCapture.IsEnabled=$true; $btnWechatCapture.Content='重新抓取'
    $btnWechatStop.IsEnabled=$false
    $script:wechatTimer.Stop()
    if (-not (Test-Path -LiteralPath $path)) { $script:wechatLastState=[pscustomobject]@{phase='error';message='抓取组件未能启动。'} }
  }
  $script:wechatPulse++
  Update-WechatCaptureStatus
}

function Add-WechatDownloadTask {
  $chosen=$wechatCandidates.SelectedItem
  if (-not $chosen) { return }
  $identity='wxchannels:'+$chosen.Id
  if (@($script:tasks | Where-Object { $_.url -eq $identity -and $_.state -ne '失败' }).Count -or @($script:history | Where-Object url -EQ $identity).Count) {
    $lblWechatDownloadState.Text='已在队列或媒体库中。'; return
  }
  $id=[guid]::NewGuid().ToString('N')
  $script:tasks.Add([pscustomobject]@{
    id=$id; url=$identity; platform='微信视频号'; state='排队中'; percent=0; retries=0; proc=$null; logPos=0
    label=('微信视频号 · '+$chosen.Label); detail='等待下载'; manifest=$chosen.Manifest
    logFile=(Join-Path $dataDir ('tasks\'+$id+'.log')); staging=(Join-Path $outDir ('.frameflow-tasks\'+$id))
  })
  Start-QueuedDownloads; Update-Queue; $script:dlTimer.Start()
  Update-WechatCandidates
  Update-WechatDownloadStatus
}

$script:wechatTimer=[Windows.Threading.DispatcherTimer]::new()
$script:wechatTimer.Interval=[TimeSpan]::FromSeconds(1)
$script:wechatTimer.Add_Tick({ Poll-WechatCapture })
$btnWechatCapture.Add_Click({ Start-WechatCapture })
$btnWechatStop.Add_Click({ Stop-WechatCapture })
$btnWechatDownload.Add_Click({ Add-WechatDownloadTask })
$wechatCandidates.Add_SelectionChanged({ Update-WechatDownloadStatus })
$btnLinkMode.Add_Click({ Set-DownloadMode $false })
$btnWechatMode.Add_Click({ Set-DownloadMode $true })
$btnLibraryView.Add_Click({ Set-WechatResultsView $false })
$btnCaptureView.Add_Click({ if(-not $script:wechatMode){Set-DownloadMode $true}else{Set-WechatResultsView $true} })

# Restore the last preview list when restarting the app; this does not restart capture.
try {
  $sessions=Join-Path $dataDir 'wechat\sessions'
  if (Test-Path -LiteralPath $sessions) {
    $last=Get-ChildItem -LiteralPath $sessions -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($last -and (Test-Path -LiteralPath (Join-Path $last.FullName 'state.json'))) {
      $script:wechatSession=$last.FullName
      Poll-WechatCapture
      Update-WechatCaptureStatus
    }
  }
} catch {}
$form.Add_Closed({
  Stop-WechatCapture
  $script:wechatTimer.Stop()
  if ($script:wechatProc) {
    if (-not $script:wechatProc.WaitForExit(2000)) { try { $script:wechatProc.Kill() } catch {} }
    $script:wechatProc.Dispose(); $script:wechatProc=$null
  }
})
