$script:platformFolders=@('哔哩哔哩','YouTube','抖音','小红书','TikTok','X','微信视频号','微信公众号','光厂片场','未分类')

function Get-PlatformFolder([string]$platform) {
  switch ($platform) {
    '抖音图文' { return '抖音' }
    'Twitter' { return 'X' }
    default { if ($platform -in $script:platformFolders) { return $platform }; return '未分类' }
  }
}

function Get-LibraryRelativePath([string]$path) {
  $base=[IO.Path]::GetFullPath($outDir).TrimEnd('\')+'\'
  $full=[IO.Path]::GetFullPath($path)
  if (-not $full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)) { throw '媒体路径不在下载目录内。' }
  return $full.Substring($base.Length)
}

function Write-LibraryJson([string]$path,$value) {
  $temp=$path+'.'+$PID+'.new'
  [IO.File]::WriteAllText($temp,(ConvertTo-Json -InputObject $value -Depth 8),[Text.UTF8Encoding]::new($false))
  if (Test-Path -LiteralPath $path) { [IO.File]::Replace($temp,$path,[NullString]::Value) }
  else { [IO.File]::Move($temp,$path) }
}

function Initialize-PlatformLibrary {
  # Journal first: interrupted moves can update their history on the next launch.
  $journal=Join-Path $outDir '.platform-migration.json'
  $plans=@()
  if (Test-Path -LiteralPath $journal) { $loaded=Get-Content -LiteralPath $journal -Raw -Encoding UTF8 | ConvertFrom-Json; $plans=@($loaded) }
  $planned=@{}
  foreach ($plan in $plans) { $planned[$plan.old]=$true }
  foreach ($file in @(Get-ChildItem -LiteralPath $outDir -File | Where-Object { $_.Extension.ToLowerInvariant() -in $mediaExts })) {
    if ($planned.ContainsKey($file.Name)) { continue }
    $entry=$script:history | Where-Object file -EQ $file.Name | Select-Object -First 1
    $platform=Get-PlatformFolder $entry.platform
    $relative=Join-Path $platform $file.Name
    if (Test-Path -LiteralPath (Join-Path $outDir $relative)) { $relative=Join-Path $platform ($file.BaseName+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)+$file.Extension) }
    $plans+= [pscustomobject]@{old=$file.Name;new=$relative;platform=$platform}
  }
  if (-not $plans.Count) { return }
  $backup=Join-Path $outDir '.history-before-platforms.json'
  if ((Test-Path -LiteralPath $historyFile) -and -not (Test-Path -LiteralPath $backup)) { Copy-Item -LiteralPath $historyFile -Destination $backup }
  Write-LibraryJson $journal @($plans)
  foreach ($plan in $plans) {
    $source=Join-Path $outDir $plan.old; $destination=Join-Path $outDir $plan.new
    # Resolve and verify both endpoints before moving anything.
    [void](Get-LibraryRelativePath $source); [void](Get-LibraryRelativePath $destination)
    if (Test-Path -LiteralPath $source -PathType Leaf) {
      if (Test-Path -LiteralPath $destination) { continue }
      [void][IO.Directory]::CreateDirectory((Split-Path $destination -Parent))
      Move-Item -LiteralPath $source -Destination $destination -ErrorAction Stop
    }
    if ((Test-Path -LiteralPath $destination -PathType Leaf) -and -not (Test-Path -LiteralPath $source)) {
      foreach ($entry in @($script:history | Where-Object file -EQ $plan.old)) { $entry.file=$plan.new; $entry.platform=$plan.platform }
    }
  }
  Save-History $script:history
}

function Get-LibraryMediaFiles {
  # Only managed platform folders; staging and thumbnail caches never enter the library.
  $files=@(Get-ChildItem -LiteralPath $outDir -File)
  foreach ($platform in $script:platformFolders) {
    $folder=Join-Path $outDir $platform
    if (Test-Path -LiteralPath $folder -PathType Container) { $files+=@(Get-ChildItem -LiteralPath $folder -File -Recurse) }
  }
  return @($files | Where-Object { $_.Extension.ToLowerInvariant() -in $mediaExts })
}

function Update-PlatformFilter {
  $previous=$platformFilter.SelectedValue
  if (-not $previous -and -not $SelfTest -and -not $QueueTest) {
    $path=Join-Path $dataDir 'library-view.json'
    if (Test-Path -LiteralPath $path) { try { $previous=(Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json).platform } catch {} }
  }
  $choices=@([pscustomobject]@{Name='全部平台';Label=('全部平台 · '+$script:allMedia.Count)})
  foreach ($name in $script:platformFolders) {
    $count=@($script:allMedia | Where-Object Kind -EQ $name).Count
    $choices+= [pscustomobject]@{Name=$name;Label=($name+' · '+$count)}
  }
  if (-not $previous) { $previous=if ($script:allMedia.Count) { $script:allMedia[0].Kind } else { 'YouTube' } }
  $script:updatingPlatform=$true
  try { $platformFilter.ItemsSource=$choices; $platformFilter.SelectedValue=$previous } finally { $script:updatingPlatform=$false }
}
