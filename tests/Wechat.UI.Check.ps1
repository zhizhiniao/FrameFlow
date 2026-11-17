$script:wechatChecks=@()
function Assert-WechatUI([bool]$value,[string]$label) {if(-not $value){throw $label};$script:wechatChecks+=$label}
$form.Add_ContentRendered({
  try {
    Assert-WechatUI ($linkDownloadPanel.Visibility -eq 'Visible' -and $wechatPanel.Visibility -eq 'Collapsed') 'Normal link download remains default'
    Set-DownloadMode $true
    $form.UpdateLayout()
    Assert-WechatUI ($wechatPanel.Visibility -eq 'Visible' -and $linkDownloadPanel.Visibility -eq 'Collapsed') 'WeChat section is separate from link inputs'
    Assert-WechatUI ($captureContent.Visibility -eq 'Visible' -and $libraryContent.Visibility -eq 'Collapsed') 'Capture view replaces empty local library on the right'
    Assert-WechatUI ($queueStatusPanel.Visibility -eq 'Collapsed') 'WeChat view omits duplicate general queue explanations'
    Assert-WechatUI ($form.Background.Color.ToString() -eq '#FF262624') 'Warm neutral canvas matches Fatio dark theme'
    Assert-WechatUI ($platformLogos.Children.Count -eq 12) 'Bottom strip renders all platform logos and more sites entry'
    Assert-WechatUI ((Resolve-Url 'https://www.instagram.com/reel/Chunk8-jurw/')[0] -eq 'Instagram') 'Instagram shares enter dedicated login and library route'
    Assert-WechatUI ((Resolve-Url 'https://instagram.com.invalid.test/reel/test')[0] -eq '自动') 'Lookalike domains remain outside Instagram account route'
    Assert-WechatUI ((Resolve-Url 'https://vimeo.com/123')[0] -eq 'Vimeo') 'Vimeo has a separate library category'
    $script:sitesSearchPassed=$false
    $script:sitesTimer=[Windows.Threading.DispatcherTimer]::new(); $script:sitesTimer.Interval=[TimeSpan]::FromMilliseconds(300)
    $script:sitesTimer.Add_Tick({
      $script:sitesTimer.Stop()
      $dialog=@($form.OwnedWindows | Where-Object Title -eq '更多网站') | Select-Object -First 1
      if($dialog){try{$dialog.Content.Children[1].Text='Instagram';$script:sitesSearchPassed=($dialog.Content.Children[2].Items.Count -gt 0 -and @($dialog.Content.Children[2].Items | Where-Object {$_ -notmatch 'Instagram'}).Count -eq 0)}finally{$dialog.Close()}}
    })
    $script:sitesTimer.Start(); $btnMoreSites.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    Assert-WechatUI $script:sitesSearchPassed 'More sites opens and search filters the installed engine catalog'
    Assert-WechatUI ($btnWechatCapture.IsEnabled -and -not $btnWechatDownload.IsEnabled) 'Download unavailable before preview selection'
    Assert-WechatUI ((Get-PlatformFolder '微信视频号') -eq '微信视频号') 'Dedicated WeChat library folder'
    $fixture=Join-Path $root '.build\wechat-known-preview'
    if (Test-Path -LiteralPath (Join-Path $fixture 'state.json')) {
      $script:wechatSession=$fixture
      Poll-WechatCapture
      Assert-WechatUI ($wechatCandidates.Items.Count -gt 0) 'Known real-media preview state renders'
      $wechatCandidates.SelectedIndex=0
      Assert-WechatUI ($btnWechatDownload.IsEnabled -and $null -ne $wechatCandidates.SelectedItem.Image) 'Only selected preview enables download'
      $form.UpdateLayout()
      $candidateOrigin=$wechatCandidates.TransformToAncestor($AppSurface).Transform([Windows.Point]::new(0,0))
      Assert-WechatUI ($candidateOrigin.X -gt $ComposeColumn.ActualWidth) 'Captured covers render in the right column'
      Assert-WechatUI ($lblWechatSelection.Text -eq $wechatCandidates.SelectedItem.Label) 'Left column reflects the selected right-side cover'
      $selected=$wechatCandidates.SelectedItem
      $fakeTask=[pscustomobject]@{url=('wxchannels:'+$selected.Id);state='已完成';detail='已保存';percent=100}
      $script:tasks.Add($fakeTask)
      Update-WechatDownloadStatus
      Assert-WechatUI ($wechatCandidates.SelectedItem.Status -eq '已完成' -and $lblWechatDownloadState.Text -eq '已保存') 'Completed download updates both result card and concise left status'
      Assert-WechatUI (-not $btnWechatDownload.IsEnabled -and $btnWechatDownload.Content -eq '已保存') 'Completed result cannot be downloaded twice'
      [void]$script:tasks.Remove($fakeTask)
      Update-WechatDownloadStatus
      Set-WechatResultsView $false
      Assert-WechatUI ($libraryContent.Visibility -eq 'Visible' -and $wechatPanel.Visibility -eq 'Visible') 'Browsing saved media keeps WeChat controls available'
      Set-WechatResultsView $true
    }
    $form.UpdateLayout()
    [void][IO.Directory]::CreateDirectory($ScreenshotDirectory)
    $target=[Windows.Media.Imaging.RenderTargetBitmap]::new([int]$AppSurface.ActualWidth,[int]$AppSurface.ActualHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32)
    $target.Render($AppSurface)
    $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($target))
    $stream=[IO.File]::Create((Join-Path $ScreenshotDirectory 'wechat-ui.png'))
    try {$encoder.Save($stream)}finally{$stream.Dispose()}
    $form.Width=860; $form.Height=620; $form.UpdateLayout()
    $origin=$platformLogos.TransformToAncestor($AppSurface).Transform([Windows.Point]::new(0,0))
    Assert-WechatUI ($platformLogos.ActualHeight -ge 28 -and ($origin.Y+$platformLogos.ActualHeight) -le $AppSurface.ActualHeight) 'Minimum window keeps platform strip visible at the bottom'
    Assert-WechatUI ($wechatCandidates.ActualWidth -gt 300 -and $btnWechatDownload.ActualWidth -gt 200) 'Minimum window preserves result space and download action'
    $target=[Windows.Media.Imaging.RenderTargetBitmap]::new([int]$AppSurface.ActualWidth,[int]$AppSurface.ActualHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32)
    $target.Render($AppSurface); $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new(); $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($target))
    $stream=[IO.File]::Create((Join-Path $ScreenshotDirectory 'wechat-ui-narrow.png'));try{$encoder.Save($stream)}finally{$stream.Dispose()}
    Set-DownloadMode $false
    Assert-WechatUI ($linkDownloadPanel.Visibility -eq 'Visible') 'Returning to links restores normal inputs'
    @{passed=$true;checks=$script:wechatChecks} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $ScreenshotDirectory 'wechat-ui.json') -Encoding UTF8
  } catch { @{passed=$false;error=$_.Exception.ToString();checks=$script:wechatChecks} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $ScreenshotDirectory 'wechat-ui.json') -Encoding UTF8 }
  finally {$form.Close()}
})
[void]$form.ShowDialog()
