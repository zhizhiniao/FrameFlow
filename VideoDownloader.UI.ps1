# WPF presentation layer. Download and article routines live in VideoDownloader.ps1.
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -Path (Join-Path $root 'VideoDownloader.Runtime.cs')
[Runtime.InteropServices.Marshal]::ThrowExceptionForHR([FrameflowWindow]::SetCurrentProcessExplicitAppUserModelID([FrameflowWindow]::AppId))
try { [void][FrameflowWindow]::SetProcessDpiAwarenessContext([IntPtr](-4)) } catch {}

$reader = [System.Xml.XmlReader]::Create((Join-Path $root 'VideoDownloader.xaml'))
try { $form = [System.Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
# Use the same approved multi-resolution asset as the launcher and shortcuts.
$iconUri = [Uri]::new((Join-Path $root 'FrameFlow.ico'), [UriKind]::Absolute)
$form.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create($iconUri,
  [System.Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
  [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
foreach ($name in @('AppSurface','ComposeColumn','txtUrl','urlPlaceholder','btnPaste','btnGo','goText',
    'lblDetect','lblStatus','lblProgress','progress','btnLogs','txtLog','txtSearch','searchPlaceholder',
    'lblCount','btnRefresh','lv','emptyState','emptyTitle','emptyHint','lblSelection','btnPlay','btnOpen',
    'queueStatusPanel','wechatDownloadProgress','btnLibraryView','btnCaptureView','lblWechatCount','libraryToolbar','libraryContent','libraryActions','captureHint','captureContent','captureSelectionHint','wechatEmptyState','lblWechatSelection','lblWechatDownloadState','btnLinkMode','btnWechatMode','linkDownloadPanel','wechatPanel','btnWechatCapture','btnWechatStop','lblWechatState','wechatCandidates','btnWechatDownload','platformFilter','btnSettings','btnRetry','queueList','btnDel','lblTotal','lblPath','btnAccounts','lblAccounts','btnFolder','btnCancelLogin')) {
  Set-Variable -Name $name -Value $form.FindName($name) -Scope Script
}
$lblPath.Text = $outDir
$lblPath.ToolTip = $outDir
. (Join-Path $root 'VideoDownloader.Platforms.ps1')
$script:history = @(Load-History)
try { Initialize-PlatformLibrary } catch { [System.Windows.MessageBox]::Show("旧文件归类未完成，文件已保留："+$_.Exception.Message,"归类提示") | Out-Null }
$script:allMedia = @()
$script:busy = $false
$script:proc = $null
$script:thumbProc = $null
$script:thumbQueue = New-Object System.Collections.Queue
$script:dlLogFile = $null
$script:dlLogPos = 0
$script:lastDownload = $null

function Set-TaskStatus([string]$state, [string]$detail, [string]$color = '#D97757') {
  $lblStatus.Text = $state
  $lblStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($color)
  $lblProgress.Text = $detail
}

function Set-Busy([bool]$value) {
  $script:busy = $value
  $btnAccounts.IsEnabled = -not $value
  $btnFolder.IsEnabled = -not $value
  $txtUrl.IsEnabled = $true
  $btnPaste.IsEnabled = $true
  $goText.Text = if ($value) { '加入下载队列' } else { '开始下载' }
  Update-Detect
}

function Update-Detect {
  $hasText = -not [string]::IsNullOrWhiteSpace($txtUrl.Text)
  $urlPlaceholder.Visibility = if ($hasText) { 'Collapsed' } else { 'Visible' }
  $tw = Resolve-Tuwen $txtUrl.Text
  $r = Resolve-Url $txtUrl.Text
  $valid = ($null -ne $tw -or $null -ne $r)
  $btnGo.IsEnabled = $valid
  if ($tw) { $lblDetect.Text = $tw[0] + ' · 图文链接已识别' }
  elseif ($r) { $lblDetect.Text = $r[0] + ' · 链接已识别' }
  elseif ($hasText) { $lblDetect.Text = '未找到有效网址，请检查分享内容。' }
  else { $lblDetect.Text = '等待添加链接' }
  $lblDetect.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString(
    $(if ($valid) { '#D97757' } elseif ($hasText) { '#E8B986' } else { '#B0AAA0' }))
}

function Get-MediaThumbnail([string]$path) {
  $thumb = Get-ThumbPath $path
  if (-not (Test-Path -LiteralPath $thumb)) { return $null }
  try {
    $bitmap = [System.Windows.Media.Imaging.BitmapImage]::new()
    $bitmap.BeginInit()
    $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bitmap.UriSource = [Uri]::new($thumb)
    $bitmap.DecodePixelWidth = 208
    $bitmap.EndInit()
    $bitmap.Freeze()
    return $bitmap
  } catch { return $null }
}

function Update-Selection {
  $selected = $lv.SelectedItem
  $btnPlay.IsEnabled = $null -ne $selected
  $btnDel.IsEnabled = $null -ne $selected
  $lblSelection.Text = if ($selected) { $selected.Title } else { '选择视频以播放或管理' }
  $lblSelection.ToolTip = if ($selected) { $selected.FullPath } else { $null }
}

function Apply-Search {
  $selectedPath = if ($lv.SelectedItem) { $lv.SelectedItem.FullPath } else { $null }
  $query = $txtSearch.Text.Trim()
  $searchPlaceholder.Visibility = if ($query) { 'Collapsed' } else { 'Visible' }
  $chosen=$platformFilter.SelectedItem.Name
  $visible = @($script:allMedia | Where-Object { (-not $chosen -or $chosen -eq '全部平台' -or $_.Kind -eq $chosen) -and (-not $query -or $_.Title.IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -ge 0) })
  $lv.ItemsSource = $visible
  if ($selectedPath) {
    $match = @($visible | Where-Object FullPath -EQ $selectedPath)
    if ($match.Count -gt 0) { $lv.SelectedItem = $match[0] }
  }
  $lblCount.Text = if ($query -or $chosen -ne '全部平台') { '{0} / {1} 个文件' -f $visible.Count, $script:allMedia.Count } else { '{0} 个文件' -f $script:allMedia.Count }
  $emptyState.Visibility = if ($visible.Count -eq 0) { 'Visible' } else { 'Collapsed' }
  $emptyTitle.Text = if ($query) { '没有匹配的视频' } elseif ($script:allMedia.Count) { '此平台暂无视频' } else { '视频库还是空的' }
  $emptyHint.Text = if ($query) { '试试标题中的其他关键词，或切换平台。' } elseif ($script:allMedia.Count) { '在上方切换平台，或选择全部平台。' } else { '从左侧添加链接，下载后的媒体会按平台保存。' }
  Update-Selection
}

function Refresh-History {
  $selectedPath = if ($lv.SelectedItem) { $lv.SelectedItem.FullPath } else { $null }
  $meta = @{}
  foreach ($entry in $script:history) { if ($entry.file) { $meta[$entry.file] = $entry } }
  $files = @(Get-LibraryMediaFiles | Sort-Object LastWriteTime -Descending)
  $script:thumbQueue.Clear()
  $script:allMedia = @(
    foreach ($file in $files) {
      $relative=Get-LibraryRelativePath $file.FullName
      $entry = $meta[$relative]
      $title = if ($entry -and $entry.title) { $entry.title } else { [IO.Path]::GetFileNameWithoutExtension($file.Name) }
      # Keep the real filename untouched; remove only the download ID suffix from its display label.
      $title = $title -replace '-\[[^\]]+\]$', ''
      $thumbnail = Get-MediaThumbnail $file.FullName
      if (-not $thumbnail) { $script:thumbQueue.Enqueue($file.FullName) }
      $savedAt = $file.LastWriteTime
      $parsedDate = [datetime]::MinValue
      if ($entry -and $entry.time -and [datetime]::TryParse([string]$entry.time, [ref]$parsedDate)) { $savedAt = $parsedDate }
      [pscustomobject]@{
        Title = $title; FullPath = $file.FullName; Thumbnail = $thumbnail
        Kind = $(if ($entry -and $entry.platform) { Get-PlatformFolder $entry.platform } else { Get-PlatformFolder ($relative -split '[\\/]')[0] })
        Date = $savedAt.ToString('yyyy-MM-dd HH:mm'); SavedAt = $savedAt
        Size = Format-Size $file.Length; Format = $file.Extension.TrimStart('.').ToUpperInvariant()
      }
    }
  )
  $script:allMedia = @($script:allMedia | Sort-Object SavedAt -Descending)
  $total = ($files | Measure-Object Length -Sum).Sum
  $lblTotal.Text = '本地媒体 · ' + (Format-Size $total)
  Update-PlatformFilter
  Apply-Search
  if ($selectedPath) {
    foreach ($item in $lv.Items) { if ($item.FullPath -eq $selectedPath) { $lv.SelectedItem = $item; break } }
  }
  if ($script:thumbQueue.Count -gt 0) { $script:thumbTimer.Start() }
}

. (Join-Path $root 'VideoDownloader.Queue.ps1')
. (Join-Path $root 'VideoDownloader.Wechat.ps1')

$script:dlTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:dlTimer.Interval = [TimeSpan]::FromMilliseconds(200)
$script:dlTimer.Add_Tick({ Poll-Download })
$script:thumbTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:thumbTimer.Interval = [TimeSpan]::FromMilliseconds(150)
$script:thumbTimer.Add_Tick({
  if ($script:thumbProc) {
    if (-not $script:thumbProc.HasExited) { return }
    $script:thumbProc.Dispose(); $script:thumbProc = $null
    foreach ($item in $script:allMedia) {
      if ($item.FullPath -eq $script:thumbVideo) { $item.Thumbnail = Get-MediaThumbnail $item.FullPath; break }
    }
    $lv.Items.Refresh()
  }
  if ($script:thumbQueue.Count -gt 0) {
    $script:thumbVideo = $script:thumbQueue.Dequeue()
    $thumb = Get-ThumbPath $script:thumbVideo
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = Join-Path $ffbin 'ffmpeg.exe'
    $psi.Arguments = '-y -nostdin -loglevel quiet -ss 1 -i "' + $script:thumbVideo + '" -frames:v 1 -vf scale=320:180:force_original_aspect_ratio=decrease -q:v 3 "' + $thumb + '"'
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    try { $script:thumbProc = [Diagnostics.Process]::Start($psi) } catch {}
  } else { $script:thumbTimer.Stop() }
})

$txtUrl.Add_TextChanged({ Update-Detect })
$txtSearch.Add_TextChanged({ Apply-Search })
$platformFilter.Add_SelectionChanged({
  if ($script:updatingPlatform) { return }
  Apply-Search
  if ($platformFilter.SelectedItem) { Write-LibraryJson (Join-Path $dataDir 'library-view.json') @{platform=[string]$platformFilter.SelectedItem.Name} }
})
$lv.Add_SelectionChanged({ Update-Selection })
$btnPaste.Add_Click({
  try { $txtUrl.Text = [System.Windows.Clipboard]::GetText() } catch { Log '[提示] 剪贴板暂时不可用，请直接按 Ctrl+V 粘贴。' }
  [void]$txtUrl.Focus()
  $txtUrl.Select($txtUrl.Text.Length, 0)
})
$btnLogs.Add_Click({
  if ($txtLog.Visibility -eq 'Visible') { $txtLog.Visibility = 'Collapsed'; $btnLogs.Content = '展开日志' }
  else { $txtLog.Visibility = 'Visible'; $btnLogs.Content = '收起日志'; $txtLog.ScrollToEnd() }
})
$btnGo.Add_Click({
  Add-DownloadTask $txtUrl.Text
  $txtUrl.Clear()
  [void]$txtUrl.Focus()
})
$btnRefresh.Add_Click({ Refresh-History; $script:thumbTimer.Start() })
$btnPlay.Add_Click({
  if ($lv.SelectedItem) {
    try { Start-Process -FilePath $lv.SelectedItem.FullPath }
    catch { Log '[提示] 文件无法打开，请刷新视频库或检查默认播放器。'; Set-TaskStatus '无法播放' '请检查默认播放器或文件是否仍然存在。' '#E8B986' }
  }
})
$lv.Add_MouseDoubleClick({
  param($sender, $eventArgs)
  $container = [System.Windows.Controls.ItemsControl]::ContainerFromElement($lv, $eventArgs.OriginalSource)
  if ($container -is [System.Windows.Controls.ListBoxItem] -and $lv.SelectedItem) {
    $btnPlay.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
  }
})
$lv.Add_KeyDown({
  param($sender, $eventArgs)
  if ($eventArgs.Key -eq 'Enter' -and $lv.SelectedItem) {
    $btnPlay.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent)); $eventArgs.Handled = $true
  }
})
$btnOpen.Add_Click({
  if ($lv.SelectedItem) { Start-Process explorer.exe -ArgumentList ('/select,"'+$lv.SelectedItem.FullPath+'"'); return }
  $folder=$outDir
  if ($platformFilter.SelectedValue -in $script:platformFolders) { $folder=Join-Path $outDir $platformFilter.SelectedValue; [void][IO.Directory]::CreateDirectory($folder) }
  Start-Process explorer.exe -ArgumentList ('"'+$folder+'"')
})
$btnDel.Add_Click({
  if (-not $lv.SelectedItem) { return }
  $path = $lv.SelectedItem.FullPath
  $choice = [System.Windows.MessageBox]::Show($form, ('确定永久删除这个文件？' + "`n`n" + [IO.Path]::GetFileName($path)), '删除文件', 'YesNo', 'Warning', 'No')
  if ($choice -ne 'Yes') { return }
  try {
    Remove-Item -LiteralPath $path -ErrorAction Stop
    $script:history = @($script:history | Where-Object { $_.file -ne (Get-LibraryRelativePath $path) })
    Save-History $script:history
    Refresh-History
    Set-TaskStatus '已删除' '所选文件已从本地视频库中移除。'
  } catch { Set-TaskStatus '删除失败' '文件可能正在使用，请关闭播放器后重试。' '#E69B8F'; Log ('[错误] ' + $_.Exception.Message) }
})
$form.Add_SizeChanged({ $ComposeColumn.Width = [System.Windows.GridLength]::new($(if ($form.ActualWidth -lt 1040) { 296 } else { 336 })) })
$form.Add_SourceInitialized({
  $handle = [System.Windows.Interop.WindowInteropHelper]::new($form).Handle
  [FrameflowWindow]::ConfigureTaskbar($handle, (Join-Path $runtimeRoot 'FrameFlow.exe'), (Join-Path $root 'FrameFlow.ico'))
  $scale = [System.Windows.PresentationSource]::FromVisual($form).CompositionTarget.TransformToDevice
  $area = $screen.WorkingArea
  $form.Width = [Math]::Max($form.MinWidth, [Math]::Min($form.Width, $area.Width / $scale.M11 - 48))
  $form.Height = [Math]::Max($form.MinHeight, [Math]::Min($form.Height, $area.Height / $scale.M22 - 48))
  $form.Left = $area.Left / $scale.M11 + ($area.Width / $scale.M11 - $form.Width) / 2
  $form.Top = $area.Top / $scale.M22 + ($area.Height / $scale.M22 - $form.Height) / 2
  $dark = 1; $captionColor = 0x00242626
  try {
    [void][FrameflowWindow]::DwmSetWindowAttribute($handle, 20, [ref]$dark, 4)
    [void][FrameflowWindow]::DwmSetWindowAttribute($handle, 35, [ref]$captionColor, 4)
  } catch {}
})
$form.Add_Closing({
  param($sender, $eventArgs)
  if ($script:busy -and -not $SelfTest) {
    $choice = [System.Windows.MessageBox]::Show($form, '下载仍在进行，确定结束任务并关闭？', '关闭帧流', 'YesNo', 'Question', 'No')
    if ($choice -ne 'Yes') { $eventArgs.Cancel = $true; return }
  }
  $script:authTimer.Stop()
  if ($script:loginProc -and -not $script:loginProc.HasExited) {
    Set-Content -LiteralPath $script:loginCancel -Value 'cancel'
    if (-not $script:loginProc.WaitForExit(2500)) {
      $killLogin = [Diagnostics.ProcessStartInfo]::new('taskkill.exe', ('/PID ' + $script:loginProc.Id + ' /T /F'))
      $killLogin.UseShellExecute=$false; $killLogin.CreateNoWindow=$true
      [void][Diagnostics.Process]::Start($killLogin)
    }
  }
  $script:dlTimer.Stop(); $script:thumbTimer.Stop()
  foreach ($task in @($script:tasks | Where-Object { $_.proc })) {
    if (-not $task.proc.HasExited) {
      $killInfo = [Diagnostics.ProcessStartInfo]::new('taskkill.exe', ('/PID ' + $task.proc.Id + ' /T /F'))
      $killInfo.UseShellExecute=$false; $killInfo.CreateNoWindow=$true
      try { $kill=[Diagnostics.Process]::Start($killInfo); $kill.WaitForExit(); $kill.Dispose() } catch {}
    }
    $task.proc.Dispose(); $task.proc=$null
  }
  if ($script:thumbProc -and -not $script:thumbProc.HasExited) { $script:thumbProc.Kill(); $script:thumbProc.Dispose() }
})

. (Join-Path $root 'VideoDownloader.Settings.ps1')
. (Join-Path $root 'VideoDownloader.Accounts.ps1')
. (Join-Path $root 'VideoDownloader.Update.ps1')

# Open on the widest monitor, where a desktop media library has room to breathe.
$screen = [System.Windows.Forms.Screen]::AllScreens | Sort-Object { $_.WorkingArea.Width } -Descending | Select-Object -First 1
$form.WindowStartupLocation = 'Manual'
$form.Left = 0
$form.Top = 0
Refresh-History
Log '就绪。粘贴链接后点击「开始下载」，或按 Enter。'
if ($QueueTest) {
  . (Join-Path $root 'tests\Queue.Check.ps1')
} elseif ($WechatTest) {
  . (Join-Path $root 'tests\Wechat.UI.Check.ps1')
} elseif ($SelfTest) {
  . (Join-Path $root 'tests\UI.Smoke.ps1')
} else {
  $form.Add_ContentRendered({ [void]$txtUrl.Focus(); $script:thumbTimer.Start(); if ($CookieSettings) { Show-CookieSettings } })
  [void]$form.ShowDialog()
}
