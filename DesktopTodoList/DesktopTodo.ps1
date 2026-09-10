param(
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$script:InstanceMutex = $null
$script:OwnsInstanceMutex = $false
if (-not $SelfTest) {
    $createdNewInstance = $false
    $script:InstanceMutex = [System.Threading.Mutex]::new($true, 'Local\DesktopTodoList.SingleInstance', [ref]$createdNewInstance)
    if (-not $createdNewInstance) {
        $script:InstanceMutex.Dispose()
        return
    }
    $script:OwnsInstanceMutex = $true
}

$script:AppName = 'DesktopTodoList'
$script:DataDirectory = Join-Path $PSScriptRoot 'data'
$script:TaskFile = Join-Path $script:DataDirectory 'tasks.json'
$script:SettingsFile = Join-Path $script:DataDirectory 'settings.json'
$script:StartupRegistryPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$script:StartupValueName = 'DesktopTodoList'
$script:Tasks = [System.Collections.ArrayList]::new()

function Ensure-DataDirectory {
    if (-not (Test-Path -LiteralPath $script:DataDirectory)) {
        New-Item -ItemType Directory -Path $script:DataDirectory -Force | Out-Null
    }
}

function Read-Tasks {
    Ensure-DataDirectory
    $script:Tasks.Clear()

    if (-not (Test-Path -LiteralPath $script:TaskFile)) {
        return
    }

    try {
        $content = Get-Content -Raw -LiteralPath $script:TaskFile -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($content)) {
            return
        }

        $items = ConvertFrom-Json -InputObject $content
        foreach ($item in @($items)) {
            if ($null -eq $item -or [string]::IsNullOrWhiteSpace([string]$item.Text)) {
                continue
            }

            $task = [pscustomobject]@{
                Id        = if ($item.Id) { [string]$item.Id } else { [guid]::NewGuid().ToString() }
                Text      = [string]$item.Text
                Completed = [bool]$item.Completed
                Deadline  = if ($item.PSObject.Properties.Name -contains 'Deadline' -and $item.Deadline) { [string]$item.Deadline } else { $null }
                CreatedAt = if ($item.CreatedAt) { [string]$item.CreatedAt } else { [DateTime]::Now.ToString('o') }
            }
            [void]$script:Tasks.Add($task)
        }
    }
    catch {
        $backupPath = "$($script:TaskFile).broken-$([DateTime]::Now.ToString('yyyyMMdd-HHmmss'))"
        Copy-Item -LiteralPath $script:TaskFile -Destination $backupPath -Force -ErrorAction SilentlyContinue
    }
}

function Save-Tasks {
    Ensure-DataDirectory
    $json = ConvertTo-Json -InputObject @($script:Tasks) -Depth 4
    Set-Content -LiteralPath $script:TaskFile -Value $json -Encoding UTF8
}

function Read-Settings {
    if (-not (Test-Path -LiteralPath $script:SettingsFile)) {
        return $null
    }

    try {
        $content = Get-Content -Raw -LiteralPath $script:SettingsFile -Encoding UTF8
        if (-not [string]::IsNullOrWhiteSpace($content)) {
            return ConvertFrom-Json -InputObject $content
        }
    }
    catch {
        return $null
    }

    return $null
}

function Save-Settings {
    Ensure-DataDirectory
    $bounds = $window.RestoreBounds
    $settings = [pscustomobject]@{
        Left    = [double]$bounds.Left
        Top     = [double]$bounds.Top
        Width   = [double]$bounds.Width
        Height  = [double]$bounds.Height
        Topmost = [bool]$window.Topmost
        Theme   = [string]$script:CurrentThemeKey
    }
    Set-Content -LiteralPath $script:SettingsFile -Value (ConvertTo-Json $settings) -Encoding UTF8
}

function Get-TaskById([string]$Id) {
    return $script:Tasks | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
}

function Get-LauncherPath {
    $launcherPath = Join-Path $PSScriptRoot '启动桌面待办.vbs'
    if (-not (Test-Path -LiteralPath $launcherPath)) {
        throw '找不到启动文件。'
    }
    return $launcherPath
}

function Get-StartupShortcutPath {
    $startupDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)
    if ([string]::IsNullOrWhiteSpace($startupDirectory)) {
        throw '无法找到 Windows 启动文件夹。'
    }
    return Join-Path $startupDirectory '我的小清单.lnk'
}

