<#
.SYNOPSIS
    Autopilot Registration Tool - Field Client
    Collects hardware hash and uploads to Autopilot via Azure Function proxy.

.DESCRIPTION
    Runs at Windows OOBE (Shift+F10) to register a device in Windows Autopilot.
    No external modules required - uses only .NET Framework classes.

.NOTES
    Version: 1.0.0
    License: MIT
    This file is a TEMPLATE. Use the Builder tool to generate a configured version.
#>

#Requires -Version 5.1

# Configuration (set by Builder tool, do not edit manually)

$Config = @{
    CompanyName  = 'Your Company'
    FunctionUrl  = 'https://your-function.azurewebsites.net'
    FunctionKey  = 'your-function-key-here'
    GroupTags    = @('Standard', 'Kiosk', 'Shared')
    DefaultTag   = 'Standard'
    Version      = '1.0.0'
}

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

function Get-AutopilotHardwareHash {
    try {
        $devDetail = Get-CimInstance -Namespace 'root/cimv2/mdm/dmmap' -Class 'MDM_DevDetail_Ext01' -Filter "InstanceID='Ext' AND ParentID='./DevDetail'" -ErrorAction Stop
        $hash = $devDetail.DeviceHardwareData

        $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
        $bios = Get-CimInstance -ClassName Win32_BIOS

        return @{
            HardwareHash = $hash
            SerialNumber = $bios.SerialNumber
            Model        = $computerSystem.Model
            Manufacturer = $computerSystem.Manufacturer
        }
    }
    catch {
        throw "Failed to collect hardware hash: $_"
    }
}

function Invoke-AutopilotUpload {
    param(
        [string]$HardwareHash,
        [string]$SerialNumber,
        [string]$GroupTag,
        [string]$Model,
        [string]$Manufacturer
    )

    $uri = "$($Config.FunctionUrl)/api/upload?code=$($Config.FunctionKey)"

    $body = @{
        hardwareHash = $HardwareHash
        serialNumber = $SerialNumber
        groupTag     = $GroupTag
        model        = $Model
        manufacturer = $Manufacturer
    } | ConvertTo-Json

    try {
        $response = Invoke-RestMethod -Uri $uri -Method POST -Body $body -ContentType 'application/json' -TimeoutSec 30
        return $response
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        if ($statusCode -eq 409) {
            throw "DUPLICATE: This device is already registered in Autopilot."
        }
        throw "Upload failed: $_"
    }
}

function Get-ImportStatus {
    param([string]$ImportId)

    $uri = "$($Config.FunctionUrl)/api/status/$($ImportId)?code=$($Config.FunctionKey)"

    try {
        $response = Invoke-RestMethod -Uri $uri -Method GET -TimeoutSec 15
        return $response
    }
    catch {
        return @{ status = 'error'; errorName = $_.Exception.Message }
    }
}

$script:LogPath = $null

