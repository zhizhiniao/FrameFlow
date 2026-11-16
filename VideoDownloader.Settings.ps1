Add-Type -AssemblyName System.Security

function Read-AuthSettings {
  $path=Join-Path $dataDir 'auth-settings.bin'
  if (Test-Path -LiteralPath $path) {
    $bytes=[Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($path),$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
    return ([Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json)
  }
  $cfg=[pscustomobject]@{source='browser';proxy='';auto_refresh=$true;endpoint='';uuid='';password='';crypto_type='legacy';request_headers=@{}}
  $legacy=Join-Path $dataDir 'cookiecloud.bin'
  if (Test-Path -LiteralPath $legacy) {
    try {
      $bytes=[Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($legacy),$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
      $old=[Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
      foreach ($key in @('endpoint','uuid','password','crypto_type','request_headers')) { if ($old.$key) { $cfg.$key=$old.$key } }
    } catch { }
  }
  return $cfg
}

function Show-CookieSettings {
  [xml]$markup=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="Cookie 设置" Width="620" Height="700" MinWidth="550" MinHeight="520" Background="#1E232A" Foreground="#E9EDF1" FontFamily="Microsoft YaHei UI" FontSize="14" WindowStartupLocation="CenterOwner">
<Grid Margin="28"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
<StackPanel><TextBlock Text="YouTube 登录与 Cookie" FontSize="22" FontWeight="SemiBold"/><TextBlock Text="内置登录会自动保存会话，无需 Docker 或浏览器扩展。" Foreground="#ADB8C4" Margin="0,12,0,20" TextWrapping="Wrap"/></StackPanel>
<ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto"><StackPanel>
<TextBlock Text="会话来源" Margin="0,0,0,10"/>
<RadioButton x:Name="SourceBrowser" GroupName="source" Content="内置浏览器（推荐）" Foreground="#E9EDF1" Margin="0,0,0,12"/>
<RadioButton x:Name="SourceCloud" GroupName="source" Content="外部 CookieCloud" Foreground="#E9EDF1" Margin="0,0,0,12"/>
<RadioButton x:Name="SourceManual" GroupName="source" Content="已导入的 Cookie 文件" Foreground="#E9EDF1" Margin="0,0,0,18"/>
<CheckBox x:Name="AutoRefresh" Content="下载前自动刷新内置会话" Foreground="#E9EDF1" Margin="0,0,0,20"/>
<TextBlock Text="YouTube 网络代理（留空使用默认网络）" Margin="0,0,0,8"/>
<TextBox x:Name="Proxy" ToolTip="例如 http://127.0.0.1:7890；不含用户名或密码"/>
<Expander x:Name="Advanced" Header="外部 CookieCloud 配置" Foreground="#E9EDF1" Margin="0,20,0,16"><StackPanel Margin="0,12,8,0">
<TextBlock Text="服务地址" Margin="0,0,0,8"/><TextBox x:Name="Endpoint"/>
<TextBlock Text="UUID" Margin="0,12,0,8"/><TextBox x:Name="Uuid"/>
<TextBlock Text="同步密码" Margin="0,12,0,8"/><PasswordBox x:Name="CloudPassword" Padding="12" Background="#171C22" Foreground="#E9EDF1"/>
<TextBlock Text="凭据加密保存在当前 Windows 用户目录，不写入日志。" Foreground="#ADB8C4" TextWrapping="Wrap" Margin="0,12,0,0"/>
</StackPanel></Expander>
<TextBlock x:Name="SettingsStatus" TextWrapping="Wrap" Foreground="#A4E9CE" LineHeight="22" Margin="0,0,0,16"/>
</StackPanel></ScrollViewer>
<WrapPanel Grid.Row="2" Margin="0,16,0,0"><Button x:Name="SaveSettings" Content="保存设置" Margin="0,0,8,8"/><Button x:Name="SettingsLogin" Content="保存并登录 / 更新" Margin="0,0,8,8"/><Button Content="关闭" IsCancel="True" Margin="0,0,0,8"/></WrapPanel>
</Grid></Window>
'@
  $dialog=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($markup))
  $dialog.Owner=$form; $dialog.Icon=$form.Icon; $dialog.Resources=$form.Resources
  $script:settingsDialog=$dialog
  $script:settingsControls=@{}
  foreach ($name in @('SourceBrowser','SourceCloud','SourceManual','AutoRefresh','Proxy','Advanced','Endpoint','Uuid','CloudPassword','SettingsStatus','SaveSettings','SettingsLogin')) { $script:settingsControls[$name]=$dialog.FindName($name) }
  $c=$script:settingsControls
  try { $script:loadedAuthSettings=Read-AuthSettings } catch {
    $c.SettingsStatus.Text='旧设置无法解密，请重新填写并保存。'
    $script:loadedAuthSettings=[pscustomobject]@{source='browser';proxy='';auto_refresh=$true;endpoint='';uuid='';password='';crypto_type='legacy'}
  }
  $cfg=$script:loadedAuthSettings
  $c.SourceBrowser.IsChecked=$cfg.source -eq 'browser'; $c.SourceCloud.IsChecked=$cfg.source -eq 'cloud'; $c.SourceManual.IsChecked=$cfg.source -eq 'manual'
  $c.AutoRefresh.IsChecked=[bool]$cfg.auto_refresh; $c.Proxy.Text=[string]$cfg.proxy
  $c.Endpoint.Text=[string]$cfg.endpoint; $c.Uuid.Text=[string]$cfg.uuid; $c.CloudPassword.Password=[string]$cfg.password
  $c.Advanced.IsExpanded=$cfg.source -eq 'cloud'
  $c.SourceCloud.Add_Checked({ $script:settingsControls.Advanced.IsExpanded=$true })
  $c.SettingsLogin.IsEnabled=-not $script:busy
  if ($script:busy) { $c.SettingsStatus.Text='下载进行中：可保存设置，下次任务生效；登录请等待当前任务结束。' }
  else {
    $meta=Join-Path $dataDir 'sessions\youtube.json'
    if (Test-Path -LiteralPath $meta) {
      try { $s=Get-Content -LiteralPath $meta -Raw -Encoding UTF8 | ConvertFrom-Json
        $c.SettingsStatus.Text=('会话保存于 '+$s.saved_at+' · '+$(if($s.download_verified){'已通过下载验证'}else{'待下载验证'}))
      } catch { $c.SettingsStatus.Text='登录一次后自动保存；需要时可随时修改这些设置。' }
    }
  }
  $c.SaveSettings.Add_Click({ [void](Save-AuthSettings) })
  $c.SettingsLogin.Add_Click({
    if (Save-AuthSettings) {
      if ($script:settingsControls.SourceManual.IsChecked) { $script:settingsControls.SettingsStatus.Text='请在「平台登录」中选择 YouTube → 导入。'; return }
      $script:settingsDialog.Close(); Start-PlatformLogin 'youtube'
    }
  })
  [void]$dialog.ShowDialog()
  $script:settingsDialog=$null; $script:settingsControls=@{}
}

function Save-AuthSettings {
  $c=$script:settingsControls
  try {
    $source=if($c.SourceCloud.IsChecked){'cloud'}elseif($c.SourceManual.IsChecked){'manual'}else{'browser'}
    $proxy=$c.Proxy.Text.Trim(); $endpoint=$c.Endpoint.Text.Trim().TrimEnd('/')
    foreach ($pair in @(@($proxy,'代理',@('http','https','socks5')), @($endpoint,'服务地址',@('http','https')))) {
      if ($pair[0]) {
        $uri=$null
        if (-not [Uri]::TryCreate($pair[0],[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -notin $pair[2] -or -not $uri.Host -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) { throw ($pair[1]+'格式不正确，请填写不含账号密码的完整地址。') }
      }
    }
    if ($source -eq 'cloud' -and (-not $endpoint -or -not $c.Uuid.Text.Trim() -or -not $c.CloudPassword.Password)) { throw '请填写 CookieCloud 地址、UUID 和同步密码。' }
    $value=@{source=$source;proxy=$proxy;auto_refresh=[bool]$c.AutoRefresh.IsChecked;endpoint=$endpoint;uuid=$c.Uuid.Text.Trim();password=$c.CloudPassword.Password;crypto_type=$script:loadedAuthSettings.crypto_type;request_headers=$script:loadedAuthSettings.request_headers}
    $bytes=[Text.Encoding]::UTF8.GetBytes(($value | ConvertTo-Json -Compress))
    $encrypted=[Security.Cryptography.ProtectedData]::Protect($bytes,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
    $path=Join-Path $dataDir 'auth-settings.bin'; $temp=$path+'.new'
    [IO.File]::WriteAllBytes($temp,$encrypted)
    if (Test-Path -LiteralPath $path) { [IO.File]::Replace($temp,$path,[NullString]::Value) } else { [IO.File]::Move($temp,$path) }
    $c.SettingsStatus.Text='设置已保存。登录 / 更新后，可直接重试失败任务。'
    Update-Accounts
    return $true
  } catch { $c.SettingsStatus.Text=$_.Exception.Message; return $false }
}

$btnSettings.Add_Click({ Show-CookieSettings })
$btnRetry.Add_Click({ Retry-FailedTasks })