function New-ApplicationShortcut([string]$ShortcutPath) {
    $launcherPath = Get-LauncherPath
    $wscriptPath = Join-Path $env:WINDIR 'System32\wscript.exe'
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = $wscriptPath
    $shortcut.Arguments = "`"$launcherPath`""
    $shortcut.WorkingDirectory = $PSScriptRoot
    $shortcut.Description = '打开我的小清单'
    $shortcut.IconLocation = "$env:SystemRoot\System32\imageres.dll,102"
    $shortcut.Save()
}

function Test-AutoStartEnabled {
    try {
        if (Test-Path -LiteralPath (Get-StartupShortcutPath)) {
            return $true
        }

        # 兼容并迁移旧版本使用的注册表启动项。
        $legacyValue = (Get-ItemProperty -LiteralPath $script:StartupRegistryPath -Name $script:StartupValueName -ErrorAction SilentlyContinue).$($script:StartupValueName)
        return -not [string]::IsNullOrWhiteSpace([string]$legacyValue)
    }
    catch {
        return $false
    }
}

function Set-AutoStart([bool]$Enabled) {
    $startupShortcutPath = Get-StartupShortcutPath
    if ($Enabled) {
        New-ApplicationShortcut $startupShortcutPath
    }
    else {
        Remove-Item -LiteralPath $startupShortcutPath -Force -ErrorAction SilentlyContinue
    }

    # 清理旧版本的注册表启动项，避免开机时重复打开。
    Remove-ItemProperty -LiteralPath $script:StartupRegistryPath -Name $script:StartupValueName -ErrorAction SilentlyContinue
}

function Get-DesktopShortcutPath {
    $desktopDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::Desktop)
    if ([string]::IsNullOrWhiteSpace($desktopDirectory)) {
        throw '无法找到桌面文件夹。'
    }
    return Join-Path $desktopDirectory '我的小清单.lnk'
}

function Test-DesktopShortcutExists {
    try {
        return Test-Path -LiteralPath (Get-DesktopShortcutPath)
    }
    catch {
        return $false
    }
}

function New-DesktopShortcut {
    $shortcutPath = Get-DesktopShortcutPath
    New-ApplicationShortcut $shortcutPath
    return $shortcutPath
}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="我的小清单"
        Width="400" Height="600" MinWidth="340" MinHeight="400"
        WindowStyle="None" ResizeMode="CanResizeWithGrip"
        WindowStartupLocation="CenterScreen"
        Background="Transparent" AllowsTransparency="True"
        ShowInTaskbar="True">
    <Window.Resources>
        <SolidColorBrush x:Key="AccentBrush" Color="#8B7FD6"/>
        <SolidColorBrush x:Key="TextBrush" Color="#4A405A"/>
        <SolidColorBrush x:Key="MutedBrush" Color="#8C8398"/>
        <LinearGradientBrush x:Key="MainSurfaceBrush" StartPoint="0,0" EndPoint="1,1">
            <GradientStop Color="#DDFEF7FB" Offset="0"/>
            <GradientStop Color="#DDEFEAFF" Offset="1"/>
        </LinearGradientBrush>

        <Style TargetType="Button">
            <Setter Property="FontFamily" Value="Microsoft YaHei UI"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="#796F88"/>
            <Setter Property="Padding" Value="8,5"/>
        </Style>
        <Style x:Key="WindowButtonStyle" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Width" Value="34"/>
            <Setter Property="Height" Value="30"/>
            <Setter Property="FontSize" Value="16"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="ButtonBorder" CornerRadius="10" Background="{TemplateBinding Background}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="ButtonBorder" Property="Background" Value="#70FFFFFF"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="PrimaryButtonStyle" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="FontSize" Value="22"/>
            <Setter Property="FontWeight" Value="Light"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="ButtonBorder" CornerRadius="16" Background="{TemplateBinding Background}">
                            <Border.Effect>
                                <DropShadowEffect BlurRadius="10" ShadowDepth="2" Opacity="0.20" Color="#8B7FD6"/>
                            </Border.Effect>
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="ButtonBorder" Property="Opacity" Value="0.82"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="SoftButtonStyle" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="#70FFFFFF"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="ButtonBorder" CornerRadius="10" Padding="{TemplateBinding Padding}"
                                Background="{TemplateBinding Background}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="ButtonBorder" Property="Background" Value="#B5FFFFFF"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="PinToggleStyle" TargetType="ToggleButton">
            <Setter Property="FontFamily" Value="Microsoft YaHei UI"/>
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="Foreground" Value="#796F88"/>
            <Setter Property="Background" Value="#72FFFFFF"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ToggleButton">
                        <Border x:Name="Pill" CornerRadius="12" Padding="10,5" Background="{TemplateBinding Background}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="Pill" Property="Background" Value="#C9F3B5CA"/>
                                <Setter Property="Foreground" Value="#725069"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Pill" Property="Opacity" Value="0.82"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="ThemeComboBoxItemStyle" TargetType="ComboBoxItem">
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBoxItem">
                        <Border x:Name="ItemBubble" CornerRadius="12" Margin="2" Padding="5"
                                Background="Transparent">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="ItemBubble" Property="Background" Value="#70FFFFFF"/>
                            </Trigger>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="ItemBubble" Property="Background" Value="#A0FFFFFF"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="ThemeComboBoxStyle" TargetType="ComboBox">
            <Setter Property="Width" Value="42"/>
            <Setter Property="Height" Value="28"/>
            <Setter Property="Background" Value="#30FFFFFF"/>
            <Setter Property="BorderBrush" Value="#66FFFFFF"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="ItemContainerStyle" Value="{StaticResource ThemeComboBoxItemStyle}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBox">
                        <Grid>
                            <ToggleButton x:Name="ThemeToggle" Focusable="False" ClickMode="Press"
                                          IsChecked="{Binding IsDropDownOpen, RelativeSource={RelativeSource TemplatedParent}, Mode=TwoWay}">
                                <ToggleButton.Template>
                                    <ControlTemplate TargetType="ToggleButton">
                                        <Border x:Name="ThemePill" CornerRadius="14"
                                                Background="{Binding Background, RelativeSource={RelativeSource AncestorType=ComboBox}}"
                                                BorderBrush="{Binding BorderBrush, RelativeSource={RelativeSource AncestorType=ComboBox}}"
                                                BorderThickness="{Binding BorderThickness, RelativeSource={RelativeSource AncestorType=ComboBox}}">
                                            <TextBlock Text="🎨" HorizontalAlignment="Center" VerticalAlignment="Center"
                                                       FontFamily="Segoe UI Emoji" FontSize="14"/>
                                        </Border>
                                        <ControlTemplate.Triggers>
                                            <Trigger Property="IsMouseOver" Value="True">
                                                <Setter TargetName="ThemePill" Property="Background" Value="#70FFFFFF"/>
                                            </Trigger>
                                            <Trigger Property="IsChecked" Value="True">
                                                <Setter TargetName="ThemePill" Property="Background" Value="#88FFFFFF"/>
                                            </Trigger>
                                        </ControlTemplate.Triggers>
                                    </ControlTemplate>
                                </ToggleButton.Template>
                            </ToggleButton>
                            <Popup x:Name="PART_Popup" IsOpen="{TemplateBinding IsDropDownOpen}"
                                   Placement="Bottom" PlacementTarget="{Binding ElementName=ThemeToggle}"
                                   AllowsTransparency="True" PopupAnimation="Fade" StaysOpen="False">
                                <Border Margin="0,5,0,0" Padding="4" CornerRadius="14"
                                        Background="#D9FFFFFF" BorderBrush="#88FFFFFF" BorderThickness="1">
                                    <Border.Effect>
                                        <DropShadowEffect BlurRadius="14" ShadowDepth="2" Opacity="0.16" Color="#6B587F"/>
                                    </Border.Effect>
                                    <ScrollViewer>
                                        <ItemsPresenter/>
                                    </ScrollViewer>
                                </Border>
                            </Popup>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="FontFamily" Value="Microsoft YaHei UI"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Background" Value="Transparent"/>
        </Style>
        <Style x:Key="DeadlineTextBoxStyle" TargetType="TextBox" BasedOn="{StaticResource {x:Type TextBox}}">
            <Setter Property="FontFamily" Value="Microsoft YaHei UI"/>
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="Foreground" Value="{StaticResource MutedBrush}"/>
            <Setter Property="Background" Value="#9EFFFFFF"/>
            <Setter Property="BorderBrush" Value="#80CFC7DB"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="7,4"/>
            <Setter Property="TextAlignment" Value="Center"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <Border x:Name="DeadlineBorder" CornerRadius="10"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}">
                            <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsKeyboardFocused" Value="True">
                                <Setter TargetName="DeadlineBorder" Property="BorderBrush" Value="#E88EAD"/>
                                <Setter TargetName="DeadlineBorder" Property="Background" Value="#DFFFFFFF"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="CheckBox">
            <Setter Property="FontFamily" Value="Microsoft YaHei UI"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>
                            <Border x:Name="CheckShape" Width="19" Height="19" CornerRadius="7"
                                    BorderBrush="#B6AACC" BorderThickness="1.5" Background="#78FFFFFF">
                                <Path x:Name="CheckMark" Data="M 4,9 L 8,13 L 15,5" Stroke="White"
                                      StrokeThickness="2.2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                                      Visibility="Collapsed"/>
                            </Border>
                            <ContentPresenter Grid.Column="1" Margin="8,0,0,0" VerticalAlignment="Center"/>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="CheckShape" Property="Background" Value="#9B8BD8"/>
                                <Setter TargetName="CheckShape" Property="BorderBrush" Value="#9B8BD8"/>
                                <Setter TargetName="CheckMark" Property="Visibility" Value="Visible"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="CheckShape" Property="BorderBrush" Value="#E88EAD"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Border x:Name="MainBorder" CornerRadius="24" Background="{StaticResource MainSurfaceBrush}" BorderBrush="#AFFFFFFF" BorderThickness="1">
        <Border.Effect>
            <DropShadowEffect BlurRadius="30" ShadowDepth="5" Opacity="0.22" Color="#6B587F"/>
        </Border.Effect>
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="70"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <Grid x:Name="TitleBar" Grid.Row="0" Background="Transparent">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel Margin="20,10,0,0" VerticalAlignment="Center">
                    <TextBlock Text="🌷 我的小清单" FontFamily="Microsoft YaHei UI"
                               FontSize="17" FontWeight="SemiBold" Foreground="{StaticResource TextBrush}"/>
                    <TextBlock Text="MY LITTLE TODO" Margin="27,2,0,0" FontFamily="Segoe UI"
                               FontSize="9" Foreground="#A195AE"/>
                </StackPanel>
                <ToggleButton x:Name="PinButton" Grid.Column="1" Height="27" Margin="0,0,4,0"
                              Style="{StaticResource PinToggleStyle}" ToolTip="保持窗口置顶" Content="♡ 置顶"/>
                <Button x:Name="MinimizeButton" Grid.Column="2" Style="{StaticResource WindowButtonStyle}"
                        Content="—" ToolTip="最小化"/>
                <Button x:Name="CloseButton" Grid.Column="3" Margin="0,0,10,0"
                        Style="{StaticResource WindowButtonStyle}" Content="×" ToolTip="关闭"/>
            </Grid>

            <Grid Grid.Row="1" Margin="18,3,18,15">
                <Border x:Name="NewTaskBorder" CornerRadius="18" Background="#CAFFFFFF" BorderBrush="#A8FFFFFF" BorderThickness="1">
                    <Border.Effect>
                        <DropShadowEffect BlurRadius="14" ShadowDepth="2" Opacity="0.10" Color="#7F6A93"/>
                    </Border.Effect>
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="56"/>
                        </Grid.ColumnDefinitions>
                        <TextBox x:Name="NewTaskTextBox" Margin="15,13,4,10" FontSize="14"
                                 VerticalContentAlignment="Center" ToolTip="输入任务后按回车"/>
                        <TextBlock x:Name="InputHint" Grid.Row="0" Grid.Column="0" Margin="16,2,0,0"
                                   VerticalAlignment="Center" IsHitTestVisible="False"
                                   Text="写下一件小事吧…" FontFamily="Microsoft YaHei UI"
                                   FontSize="14" Foreground="#AAA0B6"/>
                        <StackPanel Grid.Row="1" Grid.Column="0" Margin="15,0,4,12" Orientation="Horizontal">
                            <TextBlock Text="⏰ DDL" Margin="1,0,8,0" VerticalAlignment="Center"
                                       FontFamily="Microsoft YaHei UI" FontSize="11" Foreground="#8C8398"/>
                            <TextBox x:Name="NewDeadlineTextBox" Width="135" Height="27"
                                     Style="{StaticResource DeadlineTextBoxStyle}"
                                     ToolTip="填写截止日期" MaxLength="10"/>
                        </StackPanel>
                        <Button x:Name="AddButton" Grid.RowSpan="2" Grid.Column="1" Margin="5,7,7,7" Padding="0"
                                Style="{StaticResource PrimaryButtonStyle}" Background="#998B7FD6"
                                Content="＋" ToolTip="添加任务"/>
                    </Grid>
                </Border>
            </Grid>

            <Grid Grid.Row="2">
                <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"
                              Margin="9,0,9,0">
                    <StackPanel x:Name="TaskPanel" Margin="9,0,9,9"/>
                </ScrollViewer>
                <StackPanel x:Name="EmptyState" VerticalAlignment="Center" HorizontalAlignment="Center"
                            IsHitTestVisible="False">
                    <TextBlock Text="☁" HorizontalAlignment="Center" FontFamily="Segoe UI Symbol"
                               FontSize="48" Foreground="#BFB6D4"/>
                    <TextBlock Text="今天也可以慢慢来 ♡" HorizontalAlignment="Center" Margin="0,7,0,0"
                               FontFamily="Microsoft YaHei UI" FontSize="13" Foreground="#968CA3"/>
                </StackPanel>
            </Grid>

            <Border Grid.Row="3" Margin="18,0,18,0" BorderBrush="#66CFC7DB" BorderThickness="0,1,0,0">
                <Grid Margin="2,11,2,11">
                    <TextBlock x:Name="SummaryText" VerticalAlignment="Center"
                               FontFamily="Microsoft YaHei UI" FontSize="12" Foreground="{StaticResource MutedBrush}"/>
                    <Button x:Name="ClearCompletedButton" HorizontalAlignment="Right" Padding="8,4"
                            Style="{StaticResource SoftButtonStyle}" Content="清除已完成" FontSize="11"/>
                </Grid>
            </Border>

            <Border x:Name="FooterBorder" Grid.Row="4" Background="#55FFFFFF" CornerRadius="0,0,24,24">
                <Grid Margin="20,9">
                    <CheckBox x:Name="AutoStartCheckBox" Content="每天开机陪着我"
                              VerticalAlignment="Center" FontSize="12" Foreground="{StaticResource MutedBrush}"/>
                    <StackPanel HorizontalAlignment="Right" Orientation="Horizontal">
                        <Button x:Name="CreateShortcutButton" Margin="0,0,7,0" Padding="8,4"
                                Style="{StaticResource SoftButtonStyle}" Content="☆ 桌面"
                                FontSize="11" ToolTip="添加桌面快捷方式"/>
                        <ComboBox x:Name="ThemeComboBox" SelectedIndex="0"
                                  Style="{StaticResource ThemeComboBoxStyle}" ToolTip="选择配色">
                            <ComboBoxItem Tag="sakura"><Ellipse Width="20" Height="20" Fill="#E58AA8" ToolTip="樱花粉"/></ComboBoxItem>
                            <ComboBoxItem Tag="lavender"><Ellipse Width="20" Height="20" Fill="#8B7FD6" ToolTip="薰衣草紫"/></ComboBoxItem>
                            <ComboBoxItem Tag="mint"><Ellipse Width="20" Height="20" Fill="#6FBF9C" ToolTip="薄荷绿"/></ComboBoxItem>
                            <ComboBoxItem Tag="sky"><Ellipse Width="20" Height="20" Fill="#6BA9D6" ToolTip="晴空蓝"/></ComboBoxItem>
                            <ComboBoxItem Tag="cream"><Ellipse Width="20" Height="20" Fill="#D99A61" ToolTip="奶油橙"/></ComboBoxItem>
                        </ComboBox>
                    </StackPanel>
                </Grid>
            </Border>
        </Grid>
    </Border>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$MainBorder = $window.FindName('MainBorder')
$TitleBar = $window.FindName('TitleBar')
$PinButton = $window.FindName('PinButton')
$MinimizeButton = $window.FindName('MinimizeButton')
$CloseButton = $window.FindName('CloseButton')
$NewTaskTextBox = $window.FindName('NewTaskTextBox')
$InputHint = $window.FindName('InputHint')
$NewDeadlineTextBox = $window.FindName('NewDeadlineTextBox')
$NewTaskBorder = $window.FindName('NewTaskBorder')
$AddButton = $window.FindName('AddButton')
$TaskPanel = $window.FindName('TaskPanel')
$EmptyState = $window.FindName('EmptyState')
$SummaryText = $window.FindName('SummaryText')
$ClearCompletedButton = $window.FindName('ClearCompletedButton')
$AutoStartCheckBox = $window.FindName('AutoStartCheckBox')
$CreateShortcutButton = $window.FindName('CreateShortcutButton')
$FooterBorder = $window.FindName('FooterBorder')
$ThemeComboBox = $window.FindName('ThemeComboBox')

$script:Themes = @{
    sakura = [pscustomobject]@{
        SurfaceStart = '#DDFEF1F6'; SurfaceEnd = '#DDF8E5EC'; Accent = '#E58AA8'
        Input = '#D9FFF8FB'; Footer = '#66FFF1F6'
        Cards = @('#DDFCE8F0', '#DFFFF1F5', '#DDF7E2EB', '#DDFFE9E1', '#DDF4E8F5')
        Borders = @('#99EEA9C0', '#99E7B9C8', '#99DFA6BA', '#99ECBDAE', '#99CFB3D8')
    }
    lavender = [pscustomobject]@{
        SurfaceStart = '#DDFEF7FB'; SurfaceEnd = '#DDEFEAFF'; Accent = '#8B7FD6'
        Input = '#D9FFFFFF'; Footer = '#55FFFFFF'
        Cards = @('#DDFCEEF5', '#DDEFEAFF', '#DDEBF7FF', '#DDFFF5D8', '#DDE7F8EF')
        Borders = @('#99F1B5C9', '#99C9BDEB', '#99B8DCEA', '#99EAD99B', '#99B8DFC9')
    }
    mint = [pscustomobject]@{
        SurfaceStart = '#DDEFFAF5'; SurfaceEnd = '#DDE3F4EC'; Accent = '#6FBF9C'
        Input = '#D9F8FFFB'; Footer = '#66E8F8F0'
        Cards = @('#DDE3F7ED', '#DDEAF9F4', '#DDF3FBEA', '#DDE1F5F2', '#DDFFF6DE')
        Borders = @('#999DD5BA', '#99AFDCCB', '#99BEDCA8', '#999ED5CE', '#99E2D29D')
    }
    sky = [pscustomobject]@{
        SurfaceStart = '#DDECF8FE'; SurfaceEnd = '#DDE1EFFA'; Accent = '#6BA9D6'
        Input = '#D9F7FCFF'; Footer = '#66E9F5FC'
        Cards = @('#DDE2F3FC', '#DDEBF7FF', '#DDE1EDF9', '#DDF0F7FF', '#DDE8F1FC')
        Borders = @('#999BCBE5', '#99ACD2E8', '#999EBFDA', '#99B5CEE4', '#99A8C2DD')
    }
    cream = [pscustomobject]@{
        SurfaceStart = '#DDFFF7E9'; SurfaceEnd = '#DDFBE9DA'; Accent = '#D99A61'
        Input = '#D9FFFCF5'; Footer = '#66FFF1DF'
        Cards = @('#DDFFF0D8', '#DDFFE8D8', '#DDFAF3D8', '#DDFFEEDC', '#DDF5E7D8')
        Borders = @('#99E4BD86', '#99E5AF8D', '#99D6C18A', '#99E7B991', '#99CDB497')
    }
}
$script:CurrentThemeKey = 'lavender'
$script:ActiveCardColors = @($script:Themes.lavender.Cards)
$script:ActiveCardBorders = @($script:Themes.lavender.Borders)

function Apply-Theme([string]$ThemeKey) {
    if (-not $script:Themes.ContainsKey($ThemeKey)) {
        $ThemeKey = 'lavender'
    }

    $theme = $script:Themes[$ThemeKey]
    $script:CurrentThemeKey = $ThemeKey
    $script:ActiveCardColors = @($theme.Cards)
    $script:ActiveCardBorders = @($theme.Borders)

    $gradient = New-Object System.Windows.Media.LinearGradientBrush
    $gradient.StartPoint = [System.Windows.Point]::new(0, 0)
    $gradient.EndPoint = [System.Windows.Point]::new(1, 1)
    [void]$gradient.GradientStops.Add((New-Object System.Windows.Media.GradientStop -Property @{
        Color = [System.Windows.Media.ColorConverter]::ConvertFromString($theme.SurfaceStart); Offset = 0
    }))
    [void]$gradient.GradientStops.Add((New-Object System.Windows.Media.GradientStop -Property @{
        Color = [System.Windows.Media.ColorConverter]::ConvertFromString($theme.SurfaceEnd); Offset = 1
    }))

    $MainBorder.Background = $gradient
    $AddButton.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($theme.Accent)
    $NewTaskBorder.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($theme.Input)
    $FooterBorder.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($theme.Footer)
}

function Update-InputHint {
    $InputHint.Visibility = if ([string]::IsNullOrEmpty($NewTaskTextBox.Text)) { 'Visible' } else { 'Collapsed' }
}

function Update-Summary {
    $total = $script:Tasks.Count
    $completed = @($script:Tasks | Where-Object Completed).Count
    $remaining = $total - $completed
    $today = [DateTime]::Today
    $overdue = @($script:Tasks | Where-Object {
        -not $_.Completed -and $_.Deadline -and ([DateTime]::ParseExact($_.Deadline, 'yyyy-MM-dd', $null) -lt $today)
    }).Count

    if ($total -eq 0) {
        $SummaryText.Text = '今天从一件小事开始'
    }
    elseif ($remaining -eq 0) {
        $SummaryText.Text = "全部完成，共 $total 项"
    }
    else {
        $SummaryText.Text = "待完成 $remaining 项 · 已完成 $completed 项"
        if ($overdue -gt 0) {
            $SummaryText.Text += " · 逾期 $overdue 项"
        }
    }

    $ClearCompletedButton.Visibility = if ($completed -gt 0) { 'Visible' } else { 'Collapsed' }
}

function ConvertTo-NormalizedDeadline([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $formats = @('yyyy-MM-dd', 'yyyy/M/d', 'yyyy.M.d', 'yyyyMMdd')
    foreach ($format in $formats) {
        $parsedDate = [DateTime]::MinValue
        if ([DateTime]::TryParseExact(
            $Text.Trim(),
            $format,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None,
            [ref]$parsedDate
        )) {
            return $parsedDate.Date.ToString('yyyy-MM-dd')
        }
    }

    return $null
}

function Set-DeadlineAppearance($DeadlineTextBox, [bool]$Completed) {
    $DeadlineTextBox.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#8C8398')
    $DeadlineTextBox.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#80CFC7DB')
    $DeadlineTextBox.ToolTip = '填写或清除 DDL'
    $DeadlineTextBox.Opacity = if ($Completed) { 0.65 } else { 1 }

    if ([string]::IsNullOrWhiteSpace($DeadlineTextBox.Text)) {
        return
    }

    $normalizedDeadline = ConvertTo-NormalizedDeadline $DeadlineTextBox.Text
    if ($null -eq $normalizedDeadline) {
        $DeadlineTextBox.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#E45C7B')
        $DeadlineTextBox.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#E45C7B')
        $DeadlineTextBox.ToolTip = '日期无效，请重新填写'
        return
    }

    if ($Completed) {
        return
    }

    $deadline = [DateTime]::ParseExact($normalizedDeadline, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    if ($deadline -lt [DateTime]::Today) {
        $DeadlineTextBox.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#E45C7B')
        $DeadlineTextBox.ToolTip = 'DDL 已逾期'
    }
    elseif ($deadline -eq [DateTime]::Today) {
        $DeadlineTextBox.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#C98235')
        $DeadlineTextBox.ToolTip = 'DDL 是今天'
    }
}

function Set-TaskTextAppearance($TextBox, [bool]$Completed) {
    if ($Completed) {
        $TextBox.TextDecorations = [System.Windows.TextDecorations]::Strikethrough
        $TextBox.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#9D96A8')
        $TextBox.Opacity = 0.65
    }
    else {
        $TextBox.TextDecorations = $null
        $TextBox.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#4A405A')
        $TextBox.Opacity = 1
    }
}

function Render-Tasks {
    $TaskPanel.Children.Clear()
    $EmptyState.Visibility = if ($script:Tasks.Count -eq 0) { 'Visible' } else { 'Collapsed' }

    $cardColors = $script:ActiveCardColors
    $cardBorders = $script:ActiveCardBorders
    $taskIndex = 0
    foreach ($task in @($script:Tasks)) {
        $rowBorder = New-Object System.Windows.Controls.Border
        $colorIndex = $taskIndex % $cardColors.Count
        $rowBorder.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($cardColors[$colorIndex])
        $rowBorder.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($cardBorders[$colorIndex])
        $rowBorder.BorderThickness = '1'
        $rowBorder.CornerRadius = '15'
        $rowBorder.Margin = '0,0,0,10'
        $rowBorder.Padding = '11,9,7,9'
        $rowBorder.Effect = New-Object System.Windows.Media.Effects.DropShadowEffect -Property @{
            BlurRadius = 10
            ShadowDepth = 2
            Opacity = 0.08
            Color = [System.Windows.Media.ColorConverter]::ConvertFromString('#6B587F')
        }

        $grid = New-Object System.Windows.Controls.Grid
        [void]$grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{ Height = 'Auto' }))
        [void]$grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{ Height = 'Auto' }))
        [void]$grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = '34' }))
        [void]$grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = '*' }))
        [void]$grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = '38' }))

        $checkBox = New-Object System.Windows.Controls.CheckBox
        $checkBox.VerticalAlignment = 'Center'
        $checkBox.HorizontalAlignment = 'Center'
        $checkBox.IsChecked = [bool]$task.Completed
        $checkBox.Tag = [string]$task.Id
        [System.Windows.Controls.Grid]::SetRowSpan($checkBox, 2)

        $textBox = New-Object System.Windows.Controls.TextBox
        $textBox.Text = [string]$task.Text
        $textBox.Tag = [string]$task.Id
        $textBox.Margin = '3,3,3,3'
        $textBox.Padding = '2'
        $textBox.VerticalContentAlignment = 'Center'
        $textBox.TextWrapping = 'Wrap'
        $textBox.AcceptsReturn = $false
        $textBox.ToolTip = '点击文字即可编辑'
        Set-TaskTextAppearance $textBox ([bool]$task.Completed)

        $deadlinePanel = New-Object System.Windows.Controls.StackPanel
        $deadlinePanel.Orientation = 'Horizontal'
        $deadlinePanel.Margin = '5,1,3,2'

        $deadlineLabel = New-Object System.Windows.Controls.TextBlock
        $deadlineLabel.Text = '⏰ DDL'
        $deadlineLabel.FontFamily = 'Microsoft YaHei UI'
        $deadlineLabel.FontSize = 11
        $deadlineLabel.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#8C8398')
        $deadlineLabel.VerticalAlignment = 'Center'
        $deadlineLabel.Margin = '0,0,7,0'

        $deadlineTextBox = New-Object System.Windows.Controls.TextBox
        $deadlineTextBox.Style = $window.FindResource('DeadlineTextBoxStyle')
        $deadlineTextBox.Width = 128
        $deadlineTextBox.Height = 25
        $deadlineTextBox.MaxLength = 10
        $deadlineTextBox.Text = if ($task.Deadline) { [string]$task.Deadline } else { '' }
        $deadlineTextBox.Tag = [string]$task.Id
        Set-DeadlineAppearance $deadlineTextBox ([bool]$task.Completed)
        [void]$deadlinePanel.Children.Add($deadlineLabel)
        [void]$deadlinePanel.Children.Add($deadlineTextBox)

        $deleteButton = New-Object System.Windows.Controls.Button
        $deleteButton.Content = '✕'
        $deleteButton.Tag = [string]$task.Id
        $deleteButton.ToolTip = '删除任务'
        $deleteButton.FontSize = 16
        $deleteButton.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#B198AC')
        [System.Windows.Controls.Grid]::SetRowSpan($deleteButton, 2)

        [System.Windows.Controls.Grid]::SetColumn($checkBox, 0)
        [System.Windows.Controls.Grid]::SetColumn($textBox, 1)
        [System.Windows.Controls.Grid]::SetRow($deadlinePanel, 1)
        [System.Windows.Controls.Grid]::SetColumn($deadlinePanel, 1)
        [System.Windows.Controls.Grid]::SetColumn($deleteButton, 2)
        [void]$grid.Children.Add($checkBox)
        [void]$grid.Children.Add($textBox)
        [void]$grid.Children.Add($deadlinePanel)
        [void]$grid.Children.Add($deleteButton)
        $rowBorder.Child = $grid
        [void]$TaskPanel.Children.Add($rowBorder)
        $taskIndex++

        $checkBox.Add_Checked({
            param($sender, $eventArgs)
            $currentTask = Get-TaskById ([string]$sender.Tag)
            if ($null -ne $currentTask) {
                $currentTask.Completed = $true
                $taskTextBox = ($sender.Parent.Children | Where-Object { $_ -is [System.Windows.Controls.TextBox] } | Select-Object -First 1)
                $taskDeadlineTextBox = ($sender.Parent.Children | ForEach-Object { if ($_ -is [System.Windows.Controls.StackPanel]) { $_.Children } } | Where-Object { $_ -is [System.Windows.Controls.TextBox] } | Select-Object -First 1)
                Set-TaskTextAppearance $taskTextBox $true
                Set-DeadlineAppearance $taskDeadlineTextBox $true
                Save-Tasks
                Update-Summary
            }
        })

        $checkBox.Add_Unchecked({
            param($sender, $eventArgs)
            $currentTask = Get-TaskById ([string]$sender.Tag)
            if ($null -ne $currentTask) {
                $currentTask.Completed = $false
                $taskTextBox = ($sender.Parent.Children | Where-Object { $_ -is [System.Windows.Controls.TextBox] } | Select-Object -First 1)
                $taskDeadlineTextBox = ($sender.Parent.Children | ForEach-Object { if ($_ -is [System.Windows.Controls.StackPanel]) { $_.Children } } | Where-Object { $_ -is [System.Windows.Controls.TextBox] } | Select-Object -First 1)
                Set-TaskTextAppearance $taskTextBox $false
                Set-DeadlineAppearance $taskDeadlineTextBox $false
                Save-Tasks
                Update-Summary
            }
        })

        $textBox.Add_LostKeyboardFocus({
            param($sender, $eventArgs)
            $currentTask = Get-TaskById ([string]$sender.Tag)
            if ($null -eq $currentTask) {
                return
            }

            $newText = $sender.Text.Trim()
            if ([string]::IsNullOrWhiteSpace($newText)) {
                $sender.Text = $currentTask.Text
                return
            }

            $currentTask.Text = $newText
            $sender.Text = $newText
            Save-Tasks
        })

        $textBox.Add_KeyDown({
            param($sender, $eventArgs)
            if ($eventArgs.Key -eq [System.Windows.Input.Key]::Enter) {
                [System.Windows.Input.Keyboard]::ClearFocus()
                $eventArgs.Handled = $true
            }
        })

        $deadlineTextBox.Add_LostKeyboardFocus({
            param($sender, $eventArgs)
            $currentTask = Get-TaskById ([string]$sender.Tag)
            if ($null -ne $currentTask) {
                if ([string]::IsNullOrWhiteSpace($sender.Text)) {
                    $currentTask.Deadline = $null
                    $sender.Text = ''
                    Set-DeadlineAppearance $sender ([bool]$currentTask.Completed)
                    Save-Tasks
                    Update-Summary
                    return
                }

                $normalizedDeadline = ConvertTo-NormalizedDeadline $sender.Text
                if ($null -eq $normalizedDeadline) {
                    Set-DeadlineAppearance $sender ([bool]$currentTask.Completed)
                    return
                }

                $currentTask.Deadline = $normalizedDeadline
                $sender.Text = $normalizedDeadline
                Set-DeadlineAppearance $sender ([bool]$currentTask.Completed)
                Save-Tasks
                Update-Summary
            }
        })

        $deadlineTextBox.Add_KeyDown({
            param($sender, $eventArgs)
            if ($eventArgs.Key -eq [System.Windows.Input.Key]::Enter) {
                [System.Windows.Input.Keyboard]::ClearFocus()
                $eventArgs.Handled = $true
            }
        })

        $deleteButton.Add_Click({
            param($sender, $eventArgs)
            $currentTask = Get-TaskById ([string]$sender.Tag)
            if ($null -ne $currentTask) {
                [void]$script:Tasks.Remove($currentTask)
                Save-Tasks
                Render-Tasks
            }
        })
    }

    Update-Summary
}

function Add-NewTask {
    $text = $NewTaskTextBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return
    }

    $deadlineValue = $null
    if (-not [string]::IsNullOrWhiteSpace($NewDeadlineTextBox.Text)) {
        $deadlineValue = ConvertTo-NormalizedDeadline $NewDeadlineTextBox.Text
        if ($null -eq $deadlineValue) {
            Set-DeadlineAppearance $NewDeadlineTextBox $false
            $NewDeadlineTextBox.Focus() | Out-Null
            return
        }
    }

    $task = [pscustomobject]@{
        Id        = [guid]::NewGuid().ToString()
        Text      = $text
        Completed = $false
        Deadline  = $deadlineValue
        CreatedAt = [DateTime]::Now.ToString('o')
    }
    $script:Tasks.Insert(0, $task)
    $NewTaskTextBox.Clear()
    $NewDeadlineTextBox.Clear()
    Update-InputHint
    Save-Tasks
    Render-Tasks
    $NewTaskTextBox.Focus() | Out-Null
}

Read-Tasks
$settings = Read-Settings

if ($null -ne $settings) {
    if ($settings.Width -ge 320) { $window.Width = [double]$settings.Width }
    if ($settings.Height -ge 360) { $window.Height = [double]$settings.Height }
    if ($null -ne $settings.Left) { $window.Left = [double]$settings.Left }
    if ($null -ne $settings.Top) { $window.Top = [double]$settings.Top }
    $window.Topmost = [bool]$settings.Topmost
}

$initialTheme = 'lavender'
if ($null -ne $settings -and $settings.Theme -and $script:Themes.ContainsKey([string]$settings.Theme)) {
    $initialTheme = [string]$settings.Theme
}
for ($themeIndex = 0; $themeIndex -lt $ThemeComboBox.Items.Count; $themeIndex++) {
    if ([string]$ThemeComboBox.Items[$themeIndex].Tag -eq $initialTheme) {
        $ThemeComboBox.SelectedIndex = $themeIndex
        break
    }
}
Apply-Theme $initialTheme

$PinButton.IsChecked = $window.Topmost
$autoStartEnabled = Test-AutoStartEnabled
if ($autoStartEnabled -and -not $SelfTest) {
    try {
        # 自动刷新启动快捷方式的目标路径，并完成旧版注册表配置迁移。
        Set-AutoStart $true
    }
    catch {
        $autoStartEnabled = $false
    }
}
$AutoStartCheckBox.IsChecked = $autoStartEnabled
$AutoStartCheckBox.ToolTip = if ($autoStartEnabled) { '已开启：登录 Windows 后自动启动' } else { '已关闭：点击开启开机自动启动' }
$CreateShortcutButton.Content = if (Test-DesktopShortcutExists) { '✓ 已添加' } else { '☆ 桌面' }

$TitleBar.Add_MouseLeftButtonDown({
    param($sender, $eventArgs)
    if ($eventArgs.ClickCount -eq 2) {
        $window.WindowState = if ($window.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' }
    }
    else {
        $window.DragMove()
    }
})

$PinButton.Add_Checked({ $window.Topmost = $true; Save-Settings })
$PinButton.Add_Unchecked({ $window.Topmost = $false; Save-Settings })
$MinimizeButton.Add_Click({ $window.WindowState = 'Minimized' })
$CloseButton.Add_Click({ $window.Close() })
$AddButton.Add_Click({ Add-NewTask })
$CreateShortcutButton.Add_Click({
    try {
        $shortcutPath = New-DesktopShortcut
        $CreateShortcutButton.Content = '✓ 已添加'
        $CreateShortcutButton.ToolTip = "快捷方式已添加到：$shortcutPath"
    }
    catch {
        [System.Windows.MessageBox]::Show("无法创建桌面快捷方式：`n$($_.Exception.Message)", '我的小清单') | Out-Null
    }
})
$ThemeComboBox.Add_SelectionChanged({
    if ($null -eq $ThemeComboBox.SelectedItem) {
        return
    }

    $selectedTheme = [string]$ThemeComboBox.SelectedItem.Tag
    Apply-Theme $selectedTheme
    Render-Tasks
    Save-Settings
})
$NewTaskTextBox.Add_TextChanged({ Update-InputHint })
$NewDeadlineTextBox.Add_TextChanged({ Update-InputHint })
$NewDeadlineTextBox.Add_LostKeyboardFocus({
    if ([string]::IsNullOrWhiteSpace($NewDeadlineTextBox.Text)) {
        Set-DeadlineAppearance $NewDeadlineTextBox $false
        return
    }

    $normalizedDeadline = ConvertTo-NormalizedDeadline $NewDeadlineTextBox.Text
    if ($null -ne $normalizedDeadline) {
        $NewDeadlineTextBox.Text = $normalizedDeadline
    }
    Set-DeadlineAppearance $NewDeadlineTextBox $false
})
$NewDeadlineTextBox.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.Key -eq [System.Windows.Input.Key]::Enter) {
        Add-NewTask
        $eventArgs.Handled = $true
    }
})
$NewTaskTextBox.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.Key -eq [System.Windows.Input.Key]::Enter) {
        Add-NewTask
        $eventArgs.Handled = $true
    }
})

