param([switch]$CookieSettings, [switch]$QueueTest, [switch]$WechatTest, [switch]$SelfTest, [string]$ScreenshotDirectory, [switch]$DownloadTest, [string]$DataRoot, [string]$OutputDirectory, [ValidateSet("","all","douyin","xhs","tiktok","youtube","twitter","bilibili","instagram")][string]$LoginCheck = "")

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Control]::CheckForIllegalCrossThreadCalls = $false
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls11 -bor [System.Net.SecurityProtocolType]::Tls

function Quote-Arg([string]$s) {
  if ($s.Length -gt 0 -and $s -notmatch '[\s"]') { return $s }
  return '"' + [regex]::Replace([regex]::Replace($s, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}

# ---- 必备路径 ----
$root    = $PSScriptRoot
$runtimeRoot = $root
$bundledVersion = (Get-Content -LiteralPath (Join-Path $root 'app-version.json') -Raw | ConvertFrom-Json).version
$bundledRoot = Join-Path $root ('release\FrameFlow-Portable-v' + $bundledVersion)
if (Test-Path -LiteralPath (Join-Path $bundledRoot 'worker\FrameFlow.Worker.exe')) { $runtimeRoot = $bundledRoot }
$exe     = Join-Path $runtimeRoot 'yt-dlp.exe'
$ffbin   = Join-Path $runtimeRoot 'ffmpeg\bin'
if (-not $DataRoot) { $DataRoot = $env:FRAMEFLOW_DATA_ROOT }
if (-not $DataRoot) { $DataRoot = Join-Path $env:LOCALAPPDATA 'FrameFlow' }
$dataDir = [IO.Path]::GetFullPath($DataRoot)
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
$configPath = Join-Path $dataDir 'settings.json'
$outDir = $OutputDirectory
if (-not $outDir -and (Test-Path -LiteralPath $configPath)) {
  try { $outDir = (Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json).output } catch {}
}
if (-not $outDir) { $outDir = Join-Path ([Environment]::GetFolderPath('MyVideos')) '帧流' }
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$worker = Join-Path $runtimeRoot 'worker\FrameFlow.Worker.exe'
$workerPrefix = ''
if (-not (Test-Path -LiteralPath $worker)) {
  $worker = Join-Path $root '.build-venv\Scripts\python.exe'
  $workerPrefix = (Quote-Arg (Join-Path $root 'frameflow_worker.py')) + ' '
}

$historyFile = Join-Path $outDir 'history.json'
$thumbDir    = Join-Path $outDir '.thumbs'
New-Item -ItemType Directory -Force -Path $thumbDir | Out-Null

$mediaExts = @('.mp4','.webm','.mkv','.mov','.m4v','.avi','.flv','.ts','.wmv','.3gp','.m4a','.mp3','.opus','.ogg')

# ---- 平台配置 ----
$platforms = [ordered]@{
  '哔哩哔哩' = @{ re = 'bilibili\.com|b23\.tv'; referer = 'https://www.bilibili.com/'; cookie = 'bilibili.txt'; required = $false }
  'YouTube' = @{ re = 'youtube\.com|youtu\.be'; referer = 'https://www.youtube.com/';     cookie = 'youtube.txt'; required = $false }
  'Instagram' = @{ re = 'instagram\.com'; referer = 'https://www.instagram.com/'; cookie = 'instagram.txt'; required = $false }
  'Vimeo' = @{ re = 'vimeo\.com'; referer = 'https://vimeo.com/'; cookie = ''; required = $false }
  'X'       = @{ re = 'x\.com|twitter\.com'; referer = 'https://x.com/'; cookie = 'twitter.txt'; required = $false }
  'TikTok'  = @{ re = 'tiktok\.com';            referer = 'https://www.tiktok.com/';      cookie = 'tiktok.txt';  required = $false }
  '小红书'  = @{ re = 'xiaohongshu\.com|xhslink\.com';       referer = 'https://www.xiaohongshu.com/'; cookie = 'xhs.txt';     required = $true  }
  '抖音'    = @{ re = 'douyin\.com';            referer = 'https://www.douyin.com/';      cookie = 'douyin.txt';  required = $true  }
}

# ---- 工具函数 ----


function Resolve-Url([string]$text) {
  $m = [regex]::Match($text, 'https?://[^\s<>"'']+')
  if (-not $m.Success) { return $null }
  $url = $m.Value.TrimEnd([char[]]'，,。.！!？?：:；;）)】]')
  try { $hostName = ([uri]$url).DnsSafeHost.ToLowerInvariant() } catch { return $null }
  if ($hostName -in @('www.vjshi.com','vjshi.com') -and ([uri]$url).AbsolutePath -cmatch '^/cases/detail/[0-9]+/?$') {
    return @('光厂片场', $url)
  }
  foreach ($key in $platforms.Keys) {
    foreach ($domain in ($platforms[$key].re -split '\|')) {
      $domain = $domain.Replace('\.', '.')
      if ($hostName -eq $domain -or $hostName.EndsWith('.' + $domain)) { return @($key, $url) }
    }
  }
  return @('自动', $url)
}

function Format-Size($bytes) {
  if ($null -eq $bytes) { $bytes = 0 }
  if ($bytes -lt 1KB) { return "$bytes B" }
  if ($bytes -lt 1MB) { return ('{0:N0} KB' -f ($bytes / 1KB)) }
  if ($bytes -lt 1GB) { return ('{0:N1} MB' -f ($bytes / 1MB)) }
  return ('{0:N2} GB' -f ($bytes / 1GB))
}

function Load-History {
  if (Test-Path $historyFile) {
    try {
      $raw = Get-Content $historyFile -Raw -Encoding UTF8
      if ($raw) { $j = $raw | ConvertFrom-Json; if ($j) { return @($j) } }
    } catch {}
  }
  return @()
}

function Save-History($list) {
  Write-LibraryJson $historyFile @($list | Where-Object { $null -ne $_ })
}

. (Join-Path $root 'VideoDownloader.Library.ps1')

function Get-ThumbPath($fileName) {
  if (-not [IO.Path]::IsPathRooted($fileName)) { $fileName=Join-Path $outDir $fileName }
  $sha=[Security.Cryptography.SHA256]::Create()
  try { $safe=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($fileName.ToLowerInvariant())))).Replace('-','') } finally { $sha.Dispose() }
  Join-Path $thumbDir ($safe + '.jpg')
}

