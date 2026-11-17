$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\VideoDownloader.Queue.ps1')
$script:checks=@()
function Assert-State($value,$message) { if(-not $value){throw $message}; $script:checks += $message }
function Set-Busy($value) { $script:busy=$value }
function Update-Queue { $script:busy=$true }
function Refresh-History {}
function Update-Accounts {}
function Read-TaskLog($task) {}
function Complete-TaskFiles($task) {}
function Log($text) {}
function Start-PlatformLogin($id) { $script:loginProc=[pscustomobject]@{platform=$id} }
function Invoke-Download($platform,$url,$log,$output) {
  $script:started += $url
  $process=[pscustomobject]@{HasExited=$false; ExitCode=0}
  $process | Add-Member ScriptMethod WaitForExit {}
  $process | Add-Member ScriptMethod Dispose {}
  return $process
}
function New-Task($id,$platform) {
  [pscustomobject]@{id=$id;url=('https://example.com/'+$id);platform=$platform;state='排队中';percent=0;retries=0;proc=$null;logPos=0;logFile=(Join-Path $PSScriptRoot ('queue-state/'+$id+'.log'));staging=(Join-Path $PSScriptRoot ('queue-state/'+$id));detail=''}
}
$platformIds=@{'YouTube'='youtube';'抖音'='douyin';'X'='twitter'}
$script:started=@(); $script:loginProc=$null
$script:tasks.Add((New-Task 'a' '抖音')); $script:tasks.Add((New-Task 'b' '抖音')); $script:tasks.Add((New-Task 'c' 'YouTube'))
Start-QueuedDownloads
Assert-State ($script:tasks[0].state -eq '下载中' -and $script:tasks[1].state -eq '排队中' -and $script:tasks[2].state -eq '下载中') 'Shared browser profile serialized without blocking another platform'
$script:tasks.Clear(); $script:started=@()
$a=New-Task 'login-original' 'YouTube'; $script:tasks.Add($a); Start-QueuedDownloads
$a.proc.HasExited=$true; $a.proc.ExitCode=10
Poll-Download
Assert-State ($a.state -eq '登录中' -and $a.retries -eq 1) 'Authentication failure retains the original task for one retry'
$b=New-Task 'added-during-login' 'X'; $script:tasks.Add($b); Start-QueuedDownloads
Assert-State ($b.state -eq '排队中') 'New tasks are retained while login is in progress'
$script:loginProc=$null; Complete-QueueLogin $true; Start-QueuedDownloads
Assert-State ($script:started[-2] -eq $a.url -and $script:started[-1] -eq $b.url) 'Login retries original URL and then starts newly queued URL'
$txtLog=@{}; $btnLogs=@{}
$a.proc.HasExited=$true; $a.proc.ExitCode=10
Poll-Download
Assert-State ($a.state -eq '失败' -and $null -eq $script:loginProc) 'Second authentication failure does not loop login'
$c=New-Task 'cancelled-login' 'YouTube'; $c.state='登录中'; $script:loginTask=$c
Complete-QueueLogin $false
Assert-State ($c.state -eq '失败' -and $null -eq $script:loginTask) 'Cancelled login releases only its task'
$script:dlTimer=[pscustomobject]@{}; $script:dlTimer | Add-Member ScriptMethod Start {}
$script:tasks.Clear(); $script:loginProc=$null
$failed=New-Task 'retry' 'YouTube'; $failed.state='失败'; $failed.logPos=99999; $failed.retries=1
$script:tasks.Add($failed); Retry-FailedTasks
Assert-State ($failed.state -eq '下载中' -and $failed.logPos -eq 0 -and $failed.retries -eq 0) 'Retry reuses failed task and resets log cursor and retry budget'
$duplicate=New-Task 'retry' 'YouTube'; $duplicate.state='失败'; $script:tasks.Add($duplicate); Retry-FailedTasks
Assert-State ($duplicate.state -eq '失败') 'Retry does not duplicate an active URL'
@{passed=$true;checks=$script:checks} | ConvertTo-Json | Set-Content (Join-Path $PSScriptRoot 'queue-state/result.json') -Encoding UTF8