$ClearCompletedButton.Add_Click({
    $completedTasks = @($script:Tasks | Where-Object Completed)
    foreach ($task in $completedTasks) {
        [void]$script:Tasks.Remove($task)
    }
    Save-Tasks
    Render-Tasks
})

$AutoStartCheckBox.Add_Click({
    try {
        Set-AutoStart ([bool]$AutoStartCheckBox.IsChecked)
        $AutoStartCheckBox.ToolTip = if ($AutoStartCheckBox.IsChecked) {
            '已开启：登录 Windows 后自动启动'
        }
        else {
            '已关闭：点击开启开机自动启动'
        }
    }
    catch {
        $AutoStartCheckBox.IsChecked = Test-AutoStartEnabled
        [System.Windows.MessageBox]::Show("无法修改开机启动设置：`n$($_.Exception.Message)", '桌面待办') | Out-Null
    }
})

$window.Add_Closing({
    Save-Tasks
    Save-Settings
})

$window.Add_Closed({
    if ($script:OwnsInstanceMutex -and $null -ne $script:InstanceMutex) {
        try { $script:InstanceMutex.ReleaseMutex() } catch { }
        $script:InstanceMutex.Dispose()
        $script:OwnsInstanceMutex = $false
    }
})

$window.Add_ContentRendered({
    Render-Tasks
    Update-InputHint
    $NewTaskTextBox.Focus() | Out-Null
})

if ($SelfTest) {
    Read-Tasks
    if ((ConvertTo-NormalizedDeadline '2026/9/10') -ne '2026-09-10') {
        throw 'Deadline normalization self-test failed.'
    }
    if ($null -ne (ConvertTo-NormalizedDeadline '2026-99-99')) {
        throw 'Invalid deadline self-test failed.'
    }
    $testTask = [pscustomobject]@{
        Id        = [guid]::NewGuid().ToString()
        Text      = 'Self-test task'
        Completed = $false
        Deadline  = [DateTime]::Today.AddDays(1).ToString('yyyy-MM-dd')
        CreatedAt = [DateTime]::Now.ToString('o')
    }
    [void]$script:Tasks.Add($testTask)
    Render-Tasks
    if ($TaskPanel.Children.Count -lt 1) {
        throw 'Task rendering self-test failed.'
    }
    [void]$script:Tasks.Remove($testTask)
    Write-Output 'DesktopTodo self-test passed.'
    return
}

[void]$window.ShowDialog()
