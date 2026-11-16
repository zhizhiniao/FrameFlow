param([Parameter(Mandatory=$true)][string]$Stage,[Parameter(Mandatory=$true)][string]$Target,[int]$WaitProcessId=0,[int]$LauncherProcessId=0,[switch]$NoRestart)
$ErrorActionPreference='Stop'
$Stage=[IO.Path]::GetFullPath($Stage); $Target=[IO.Path]::GetFullPath($Target)
. (Join-Path $Target 'Update.Check.ps1') -LibraryOnly
$manifest=Confirm-UpdateFiles $Stage
if ($Stage.StartsWith($Target.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Update staging must be outside the application' }
foreach ($processId in @($WaitProcessId,$LauncherProcessId)) {
  if ($processId -gt 0 -and (Get-Process -Id $processId -ErrorAction SilentlyContinue)) { Wait-Process -Id $processId -Timeout 90 -ErrorAction Stop }
}
$backup=Join-Path (Split-Path $Stage -Parent) 'rollback'
[void][IO.Directory]::CreateDirectory($backup)
$changed=[Collections.Generic.List[object]]::new()
try {
  foreach ($entry in @($manifest.files)+@([pscustomobject]@{path='manifest.json'})) {
    $source=Get-UpdatePath $Stage $entry.path; $dest=Get-UpdatePath $Target $entry.path; $saved=Get-UpdatePath $backup $entry.path
    # Refuse junctions/reparse points in existing target ancestors.
    $ancestor=Split-Path $dest -Parent
    while ($ancestor -and $ancestor.Length -ge $Target.Length) {
      if ((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Update target contains a reparse point' }
      $ancestor=Split-Path $ancestor -Parent
    }
    [void][IO.Directory]::CreateDirectory((Split-Path $dest -Parent))
    $existed=Test-Path -LiteralPath $dest
    if ($existed) { [void][IO.Directory]::CreateDirectory((Split-Path $saved -Parent)); Copy-Item -LiteralPath $dest -Destination $saved -Force }
    $changed.Add([pscustomobject]@{dest=$dest;saved=$saved;existed=$existed})
    Copy-Item -LiteralPath $source -Destination $dest -Force
  }
  @{status='installed';version=(Get-Content -LiteralPath (Join-Path $Target 'app-version.json') -Raw | ConvertFrom-Json).version} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path (Split-Path $Stage -Parent) 'install-result.json') -Encoding UTF8
} catch {
  $failure=$_
  for ($i=$changed.Count-1;$i -ge 0;$i--) {
    $entry=$changed[$i]
    if ($entry.existed) { Copy-Item -LiteralPath $entry.saved -Destination $entry.dest -Force }
    elseif (Test-Path -LiteralPath $entry.dest -PathType Leaf) { Remove-Item -LiteralPath $entry.dest -Force }
  }
  @{status='rolled-back';error=$failure.Exception.Message} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path (Split-Path $Stage -Parent) 'install-result.json') -Encoding UTF8
  if (-not $NoRestart) { Start-Process -FilePath (Join-Path $Target 'FrameFlow.exe') -WorkingDirectory $Target -WindowStyle Normal }
  throw $failure
}
if (-not $NoRestart) { Start-Process -FilePath (Join-Path $Target 'FrameFlow.exe') -WorkingDirectory $Target -WindowStyle Normal }