function Initialize-Log {
    $usbDrives = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=2" | Select-Object -ExpandProperty DeviceID
    $logDir = if ($usbDrives) { "$($usbDrives[0])\AutopilotTool-Logs" } else { "$env:TEMP\AutopilotTool-Logs" }

    if (-not (Test-Path $logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    $script:LogPath = Join-Path $logDir "autopilot-$timestamp.log"
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    if ($script:LogPath) {
        Add-Content -Path $script:LogPath -Value $entry -ErrorAction SilentlyContinue
    }
}

function Show-MainWindow {
    Initialize-Log
    Write-Log "Autopilot Tool v$($Config.Version) started"

    $xamlString = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$($Config.CompanyName)"
        Width="520" Height="560"
        WindowStartupLocation="CenterScreen"
        ResizeMode="NoResize"
        Background="#1b1b1f">

    <Window.Resources>
        <SolidColorBrush x:Key="AccentBrush" Color="#0063b1"/>
        <SolidColorBrush x:Key="AccentHoverBrush" Color="#1a7ad4"/>
        <SolidColorBrush x:Key="AccentPressedBrush" Color="#004e8c"/>
        <SolidColorBrush x:Key="CardBgBrush" Color="#2b2d31"/>
        <SolidColorBrush x:Key="InputBgBrush" Color="#383a3e"/>
        <SolidColorBrush x:Key="InputBorderBrush" Color="#4a4c50"/>
        <SolidColorBrush x:Key="TextBrush" Color="#f0f0f0"/>
        <SolidColorBrush x:Key="TextMutedBrush" Color="#a0a0a0"/>
        <SolidColorBrush x:Key="SuccessBrush" Color="#4caf50"/>
        <SolidColorBrush x:Key="WarningBrush" Color="#ffb74d"/>
        <SolidColorBrush x:Key="ErrorBrush" Color="#ef5350"/>
        <SolidColorBrush x:Key="InfoBrush" Color="#4da3ff"/>
        <SolidColorBrush x:Key="LogBgBrush" Color="#141414"/>

        <Style x:Key="LightComboBox" TargetType="ComboBox">
            <Setter Property="Background" Value="#f0f0f0"/>
            <Setter Property="Foreground" Value="#1e1e1e"/>
            <Setter Property="BorderBrush" Value="#c0c0c0"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
            <Setter Property="Padding" Value="8,6"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBox">
                        <Grid>
                            <ToggleButton x:Name="ToggleButton" Focusable="False"
                                          IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"
                                          ClickMode="Press">
                                <ToggleButton.Template>
                                    <ControlTemplate TargetType="ToggleButton">
                                        <Border Background="#f0f0f0"
                                                BorderBrush="#c0c0c0"
                                                BorderThickness="1" CornerRadius="4">
                                            <Grid>
                                                <Grid.ColumnDefinitions>
                                                    <ColumnDefinition/>
                                                    <ColumnDefinition Width="28"/>
                                                </Grid.ColumnDefinitions>
                                                <Border Grid.Column="1">
                                                    <Path x:Name="Arrow" Fill="#666666" HorizontalAlignment="Center"
                                                          VerticalAlignment="Center"
                                                          Data="M 0 0 L 5 5 L 10 0 Z"/>
                                                </Border>
                                            </Grid>
                                        </Border>
                                    </ControlTemplate>
                                </ToggleButton.Template>
                            </ToggleButton>
                            <ContentPresenter x:Name="ContentSite" IsHitTestVisible="False"
                                              Content="{TemplateBinding SelectionBoxItem}"
                                              ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                              Margin="10,6,28,6" VerticalAlignment="Center"
                                              HorizontalAlignment="Left"
                                              TextBlock.Foreground="#1e1e1e"/>
                            <Popup x:Name="PART_Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}"
                                   AllowsTransparency="True" Focusable="False" PopupAnimation="Slide">
                                <Grid x:Name="DropDown" SnapsToDevicePixels="True"
                                      MinWidth="{TemplateBinding ActualWidth}"
                                      MaxHeight="{TemplateBinding MaxDropDownHeight}">
                                    <Border Background="#f0f0f0" BorderBrush="#c0c0c0" BorderThickness="1"
                                            CornerRadius="4" Padding="0,4">
                                        <ScrollViewer SnapsToDevicePixels="True">
                                            <StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Contained"/>
                                        </ScrollViewer>
                                    </Border>
                                </Grid>
                            </Popup>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="LightComboBoxItem" TargetType="ComboBoxItem">
            <Setter Property="Background" Value="#f0f0f0"/>
            <Setter Property="Foreground" Value="#1e1e1e"/>
            <Setter Property="Padding" Value="8,6"/>
            <Setter Property="FontSize" Value="13"/>
            <Style.Triggers>
                <Trigger Property="IsHighlighted" Value="True">
                    <Setter Property="Background" Value="#0063b1"/>
                    <Setter Property="Foreground" Value="White"/>
                </Trigger>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="#e0e0e0"/>
                    <Setter Property="Foreground" Value="#1e1e1e"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <Style x:Key="UploadButton" TargetType="Button">
            <Setter Property="Background" Value="{StaticResource AccentBrush}"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border"
                                Background="{TemplateBinding Background}"
                                CornerRadius="4"
                                Padding="16,10">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="{StaticResource AccentHoverBrush}"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="{StaticResource AccentPressedBrush}"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Opacity" Value="0.4"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Grid Margin="0">
        <Grid.RowDefinitions>
            <RowDefinition Height="52"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <Border Grid.Row="0" Background="{StaticResource AccentBrush}">
            <TextBlock Text="$($Config.CompanyName) - Autopilot Registration"
                       Foreground="White" FontSize="16" FontWeight="Bold"
                       FontFamily="Segoe UI"
                       VerticalAlignment="Center" HorizontalAlignment="Center"/>
        </Border>

        <Border Grid.Row="1" Background="{StaticResource CardBgBrush}"
                CornerRadius="6" Margin="15,15,15,0" Padding="16,14">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="10"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="6"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="6"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="6"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="120"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>

                <TextBlock Grid.Row="0" Grid.ColumnSpan="2"
                           Text="Device Information" FontSize="13" FontWeight="SemiBold"
                           Foreground="{StaticResource TextMutedBrush}" FontFamily="Segoe UI"/>

                <TextBlock Grid.Row="2" Grid.Column="0" Text="Serial Number"
                           Foreground="{StaticResource TextMutedBrush}" FontSize="12" FontFamily="Segoe UI"
                           VerticalAlignment="Center"/>
                <TextBlock Grid.Row="2" Grid.Column="1" Name="lblSerial" Text="Collecting..."
                           Foreground="{StaticResource TextBrush}" FontSize="12" FontFamily="Segoe UI"
                           VerticalAlignment="Center"/>

                <TextBlock Grid.Row="4" Grid.Column="0" Text="Manufacturer"
                           Foreground="{StaticResource TextMutedBrush}" FontSize="12" FontFamily="Segoe UI"
                           VerticalAlignment="Center"/>
                <TextBlock Grid.Row="4" Grid.Column="1" Name="lblManufacturer" Text="Collecting..."
                           Foreground="{StaticResource TextBrush}" FontSize="12" FontFamily="Segoe UI"
                           VerticalAlignment="Center"/>

                <TextBlock Grid.Row="6" Grid.Column="0" Text="Model"
                           Foreground="{StaticResource TextMutedBrush}" FontSize="12" FontFamily="Segoe UI"
                           VerticalAlignment="Center"/>
                <TextBlock Grid.Row="6" Grid.Column="1" Name="lblModel" Text="Collecting..."
                           Foreground="{StaticResource TextBrush}" FontSize="12" FontFamily="Segoe UI"
                           VerticalAlignment="Center"/>

                <TextBlock Grid.Row="8" Grid.Column="0" Text="Hardware Hash"
                           Foreground="{StaticResource TextMutedBrush}" FontSize="12" FontFamily="Segoe UI"
                           VerticalAlignment="Center"/>
                <TextBlock Grid.Row="8" Grid.Column="1" Name="lblHash" Text="Collecting..."
                           Foreground="{StaticResource TextBrush}" FontSize="12" FontFamily="Segoe UI"
                           TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
            </Grid>
        </Border>

        <Grid Grid.Row="2" Margin="15,12,15,0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="90"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <TextBlock Grid.Column="0" Text="Group Tag"
                       Foreground="{StaticResource TextBrush}" FontSize="13" FontFamily="Segoe UI"
                       VerticalAlignment="Center"/>
            <ComboBox Grid.Column="1" Name="cmbGroupTag"
                      Style="{StaticResource LightComboBox}"
                      ItemContainerStyle="{StaticResource LightComboBoxItem}"
                      Height="34"/>
        </Grid>

        <Button Grid.Row="3" Name="btnUpload"
                Content="Upload to Autopilot"
                Style="{StaticResource UploadButton}"
                IsEnabled="False"
                Margin="15,12,15,0" Height="42"/>

        <Border Grid.Row="4" Background="{StaticResource LogBgBrush}"
                CornerRadius="6" Margin="15,12,15,15">
            <ScrollViewer Name="logScroller" VerticalScrollBarVisibility="Auto"
                          Padding="10,8">
                <StackPanel Name="logPanel"/>
            </ScrollViewer>
        </Border>
    </Grid>
</Window>
"@

    $processedXaml = $xamlString -replace 'x:Name="', 'Name="'
    [xml]$xaml = $processedXaml
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [System.Windows.Markup.XamlReader]::Load($reader)

    $ui = @{}
    $namedElements = @(
        'lblSerial', 'lblManufacturer', 'lblModel', 'lblHash',
        'cmbGroupTag', 'btnUpload',
        'logPanel', 'logScroller'
    )
    foreach ($name in $namedElements) {
        $el = $window.FindName($name)
        if ($el) { $ui[$name] = $el }
        else { Write-Warning "Element not found: $name" }
    }

    foreach ($tag in $Config.GroupTags) {
        $ui.cmbGroupTag.Items.Add($tag) | Out-Null
    }
    if ($Config.DefaultTag -and $ui.cmbGroupTag.Items.Contains($Config.DefaultTag)) {
        $ui.cmbGroupTag.SelectedItem = $Config.DefaultTag
    }
    elseif ($ui.cmbGroupTag.Items.Count -gt 0) {
        $ui.cmbGroupTag.SelectedIndex = 0
    }

    function Add-Status {
        param([string]$Text, [string]$Color = 'White')
        $colorMap = @{
            'White'  = '#c8c8c8'
            'Green'  = '#4caf50'
            'Yellow' = '#ffb74d'
            'Red'    = '#ef5350'
            'Blue'   = '#4da3ff'
        }
        $hexColor = $colorMap[$Color]
        if (-not $hexColor) { $hexColor = '#c8c8c8' }

        $timestamp = Get-Date -Format 'HH:mm:ss'
        $textBlock = New-Object System.Windows.Controls.TextBlock
        $textBlock.Text = "[$timestamp] $Text"
        $textBlock.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($hexColor)
        $textBlock.FontFamily = New-Object System.Windows.Media.FontFamily('Cascadia Mono, Consolas, Courier New')
        $textBlock.FontSize = 11.5
        $textBlock.Margin = [System.Windows.Thickness]::new(0, 1, 0, 1)
        $textBlock.TextWrapping = 'Wrap'
        $ui.logPanel.Children.Add($textBlock) | Out-Null
        $ui.logScroller.ScrollToEnd()

        Write-Log $Text
        $window.Dispatcher.Invoke([Action]{}, 'Render')
    }

    $script:deviceInfo = $null

    $window.Add_Loaded({
        Add-Status 'Collecting hardware hash...' 'Blue'
        try {
            $script:deviceInfo = Get-AutopilotHardwareHash
            $ui.lblSerial.Text = $script:deviceInfo.SerialNumber
            $ui.lblManufacturer.Text = $script:deviceInfo.Manufacturer
            $ui.lblModel.Text = $script:deviceInfo.Model
            $hashPreview = $script:deviceInfo.HardwareHash
            if ($hashPreview.Length -gt 40) { $hashPreview = $hashPreview.Substring(0, 40) + '...' }
            $ui.lblHash.Text = $hashPreview
            $ui.btnUpload.IsEnabled = $true
            Add-Status "Device info collected: $($script:deviceInfo.SerialNumber)" 'Green'
        }
        catch {
            Add-Status "ERROR: $_" 'Red'
            $ui.lblSerial.Text = 'Failed'
            $ui.lblHash.Text = 'Failed'
            Write-Log "Hardware hash collection failed: $_" 'ERROR'
        }
    })

    $ui.btnUpload.Add_Click({
        $ui.btnUpload.IsEnabled = $false
        $ui.cmbGroupTag.IsEnabled = $false
        $selectedTag = $ui.cmbGroupTag.SelectedItem

        Add-Status "Uploading hash with tag: $selectedTag" 'Blue'

        try {
            $result = Invoke-AutopilotUpload `
                -HardwareHash $script:deviceInfo.HardwareHash `
                -SerialNumber $script:deviceInfo.SerialNumber `
                -GroupTag $selectedTag `
                -Model $script:deviceInfo.Model `
                -Manufacturer $script:deviceInfo.Manufacturer

            Add-Status "Upload submitted. Import ID: $($result.importId)" 'Green'
            Add-Status 'Waiting for Autopilot sync...' 'Yellow'

            $importId = $result.importId
            $maxAttempts = 40
            $attempt = 0
            $complete = $false

            while ($attempt -lt $maxAttempts -and -not $complete) {
                Start-Sleep -Seconds 12
                $window.Dispatcher.Invoke([Action]{}, 'Render')
                $attempt++

                $status = Get-ImportStatus -ImportId $importId

                switch ($status.status) {
                    'complete' {
                        Add-Status "Device registered successfully!" 'Green'
                        Add-Status "Serial: $($script:deviceInfo.SerialNumber) | Tag: $selectedTag" 'Green'
                        Add-Status '' 'White'
                        Add-Status 'You can now close this tool and restart OOBE.' 'Blue'
                        Add-Status 'The device will pick up its Autopilot profile.' 'Blue'
                        $complete = $true
                    }
                    'error' {
                        Add-Status "Import failed: $($status.errorName)" 'Red'
                        $complete = $true
                    }
                    default {
                        if ($attempt -eq 1 -or $attempt % 5 -eq 0) {
                            $elapsed = $attempt * 12
                            $minutes = [math]::Floor($elapsed / 60)
                            $seconds = $elapsed % 60
                            Add-Status "Syncing... ${minutes}m ${seconds}s elapsed" 'Yellow'
                        }
                    }
                }
            }

            if (-not $complete) {
                Add-Status 'Sync is taking longer than expected.' 'Yellow'
                Add-Status 'The hash was uploaded. It may take a few more minutes to sync.' 'Yellow'
                Add-Status 'You can restart OOBE and the profile should apply shortly.' 'Blue'
            }
        }
        catch {
            if ($_.Exception.Message -match 'DUPLICATE') {
                Add-Status 'This device is already registered in Autopilot.' 'Yellow'
                Add-Status 'No action needed. Restart OOBE to continue.' 'Blue'
            }
            else {
                Add-Status "ERROR: $($_.Exception.Message)" 'Red'
                Write-Log "Upload failed: $($_.Exception.Message)" 'ERROR'
                $ui.btnUpload.IsEnabled = $true
                $ui.cmbGroupTag.IsEnabled = $true
            }
        }
    })

    $window.ShowDialog() | Out-Null
}

Show-MainWindow
