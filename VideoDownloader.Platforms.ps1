# Informational brand strip; download routing remains in the worker.
$script:platformLogos=$form.FindName('platformLogos')
$label=[Windows.Controls.TextBlock]::new()
$label.Text='支持'; $label.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString('#938D83')
$label.FontSize=11; $label.VerticalAlignment='Center'; $label.Margin='0,0,20,0'
[void]$platformLogos.Children.Add($label)
foreach ($brand in (Get-Content -LiteralPath (Join-Path $root 'assets\platforms.json') -Raw -Encoding UTF8 | ConvertFrom-Json)) {
  $chip=[Windows.Controls.StackPanel]::new(); $chip.Orientation='Horizontal'; $chip.Margin='0,0,18,0'; $chip.Height=28; $chip.ToolTip=$brand.hint
  $icon=[Windows.Shapes.Path]::new(); $icon.Data=[Windows.Media.Geometry]::Parse($brand.path)
  $icon.Fill=[Windows.Media.BrushConverter]::new().ConvertFromString($brand.color); $icon.Stretch='Uniform'; $icon.Width=17; $icon.Height=17; $icon.VerticalAlignment='Center'
  [void]$chip.Children.Add($icon)
  $text=[Windows.Controls.TextBlock]::new(); $text.Text=$brand.name; $text.FontSize=11; $text.Margin='6,0,0,0'; $text.VerticalAlignment='Center'
  $text.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString($(if($brand.id -eq 'youtube'){'#EEEade'}else{'#B0AAA0'}))
  [void]$chip.Children.Add($text); [void]$platformLogos.Children.Add($chip)
}
# This provider uses its name instead of an invented brand icon.
$text=[Windows.Controls.TextBlock]::new(); $text.Text='光厂'; $text.FontSize=11; $text.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString('#B0AAA0'); $text.VerticalAlignment='Center'; $text.Margin='0,0,18,0'; $text.ToolTip='光厂片场案例详情页的公开播放版'
[void]$platformLogos.Children.Add($text)
$script:btnMoreSites=[Windows.Controls.Button]::new(); $btnMoreSites.Content='更多网站'; $btnMoreSites.Style=$form.FindResource('QuietButton'); $btnMoreSites.FontSize=11; $btnMoreSites.Height=28
$btnMoreSites.ToolTip='查看当前引擎的站点名单；其他网站也可直接粘贴链接尝试。'
[void]$platformLogos.Children.Add($btnMoreSites)
$btnMoreSites.Add_Click({
  $dialog=[Windows.Window]::new(); $dialog.Title='更多网站'; $dialog.Owner=$form; $dialog.Width=500; $dialog.Height=540; $dialog.MinWidth=360; $dialog.MinHeight=360; $dialog.WindowStartupLocation='CenterOwner'
  $dialog.Background=$form.Background; $dialog.Foreground=$form.Foreground; $dialog.FontFamily=$form.FontFamily
  $grid=[Windows.Controls.Grid]::new(); $grid.Margin='24'
  foreach($height in @('Auto','Auto','*')){$row=[Windows.Controls.RowDefinition]::new();$row.Height=[Windows.GridLengthConverter]::new().ConvertFromString($height);[void]$grid.RowDefinitions.Add($row)}
  $hint=[Windows.Controls.TextBlock]::new(); $hint.Text='直接粘贴链接即可尝试，部分网站需要登录。'; $hint.TextWrapping='Wrap'; $hint.Margin='0,0,0,16';[void]$grid.Children.Add($hint)
  $search=[Windows.Controls.TextBox]::new(); $search.ToolTip='搜索网站名称，如 Instagram、Vimeo、Facebook'; $search.Margin='0,0,0,12'; $search.Style=$form.FindResource([Windows.Controls.TextBox]);[Windows.Controls.Grid]::SetRow($search,1);[void]$grid.Children.Add($search)
  $list=[Windows.Controls.ListBox]::new(); $list.Background=$dialog.Background; $list.Foreground=$dialog.Foreground; $list.BorderThickness=0;[Windows.Controls.Grid]::SetRow($list,2);[void]$grid.Children.Add($list)
  $sites=@(Get-Content -LiteralPath (Join-Path $root 'assets\supported-extractors.txt') -Encoding UTF8)
  $list.ItemsSource=$sites
  $filter={ $term=$search.Text.Trim(); $list.ItemsSource=@($sites | Where-Object { -not $term -or $_.IndexOf($term,[StringComparison]::OrdinalIgnoreCase) -ge 0 }) }.GetNewClosure()
  $search.Add_TextChanged($filter)
  $dialog.Content=$grid; [void]$dialog.ShowDialog()
})
