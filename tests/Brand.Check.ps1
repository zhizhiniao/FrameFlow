param([int]$WindowProcessId,[string]$EvidenceDirectory,[string]$Shortcut)
$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
Add-Type -Path (Join-Path $project 'VideoDownloader.Runtime.cs')
Add-Type -AssemblyName System.Drawing
Add-Type -Path (Join-Path $PSScriptRoot 'WindowCapture.cs') -ReferencedAssemblies System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class FrameFlowTaskbarCapture {
  [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left,Top,Right,Bottom; }
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string name,string title);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd,out Rect rect);
  [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
}
'@
[void][IO.Directory]::CreateDirectory($EvidenceDirectory)
$window=Get-Process -Id $WindowProcessId
if ($window.MainWindowTitle -ne '帧流 · 视频下载') { throw 'Unexpected window' }
$handle=$window.MainWindowHandle
$id=[FrameflowWindow]::ReadTaskbarProperty($handle,5)
$icon=[FrameflowWindow]::ReadTaskbarProperty($handle,3)
$command=[FrameflowWindow]::ReadTaskbarProperty($handle,2)
if ($id -cne [FrameflowWindow]::AppId -or $icon -notlike '*FrameFlow.ico,0' -or $command -notlike '*FrameFlow.exe"') { throw 'Taskbar metadata is incorrect' }
if ($Shortcut) { [FrameflowWindow]::ConfigureShortcut($Shortcut) }
[WindowCapture]::Save($handle,(Join-Path $EvidenceDirectory 'window.png'))
$taskbar=[FrameFlowTaskbarCapture]::FindWindow('Shell_TrayWnd',$null)
$previous=[FrameFlowTaskbarCapture]::SetThreadDpiAwarenessContext([IntPtr](-4))
try {
  $rect=[FrameFlowTaskbarCapture+Rect]::new()
  if (-not [FrameFlowTaskbarCapture]::GetWindowRect($taskbar,[ref]$rect)) { throw 'Taskbar was not found' }
  $bitmap=[Drawing.Bitmap]::new($rect.Right-$rect.Left,$rect.Bottom-$rect.Top)
  $graphics=[Drawing.Graphics]::FromImage($bitmap)
  try {
    $graphics.CopyFromScreen($rect.Left,$rect.Top,0,0,$bitmap.Size)
    $bitmap.Save((Join-Path $EvidenceDirectory 'taskbar.png'),[Drawing.Imaging.ImageFormat]::Png)
  } finally { $graphics.Dispose(); $bitmap.Dispose() }
} finally { [void][FrameFlowTaskbarCapture]::SetThreadDpiAwarenessContext($previous) }
@{appId=$id;icon=$icon;relaunchCommand=$command;processId=$WindowProcessId;responding=$window.Responding} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'brand-result.json') -Encoding UTF8
Write-Output ('PASS: native taskbar AppID, relaunch icon, relaunch command; captured live window and taskbar. '+$id)