function Generate-Thumb([string]$video, [string]$thumb) {
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $ffbin 'ffmpeg.exe'
    $psi.Arguments = '-y -nostdin -loglevel error -ss 1 -i "' + $video + '" -frames:v 1 -vf scale=160:160:force_original_aspect_ratio=increase,crop=160:160 -q:v 3 "' + $thumb + '"'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.WaitForExit()
    return (($p.ExitCode -eq 0) -and (Test-Path $thumb))
  } catch { return $false }
}

function Log([string]$msg) {
  if ($null -ne $script:txtLog) {
    $script:txtLog.AppendText($msg + "`r`n")
    $script:txtLog.SelectionStart = $script:txtLog.Text.Length
    $script:txtLog.ScrollToEnd()
  }
  if ($SelfTest) { Write-Host $msg }
}

$platformIds = @{ '光厂片场'='auto'; '哔哩哔哩'='bilibili'; 'YouTube'='youtube'; 'Instagram'='instagram'; 'Vimeo'='auto'; 'TikTok'='tiktok'; 'X'='twitter'; '小红书'='xhs'; '抖音'='douyin'; '抖音图文'='douyin'; '微信公众号'='weixin'; '微信视频号'='wxchannels'; '自动'='auto' }

function Start-Worker([string[]]$arguments, [string]$logFile) {
  $command = $workerPrefix + (($arguments | ForEach-Object { Quote-Arg $_ }) -join ' ')
  return [FrameflowProcess]::Start($worker, $command, $logFile)
}

function Invoke-Download([string]$plat, [string]$url, [string]$logFile, [string]$taskOutput) {
  $id = $platformIds[$plat]; if (-not $id) { $id='auto' }
  return Start-Worker @('download','--data',$dataDir,'--platform',$id,'--url',$url,'--output',$taskOutput) $logFile
}

# ---- 图文抓取（微信公众号文章）----
function Resolve-Tuwen([string]$text) {
  $m = [regex]::Match($text, 'https?://\S+')
  if (-not $m.Success) { return $null }
  $u = $m.Value.TrimEnd([char[]]'，,。.！!？?：:；;）)】]')
  if (([uri]$u).DnsSafeHost -eq 'mp.weixin.qq.com') { return @('微信公众号', $u) }
  if (([uri]$u).DnsSafeHost -match '(^|\.)douyin\.com$' -and ([uri]$u).AbsolutePath -match '^/note/') { return @('抖音图文', $u) }
  return $null
}

. (Join-Path $root 'VideoDownloader.UI.ps1')
