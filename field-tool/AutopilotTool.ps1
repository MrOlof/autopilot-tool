<#
.SYNOPSIS
    Autopilot Registration Tool - Field Client
    Collects hardware hash and uploads to Autopilot via Azure Function proxy.

.DESCRIPTION
    Runs at Windows OOBE (Shift+F10) to register a device in Windows Autopilot.
    No external modules required - uses only .NET Framework classes.

.NOTES
    Version: 2.0.0
    Author:  MrOlof (https://mrolof.dev)
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
    EnableQR     = $false
    Version      = '2.0.0'
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
        [string]$Manufacturer,
        [string]$SessionToken
    )

    $uri = "$($Config.FunctionUrl)/api/upload?code=$($Config.FunctionKey)"

    $body = @{
        hardwareHash = $HardwareHash
        serialNumber = $SerialNumber
        groupTag     = $GroupTag
        model        = $Model
        manufacturer = $Manufacturer
    } | ConvertTo-Json

    $headers = @{ 'Content-Type' = 'application/json' }
    if ($SessionToken) {
        $headers['Authorization'] = "Bearer $SessionToken"
    }

    try {
        $response = Invoke-RestMethod -Uri $uri -Method POST -Body $body -Headers $headers -TimeoutSec 30
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

# --- QR Session Functions (used when EnableQR = $true) ---

function Start-QRSession {
    param([string]$SerialNumber)

    $uri = "$($Config.FunctionUrl)/api/session"
    $body = @{ serialNumber = $SerialNumber } | ConvertTo-Json

    $response = Invoke-RestMethod -Uri $uri -Method POST -Body $body -ContentType 'application/json' -TimeoutSec 60
    return $response
}

function Get-SessionStatus {
    param([string]$SessionId, [string]$PartitionKey)

    $uri = "$($Config.FunctionUrl)/api/session/$SessionId/status?pk=$([uri]::EscapeDataString($PartitionKey))"
    return Invoke-RestMethod -Uri $uri -Method GET -TimeoutSec 10
}

function New-QRBitmapImage {
    param([string]$Url)

    $scriptDir = Split-Path -Parent $MyInvocation.ScriptName
    # Try script directory first, then parent lib folder
    $dllPath = Join-Path $scriptDir 'QRCoder.dll'
    if (-not (Test-Path $dllPath)) {
        $dllPath = Join-Path $scriptDir 'lib\QRCoder.dll'
    }
    if (-not (Test-Path $dllPath)) {
        throw "QRCoder.dll not found. Expected at: $dllPath"
    }

    Add-Type -Path $dllPath

    $qrGenerator = New-Object QRCoder.QRCodeGenerator
    $qrData = $qrGenerator.CreateQrCode($Url, [QRCoder.QRCodeGenerator+ECCLevel]::M)
    $qrCode = New-Object QRCoder.PngByteQRCode($qrData)
    $darkColor = [byte[]]@(0, 0, 0)
    $lightColor = [byte[]]@(255, 255, 255)
    $qrBytes = $qrCode.GetGraphic(8, $darkColor, $lightColor)

    $stream = New-Object System.IO.MemoryStream(, $qrBytes)
    $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
    $bitmap.BeginInit()
    $bitmap.StreamSource = $stream
    $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bitmap.EndInit()
    $bitmap.Freeze()

    return $bitmap
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
        Title="$($Config.CompanyName) - Autopilot Registration"
        Width="640" Height="720"
        WindowStartupLocation="CenterScreen"
        ResizeMode="CanResizeWithGrip"
        MinWidth="540" MinHeight="600"
        Background="#0f0f13">

    <Window.Resources>
        <SolidColorBrush x:Key="AccentBrush" Color="#3b82f6"/>
        <SolidColorBrush x:Key="AccentHoverBrush" Color="#60a5fa"/>
        <SolidColorBrush x:Key="AccentPressedBrush" Color="#2563eb"/>
        <SolidColorBrush x:Key="CardBgBrush" Color="#1a1b20"/>
        <SolidColorBrush x:Key="CardBorderBrush" Color="#2a2b30"/>
        <SolidColorBrush x:Key="InputBgBrush" Color="#25262b"/>
        <SolidColorBrush x:Key="InputBorderBrush" Color="#35363b"/>
        <SolidColorBrush x:Key="TextBrush" Color="#e8e8ec"/>
        <SolidColorBrush x:Key="TextMutedBrush" Color="#7a7d85"/>
        <SolidColorBrush x:Key="SuccessBrush" Color="#34d399"/>
        <SolidColorBrush x:Key="WarningBrush" Color="#fbbf24"/>
        <SolidColorBrush x:Key="ErrorBrush" Color="#f87171"/>
        <SolidColorBrush x:Key="InfoBrush" Color="#3b82f6"/>
        <SolidColorBrush x:Key="LogBgBrush" Color="#111114"/>

        <!-- Dark ComboBox -->
        <Style x:Key="DarkComboBox" TargetType="ComboBox">
            <Setter Property="Background" Value="{StaticResource InputBgBrush}"/>
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="BorderBrush" Value="{StaticResource InputBorderBrush}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
            <Setter Property="Padding" Value="10,8"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBox">
                        <Grid>
                            <ToggleButton x:Name="ToggleButton" Focusable="False"
                                          IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"
                                          ClickMode="Press">
                                <ToggleButton.Template>
                                    <ControlTemplate TargetType="ToggleButton">
                                        <Border Background="#25262b"
                                                BorderBrush="#35363b"
                                                BorderThickness="1" CornerRadius="10">
                                            <Grid>
                                                <Grid.ColumnDefinitions>
                                                    <ColumnDefinition/>
                                                    <ColumnDefinition Width="32"/>
                                                </Grid.ColumnDefinitions>
                                                <Border Grid.Column="1">
                                                    <Path Fill="#7a7d85" HorizontalAlignment="Center"
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
                                              Margin="12,8,32,8" VerticalAlignment="Center"
                                              HorizontalAlignment="Left"
                                              TextBlock.Foreground="#e8e8ec"/>
                            <Popup x:Name="PART_Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}"
                                   AllowsTransparency="True" Focusable="False" PopupAnimation="Slide">
                                <Grid x:Name="DropDown" SnapsToDevicePixels="True"
                                      MinWidth="{TemplateBinding ActualWidth}"
                                      MaxHeight="{TemplateBinding MaxDropDownHeight}">
                                    <Border Background="#25262b" BorderBrush="#35363b" BorderThickness="1"
                                            CornerRadius="10" Padding="0,4">
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
        <Style x:Key="DarkComboBoxItem" TargetType="ComboBoxItem">
            <Setter Property="Background" Value="#25262b"/>
            <Setter Property="Foreground" Value="#e8e8ec"/>
            <Setter Property="Padding" Value="10,8"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
            <Style.Triggers>
                <Trigger Property="IsHighlighted" Value="True">
                    <Setter Property="Background" Value="#3b82f6"/>
                    <Setter Property="Foreground" Value="White"/>
                </Trigger>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="#2a2b30"/>
                    <Setter Property="Foreground" Value="#e8e8ec"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <!-- Upload button with gradient -->
        <Style x:Key="UploadButton" TargetType="Button">
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" CornerRadius="10" Padding="16,10">
                            <Border.Background>
                                <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                                    <GradientStop Color="#3b82f6" Offset="0"/>
                                    <GradientStop Color="#2563eb" Offset="1"/>
                                </LinearGradientBrush>
                            </Border.Background>
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background">
                                    <Setter.Value>
                                        <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                                            <GradientStop Color="#60a5fa" Offset="0"/>
                                            <GradientStop Color="#3b82f6" Offset="1"/>
                                        </LinearGradientBrush>
                                    </Setter.Value>
                                </Setter>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background">
                                    <Setter.Value>
                                        <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                                            <GradientStop Color="#2563eb" Offset="0"/>
                                            <GradientStop Color="#1d4ed8" Offset="1"/>
                                        </LinearGradientBrush>
                                    </Setter.Value>
                                </Setter>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Opacity" Value="0.4"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Subtle cancel button -->
        <Style x:Key="CancelButton" TargetType="Button">
            <Setter Property="Foreground" Value="#7a7d85"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="#25262b" BorderBrush="#35363b"
                                BorderThickness="1" CornerRadius="8" Padding="16,8">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#35363b"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#1a1b20"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Grid Margin="0">
        <Grid.RowDefinitions>
            <RowDefinition Height="56"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <!-- Row 0: Header bar -->
        <Border Grid.Row="0" Background="#1a1b20" BorderBrush="#2a2b30" BorderThickness="0,0,0,1">
            <Grid Margin="20,0">
                <TextBlock Text="$($Config.CompanyName)"
                           Foreground="{StaticResource TextMutedBrush}" FontSize="13"
                           FontFamily="Segoe UI" FontWeight="Normal"
                           VerticalAlignment="Center" HorizontalAlignment="Left"/>
                <Border Background="#25262b" CornerRadius="6" Padding="8,3"
                        VerticalAlignment="Center" HorizontalAlignment="Right">
                    <TextBlock Text="v$($Config.Version)"
                               Foreground="{StaticResource TextMutedBrush}" FontSize="11"
                               FontFamily="Segoe UI"/>
                </Border>
            </Grid>
        </Border>

        <!-- Row 1: Device info card -->
        <Border Grid.Row="1" Background="{StaticResource CardBgBrush}"
                BorderBrush="{StaticResource CardBorderBrush}" BorderThickness="1"
                CornerRadius="12" Margin="16,16,16,0" Padding="18,14">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="12"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="8"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="8"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="8"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="110"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>

                <TextBlock Grid.Row="0" Grid.ColumnSpan="2"
                           Text="DEVICE INFORMATION" FontSize="10" FontWeight="SemiBold"
                           Foreground="{StaticResource TextMutedBrush}" FontFamily="Segoe UI"/>

                <TextBlock Grid.Row="2" Grid.Column="0" Text="Serial"
                           Foreground="{StaticResource TextMutedBrush}" FontSize="12" FontFamily="Segoe UI"
                           VerticalAlignment="Center"/>
                <TextBlock Grid.Row="2" Grid.Column="1" x:Name="lblSerial" Text="Collecting..."
                           Foreground="{StaticResource TextBrush}" FontSize="12" FontFamily="Segoe UI"
                           VerticalAlignment="Center"/>

                <TextBlock Grid.Row="4" Grid.Column="0" Text="Manufacturer"
                           Foreground="{StaticResource TextMutedBrush}" FontSize="12" FontFamily="Segoe UI"
                           VerticalAlignment="Center"/>
                <TextBlock Grid.Row="4" Grid.Column="1" x:Name="lblManufacturer" Text="Collecting..."
                           Foreground="{StaticResource TextBrush}" FontSize="12" FontFamily="Segoe UI"
                           VerticalAlignment="Center"/>

                <TextBlock Grid.Row="6" Grid.Column="0" Text="Model"
                           Foreground="{StaticResource TextMutedBrush}" FontSize="12" FontFamily="Segoe UI"
                           VerticalAlignment="Center"/>
                <TextBlock Grid.Row="6" Grid.Column="1" x:Name="lblModel" Text="Collecting..."
                           Foreground="{StaticResource TextBrush}" FontSize="12" FontFamily="Segoe UI"
                           VerticalAlignment="Center"/>

                <TextBlock Grid.Row="8" Grid.Column="0" Text="Hash"
                           Foreground="{StaticResource TextMutedBrush}" FontSize="12" FontFamily="Segoe UI"
                           VerticalAlignment="Center"/>
                <TextBlock Grid.Row="8" Grid.Column="1" x:Name="lblHash" Text="Collecting..."
                           Foreground="{StaticResource TextBrush}" FontSize="12" FontFamily="Segoe UI"
                           TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
            </Grid>
        </Border>

        <!-- Row 2: Group Tag -->
        <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Center" Margin="16,12,16,0">
            <TextBlock Text="Group Tag"
                       Foreground="{StaticResource TextBrush}" FontSize="13"
                       FontFamily="Segoe UI" FontWeight="SemiBold"
                       VerticalAlignment="Center" Margin="0,0,12,0"/>
            <ComboBox x:Name="cmbGroupTag"
                      Style="{StaticResource DarkComboBox}"
                      ItemContainerStyle="{StaticResource DarkComboBoxItem}"
                      Width="200" Height="38"/>
        </StackPanel>

        <!-- Row 3: Upload Button -->
        <Button Grid.Row="3" x:Name="btnUpload"
                Content="Upload to Autopilot"
                Style="{StaticResource UploadButton}"
                IsEnabled="False"
                Height="46" Margin="16,12,16,0"/>

        <!-- Row 4: Main content area (log + QR overlay) -->
        <Border Grid.Row="4" Background="{StaticResource LogBgBrush}"
                CornerRadius="10" Margin="16,12,16,16">
            <Grid>
                <!-- Log panel -->
                <ScrollViewer x:Name="logScroller" VerticalScrollBarVisibility="Auto"
                              Padding="12,10">
                    <StackPanel x:Name="logPanel"/>
                </ScrollViewer>

                <!-- QR Code overlay (hidden by default, fills entire content area) -->
                <Border x:Name="qrOverlay" Visibility="Collapsed"
                        Background="{StaticResource CardBgBrush}" CornerRadius="10">
                    <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center">
                        <TextBlock Text="Scan with your phone to approve"
                                   Foreground="{StaticResource TextBrush}" FontSize="14"
                                   FontFamily="Segoe UI" FontWeight="SemiBold"
                                   HorizontalAlignment="Center" Margin="0,0,0,14"/>

                        <Border Background="White" CornerRadius="6" Padding="10"
                                HorizontalAlignment="Center">
                            <Image x:Name="qrImage" Width="200" Height="200"
                                   RenderOptions.BitmapScalingMode="NearestNeighbor"/>
                        </Border>

                        <TextBlock x:Name="qrStatus" Text="Waiting for approval..."
                                   Foreground="{StaticResource WarningBrush}" FontSize="12"
                                   FontFamily="Segoe UI"
                                   HorizontalAlignment="Center" Margin="0,12,0,0"/>

                        <Button x:Name="btnQRCancel" Content="Cancel"
                                Style="{StaticResource CancelButton}"
                                HorizontalAlignment="Center" Margin="0,10,0,0"/>
                    </StackPanel>
                </Border>
            </Grid>
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
        'logPanel', 'logScroller',
        'qrOverlay', 'qrImage', 'qrStatus', 'btnQRCancel'
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

    # --- Shared state for async operations ---
    $script:qrCancelled = $false
    $script:sessionToken = $null
    $script:sessionResponse = $null
    $script:selectedTag = $null
    $script:qrPollCount = 0

    if ($ui.btnQRCancel) {
        $ui.btnQRCancel.Add_Click({
            $script:qrCancelled = $true
        })
    }

    # --- Function: perform upload (called after QR approval or directly) ---
    function Start-Upload {
        Add-Status "Uploading hash with tag: $($script:selectedTag)" 'Blue'
        $window.Dispatcher.Invoke([Action]{}, 'Render')

        try {
            $result = Invoke-AutopilotUpload `
                -HardwareHash $script:deviceInfo.HardwareHash `
                -SerialNumber $script:deviceInfo.SerialNumber `
                -GroupTag $script:selectedTag `
                -Model $script:deviceInfo.Model `
                -Manufacturer $script:deviceInfo.Manufacturer `
                -SessionToken $script:sessionToken

            Add-Status "Upload submitted. Import ID: $($result.importId)" 'Green'
            Add-Status 'Waiting for Autopilot sync...' 'Yellow'

            # Start sync polling timer
            $script:syncImportId = $result.importId
            $script:syncAttempt = 0
            $script:syncTimer = New-Object System.Windows.Threading.DispatcherTimer
            $script:syncTimer.Interval = [TimeSpan]::FromSeconds(12)
            $script:syncTimer.Add_Tick({
                $script:syncAttempt++
                try {
                    $status = Get-ImportStatus -ImportId $script:syncImportId
                    switch ($status.status) {
                        'complete' {
                            $script:syncTimer.Stop()
                            Add-Status "Device registered successfully!" 'Green'
                            Add-Status "Serial: $($script:deviceInfo.SerialNumber) | Tag: $($script:selectedTag)" 'Green'
                            Add-Status '' 'White'
                            Add-Status 'You can now close this tool and restart OOBE.' 'Blue'
                            Add-Status 'The device will pick up its Autopilot profile.' 'Blue'
                        }
                        'error' {
                            $script:syncTimer.Stop()
                            Add-Status "Import failed: $($status.errorName)" 'Red'
                        }
                        default {
                            if ($script:syncAttempt -eq 1 -or $script:syncAttempt % 5 -eq 0) {
                                $elapsed = $script:syncAttempt * 12
                                $minutes = [math]::Floor($elapsed / 60)
                                $seconds = $elapsed % 60
                                Add-Status "Syncing... ${minutes}m ${seconds}s elapsed" 'Yellow'
                            }
                        }
                    }
                    if ($script:syncAttempt -ge 40) {
                        $script:syncTimer.Stop()
                        Add-Status 'Sync is taking longer than expected.' 'Yellow'
                        Add-Status 'The hash was uploaded. It may take a few more minutes to sync.' 'Yellow'
                        Add-Status 'You can restart OOBE and the profile should apply shortly.' 'Blue'
                    }
                }
                catch {
                    Write-Log "Sync poll error: $_" 'WARN'
                }
            })
            $script:syncTimer.Start()
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
    }

    $ui.btnUpload.Add_Click({
        $ui.btnUpload.IsEnabled = $false
        $ui.cmbGroupTag.IsEnabled = $false
        $script:selectedTag = $ui.cmbGroupTag.SelectedItem
        $script:sessionToken = $null

        # --- QR Authentication Flow (non-blocking with DispatcherTimer) ---
        if ($Config.EnableQR -eq $true) {
            Add-Status 'Starting QR authentication...' 'Blue'
            $script:qrCancelled = $false
            $script:qrPollCount = 0

            try {
                $script:sessionResponse = Start-QRSession -SerialNumber $script:deviceInfo.SerialNumber
                Add-Status "Session created. Scan QR code to approve." 'Yellow'
                Write-Log "QR session created: $($script:sessionResponse.sessionId)"

                $qrBitmap = New-QRBitmapImage -Url $script:sessionResponse.qrUrl
                $ui.qrImage.Source = $qrBitmap
                $ui.qrOverlay.Visibility = 'Visible'

                # Non-blocking poll timer (3 second interval)
                $script:qrTimer = New-Object System.Windows.Threading.DispatcherTimer
                $script:qrTimer.Interval = [TimeSpan]::FromSeconds(3)
                $script:qrTimer.Add_Tick({
                    $script:qrPollCount++

                    if ($script:qrCancelled) {
                        $script:qrTimer.Stop()
                        $ui.qrOverlay.Visibility = 'Collapsed'
                        Add-Status 'QR authentication cancelled.' 'Yellow'
                        $ui.btnUpload.IsEnabled = $true
                        $ui.cmbGroupTag.IsEnabled = $true
                        return
                    }

                    if ($script:qrPollCount -ge 100) {
                        $script:qrTimer.Stop()
                        $ui.qrOverlay.Visibility = 'Collapsed'
                        Add-Status 'QR approval timed out. Please try again.' 'Red'
                        $ui.btnUpload.IsEnabled = $true
                        $ui.cmbGroupTag.IsEnabled = $true
                        return
                    }

                    try {
                        $pollResult = Get-SessionStatus -SessionId $script:sessionResponse.sessionId -PartitionKey $script:sessionResponse.partitionKey

                        switch ($pollResult.status) {
                            'approved' {
                                $script:qrTimer.Stop()
                                $script:sessionToken = $pollResult.token
                                $ui.qrStatus.Text = "Approved by $($pollResult.approvedBy)"
                                $ui.qrStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#34d399')
                                Add-Status "Approved by $($pollResult.approvedBy)" 'Green'
                                $ui.qrOverlay.Visibility = 'Collapsed'
                                Start-Upload
                            }
                            'expired' {
                                $script:qrTimer.Stop()
                                $ui.qrOverlay.Visibility = 'Collapsed'
                                Add-Status 'Session expired. Please try again.' 'Red'
                                $ui.btnUpload.IsEnabled = $true
                                $ui.cmbGroupTag.IsEnabled = $true
                            }
                            default {
                                if ($script:qrPollCount % 10 -eq 0) {
                                    $elapsed = $script:qrPollCount * 3
                                    $ui.qrStatus.Text = "Waiting for approval... (${elapsed}s)"
                                }
                            }
                        }
                    }
                    catch {
                        Write-Log "Session poll error: $_" 'WARN'
                    }
                })
                $script:qrTimer.Start()
            }
            catch {
                $ui.qrOverlay.Visibility = 'Collapsed'
                Add-Status "QR auth failed: $($_.Exception.Message)" 'Red'
                Write-Log "QR auth failed: $($_.Exception.Message)" 'ERROR'
                $ui.btnUpload.IsEnabled = $true
                $ui.cmbGroupTag.IsEnabled = $true
            }
        }
        else {
            # No QR — upload directly
            Start-Upload
        }
    })

    $window.ShowDialog() | Out-Null
}

Show-MainWindow
