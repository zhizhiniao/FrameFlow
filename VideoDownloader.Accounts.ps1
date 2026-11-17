# Login controls share the window dispatcher; browser work stays in the worker process.
$script:loginProc = $null
$script:pendingDownload = $false
$script:authDialog = $null
$script:accountLabels = @{}
$script:loginAuditQueue = [Collections.Generic.Queue[string]]::new()
$script:loginAudit = @()
$accountNames = [ordered]@{ bilibili='哔哩哔哩'; youtube='YouTube'; instagram='Instagram'; tiktok='TikTok'; twitter='X (Twitter)'; xhs='小红书'; douyin='抖音' }

function Test-CloudConnection([string]$id) {
  if ($id -eq 'youtube') {
    try { return (Read-AuthSettings).source -eq 'cloud' } catch { return $false }
  }
  $path=Join-Path $dataDir 'cookiecloud.json'
  if (-not (Test-Path -LiteralPath $path) -or -not (Test-Path -LiteralPath (Join-Path $dataDir 'cookiecloud.bin'))) { return $false }
  try { return $id -in @((Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json).platforms) } catch { return $false }
}

function Update-Accounts {
  $saved = @()
  foreach ($id in $accountNames.Keys) {
    $state = '未登录'
    if (Test-CloudConnection $id) { $state = 'CookieCloud 已连接 · 待同步' }
    $metaPath = Join-Path $dataDir ('sessions\' + $id + '.json')
    if ((Test-Path -LiteralPath $metaPath) -and (Test-Path -LiteralPath (Join-Path $dataDir ('sessions\' + $id + '.bin')))) {
      try {
        $meta = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $state = if ($meta.download_verified) { '已通过下载验证' } elseif ($meta.source -eq 'import') { '已导入 · 待下载验证' } else { '已保存 · 待下载验证' }
        $state += '  ' + $meta.saved_at
        if ($meta.source -eq 'cookiecloud') { $state = 'CookieCloud · ' + $state }
        $saved += $accountNames[$id]
      } catch { $state = '记录异常，请重新登录' }
    }
    if ($script:accountLabels.ContainsKey($id)) { $script:accountLabels[$id].Text = $state }
  }
  $lblAccounts.Text = if ($saved.Count) { '已保存：' + ($saved -join '、') + '。失效时重新登录即可。' } else { '首次点击平台完成登录，之后自动使用。公开视频可直接下载。' }
}

function Start-PlatformLogin([string]$id) {
  if ($script:busy -or $script:loginProc) { return }
  if ($script:authDialog) { $script:authDialog.Close() }
  $script:loginResult = Join-Path $dataDir 'login-result.json'
  $script:loginCancel = Join-Path $dataDir 'login-cancel'
  Remove-Item -LiteralPath $script:loginResult,$script:loginCancel -ErrorAction SilentlyContinue
  $loginLog = Join-Path $dataDir 'login.log'
  Remove-Item -LiteralPath $loginLog -ErrorAction SilentlyContinue
  try {
    $script:loginProc = Start-Worker @('login','--data',$dataDir,'--platform',$id,'--result',$script:loginResult,'--cancel',$script:loginCancel) $loginLog
    Set-Busy $true
    $fromCloud=Test-CloudConnection $id
    $goText.Text = '加入下载队列'
    $btnCancelLogin.Visibility = 'Visible'
    if ($fromCloud) { Set-TaskStatus '同步 Cookie' '正在读取浏览器已同步的登录态，无需重复登录。' }
    else { Set-TaskStatus '等待登录' ('请在打开的 ' + $accountNames[$id] + ' 窗口完成扫码或账号登录。') }
    $script:authTimer.Start()
  } catch {
    $script:pendingDownload = $false
    Set-Busy $false
    Set-TaskStatus '无法打开登录' '请确认已完整解压便携包。' '#E69B8F'
  }
}

$script:authTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:authTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$script:authTimer.Add_Tick({
  $result = $null
  if (Test-Path -LiteralPath $script:loginResult) {
    try { $result = Get-Content -LiteralPath $script:loginResult -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
  }
  if ($result) { $lblProgress.Text = $result.message }
  if (-not $script:loginProc -or -not $script:loginProc.HasExited) { return }
  $script:loginProc.WaitForExit()
  $code = $script:loginProc.ExitCode
  $script:loginProc.Dispose(); $script:loginProc = $null
  $script:authTimer.Stop()
  $btnCancelLogin.Visibility = 'Collapsed'
  Set-Busy $false
  Update-Accounts
  if ($code -eq 0 -and $result.status -eq 'saved') {
    Set-TaskStatus '登录态已保存' '可以开始下载，程序会自动使用该平台的登录态。'
    Complete-QueueLogin $true
  } else {
    $script:pendingDownload = $false
    Complete-QueueLogin $false
    Set-TaskStatus '登录未完成' $(if ($result) { $result.message } else { '请重新点击平台登录。若平台拒绝登录窗口，可使用已有 Cookie 文件导入。' }) '#E8B986'
  }
  if ($LoginCheck) {
    $script:loginAudit += [pscustomobject]@{platform=$script:auditPlatform; status=$(if ($result) {$result.status} else {'error'}); exitCode=$code; at=(Get-Date).ToString('s')}
    $script:loginAudit | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dataDir 'login-audit.json') -Encoding UTF8
    if ($script:loginAuditQueue.Count -gt 0) { Start-NextLoginCheck }
  }
})
$btnCancelLogin.Add_Click({
  $script:pendingDownload = $false
  Set-Content -LiteralPath $script:loginCancel -Value 'cancel'
  $lblProgress.Text = '正在关闭登录窗口…'
})

function Show-Accounts {
  if ($script:busy) { return }
  $dialog = [System.Windows.Window]::new()
  $dialog.Title = '平台登录'
  $dialog.Width = 650; $dialog.Height = 610
  $dialog.Icon = $form.Icon
  $dialog.ResizeMode = 'NoResize'; $dialog.WindowStartupLocation = 'CenterOwner'; $dialog.Owner = $form
  $dialog.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#2D2C29')
  $dialog.Foreground = [System.Windows.Media.Brushes]::White
  $dialog.FontFamily = $form.FontFamily; $dialog.FontSize = 13
  $dialog.Resources = $form.Resources
  $dialog.Add_SourceInitialized({
    param($sender,$eventArgs)
    $handle=[System.Windows.Interop.WindowInteropHelper]::new($sender).Handle
    $dark=1; $captionColor=0x002A231E
    try {
      [void][FrameflowWindow]::DwmSetWindowAttribute($handle,20,[ref]$dark,4)
      [void][FrameflowWindow]::DwmSetWindowAttribute($handle,35,[ref]$captionColor,4)
    } catch {}
  })
  $panel = [System.Windows.Controls.StackPanel]::new(); $panel.Margin = '28'
  $title = [System.Windows.Controls.TextBlock]::new(); $title.Text = '登录一次，自动准备'; $title.FontSize = 22; $title.FontWeight = 'SemiBold'
  $panel.Children.Add($title) | Out-Null
  $hint = [System.Windows.Controls.TextBlock]::new()
  $hint.Text = "点击平台，在弹出的专用窗口完成登录。识别成功后自动保存并关闭。`n验证码、扫码由你完成；不会读取你日常浏览器的其他网站。"
  $hint.TextWrapping = 'Wrap'; $hint.LineHeight = 22; $hint.Margin = '0,12,0,18'; $hint.Foreground = [System.Windows.Media.Brushes]::LightSlateGray
  $panel.Children.Add($hint) | Out-Null
  $script:accountLabels = @{}
  foreach ($id in $accountNames.Keys) {
    $row = [System.Windows.Controls.Grid]::new(); $row.Margin = '0,0,0,12'
    foreach ($width in @('*','Auto','Auto','Auto')) { $col=[System.Windows.Controls.ColumnDefinition]::new(); $col.Width=[System.Windows.GridLengthConverter]::new().ConvertFromString($width); $row.ColumnDefinitions.Add($col) }
    $textPanel = [System.Windows.Controls.StackPanel]::new()
    $label=[System.Windows.Controls.TextBlock]::new(); $label.Text=$accountNames[$id]; $label.FontWeight='SemiBold'
    $textPanel.Children.Add($label) | Out-Null
    $status=[System.Windows.Controls.TextBlock]::new(); $status.FontSize=11; $status.Margin='0,6,0,0'; $status.Foreground=[System.Windows.Media.Brushes]::LightSlateGray; $status.TextWrapping='Wrap'
    $script:accountLabels[$id]=$status; $textPanel.Children.Add($status) | Out-Null; $row.Children.Add($textPanel) | Out-Null
    $login=[System.Windows.Controls.Button]::new(); $login.Content='登录 / 更新'; $login.Tag=$id; $login.Margin='8,0,0,0'
    if (Test-CloudConnection $id) { $login.Content='同步 Cookie'; $login.ToolTip='从现有 CookieCloud 服务获取最新登录态' }
    [System.Windows.Controls.Grid]::SetColumn($login,1); $row.Children.Add($login) | Out-Null
    $login.Add_Click({ param($sender,$e) Start-PlatformLogin ([string]$sender.Tag) })
    $import=[System.Windows.Controls.Button]::new(); $import.Content='导入'; $import.Tag=$id; $import.Margin='8,0,0,0'; $import.ToolTip='可选：导入你自己导出的 Netscape Cookie 文件'
    [System.Windows.Controls.Grid]::SetColumn($import,2); $row.Children.Add($import) | Out-Null
    $import.Add_Click({
      param($sender,$e)
      $picker=[Microsoft.Win32.OpenFileDialog]::new(); $picker.Filter='Cookie 文件 (*.txt)|*.txt'; $picker.Title='选择自己的 Cookie 文件'
      if ($picker.ShowDialog($script:authDialog)) {
        $log=Join-Path $dataDir 'import.log'
        $p=Start-Worker @('import','--data',$dataDir,'--platform',[string]$sender.Tag,'--file',$picker.FileName) $log
        $p.WaitForExit(); $ok=$p.ExitCode -eq 0; $p.Dispose()
        Update-Accounts
        if (-not $ok) { [void][System.Windows.MessageBox]::Show($script:authDialog,'导入失败，请选择该平台的有效 Netscape Cookie 文件。','未能导入') }
      }
    })
    $clear=[System.Windows.Controls.Button]::new(); $clear.Content='清除'; $clear.Tag=$id; $clear.Margin='8,0,0,0'; $clear.Foreground=[System.Windows.Media.Brushes]::LightSalmon
    [System.Windows.Controls.Grid]::SetColumn($clear,3); $row.Children.Add($clear) | Out-Null
    $clear.Add_Click({
      param($sender,$e)
      if ([System.Windows.MessageBox]::Show($script:authDialog,'清除此平台在帧流中的登录态？之后需要重新登录。','清除登录态','YesNo','Question','No') -ne 'Yes') { return }
      $p=Start-Worker @('forget','--data',$dataDir,'--platform',[string]$sender.Tag) (Join-Path $dataDir 'forget.log')
      $p.WaitForExit(); $ok=$p.ExitCode -eq 0; $p.Dispose(); Update-Accounts
      if (-not $ok) { [void][System.Windows.MessageBox]::Show($script:authDialog,'部分浏览器文件正在使用，请关闭登录窗口后重试。','清除未完成') }
    })
    $panel.Children.Add($row) | Out-Null
  }
  $foot=[System.Windows.Controls.TextBlock]::new(); $foot.Text='登录态仅供本机当前 Windows 用户使用。其他人使用便携包时自行登录。'; $foot.TextWrapping='Wrap'; $foot.FontSize=11; $foot.Foreground=[System.Windows.Media.Brushes]::LightSlateGray; $foot.Margin='0,8,0,0'
  $panel.Children.Add($foot) | Out-Null
  $scroll=[Windows.Controls.ScrollViewer]::new(); $scroll.VerticalScrollBarVisibility='Auto'; $scroll.Content=$panel
  $dialog.Content=$scroll; $script:authDialog=$dialog
  Update-Accounts
  [void]$dialog.ShowDialog()
  $script:authDialog=$null; $script:accountLabels=@{}
}
$btnAccounts.Add_Click({ Show-Accounts })
$btnFolder.Add_Click({
  $picker=[System.Windows.Forms.FolderBrowserDialog]::new()
  $picker.Description='选择下载内容的保存目录'; $picker.SelectedPath=$outDir
  if ($picker.ShowDialog() -eq 'OK') {
    $script:outDir=$picker.SelectedPath
    $script:historyFile=Join-Path $outDir 'history.json'; $script:thumbDir=Join-Path $outDir '.thumbs'
    New-Item -ItemType Directory -Force -Path $thumbDir | Out-Null
    @{output=$outDir} | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8
    $script:history=Load-History; Initialize-PlatformLibrary; $lblPath.Text=$outDir; $lblPath.ToolTip=$outDir
    Refresh-History
  }
  $picker.Dispose()
})
Update-Accounts

function Start-NextLoginCheck {
  if ($script:loginAuditQueue.Count -gt 0) {
    $script:auditPlatform=$script:loginAuditQueue.Dequeue()
    Start-PlatformLogin $script:auditPlatform
  }
}
if ($LoginCheck -and -not $SelfTest) {
  $ids=if ($LoginCheck -eq 'all') { @('douyin','xhs','tiktok','youtube','twitter','bilibili') } else { @($LoginCheck) }
  foreach ($id in $ids) { $script:loginAuditQueue.Enqueue($id) }
  $form.Add_ContentRendered({ Start-NextLoginCheck })
}
