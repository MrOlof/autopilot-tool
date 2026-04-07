<#
.SYNOPSIS
    Autopilot Tool Builder - Admin Configuration GUI (WPF)
    Generates a configured field tool with company branding and Azure Function settings.

.NOTES
    Version: 2.0.0
    Author:  MrOlof (https://mrolof.dev)
    License: MIT
#>

#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

# --- Hide Console Window ---
Add-Type -Name ConsoleWindow -Namespace Win32 -MemberDefinition '
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'
$consoleHwnd = [Win32.ConsoleWindow]::GetConsoleWindow()
if ($consoleHwnd -ne [IntPtr]::Zero) {
    [Win32.ConsoleWindow]::ShowWindow($consoleHwnd, 0) | Out-Null
}

# --- Prerequisite Check ---
function Test-Prerequisites {
    $missing = @()

    # Check Az module (needed for Simple deploy)
    if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
        $missing += 'Az'
    }

    # Check Microsoft.Graph module (needed for Graph permission grant)
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Applications)) {
        $missing += 'Microsoft.Graph'
    }

    if ($missing.Count -gt 0) {
        Add-Type -AssemblyName PresentationFramework
        $moduleList = $missing -join ', '
        $result = [System.Windows.MessageBox]::Show(
            "The following PowerShell modules are recommended for full functionality:`n`n$moduleList`n`nWould you like to install them now?`n`n(You can skip this if you already have an Azure Function deployed and just want to build a field tool.)",
            'Autopilot Tool Builder - Prerequisites',
            'YesNoCancel',
            'Question'
        )

        switch ($result) {
            'Yes' {
                foreach ($mod in $missing) {
                    Write-Host "Installing $mod..." -ForegroundColor Cyan
                    Install-Module $mod -Scope CurrentUser -Force -AllowClobber
                    Write-Host "$mod installed." -ForegroundColor Green
                }
            }
            'Cancel' { exit }
            # 'No' continues without installing
        }
    }
}

Test-Prerequisites

# --- Resolve paths ---
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$projectRoot = Split-Path $scriptDir
$templatePath = Join-Path $projectRoot 'field-tool\AutopilotTool.ps1'
$templatePath_ARM = Join-Path $projectRoot 'azure-function\deploy.json'
$grantScriptPath = Join-Path $projectRoot 'setup\Grant-GraphPermission.ps1'
$outputDir = Join-Path $projectRoot 'field-tool\output'

# --- Load WPF ---
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# --- Shared state ---
$script:FunctionUrl = ''
$script:FunctionKey = ''
$script:ConnectionValidated = $false
$script:CurrentStep = 0
$script:StepCompleted = @{ 0 = $false; 1 = $false; 2 = $false; 3 = $false; 4 = $false; 5 = $false; 6 = $false }

$xamlString = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Autopilot Tool Builder"
        Width="1060" Height="780"
        WindowStartupLocation="CenterScreen"
        ResizeMode="CanResizeWithGrip"
        MinWidth="800" MinHeight="560"
        Background="#0f0f13">

    <Window.Resources>
        <SolidColorBrush x:Key="AccentBrush" Color="#4da3ff"/>
        <SolidColorBrush x:Key="AccentHoverBrush" Color="#6bb5ff"/>
        <SolidColorBrush x:Key="AccentPressedBrush" Color="#3a8ee6"/>
        <SolidColorBrush x:Key="CardBgBrush" Color="#1a1b20"/>
        <SolidColorBrush x:Key="InputBgBrush" Color="#25262b"/>
        <SolidColorBrush x:Key="InputBorderBrush" Color="#35363b"/>
        <SolidColorBrush x:Key="InputFocusBrush" Color="#4da3ff"/>
        <SolidColorBrush x:Key="TextBrush" Color="#e8e8ec"/>
        <SolidColorBrush x:Key="TextMutedBrush" Color="#7a7d85"/>
        <SolidColorBrush x:Key="SuccessBrush" Color="#34d399"/>
        <SolidColorBrush x:Key="WarningBrush" Color="#fbbf24"/>
        <SolidColorBrush x:Key="ErrorBrush" Color="#f87171"/>
        <SolidColorBrush x:Key="StepPendingBrush" Color="#35363b"/>
        <SolidColorBrush x:Key="NavBarBrush" Color="#141418"/>
        <SolidColorBrush x:Key="NavBorderBrush" Color="#1e1f24"/>

        <!-- TextBox style -->
        <Style TargetType="TextBox">
            <Setter Property="Background" Value="{StaticResource InputBgBrush}"/>
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="BorderBrush" Value="{StaticResource InputBorderBrush}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="10,8"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
            <Setter Property="CaretBrush" Value="White"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <Border x:Name="border"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="8">
                            <ScrollViewer x:Name="PART_ContentHost" Margin="0"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsFocused" Value="True">
                                <Setter TargetName="border" Property="BorderBrush" Value="{StaticResource InputFocusBrush}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- PasswordBox style -->
        <Style TargetType="PasswordBox">
            <Setter Property="Background" Value="{StaticResource InputBgBrush}"/>
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="BorderBrush" Value="{StaticResource InputBorderBrush}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="10,8"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="CaretBrush" Value="White"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="PasswordBox">
                        <Border x:Name="border"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="8">
                            <ScrollViewer x:Name="PART_ContentHost" Margin="0"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsFocused" Value="True">
                                <Setter TargetName="border" Property="BorderBrush" Value="{StaticResource InputFocusBrush}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Default button style -->
        <Style x:Key="DefaultButton" TargetType="Button">
            <Setter Property="Background" Value="#25262b"/>
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="BorderBrush" Value="{StaticResource InputBorderBrush}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="16,8"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="8"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#35363b"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#1e1f24"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Opacity" Value="0.4"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Primary button -->
        <Style x:Key="PrimaryButton" TargetType="Button" BasedOn="{StaticResource DefaultButton}">
            <Setter Property="Background" Value="{StaticResource AccentBrush}"/>
            <Setter Property="BorderBrush" Value="#5aadff"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="1"
                                CornerRadius="8"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#6bb5ff"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#3a8ee6"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Opacity" Value="0.4"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Ghost/Skip button -->
        <Style x:Key="GhostButton" TargetType="Button" BasedOn="{StaticResource DefaultButton}">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderBrush" Value="Transparent"/>
            <Setter Property="Foreground" Value="{StaticResource TextMutedBrush}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="0"
                                CornerRadius="8"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#1e1f24"/>
                                <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#141418"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Opacity" Value="0.4"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Toggle Switch style (CheckBox with custom template) -->
        <Style x:Key="ToggleSwitch" TargetType="CheckBox">
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                            <Grid Width="40" Height="22" Margin="0,0,12,0">
                                <Border x:Name="track" Background="#35363b" CornerRadius="11"
                                        Width="40" Height="22"/>
                                <Border x:Name="thumb" Background="#7a7d85" CornerRadius="9"
                                        Width="18" Height="18" HorizontalAlignment="Left"
                                        Margin="2,0,0,0" VerticalAlignment="Center"/>
                            </Grid>
                            <ContentPresenter VerticalAlignment="Center"/>
                        </StackPanel>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="track" Property="Background" Value="#4da3ff"/>
                                <Setter TargetName="thumb" Property="Background" Value="White"/>
                                <Setter TargetName="thumb" Property="HorizontalAlignment" Value="Right"/>
                                <Setter TargetName="thumb" Property="Margin" Value="0,0,2,0"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="thumb" Property="Opacity" Value="0.9"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Label style -->
        <Style TargetType="Label">
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Padding" Value="0"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
        </Style>

        <!-- ListBox style -->
        <Style TargetType="ListBox">
            <Setter Property="Background" Value="{StaticResource InputBgBrush}"/>
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="BorderBrush" Value="{StaticResource InputBorderBrush}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="FontSize" Value="13"/>
        </Style>

        <!-- ComboBox dark theme with custom template -->
        <Style TargetType="ComboBox">
            <Setter Property="Background" Value="{StaticResource InputBgBrush}"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderBrush" Value="{StaticResource InputBorderBrush}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="FontSize" Value="13"/>
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
                                        <Border Background="{StaticResource InputBgBrush}"
                                                BorderBrush="{StaticResource InputBorderBrush}"
                                                BorderThickness="1" CornerRadius="8">
                                            <Grid>
                                                <Grid.ColumnDefinitions>
                                                    <ColumnDefinition/>
                                                    <ColumnDefinition Width="28"/>
                                                </Grid.ColumnDefinitions>
                                                <Border Grid.Column="1">
                                                    <Path x:Name="Arrow" Fill="#7a7d85" HorizontalAlignment="Center"
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
                                              Margin="12,8,28,8" VerticalAlignment="Center"
                                              HorizontalAlignment="Left"
                                              TextBlock.Foreground="White"/>
                            <Popup x:Name="PART_Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}"
                                   AllowsTransparency="True" Focusable="False" PopupAnimation="Slide">
                                <Grid x:Name="DropDown" SnapsToDevicePixels="True"
                                      MinWidth="{TemplateBinding ActualWidth}"
                                      MaxHeight="{TemplateBinding MaxDropDownHeight}">
                                    <Border Background="#1a1b20" BorderBrush="#35363b" BorderThickness="1"
                                            CornerRadius="8" Padding="0,4">
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
        <Style TargetType="ComboBoxItem">
            <Setter Property="Background" Value="#1a1b20"/>
            <Setter Property="Foreground" Value="#e8e8ec"/>
            <Setter Property="Padding" Value="10,8"/>
            <Setter Property="FontSize" Value="13"/>
            <Style.Triggers>
                <Trigger Property="IsHighlighted" Value="True">
                    <Setter Property="Background" Value="#4da3ff"/>
                    <Setter Property="Foreground" Value="White"/>
                </Trigger>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="#25262b"/>
                    <Setter Property="Foreground" Value="White"/>
                </Trigger>
            </Style.Triggers>
        </Style>
    </Window.Resources>

    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="56"/>
        </Grid.RowDefinitions>

        <!-- Step Indicator Bar (hidden on Welcome) -->
        <Border x:Name="stepIndicatorBar" Grid.Row="0" Background="#141418"
                BorderBrush="#1e1f24" BorderThickness="0,0,0,1"
                Padding="0,14" Visibility="Collapsed">
            <StackPanel HorizontalAlignment="Center">
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,0,0,8">
                    <Ellipse x:Name="dot1" Width="8" Height="8" Fill="#4da3ff" Margin="0,0,8,0"/>
                    <Ellipse x:Name="dot2" Width="8" Height="8" Fill="#35363b" Margin="0,0,8,0"/>
                    <Ellipse x:Name="dot3" Width="8" Height="8" Fill="#35363b" Margin="0,0,8,0"/>
                    <Ellipse x:Name="dot4" Width="8" Height="8" Fill="#35363b" Margin="0,0,8,0"/>
                    <Ellipse x:Name="dot5" Width="8" Height="8" Fill="#35363b" Margin="0,0,8,0"/>
                    <Ellipse x:Name="dot6" Width="8" Height="8" Fill="#35363b" Margin="0,0,0,0"/>
                </StackPanel>
                <TextBlock x:Name="stepNameLabel" Text="Step 1: Features"
                           Foreground="#7a7d85" FontSize="12" HorizontalAlignment="Center"
                           FontFamily="Segoe UI"/>
            </StackPanel>
        </Border>

        <!-- Content Area -->
        <Grid Grid.Row="1">

            <!-- Step 0: Welcome -->
            <Border x:Name="pageStep0" Visibility="Visible">
                <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
                    <TextBlock Text="Autopilot Registration Tool" FontSize="32" FontWeight="Bold"
                               Foreground="{StaticResource TextBrush}" HorizontalAlignment="Center"
                               FontFamily="Segoe UI" Margin="0,0,0,6"/>
                    <Border Background="#25262b" CornerRadius="12" Padding="10,4" Margin="0,0,0,16"
                            HorizontalAlignment="Center">
                        <TextBlock Text="Builder v2.0" FontSize="12" Foreground="#4da3ff"
                                   FontFamily="Segoe UI" FontWeight="SemiBold"/>
                    </Border>
                    <TextBlock Text="Configure and generate a branded field tool"
                               FontSize="15" Foreground="{StaticResource TextMutedBrush}"
                               HorizontalAlignment="Center" Margin="0,0,0,4" FontFamily="Segoe UI"/>
                    <TextBlock Text="for Windows Autopilot device registration."
                               FontSize="15" Foreground="{StaticResource TextMutedBrush}"
                               HorizontalAlignment="Center" Margin="0,0,0,36" FontFamily="Segoe UI"/>
                    <Button x:Name="btnStartBuild" Content="Start Build"
                            Style="{StaticResource PrimaryButton}" Padding="36,14"
                            FontSize="16" HorizontalAlignment="Center"/>
                    <TextBlock Text="by MrOlof &#x2022; github.com/MrOlof/autopilot-tool"
                               FontSize="11" Foreground="#3b3d42" HorizontalAlignment="Center"
                               Margin="0,32,0,0" FontFamily="Segoe UI"/>
                </StackPanel>
            </Border>

            <!-- Step 1: Features -->
            <Border x:Name="pageStep1" Visibility="Collapsed" Margin="32,12,32,8">
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <StackPanel>
                        <TextBlock Text="Features" FontSize="20" FontWeight="Bold"
                                   Foreground="{StaticResource TextBrush}" Margin="0,0,0,4"
                                   FontFamily="Segoe UI"/>
                        <TextBlock Text="Enable optional features for the field tool. Configuration for selected features is on the next step."
                                   Foreground="{StaticResource TextMutedBrush}" FontSize="12" Margin="0,0,0,20"
                                   TextWrapping="Wrap" FontFamily="Segoe UI"/>

                        <!-- Feature Card: Audit Log -->
                        <Border Background="{StaticResource CardBgBrush}" CornerRadius="10"
                                BorderBrush="#2a2b30" BorderThickness="1"
                                Padding="20" Margin="0,0,0,10">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <TextBlock Text="&#x1F4CB;" FontSize="24" VerticalAlignment="Top"
                                           Foreground="#7a7d85" Margin="0,0,16,0" Grid.Column="0"/>
                                <StackPanel Grid.Column="1">
                                    <DockPanel>
                                        <CheckBox x:Name="chkAuditLog" Style="{StaticResource ToggleSwitch}"
                                                  DockPanel.Dock="Right" VerticalAlignment="Center"/>
                                        <TextBlock Text="Audit Log" FontSize="15" FontWeight="SemiBold"
                                                   Foreground="{StaticResource TextBrush}" VerticalAlignment="Center"/>
                                    </DockPanel>
                                    <TextBlock Text="Logs every registration to Azure Table Storage for central auditing and compliance."
                                               Foreground="{StaticResource TextMutedBrush}" FontSize="12"
                                               Margin="0,6,0,0" TextWrapping="Wrap"/>
                                </StackPanel>
                            </Grid>
                        </Border>

                        <!-- Feature Card: Teams Notifications -->
                        <Border Background="{StaticResource CardBgBrush}" CornerRadius="10"
                                BorderBrush="#2a2b30" BorderThickness="1"
                                Padding="20" Margin="0,0,0,10">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <TextBlock Text="&#x1F514;" FontSize="24" VerticalAlignment="Top"
                                           Foreground="#7a7d85" Margin="0,0,16,0" Grid.Column="0"/>
                                <StackPanel Grid.Column="1">
                                    <DockPanel>
                                        <CheckBox x:Name="chkTeamsNotify" Style="{StaticResource ToggleSwitch}"
                                                  DockPanel.Dock="Right" VerticalAlignment="Center"/>
                                        <TextBlock Text="Teams Notifications" FontSize="15" FontWeight="SemiBold"
                                                   Foreground="{StaticResource TextBrush}" VerticalAlignment="Center"/>
                                    </DockPanel>
                                    <TextBlock Text="Sends an Adaptive Card to a Teams channel whenever a device is registered."
                                               Foreground="{StaticResource TextMutedBrush}" FontSize="12"
                                               Margin="0,6,0,0" TextWrapping="Wrap"/>
                                </StackPanel>
                            </Grid>
                        </Border>

                        <!-- Feature Card: QR Authentication -->
                        <Border Background="{StaticResource CardBgBrush}" CornerRadius="10"
                                BorderBrush="#2a2b30" BorderThickness="1"
                                Padding="20" Margin="0,0,0,10">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <TextBlock Text="&#x1F511;" FontSize="24" VerticalAlignment="Top"
                                           Foreground="#7a7d85"
                                           Margin="0,0,16,0" Grid.Column="0"/>
                                <StackPanel Grid.Column="1">
                                    <DockPanel>
                                        <CheckBox x:Name="chkEnableQR" Style="{StaticResource ToggleSwitch}"
                                                  DockPanel.Dock="Right" VerticalAlignment="Center"/>
                                        <TextBlock Text="QR Authentication" FontSize="15" FontWeight="SemiBold"
                                                   Foreground="{StaticResource TextBrush}" VerticalAlignment="Center"/>
                                    </DockPanel>
                                    <TextBlock Foreground="{StaticResource TextMutedBrush}" FontSize="12"
                                               Margin="0,6,0,0" TextWrapping="Wrap">
                                        <Run Text="Adds Entra ID user authentication via phone QR scan. "/>
                                        <Run Text="Without this, anyone with the USB can register devices." FontWeight="Bold"/>
                                    </TextBlock>
                                </StackPanel>
                            </Grid>
                        </Border>

                    </StackPanel>
                </ScrollViewer>
            </Border>

            <!-- Step 2: Configure (only shown when Teams or QR is checked) -->
            <Border x:Name="pageStep2" Visibility="Collapsed" Margin="32,12,32,8">
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <StackPanel>
                        <TextBlock Text="Configure" FontSize="20" FontWeight="Bold"
                                   Foreground="{StaticResource TextBrush}" Margin="0,0,0,4"
                                   FontFamily="Segoe UI"/>
                        <TextBlock Text="Enter the configuration details for your selected features."
                                   Foreground="{StaticResource TextMutedBrush}" FontSize="12" Margin="0,0,0,20"
                                   TextWrapping="Wrap" FontFamily="Segoe UI"/>

                        <!-- Teams Config Card -->
                        <Border x:Name="panelTeamsConfig" Background="{StaticResource CardBgBrush}" CornerRadius="10"
                                BorderBrush="#2a2b30" BorderThickness="1"
                                Padding="18,16" Margin="0,0,0,10" Visibility="Collapsed">
                            <StackPanel>
                                <TextBlock Text="Teams Notifications" FontSize="14" FontWeight="SemiBold"
                                           Foreground="{StaticResource TextBrush}" Margin="0,0,0,10"/>
                                <TextBlock Text="Webhook URL" FontSize="11"
                                           Foreground="{StaticResource TextMutedBrush}" Margin="0,0,0,5"/>
                                <TextBox x:Name="txtTeamsWebhook" FontSize="12" Margin="0,0,0,8"/>
                                <TextBlock x:Name="btnTeamsHelp" Text="&#x2139;  How to get a webhook URL"
                                           FontSize="11" Foreground="{StaticResource AccentBrush}" Cursor="Hand"
                                           Margin="0,0,0,0"/>
                                <Border x:Name="panelTeamsHelp" Background="#15161a" CornerRadius="6" Padding="12,10"
                                        Margin="0,8,0,0" Visibility="Collapsed">
                                    <TextBlock TextWrapping="Wrap" FontSize="10.5" Foreground="#5a5d65" LineHeight="18"
                                               Text="1. Open the Teams channel > ... > Workflows&#x0a;2. Search 'Send webhook alerts to a channel'&#x0a;3. Name it (e.g. 'Autopilot Notifications'), select the channel&#x0a;4. Copy the webhook URL and paste it above"/>
                                </Border>
                            </StackPanel>
                        </Border>

                        <!-- QR Config Card -->
                        <Border x:Name="panelQRConfig" Background="{StaticResource CardBgBrush}" CornerRadius="10"
                                BorderBrush="#2a2b30" BorderThickness="1"
                                Padding="18,16" Margin="0,0,0,10" Visibility="Collapsed">
                            <StackPanel>
                                <TextBlock Text="QR Authentication" FontSize="14" FontWeight="SemiBold"
                                           Foreground="{StaticResource TextBrush}" Margin="0,0,0,12"/>

                                <!-- Auto vs Manual choice -->
                                <Grid Margin="0,0,0,14">
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="10"/>
                                        <ColumnDefinition Width="*"/>
                                    </Grid.ColumnDefinitions>
                                    <Border x:Name="cardQRAutomatic" Grid.Column="0" Background="#15161a"
                                            CornerRadius="8" BorderBrush="{StaticResource AccentBrush}" BorderThickness="2"
                                            Padding="14,12" Cursor="Hand">
                                        <StackPanel>
                                            <TextBlock Text="&#x26A1; Automatic" FontSize="13" FontWeight="SemiBold"
                                                       Foreground="{StaticResource TextBrush}" Margin="0,0,0,4"/>
                                            <TextBlock Text="Creates App Registration and Security Group for you during deploy."
                                                       FontSize="10.5" Foreground="{StaticResource TextMutedBrush}"
                                                       TextWrapping="Wrap"/>
                                        </StackPanel>
                                    </Border>
                                    <Border x:Name="cardQRManual" Grid.Column="2" Background="#15161a"
                                            CornerRadius="8" BorderBrush="#2a2b30" BorderThickness="1"
                                            Padding="14,12" Cursor="Hand">
                                        <StackPanel>
                                            <TextBlock Text="&#x270E; Manual" FontSize="13" FontWeight="SemiBold"
                                                       Foreground="{StaticResource TextBrush}" Margin="0,0,0,4"/>
                                            <TextBlock Text="Enter existing Tenant ID, Client ID, and Group ID manually."
                                                       FontSize="10.5" Foreground="{StaticResource TextMutedBrush}"
                                                       TextWrapping="Wrap"/>
                                        </StackPanel>
                                    </Border>
                                </Grid>

                                <!-- Automatic mode info -->
                                <Border x:Name="panelQRAuto" Background="#15161a" CornerRadius="6" Padding="14,12">
                                    <StackPanel>
                                        <TextBlock Text="The following will be created during the Backend deploy step:"
                                                   FontSize="11" Foreground="{StaticResource TextMutedBrush}" Margin="0,0,0,8"/>
                                        <TextBlock Text="&#x2022;  App Registration 'autopilot-tool-approval' (SPA with redirect URI)"
                                                   FontSize="11" Foreground="#5a5d65" Margin="0,0,0,3"/>
                                        <TextBlock Text="&#x2022;  API permissions: openid, profile (delegated)"
                                                   FontSize="11" Foreground="#5a5d65" Margin="0,0,0,3"/>
                                        <TextBlock Text="&#x2022;  Security Group 'AutopilotRegistrators'"
                                                   FontSize="11" Foreground="#5a5d65" Margin="0,0,0,3"/>
                                        <TextBlock Text="&#x2022;  IDs auto-populated after deploy completes"
                                                   FontSize="11" Foreground="#5a5d65"/>
                                        <TextBlock Text="Requires: Microsoft.Graph PowerShell module + Global Admin or App Admin role"
                                                   FontSize="10" Foreground="#4a4d55" Margin="0,8,0,0" FontStyle="Italic"/>
                                    </StackPanel>
                                </Border>

                                <!-- Manual mode fields -->
                                <StackPanel x:Name="panelQRManual" Visibility="Collapsed">
                                    <Grid Margin="0,0,0,8">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="12"/>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="12"/>
                                            <ColumnDefinition Width="*"/>
                                        </Grid.ColumnDefinitions>
                                        <StackPanel Grid.Column="0">
                                            <TextBlock Text="Tenant ID" FontSize="11"
                                                       Foreground="{StaticResource TextMutedBrush}" Margin="0,0,0,5"/>
                                            <TextBox x:Name="txtTenantId" FontSize="12"/>
                                        </StackPanel>
                                        <StackPanel Grid.Column="2">
                                            <TextBlock Text="Client ID" FontSize="11"
                                                       Foreground="{StaticResource TextMutedBrush}" Margin="0,0,0,5"/>
                                            <TextBox x:Name="txtClientId" FontSize="12"/>
                                        </StackPanel>
                                        <StackPanel Grid.Column="4">
                                            <TextBlock Text="Security Group ID" FontSize="11"
                                                       Foreground="{StaticResource TextMutedBrush}" Margin="0,0,0,5"/>
                                            <TextBox x:Name="txtGroupId" FontSize="12"/>
                                        </StackPanel>
                                    </Grid>
                                    <TextBlock x:Name="btnQRHelp" Text="&#x2139;  How to set up Entra ID App Registration"
                                               FontSize="11" Foreground="{StaticResource AccentBrush}" Cursor="Hand"/>
                                    <Border x:Name="panelQRHelp" Background="#15161a" CornerRadius="6" Padding="12,10"
                                            Margin="0,8,0,0" Visibility="Collapsed">
                                        <TextBlock TextWrapping="Wrap" FontSize="10.5" Foreground="#5a5d65" LineHeight="18"
                                                   Text="1. Azure Portal > Entra ID > App registrations > New&#x0a;2. Name: 'Autopilot Tool Approval'&#x0a;3. Redirect URI (SPA): https://your-func.azurewebsites.net/api/approve&#x0a;4. API permissions: openid, profile (delegated)&#x0a;5. Create security group and add technicians"/>
                                    </Border>
                                </StackPanel>
                            </StackPanel>
                        </Border>
                    </StackPanel>
                </ScrollViewer>
            </Border>

            <!-- Step 3: Backend -->
            <Border x:Name="pageStep3" Visibility="Collapsed" Margin="32,8,32,4">
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <StackPanel>
                        <TextBlock Text="Backend" FontSize="18" FontWeight="Bold"
                                   Foreground="{StaticResource TextBrush}" Margin="0,0,0,2"
                                   FontFamily="Segoe UI"/>
                        <TextBlock Text="Choose how to set up the Azure Function backend."
                                   Foreground="{StaticResource TextMutedBrush}" FontSize="11" Margin="0,0,0,12"
                                   TextWrapping="Wrap" FontFamily="Segoe UI"/>

                        <!-- Backend option cards (compact horizontal) -->
                        <Grid Margin="0,0,0,12">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="8"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="8"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>

                            <Border x:Name="cardExisting" Grid.Column="0" Background="{StaticResource CardBgBrush}"
                                    CornerRadius="8" BorderBrush="#4da3ff" BorderThickness="2"
                                    Padding="12,10" Cursor="Hand">
                                <StackPanel Orientation="Horizontal">
                                    <TextBlock Text="&#x2601;" FontSize="18" Foreground="{StaticResource TextBrush}"
                                               VerticalAlignment="Center" Margin="0,0,10,0"/>
                                    <StackPanel VerticalAlignment="Center">
                                        <TextBlock Text="Existing" FontSize="13" FontWeight="SemiBold"
                                                   Foreground="{StaticResource TextBrush}"/>
                                        <TextBlock Text="Already deployed" FontSize="10"
                                                   Foreground="{StaticResource TextMutedBrush}"/>
                                    </StackPanel>
                                </StackPanel>
                            </Border>

                            <Border x:Name="cardAutomated" Grid.Column="2" Background="{StaticResource CardBgBrush}"
                                    CornerRadius="8" BorderBrush="#2a2b30" BorderThickness="1"
                                    Padding="12,10" Cursor="Hand">
                                <Grid>
                                    <StackPanel Orientation="Horizontal">
                                        <TextBlock Text="&#x26A1;" FontSize="18" Foreground="{StaticResource TextBrush}"
                                                   VerticalAlignment="Center" Margin="0,0,10,0"/>
                                        <StackPanel VerticalAlignment="Center">
                                            <TextBlock Text="Automated" FontSize="13" FontWeight="SemiBold"
                                                       Foreground="{StaticResource TextBrush}"/>
                                            <TextBlock Text="Deploy for you" FontSize="10"
                                                       Foreground="{StaticResource TextMutedBrush}"/>
                                        </StackPanel>
                                    </StackPanel>
                                    <Border Background="#0d3320" CornerRadius="4" Padding="6,2"
                                            HorizontalAlignment="Right" VerticalAlignment="Top"
                                            Margin="0,-4,-4,0">
                                        <TextBlock Text="Recommended" FontSize="9" FontWeight="SemiBold"
                                                   Foreground="#34d399"/>
                                    </Border>
                                </Grid>
                            </Border>

                            <Border x:Name="cardManual" Grid.Column="4" Background="{StaticResource CardBgBrush}"
                                    CornerRadius="8" BorderBrush="#2a2b30" BorderThickness="1"
                                    Padding="12,10" Cursor="Hand">
                                <StackPanel Orientation="Horizontal">
                                    <TextBlock Text="&#x2263;" FontSize="18" Foreground="{StaticResource TextBrush}"
                                               VerticalAlignment="Center" Margin="0,0,10,0"/>
                                    <StackPanel VerticalAlignment="Center">
                                        <TextBlock Text="Manual" FontSize="13" FontWeight="SemiBold"
                                                   Foreground="{StaticResource TextBrush}"/>
                                        <TextBlock Text="CLI guide" FontSize="10"
                                                   Foreground="{StaticResource TextMutedBrush}"/>
                                    </StackPanel>
                                </StackPanel>
                            </Border>
                        </Grid>

                        <!-- Hidden radio buttons for state tracking -->
                        <RadioButton x:Name="radioExisting" IsChecked="True" GroupName="AzureSetup"
                                     Visibility="Collapsed"/>
                        <RadioButton x:Name="radioNew" GroupName="AzureSetup" Visibility="Collapsed"/>
                        <RadioButton x:Name="radioManual" GroupName="AzureSetup" Visibility="Collapsed"/>

                        <!-- Panel: Existing Function -->
                        <Border x:Name="panelExisting" Background="{StaticResource CardBgBrush}"
                                CornerRadius="10" BorderBrush="#2a2b30" BorderThickness="1"
                                Padding="20" Margin="0,0,0,8">
                            <StackPanel>
                                <TextBlock Text="Function URL" FontSize="12"
                                           Foreground="{StaticResource TextMutedBrush}" Margin="0,0,0,6"/>
                                <TextBox x:Name="txtExistingUrl" Text="https://" Margin="0,0,0,12"/>
                                <TextBlock Text="Function Key" FontSize="12"
                                           Foreground="{StaticResource TextMutedBrush}" Margin="0,0,0,6"/>
                                <PasswordBox x:Name="txtExistingKey" Margin="0,0,0,14"/>
                                <StackPanel Orientation="Horizontal">
                                    <Button x:Name="btnTestExisting" Content="Test Connection"
                                            Style="{StaticResource DefaultButton}"/>
                                    <TextBlock x:Name="lblTestExisting" Text="" VerticalAlignment="Center"
                                               Margin="14,0,0,0" FontSize="12"/>
                                </StackPanel>
                            </StackPanel>
                        </Border>

                        <!-- Panel: Automated Setup -->
                        <Border x:Name="panelNew" Background="{StaticResource CardBgBrush}"
                                CornerRadius="10" BorderBrush="#2a2b30" BorderThickness="1"
                                Padding="20" Margin="0,0,0,8" Visibility="Collapsed">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="16"/>
                                    <ColumnDefinition Width="280"/>
                                </Grid.ColumnDefinitions>

                                <StackPanel Grid.Column="0">
                                    <StackPanel Orientation="Horizontal" Margin="0,0,0,14">
                                        <Button x:Name="btnSignIn" Content="Sign in to Azure"
                                                Style="{StaticResource PrimaryButton}" Padding="14,8"/>
                                        <TextBlock x:Name="lblSignInStatus" Text="" VerticalAlignment="Center"
                                                   Margin="12,0,0,0" FontSize="11"/>
                                    </StackPanel>

                                    <StackPanel x:Name="panelDeployConfig" Visibility="Collapsed">
                                        <TextBlock Text="Subscription" FontSize="11"
                                                   Foreground="{StaticResource TextMutedBrush}" Margin="0,0,0,4"/>
                                        <ComboBox x:Name="cmbSubscription" MaxDropDownHeight="250" Margin="0,0,0,10"/>

                                        <Grid Margin="0,0,0,10">
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="*"/>
                                                <ColumnDefinition Width="10"/>
                                                <ColumnDefinition Width="*"/>
                                            </Grid.ColumnDefinitions>
                                            <StackPanel Grid.Column="0">
                                                <TextBlock Text="Resource Group" FontSize="11"
                                                           Foreground="{StaticResource TextMutedBrush}" Margin="0,0,0,4"/>
                                                <TextBox x:Name="txtResourceGroup" Text="rg-autopilot-tool"/>
                                            </StackPanel>
                                            <StackPanel Grid.Column="2">
                                                <TextBlock Text="Name Prefix" FontSize="11"
                                                           Foreground="{StaticResource TextMutedBrush}" Margin="0,0,0,4"/>
                                                <TextBox x:Name="txtPrefix" Text="autopilot-tool"/>
                                            </StackPanel>
                                        </Grid>

                                        <TextBlock Text="Location" FontSize="11"
                                                   Foreground="{StaticResource TextMutedBrush}" Margin="0,0,0,4"/>
                                        <ComboBox x:Name="cmbLocation" SelectedIndex="0" MaxDropDownHeight="300" Margin="0,0,0,12">
                                            <ComboBoxItem Content="westeurope"/>
                                            <ComboBoxItem Content="northeurope"/>
                                            <ComboBoxItem Content="swedencentral"/>
                                            <ComboBoxItem Content="uksouth"/>
                                            <ComboBoxItem Content="ukwest"/>
                                            <ComboBoxItem Content="francecentral"/>
                                            <ComboBoxItem Content="germanywestcentral"/>
                                            <ComboBoxItem Content="switzerlandnorth"/>
                                            <ComboBoxItem Content="norwayeast"/>
                                            <ComboBoxItem Content="polandcentral"/>
                                            <ComboBoxItem Content="italynorth"/>
                                            <ComboBoxItem Content="spaincentral"/>
                                            <ComboBoxItem Content="eastus"/>
                                            <ComboBoxItem Content="eastus2"/>
                                            <ComboBoxItem Content="centralus"/>
                                            <ComboBoxItem Content="westus2"/>
                                            <ComboBoxItem Content="westus3"/>
                                            <ComboBoxItem Content="southcentralus"/>
                                            <ComboBoxItem Content="canadacentral"/>
                                            <ComboBoxItem Content="canadaeast"/>
                                            <ComboBoxItem Content="australiaeast"/>
                                            <ComboBoxItem Content="southeastasia"/>
                                            <ComboBoxItem Content="eastasia"/>
                                            <ComboBoxItem Content="japaneast"/>
                                            <ComboBoxItem Content="uaenorth"/>
                                            <ComboBoxItem Content="southafricanorth"/>
                                            <ComboBoxItem Content="brazilsouth"/>
                                        </ComboBox>

                                        <!-- Deploy checklist -->
                                        <TextBlock Text="WILL BE CREATED" FontWeight="SemiBold" FontSize="10"
                                                   Foreground="#5a5d65" Margin="0,0,0,8"/>
                                        <CheckBox x:Name="chkDeployInfra" IsChecked="True" IsEnabled="False"
                                                  Foreground="{StaticResource TextMutedBrush}" FontSize="11"
                                                  Content="Resource Group + Storage + Function App" Margin="0,0,0,4"/>
                                        <CheckBox x:Name="chkDeployGraph" IsChecked="True"
                                                  Foreground="{StaticResource TextMutedBrush}" FontSize="11"
                                                  Content="Graph API Permission" Margin="0,0,0,4"/>
                                        <CheckBox x:Name="chkDeployCode" IsChecked="True" IsEnabled="False"
                                                  Foreground="{StaticResource TextMutedBrush}" FontSize="11"
                                                  Content="Deploy Function Code" Margin="0,0,0,4"/>
                                        <CheckBox x:Name="chkDeployAppReg" Visibility="Collapsed"
                                                  IsChecked="True"
                                                  Foreground="{StaticResource TextMutedBrush}" FontSize="11"
                                                  Content="Entra ID App Registration (QR)" Margin="0,0,0,4"/>
                                        <CheckBox x:Name="chkDeploySecGroup" Visibility="Collapsed"
                                                  IsChecked="True"
                                                  Foreground="{StaticResource TextMutedBrush}" FontSize="11"
                                                  Content="Security Group (QR)" Margin="0,0,0,4"/>
                                        <CheckBox x:Name="chkDeploySettings" IsChecked="True" IsEnabled="False"
                                                  Foreground="{StaticResource TextMutedBrush}" FontSize="11"
                                                  Content="Configure App Settings" Margin="0,0,0,14"/>

                                        <Button x:Name="btnDeploy" Content="Deploy"
                                                Style="{StaticResource PrimaryButton}" Padding="14,10"
                                                FontSize="13" HorizontalAlignment="Stretch"/>
                                    </StackPanel>
                                </StackPanel>

                                <Border Grid.Column="2" Background="#15161a" CornerRadius="10" Padding="16">
                                    <StackPanel>
                                        <TextBlock Text="PROGRESS" FontWeight="SemiBold" FontSize="11"
                                                   Foreground="{StaticResource AccentBrush}" Margin="0,0,0,12"/>
                                        <StackPanel x:Name="panelSteps">
                                            <Grid Margin="0,4,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="22"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                                <TextBlock x:Name="icoStep1" Text="&#x25CB;" Grid.Column="0" FontSize="13" Foreground="{StaticResource TextMutedBrush}" VerticalAlignment="Center"/>
                                                <TextBlock x:Name="lblStep1" Text="Resource Group" Grid.Column="1" FontSize="11" Foreground="{StaticResource TextMutedBrush}" VerticalAlignment="Center"/>
                                            </Grid>
                                            <Grid Margin="0,4,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="22"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                                <TextBlock x:Name="icoStep2" Text="&#x25CB;" Grid.Column="0" FontSize="13" Foreground="{StaticResource TextMutedBrush}" VerticalAlignment="Center"/>
                                                <TextBlock x:Name="lblStep2" Text="Storage Account" Grid.Column="1" FontSize="11" Foreground="{StaticResource TextMutedBrush}" VerticalAlignment="Center"/>
                                            </Grid>
                                            <Grid Margin="0,4,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="22"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                                <TextBlock x:Name="icoStep3" Text="&#x25CB;" Grid.Column="0" FontSize="13" Foreground="{StaticResource TextMutedBrush}" VerticalAlignment="Center"/>
                                                <TextBlock x:Name="lblStep3" Text="Function App" Grid.Column="1" FontSize="11" Foreground="{StaticResource TextMutedBrush}" VerticalAlignment="Center"/>
                                            </Grid>
                                            <Grid Margin="0,4,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="22"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                                <TextBlock x:Name="icoStep4" Text="&#x25CB;" Grid.Column="0" FontSize="13" Foreground="{StaticResource TextMutedBrush}" VerticalAlignment="Center"/>
                                                <TextBlock x:Name="lblStep4" Text="Graph Permission" Grid.Column="1" FontSize="11" Foreground="{StaticResource TextMutedBrush}" VerticalAlignment="Center"/>
                                            </Grid>
                                            <Grid Margin="0,4,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="22"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                                <TextBlock x:Name="icoStep5" Text="&#x25CB;" Grid.Column="0" FontSize="13" Foreground="{StaticResource TextMutedBrush}" VerticalAlignment="Center"/>
                                                <TextBlock x:Name="lblStep5" Text="Deploy Code" Grid.Column="1" FontSize="11" Foreground="{StaticResource TextMutedBrush}" VerticalAlignment="Center"/>
                                            </Grid>
                                            <Grid x:Name="deployStepAppReg" Margin="0,4,0,0" Visibility="Collapsed"><Grid.ColumnDefinitions><ColumnDefinition Width="22"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                                <TextBlock x:Name="icoStep6" Text="&#x25CB;" Grid.Column="0" FontSize="13" Foreground="{StaticResource TextMutedBrush}" VerticalAlignment="Center"/>
                                                <TextBlock x:Name="lblStep6" Text="App Registration" Grid.Column="1" FontSize="11" Foreground="{StaticResource TextMutedBrush}" VerticalAlignment="Center"/>
                                            </Grid>
                                            <Grid x:Name="deployStepSecGroup" Margin="0,4,0,0" Visibility="Collapsed"><Grid.ColumnDefinitions><ColumnDefinition Width="22"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                                <TextBlock x:Name="icoStep7" Text="&#x25CB;" Grid.Column="0" FontSize="13" Foreground="{StaticResource TextMutedBrush}" VerticalAlignment="Center"/>
                                                <TextBlock x:Name="lblStep7" Text="Security Group" Grid.Column="1" FontSize="11" Foreground="{StaticResource TextMutedBrush}" VerticalAlignment="Center"/>
                                            </Grid>
                                            <Grid Margin="0,4,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="22"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                                <TextBlock x:Name="icoStep8" Text="&#x25CB;" Grid.Column="0" FontSize="13" Foreground="{StaticResource TextMutedBrush}" VerticalAlignment="Center"/>
                                                <TextBlock x:Name="lblStep8" Text="App Settings" Grid.Column="1" FontSize="11" Foreground="{StaticResource TextMutedBrush}" VerticalAlignment="Center"/>
                                            </Grid>
                                        </StackPanel>
                                        <TextBlock x:Name="lblDeployError" Text="" FontSize="10"
                                                   Foreground="{StaticResource ErrorBrush}"
                                                   TextWrapping="Wrap" Margin="0,10,0,0"/>
                                    </StackPanel>
                                </Border>
                            </Grid>
                        </Border>

                        <!-- Panel: Manual Setup Guide -->
                        <Border x:Name="panelManual" Background="{StaticResource CardBgBrush}"
                                CornerRadius="10" BorderBrush="#2a2b30" BorderThickness="1"
                                Padding="16,14" Margin="0,0,0,8" Visibility="Collapsed">
                            <StackPanel>
                                <TextBlock Text="Run these commands in PowerShell or Azure CLI. After completing, click Next to enter your URL and key."
                                           Foreground="{StaticResource TextMutedBrush}" FontSize="11"
                                           TextWrapping="Wrap" Margin="0,0,0,10"/>
                                <TextBox x:Name="txtCliCommands" Height="180" IsReadOnly="True"
                                         TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"
                                         FontFamily="Cascadia Mono,Consolas" FontSize="11"
                                         Background="#15161a" BorderThickness="0" Padding="12"
                                         AcceptsReturn="True"/>
                                <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
                                    <Button x:Name="btnCopyCommands" Content="Copy to Clipboard"
                                            Style="{StaticResource DefaultButton}"/>
                                    <TextBlock x:Name="lblCopied" Text="" VerticalAlignment="Center"
                                               Margin="14,0,0,0" FontSize="12"
                                               Foreground="{StaticResource SuccessBrush}"/>
                                </StackPanel>
                            </StackPanel>
                        </Border>

                    </StackPanel>
                </ScrollViewer>
            </Border>

            <!-- Step 4: Validate Connection -->
            <Border x:Name="pageStep4" Visibility="Collapsed" Margin="32,12,32,8">
                <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center" Width="520">
                    <TextBlock Text="Validate Connection" FontSize="20" FontWeight="Bold"
                               Foreground="{StaticResource TextBrush}" Margin="0,0,0,4"
                               FontFamily="Segoe UI"/>
                    <TextBlock Text="Enter your Azure Function URL and key, then test the connection before continuing."
                               Foreground="{StaticResource TextMutedBrush}" FontSize="12" Margin="0,0,0,24"
                               TextWrapping="Wrap" FontFamily="Segoe UI"/>

                    <Border Background="{StaticResource CardBgBrush}" CornerRadius="10"
                            BorderBrush="#2a2b30" BorderThickness="1" Padding="20" Margin="0,0,0,16">
                        <StackPanel>
                            <TextBlock Text="Function URL" FontSize="12"
                                       Foreground="{StaticResource TextMutedBrush}" Margin="0,0,0,6"/>
                            <TextBox x:Name="txtValidateUrl" Text="https://" Margin="0,0,0,12"/>
                            <TextBlock Text="Function Key" FontSize="12"
                                       Foreground="{StaticResource TextMutedBrush}" Margin="0,0,0,6"/>
                            <PasswordBox x:Name="txtValidateKey" Margin="0,0,0,14"/>
                            <StackPanel Orientation="Horizontal">
                                <Button x:Name="btnValidateTest" Content="Test Connection"
                                        Style="{StaticResource DefaultButton}" Padding="14,8"/>
                                <TextBlock x:Name="lblValidateStatus" Text="" VerticalAlignment="Center"
                                           Margin="14,0,0,0" FontSize="12"/>
                            </StackPanel>
                        </StackPanel>
                    </Border>

                    <TextBlock x:Name="btnValidateHelp" Text="&#x2139;  Where to find the URL and key"
                               FontSize="11" Foreground="{StaticResource AccentBrush}" Cursor="Hand"/>
                    <Border x:Name="panelValidateHelp" Background="{StaticResource CardBgBrush}" CornerRadius="8"
                            BorderBrush="#2a2b30" BorderThickness="1" Padding="16,14"
                            Margin="0,8,0,0" Visibility="Collapsed">
                        <StackPanel>
                            <TextBlock Text="Where to find these in Azure Portal:" FontSize="11" FontWeight="SemiBold"
                                       Foreground="{StaticResource TextMutedBrush}" Margin="0,0,0,8"/>
                            <TextBlock TextWrapping="Wrap" FontSize="11" Foreground="#5a5d65" LineHeight="20"
                                       Text="1. Go to Azure Portal &#x2192; Function App &#x2192; your function app&#x0a;2. URL: Overview &#x2192; Default domain&#x0a;3. Key: App keys &#x2192; default (under Host keys)&#x0a;&#x0a;If you used Automated deploy, the URL was pre-filled. You still need to copy the key from the portal — it takes a few minutes for RBAC to propagate after deploy."/>
                        </StackPanel>
                    </Border>
                </StackPanel>
            </Border>

            <!-- Step 5: Branding & Tags -->
            <Border x:Name="pageStep5" Visibility="Collapsed" Margin="32,12,32,8">
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <StackPanel>
                        <TextBlock Text="Branding &amp; Group Tags" FontSize="20" FontWeight="Bold"
                                   Foreground="{StaticResource TextBrush}" Margin="0,0,0,4"
                                   FontFamily="Segoe UI"/>
                        <TextBlock Text="Configure how the field tool looks and what group tags are available."
                                   Foreground="{StaticResource TextMutedBrush}" FontSize="12" Margin="0,0,0,20"
                                   TextWrapping="Wrap" FontFamily="Segoe UI"/>

                        <!-- Company Card -->
                        <Border Background="{StaticResource CardBgBrush}" CornerRadius="10"
                                BorderBrush="#2a2b30" BorderThickness="1"
                                Padding="20" Margin="0,0,0,12">
                            <StackPanel>
                                <TextBlock Text="Company" FontSize="14" FontWeight="SemiBold"
                                           Foreground="{StaticResource TextBrush}" Margin="0,0,0,12"/>
                                <TextBlock Text="Company Name" FontSize="12"
                                           Foreground="{StaticResource TextMutedBrush}" Margin="0,0,0,6"/>
                                <TextBox x:Name="txtCompanyName" Text="Your Company" Margin="0,0,0,8"/>
                                <TextBlock Text="Displays as: [Company Name] - Autopilot Registration" FontSize="11"
                                           Foreground="{StaticResource TextMutedBrush}"/>
                            </StackPanel>
                        </Border>

                        <!-- Group Tags Card -->
                        <Border Background="{StaticResource CardBgBrush}" CornerRadius="10"
                                BorderBrush="#2a2b30" BorderThickness="1"
                                Padding="20" Margin="0,0,0,12">
                            <StackPanel>
                                <TextBlock Text="Group Tags" FontSize="14" FontWeight="SemiBold"
                                           Foreground="{StaticResource TextBrush}" Margin="0,0,0,12"/>

                                <Grid Margin="0,0,0,10">
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <ListBox x:Name="tagListBox" Grid.Column="0" Height="120" Margin="0,0,8,0"/>
                                    <StackPanel Grid.Column="1" VerticalAlignment="Top">
                                        <Button x:Name="btnTagUp" Content="&#x25B2;" Style="{StaticResource DefaultButton}"
                                                Padding="8,4" Margin="0,0,0,4" FontSize="11"/>
                                        <Button x:Name="btnTagDown" Content="&#x25BC;" Style="{StaticResource DefaultButton}"
                                                Padding="8,4" FontSize="11"/>
                                    </StackPanel>
                                </Grid>
                                <Grid Margin="0,0,0,14">
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBox x:Name="txtNewTag" Grid.Column="0" Margin="0,0,6,0"/>
                                    <Button x:Name="btnAddTag" Content="Add" Grid.Column="1"
                                            Style="{StaticResource DefaultButton}" Padding="12,6" Margin="0,0,4,0"/>
                                    <Button x:Name="btnRemoveTag" Content="Remove" Grid.Column="2"
                                            Style="{StaticResource DefaultButton}" Padding="12,6"/>
                                </Grid>
                                <TextBlock Text="Default Tag" FontSize="12"
                                           Foreground="{StaticResource TextMutedBrush}" Margin="0,0,0,6"/>
                                <ComboBox x:Name="txtDefaultTag" MaxDropDownHeight="200" Width="220"
                                          HorizontalAlignment="Left"/>
                            </StackPanel>
                        </Border>
                    </StackPanel>
                </ScrollViewer>
            </Border>

            <!-- Step 6: Generate -->
            <Border x:Name="pageStep6" Visibility="Collapsed" Margin="32,12,32,8">
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <StackPanel>
                        <TextBlock Text="Generate Field Tool" FontSize="20" FontWeight="Bold"
                                   Foreground="{StaticResource TextBrush}" Margin="0,0,0,4"
                                   FontFamily="Segoe UI"/>
                        <TextBlock Text="Review your configuration and generate the field tool for USB deployment."
                                   Foreground="{StaticResource TextMutedBrush}" FontSize="12" Margin="0,0,0,20"
                                   TextWrapping="Wrap" FontFamily="Segoe UI"/>

                        <!-- Summary Card -->
                        <Border Background="{StaticResource CardBgBrush}" CornerRadius="10"
                                BorderBrush="#2a2b30" BorderThickness="1"
                                Padding="20" Margin="0,0,0,16">
                            <StackPanel>
                                <TextBlock Text="Configuration Summary" FontSize="14" FontWeight="SemiBold"
                                           Foreground="{StaticResource TextBrush}" Margin="0,0,0,12"/>
                                <TextBox x:Name="txtSummary" Height="140" IsReadOnly="True" TextWrapping="Wrap"
                                         VerticalScrollBarVisibility="Auto" FontFamily="Cascadia Mono,Consolas"
                                         FontSize="12" Background="#15161a" BorderThickness="0" Padding="14"
                                         AcceptsReturn="True"/>
                            </StackPanel>
                        </Border>

                        <!-- Test -->
                        <StackPanel Orientation="Horizontal" Margin="0,0,0,18">
                            <Button x:Name="btnTestFinal" Content="Test Connection"
                                    Style="{StaticResource DefaultButton}"/>
                            <TextBlock x:Name="lblFinalTest" Text="" VerticalAlignment="Center"
                                       Margin="14,0,0,0" FontSize="12"/>
                        </StackPanel>

                        <!-- Generate -->
                        <Button x:Name="btnGenerate" Content="Generate Field Tool"
                                Style="{StaticResource PrimaryButton}" Padding="16,14"
                                FontSize="15" HorizontalAlignment="Stretch" Margin="0,0,0,16"/>

                        <TextBlock x:Name="lblGenResult" Text="" TextWrapping="Wrap"
                                   Foreground="{StaticResource SuccessBrush}" FontSize="12"/>
                    </StackPanel>
                </ScrollViewer>
            </Border>

        </Grid>

        <!-- Navigation Bar -->
        <Border Grid.Row="2" Background="#141418" BorderBrush="#1e1f24" BorderThickness="0,1,0,0">
            <Grid Margin="32,0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>

                <Button x:Name="btnSkip" Content="Skip" Grid.Column="0"
                        Style="{StaticResource GhostButton}" Padding="16,8"
                        VerticalAlignment="Center" Visibility="Collapsed"/>

                <Button x:Name="btnBack" Content="Back" Grid.Column="2"
                        Style="{StaticResource DefaultButton}" Padding="20,8"
                        VerticalAlignment="Center" Margin="0,0,10,0" Visibility="Collapsed"/>

                <Button x:Name="btnNext" Content="Next &#x2192;" Grid.Column="3"
                        Style="{StaticResource PrimaryButton}" Padding="24,8"
                        VerticalAlignment="Center" FontSize="13" Visibility="Collapsed"/>
            </Grid>
        </Border>

    </Grid>
</Window>
"@

# Remove x:Name -> Name for PowerShell compatibility, preserve x:Key
$processedXaml = $xamlString -replace 'x:Name="', 'Name="'
[xml]$xaml = $processedXaml
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [System.Windows.Markup.XamlReader]::Load($reader)

# --- Find all named elements ---
$ui = @{}
$namedElements = @(
    'stepIndicatorBar','dot1','dot2','dot3','dot4','dot5','dot6','stepNameLabel',
    'pageStep0','pageStep1','pageStep2','pageStep3','pageStep4','pageStep5','pageStep6',
    'btnStartBuild',
    'chkAuditLog','chkTeamsNotify','chkEnableQR',
    'panelTeamsConfig','txtTeamsWebhook','btnTeamsHelp','panelTeamsHelp',
    'panelQRConfig','cardQRAutomatic','cardQRManual','panelQRAuto','panelQRManual',
    'txtTenantId','txtClientId','txtGroupId','btnQRHelp','panelQRHelp',
    'cardExisting','cardAutomated','cardManual',
    'radioExisting','radioNew','radioManual',
    'panelExisting','panelNew','panelManual',
    'txtExistingUrl','txtExistingKey','btnTestExisting','lblTestExisting',
    'btnSignIn','lblSignInStatus','panelDeployConfig','cmbSubscription',
    'txtResourceGroup','cmbLocation','txtPrefix','btnDeploy',
    'panelSteps','icoStep1','lblStep1','icoStep2','lblStep2','icoStep3','lblStep3',
    'icoStep4','lblStep4','icoStep5','lblStep5',
    'deployStepAppReg','icoStep6','lblStep6','deployStepSecGroup','icoStep7','lblStep7',
    'icoStep8','lblStep8',
    'chkDeployInfra','chkDeployGraph','chkDeployCode','chkDeployAppReg','chkDeploySecGroup','chkDeploySettings',
    'lblDeployError',
    'txtCliCommands','btnCopyCommands','lblCopied',
    'txtValidateUrl','txtValidateKey','btnValidateTest','lblValidateStatus','btnValidateHelp','panelValidateHelp',
    'txtCompanyName',
    'tagListBox','txtNewTag','btnAddTag','btnRemoveTag','btnTagUp','btnTagDown','txtDefaultTag',
    'txtSummary','btnTestFinal','lblFinalTest','btnGenerate','lblGenResult',
    'btnSkip','btnBack','btnNext'
)
foreach ($name in $namedElements) {
    $el = $window.FindName($name)
    if ($el) { $ui[$name] = $el }
    else { Write-Warning "Element not found: $name" }
}

# --- Pre-populate tag list ---
$ui.tagListBox.Items.Add('Standard') | Out-Null
$ui.tagListBox.Items.Add('Kiosk') | Out-Null
$ui.tagListBox.Items.Add('Shared') | Out-Null

# --- CLI commands text ---
$cliCommands = @"
# 1. Login to Azure
az login

# 2. Create resource group
az group create --name rg-autopilot-tool --location westeurope

# 3. Deploy the Azure Function
az deployment group create `
  --resource-group rg-autopilot-tool `
  --template-file azure-function/deploy.json `
  --parameters namePrefix=autopilot-tool

# 4. Note the outputs: functionAppName, functionAppUrl, managedIdentityPrincipalId

# 5. Grant Graph API permission (requires Global Admin)
#    Add -IncludeGroupRead if using QR authentication
.\setup\Grant-GraphPermission.ps1 -ManagedIdentityPrincipalId "<principalId>" -IncludeGroupRead

# 6. Deploy function code
cd azure-function
func azure functionapp publish <functionAppName>

# 7. Get the function key
az functionapp keys list --name <functionAppName> `
  --resource-group rg-autopilot-tool `
  --query "functionKeys.default" -o tsv
"@
$ui.txtCliCommands.Text = $cliCommands

# --- Step names for the indicator (steps 1-6 displayed, step 0 = Welcome has no indicator) ---
$stepNames = @{
    1 = 'Features'
    2 = 'Configure'
    3 = 'Backend'
    4 = 'Validate'
    5 = 'Branding'
    6 = 'Generate'
}

# --- Wizard Navigation Logic ---
function Set-WizardStep {
    param([int]$Step)

    $script:CurrentStep = $Step

    # Hide all pages
    for ($i = 0; $i -le 6; $i++) {
        $ui["pageStep$i"].Visibility = 'Collapsed'
    }

    # Show current page
    $ui["pageStep$Step"].Visibility = 'Visible'

    # Step indicator visibility (hidden on Welcome)
    if ($Step -eq 0) {
        $ui.stepIndicatorBar.Visibility = 'Collapsed'
    }
    else {
        $ui.stepIndicatorBar.Visibility = 'Visible'
        # Update dot indicator
        for ($i = 1; $i -le 6; $i++) {
            $dot = $ui["dot$i"]
            if ($script:StepCompleted[$i] -and $i -ne $Step) {
                $dot.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#34d399')
            }
            elseif ($i -eq $Step) {
                $dot.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#4da3ff')
            }
            else {
                $dot.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#35363b')
            }
        }
        $ui.stepNameLabel.Text = "Step $Step`: $($stepNames[$Step])"
    }

    # Show/hide QR deploy options when entering Backend step
    if ($Step -eq 3) {
        $qrAuto = ($ui.chkEnableQR.IsChecked -eq $true) -and $script:QRAutoMode
        $vis = if ($qrAuto) { 'Visible' } else { 'Collapsed' }
        $ui.chkDeployAppReg.Visibility = $vis
        $ui.chkDeploySecGroup.Visibility = $vis
        $ui.deployStepAppReg.Visibility = $vis
        $ui.deployStepSecGroup.Visibility = $vis
    }

    # Pre-fill validate URL from deploy
    if ($Step -eq 4 -and $script:FunctionUrl -and $ui.txtValidateUrl.Text -eq 'https://') {
        $ui.txtValidateUrl.Text = $script:FunctionUrl
    }

    # Update summary when entering Generate step
    if ($Step -eq 6) {
        Update-Summary
    }

    # Pre-fill validate URL from deploy if available
    if ($Step -eq 4) {
        if ($script:FunctionUrl -and $ui.txtValidateUrl.Text -eq 'https://') {
            $ui.txtValidateUrl.Text = $script:FunctionUrl
        }
    }

    # Navigation buttons
    if ($Step -eq 0) {
        $ui.btnBack.Visibility = 'Collapsed'
        $ui.btnNext.Visibility = 'Collapsed'
        $ui.btnSkip.Visibility = 'Collapsed'
    }
    else {
        $ui.btnBack.Visibility = 'Visible'
        $ui.btnNext.Visibility = if ($Step -eq 6) { 'Collapsed' } else { 'Visible' }
        $ui.btnSkip.Visibility = if ($Step -eq 3) { 'Visible' } else { 'Collapsed' }
        $ui.btnNext.Content = "Next $([char]0x2192)"
    }
}

function Update-Summary {
    $keyPreview = if ($script:FunctionKey) {
        "$($script:FunctionKey.Substring(0, [Math]::Min(8, $script:FunctionKey.Length)))..."
    } else { '(not configured)' }
    $tagList = ($ui.tagListBox.Items | ForEach-Object { $_ }) -join ', '

    $features = @()
    if ($ui.chkAuditLog.IsChecked -eq $true) { $features += 'Audit Log' }
    if ($ui.chkTeamsNotify.IsChecked -eq $true) { $features += 'Teams Notifications' }
    if ($ui.chkEnableQR.IsChecked -eq $true) { $features += 'QR Authentication' }
    $featureStr = if ($features.Count -gt 0) { $features -join ', ' } else { 'None' }

    $ui.txtSummary.Text = @"
Company:       $($ui.txtCompanyName.Text)
Function URL:  $(if ($script:FunctionUrl) { $script:FunctionUrl } else { '(not configured)' })
Function Key:  $keyPreview
Group Tags:    $tagList
Default Tag:   $(if ($ui.txtDefaultTag.SelectedItem -and $ui.txtDefaultTag.SelectedItem -ne '(none)') { $ui.txtDefaultTag.SelectedItem } else { '(none)' })
Features:      $featureStr
"@
}

# --- Helper: check if configure step should be shown ---
function Test-ConfigNeeded {
    return ($ui.chkTeamsNotify.IsChecked -eq $true) -or ($ui.chkEnableQR.IsChecked -eq $true)
}

# --- QR setup mode (automatic vs manual) ---
$script:QRAutoMode = $true

function Select-QRMode {
    param([bool]$Auto)
    $script:QRAutoMode = $Auto
    $accentBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#4da3ff')
    $mutedBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#2a2b30')
    if ($Auto) {
        $ui.cardQRAutomatic.BorderBrush = $accentBrush
        $ui.cardQRAutomatic.BorderThickness = [System.Windows.Thickness]::new(2)
        $ui.cardQRManual.BorderBrush = $mutedBrush
        $ui.cardQRManual.BorderThickness = [System.Windows.Thickness]::new(1)
        $ui.panelQRAuto.Visibility = 'Visible'
        $ui.panelQRManual.Visibility = 'Collapsed'
    } else {
        $ui.cardQRAutomatic.BorderBrush = $mutedBrush
        $ui.cardQRAutomatic.BorderThickness = [System.Windows.Thickness]::new(1)
        $ui.cardQRManual.BorderBrush = $accentBrush
        $ui.cardQRManual.BorderThickness = [System.Windows.Thickness]::new(2)
        $ui.panelQRAuto.Visibility = 'Collapsed'
        $ui.panelQRManual.Visibility = 'Visible'
    }
}
$ui.cardQRAutomatic.Add_MouseLeftButtonDown({ Select-QRMode -Auto $true })
$ui.cardQRManual.Add_MouseLeftButtonDown({ Select-QRMode -Auto $false })

# --- Help text toggle handlers ---
$ui.btnTeamsHelp.Add_MouseLeftButtonDown({
    if ($ui.panelTeamsHelp.Visibility -eq 'Collapsed') {
        $ui.panelTeamsHelp.Visibility = 'Visible'
        $ui.btnTeamsHelp.Text = [char]0x2139 + "  Hide help"
    } else {
        $ui.panelTeamsHelp.Visibility = 'Collapsed'
        $ui.btnTeamsHelp.Text = [char]0x2139 + "  How to get a webhook URL"
    }
})
$ui.btnQRHelp.Add_MouseLeftButtonDown({
    if ($ui.panelQRHelp.Visibility -eq 'Collapsed') {
        $ui.panelQRHelp.Visibility = 'Visible'
        $ui.btnQRHelp.Text = [char]0x2139 + "  Hide help"
    } else {
        $ui.panelQRHelp.Visibility = 'Collapsed'
        $ui.btnQRHelp.Text = [char]0x2139 + "  How to set up Entra ID App Registration"
    }
})
$ui.btnValidateHelp.Add_MouseLeftButtonDown({
    if ($ui.panelValidateHelp.Visibility -eq 'Collapsed') {
        $ui.panelValidateHelp.Visibility = 'Visible'
        $ui.btnValidateHelp.Text = [char]0x2139 + "  Hide help"
    } else {
        $ui.panelValidateHelp.Visibility = 'Collapsed'
        $ui.btnValidateHelp.Text = [char]0x2139 + "  Where to find the URL and key"
    }
})

# --- Navigation button events ---

# Welcome: Start Build
$ui.btnStartBuild.Add_Click({
    $script:StepCompleted[0] = $true
    Set-WizardStep 1
})

# Next button
$ui.btnNext.Add_Click({
    switch ($script:CurrentStep) {
        1 {
            # Features -> Configure or Backend
            $script:StepCompleted[1] = $true
            if (Test-ConfigNeeded) {
                # Show configure step, update which config panels are visible
                if ($ui.chkTeamsNotify.IsChecked -eq $true) {
                    $ui.panelTeamsConfig.Visibility = 'Visible'
                } else {
                    $ui.panelTeamsConfig.Visibility = 'Collapsed'
                }
                if ($ui.chkEnableQR.IsChecked -eq $true) {
                    $ui.panelQRConfig.Visibility = 'Visible'
                } else {
                    $ui.panelQRConfig.Visibility = 'Collapsed'
                }
                Set-WizardStep 2
            } else {
                $script:StepCompleted[2] = $true
                Set-WizardStep 3
            }
        }
        2 {
            # Configure -> Backend (validate inputs)
            if ($ui.chkTeamsNotify.IsChecked -eq $true) {
                $webhookUrl = $ui.txtTeamsWebhook.Text.Trim()
                if (-not $webhookUrl -or $webhookUrl -notmatch '^https://') {
                    [System.Windows.MessageBox]::Show('Teams Webhook URL is required and must start with https://', 'Validation', 'OK', 'Warning')
                    return
                }
            }
            if ($ui.chkEnableQR.IsChecked -eq $true -and -not $script:QRAutoMode) {
                # Only validate GUIDs in manual mode — auto mode creates them during deploy
                $guidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
                if ($ui.txtTenantId.Text.Trim() -notmatch $guidPattern) {
                    [System.Windows.MessageBox]::Show('Tenant ID must be a valid GUID.', 'Validation', 'OK', 'Warning')
                    return
                }
                if ($ui.txtClientId.Text.Trim() -notmatch $guidPattern) {
                    [System.Windows.MessageBox]::Show('Client ID must be a valid GUID.', 'Validation', 'OK', 'Warning')
                    return
                }
                if ($ui.txtGroupId.Text.Trim() -notmatch $guidPattern) {
                    [System.Windows.MessageBox]::Show('Security Group ID must be a valid GUID.', 'Validation', 'OK', 'Warning')
                    return
                }
            }
            $script:StepCompleted[2] = $true
            Set-WizardStep 3
        }
        3 {
            # Backend -> Validate
            $script:StepCompleted[3] = $true
            Set-WizardStep 4
        }
        4 {
            # Validate -> Branding (must test connection first)
            if (-not $script:FunctionUrl -or $script:FunctionUrl -eq 'https://') {
                [System.Windows.MessageBox]::Show(
                    "Please enter the Function URL and key, then test the connection.",
                    'Connection Required', 'OK', 'Warning')
                return
            }
            if (-not $script:FunctionKey) {
                [System.Windows.MessageBox]::Show(
                    "Please enter the Function Key.`n`nGet it from Azure Portal:`nFunction App > App keys > default",
                    'Function Key Required', 'OK', 'Warning')
                return
            }
            if (-not $script:ConnectionValidated) {
                [System.Windows.MessageBox]::Show(
                    "Please test the connection first by clicking 'Test Connection'.",
                    'Validation Required', 'OK', 'Warning')
                return
            }
            $script:StepCompleted[4] = $true
            Set-WizardStep 5
        }
        5 {
            # Branding -> Generate
            $script:StepCompleted[5] = $true
            Set-WizardStep 6
        }
    }
})

$ui.btnBack.Add_Click({
    switch ($script:CurrentStep) {
        1 { Set-WizardStep 0 }
        2 { Set-WizardStep 1 }
        3 {
            # Backend -> back to Configure if config was needed, else Features
            if (Test-ConfigNeeded) {
                Set-WizardStep 2
            } else {
                Set-WizardStep 1
            }
        }
        4 { Set-WizardStep 3 }
        5 { Set-WizardStep 4 }
        6 { Set-WizardStep 5 }
    }
})

$ui.btnSkip.Add_Click({
    # Skip from Backend step -> go directly to Validate
    if ($script:CurrentStep -eq 3) {
        $script:StepCompleted[3] = $true
        Set-WizardStep 4
    }
})

# --- Backend card selection ---
function Select-BackendCard {
    param([string]$Selection)

    # Reset all card borders
    $ui.cardExisting.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#2a2b30')
    $ui.cardExisting.BorderThickness = [System.Windows.Thickness]::new(1)
    $ui.cardAutomated.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#2a2b30')
    $ui.cardAutomated.BorderThickness = [System.Windows.Thickness]::new(1)
    $ui.cardManual.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#2a2b30')
    $ui.cardManual.BorderThickness = [System.Windows.Thickness]::new(1)

    # Hide all panels
    $ui.panelExisting.Visibility = 'Collapsed'
    $ui.panelNew.Visibility = 'Collapsed'
    $ui.panelManual.Visibility = 'Collapsed'

    $accentBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#4da3ff')

    switch ($Selection) {
        'existing' {
            $ui.cardExisting.BorderBrush = $accentBrush
            $ui.cardExisting.BorderThickness = [System.Windows.Thickness]::new(2)
            $ui.panelExisting.Visibility = 'Visible'
            $ui.radioExisting.IsChecked = $true
        }
        'automated' {
            $ui.cardAutomated.BorderBrush = $accentBrush
            $ui.cardAutomated.BorderThickness = [System.Windows.Thickness]::new(2)
            $ui.panelNew.Visibility = 'Visible'
            $ui.radioNew.IsChecked = $true
        }
        'manual' {
            $ui.cardManual.BorderBrush = $accentBrush
            $ui.cardManual.BorderThickness = [System.Windows.Thickness]::new(2)
            $ui.panelManual.Visibility = 'Visible'
            $ui.radioManual.IsChecked = $true
        }
    }
}

$ui.cardExisting.Add_MouseLeftButtonDown({ Select-BackendCard 'existing' })
$ui.cardAutomated.Add_MouseLeftButtonDown({ Select-BackendCard 'automated' })
$ui.cardManual.Add_MouseLeftButtonDown({ Select-BackendCard 'manual' })

# --- Backend: Test existing connection ---
$ui.btnTestExisting.Add_Click({
    $ui.lblTestExisting.Foreground = [System.Windows.Media.Brushes]::Gold
    $ui.lblTestExisting.Text = 'Testing...'
    $window.Dispatcher.Invoke([Action]{}, 'Render')
    try {
        $healthUrl = "$($ui.txtExistingUrl.Text.TrimEnd('/'))/api/health"
        $response = Invoke-RestMethod -Uri $healthUrl -Method GET -TimeoutSec 10
        if ($response.status -eq 'healthy') {
            $ui.lblTestExisting.Text = "Connected (v$($response.version))"
            $ui.lblTestExisting.Foreground = [System.Windows.Media.Brushes]::LimeGreen
            $script:FunctionUrl = $ui.txtExistingUrl.Text.TrimEnd('/')
            $script:FunctionKey = $ui.txtExistingKey.Password
            $script:ConnectionValidated = $true
        }
        else {
            $ui.lblTestExisting.Text = "Degraded: $($response.identity)"
            $ui.lblTestExisting.Foreground = [System.Windows.Media.Brushes]::Gold
        }
    }
    catch {
        $ui.lblTestExisting.Text = 'Connection failed'
        $ui.lblTestExisting.Foreground = [System.Windows.Media.Brushes]::Tomato
    }
})

# --- Validate: Test Connection ---
$ui.btnValidateTest.Add_Click({
    $ui.lblValidateStatus.Foreground = [System.Windows.Media.Brushes]::Gold
    $ui.lblValidateStatus.Text = 'Testing...'
    $window.Dispatcher.Invoke([Action]{}, 'Render')
    try {
        $url = $ui.txtValidateUrl.Text.TrimEnd('/')
        $healthUrl = "$url/api/health"
        $response = Invoke-RestMethod -Uri $healthUrl -Method GET -TimeoutSec 10
        if ($response.status -eq 'healthy') {
            $ui.lblValidateStatus.Text = "Connected (v$($response.version))"
            $ui.lblValidateStatus.Foreground = [System.Windows.Media.Brushes]::LimeGreen
            $script:FunctionUrl = $url
            $script:FunctionKey = $ui.txtValidateKey.Password
            $script:ConnectionValidated = $true
        }
        else {
            $ui.lblValidateStatus.Text = "Degraded: $($response.identity)"
            $ui.lblValidateStatus.Foreground = [System.Windows.Media.Brushes]::Gold
            $script:ConnectionValidated = $false
        }
    }
    catch {
        $ui.lblValidateStatus.Text = 'Connection failed'
        $ui.lblValidateStatus.Foreground = [System.Windows.Media.Brushes]::Tomato
        $script:ConnectionValidated = $false
    }
})

# --- Copy CLI commands ---
$ui.btnCopyCommands.Add_Click({
    [System.Windows.Clipboard]::SetText($cliCommands)
    $ui.lblCopied.Text = 'Copied!'
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds(2)
    $timer.Add_Tick({ $ui.lblCopied.Text = ''; $timer.Stop() })
    $timer.Start()
})

# --- Sign In & Load Subscriptions ---
$ui.btnSignIn.Add_Click({
    $ui.btnSignIn.IsEnabled = $false
    $ui.lblSignInStatus.Text = 'Signing in...'
    $ui.lblSignInStatus.Foreground = [System.Windows.Media.Brushes]::Gold
    $window.Dispatcher.Invoke([Action]{}, 'Render')

    try {
        $WarningPreference = 'SilentlyContinue'
        Connect-AzAccount -ErrorAction Stop | Out-Null
        $WarningPreference = 'Continue'

        $script:AzSubscriptions = @(Get-AzSubscription -ErrorAction Stop | Where-Object { $_.State -eq 'Enabled' })

        $ui.cmbSubscription.Items.Clear()
        foreach ($sub in $script:AzSubscriptions) {
            $ui.cmbSubscription.Items.Add("$($sub.Name)  ($($sub.Id))") | Out-Null
        }
        if ($ui.cmbSubscription.Items.Count -gt 0) {
            $ui.cmbSubscription.SelectedIndex = 0
        }

        $ui.lblSignInStatus.Text = "Signed in. $($script:AzSubscriptions.Count) subscription(s) found."
        $ui.lblSignInStatus.Foreground = [System.Windows.Media.Brushes]::LimeGreen
        $ui.panelDeployConfig.Visibility = 'Visible'
    }
    catch {
        $ui.lblSignInStatus.Text = "Sign-in failed: $($_.Exception.Message)"
        $ui.lblSignInStatus.Foreground = [System.Windows.Media.Brushes]::Tomato
        $ui.btnSignIn.IsEnabled = $true
    }
})

# --- Deploy (background runspace) ---

$script:DeployState = [hashtable]::Synchronized(@{
    CurrentStep = 0
    StepLabels  = @{}
    Error       = ''
    Done        = $false
    ResultUrl   = ''
    ResultKey   = ''
})

function Update-DeployStepUI {
    $state = $script:DeployState
    for ($i = 1; $i -le 8; $i++) {
        $ico = $ui["icoStep$i"]
        $lbl = $ui["lblStep$i"]
        if (-not $ico -or -not $lbl) { continue }
        if ($state.StepLabels.ContainsKey($i)) { $lbl.Text = $state.StepLabels[$i] }

        if ($state.Error -and $i -eq $state.CurrentStep) {
            $ico.Text = [string][char]0x2717; $ico.Foreground = [System.Windows.Media.Brushes]::Tomato
            $lbl.Foreground = [System.Windows.Media.Brushes]::Tomato
        }
        elseif ($i -lt $state.CurrentStep) {
            $ico.Text = [string][char]0x2713; $ico.Foreground = [System.Windows.Media.Brushes]::LimeGreen
            $lbl.Foreground = [System.Windows.Media.Brushes]::LimeGreen
        }
        elseif ($i -eq $state.CurrentStep) {
            $ico.Text = [string][char]0x25CF; $ico.Foreground = [System.Windows.Media.Brushes]::Gold
            $lbl.Foreground = [System.Windows.Media.Brushes]::White
        }
        else {
            $ico.Text = [string][char]0x25CB; $ico.Foreground = [System.Windows.Media.Brushes]::Gray
            $lbl.Foreground = [System.Windows.Media.Brushes]::Gray
        }
    }

    if ($state.Error) {
        $ui.lblDeployError.Foreground = [System.Windows.Media.Brushes]::Tomato
        $ui.lblDeployError.Text = "Error: $($state.Error)"
        $ui.btnDeploy.IsEnabled = $true
    }

    if ($state.Done -and -not $state.Error) {
        $script:FunctionUrl = $state.ResultUrl
        $script:FunctionKey = $state.ResultKey
        $ui.lblDeployError.Foreground = [System.Windows.Media.Brushes]::LimeGreen
        $appName = if ($state.ResultFunctionAppName) { $state.ResultFunctionAppName } else { 'your Function App' }
        $msg = "Deployment complete!`nURL: $($state.ResultUrl)`n`nGet your Function Key from Azure Portal:`nFunction App > $appName > App keys > default"

        # Auto-populate Configure fields with created resources
        if ($state.ResultAppClientId) {
            $ui.txtClientId.Text = $state.ResultAppClientId
            $msg += "`n`nApp Registration created (Client ID: $($state.ResultAppClientId))"
        }
        if ($state.ResultTenantId) {
            $ui.txtTenantId.Text = $state.ResultTenantId
        }
        if ($state.ResultGroupId) {
            $ui.txtGroupId.Text = $state.ResultGroupId
            $msg += "`nSecurity Group created (ID: $($state.ResultGroupId))"
        }

        $msg += "`n`nClick Next to validate the connection."
        $ui.lblDeployError.Text = $msg
    }
}

$ui.btnDeploy.Add_Click({
    $ui.btnDeploy.IsEnabled = $false
    $ui.panelSteps.Visibility = 'Visible'
    $ui.lblDeployError.Text = ''

    $rg = $ui.txtResourceGroup.Text.Trim()
    $loc = ($ui.cmbLocation.SelectedItem).Content
    $prefix = $ui.txtPrefix.Text.Trim()
    $selectedIdx = $ui.cmbSubscription.SelectedIndex

    # Feature flags
    $enableAuditLog = $ui.chkAuditLog.IsChecked -eq $true
    $enableTeams = $ui.chkTeamsNotify.IsChecked -eq $true
    $teamsWebhookUrl = if ($enableTeams) { $ui.txtTeamsWebhook.Text.Trim() } else { '' }
    $enableQR = $ui.chkEnableQR.IsChecked -eq $true
    $tenantId = if ($enableQR) { $ui.txtTenantId.Text.Trim() } else { '' }
    $clientId = if ($enableQR) { $ui.txtClientId.Text.Trim() } else { '' }
    $groupId = if ($enableQR) { $ui.txtGroupId.Text.Trim() } else { '' }

    # Deploy checklist flags
    $deployGraph = $ui.chkDeployGraph.IsChecked -eq $true
    $deployAppReg = $enableQR -and $script:QRAutoMode -and ($ui.chkDeployAppReg.IsChecked -eq $true)
    $deploySecGroup = $enableQR -and $script:QRAutoMode -and ($ui.chkDeploySecGroup.IsChecked -eq $true)
    if ($selectedIdx -lt 0) {
        $ui.lblDeployError.Text = 'No subscription selected.'
        $ui.lblDeployError.Foreground = [System.Windows.Media.Brushes]::Tomato
        $ui.btnDeploy.IsEnabled = $true
        return
    }
    $subId = $script:AzSubscriptions[$selectedIdx].Id

    # Reset state
    $script:DeployState.CurrentStep = 0
    $script:DeployState.StepLabels = @{}
    $script:DeployState.Error = ''
    $script:DeployState.Done = $false
    $script:DeployState.ResultUrl = ''
    $script:DeployState.ResultKey = ''

    # Generate unique names
    $uniqueSuffix = -join ((Get-Random -Count 8 -InputObject ([char[]]'abcdefghijklmnopqrstuvwxyz0123456789')))
    $rawStorageName = "st$($prefix -replace '-','')$uniqueSuffix"
    $storageAccountName = $rawStorageName.Substring(0, [Math]::Min(24, $rawStorageName.Length))
    $planName = "$prefix-plan"
    $functionAppName = "$prefix-$uniqueSuffix"
    $functionDir = Split-Path $templatePath_ARM
    $grantScript = $grantScriptPath

    # Start background runspace
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable('state', $script:DeployState)
    $runspace.SessionStateProxy.SetVariable('rg', $rg)
    $runspace.SessionStateProxy.SetVariable('loc', $loc)
    $runspace.SessionStateProxy.SetVariable('subId', $subId)
    $runspace.SessionStateProxy.SetVariable('storageAccountName', $storageAccountName)
    $runspace.SessionStateProxy.SetVariable('planName', $planName)
    $runspace.SessionStateProxy.SetVariable('functionAppName', $functionAppName)
    $runspace.SessionStateProxy.SetVariable('functionDir', $functionDir)
    $runspace.SessionStateProxy.SetVariable('grantScript', $grantScript)
    $runspace.SessionStateProxy.SetVariable('enableAuditLog', $enableAuditLog)
    $runspace.SessionStateProxy.SetVariable('enableTeams', $enableTeams)
    $runspace.SessionStateProxy.SetVariable('teamsWebhookUrl', $teamsWebhookUrl)
    $runspace.SessionStateProxy.SetVariable('enableQR', $enableQR)
    $runspace.SessionStateProxy.SetVariable('tenantId', $tenantId)
    $runspace.SessionStateProxy.SetVariable('clientId', $clientId)
    $runspace.SessionStateProxy.SetVariable('groupId', $groupId)
    $runspace.SessionStateProxy.SetVariable('deployGraph', $deployGraph)
    $runspace.SessionStateProxy.SetVariable('deployAppReg', $deployAppReg)
    $runspace.SessionStateProxy.SetVariable('deploySecGroup', $deploySecGroup)
    $runspace.SessionStateProxy.SetVariable('prefix', $prefix)

    $ps = [powershell]::Create()
    $ps.Runspace = $runspace
    $ps.AddScript({
        $ErrorActionPreference = 'Stop'
        $WarningPreference = 'SilentlyContinue'
        try {
            Import-Module Az.Accounts -ErrorAction Stop -WarningAction SilentlyContinue
            Import-Module Az.Resources -ErrorAction Stop -WarningAction SilentlyContinue
            Import-Module Az.Storage -ErrorAction Stop -WarningAction SilentlyContinue
            Import-Module Az.Websites -ErrorAction Stop -WarningAction SilentlyContinue
            Import-Module Az.Functions -ErrorAction Stop -WarningAction SilentlyContinue

            Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null

            # Step 1: Resource Group
            $state.CurrentStep = 1
            $state.StepLabels[1] = "Create Resource Group ($rg)"
            New-AzResourceGroup -Name $rg -Location $loc -Force -ErrorAction Stop | Out-Null

            # Step 2: Storage Account
            $state.CurrentStep = 2
            $state.StepLabels[2] = "Create Storage Account ($storageAccountName)"
            New-AzStorageAccount -ResourceGroupName $rg -Name $storageAccountName -Location $loc -SkuName 'Standard_LRS' -Kind 'StorageV2' -MinimumTlsVersion 'TLS1_2' -AllowBlobPublicAccess $false -ErrorAction Stop | Out-Null

            # Step 3: Function App
            $state.CurrentStep = 3
            $state.StepLabels[3] = "Create Function App ($functionAppName)"
            New-AzFunctionApp -ResourceGroupName $rg -Name $functionAppName -Location $loc `
                -StorageAccountName $storageAccountName -Runtime 'PowerShell' -RuntimeVersion '7.2' `
                -FunctionsVersion 4 -OSType 'Windows' -ErrorAction Stop | Out-Null
            Update-AzFunctionApp -ResourceGroupName $rg -Name $functionAppName -IdentityType 'SystemAssigned' -Force -ErrorAction Stop | Out-Null
            $funcApp = Get-AzWebApp -ResourceGroupName $rg -Name $functionAppName -ErrorAction Stop
            $functionAppUrl = "https://$($funcApp.DefaultHostName)"
            $principalId = $funcApp.Identity.PrincipalId
            $state.StepLabels[3] = "Create Function App ($functionAppName)"

            # Step 4: Grant Graph Permission
            if ($deployGraph) {
                $state.CurrentStep = 4
                $state.StepLabels[4] = "Grant Graph API Permission (sign-in popup may appear)"
                $WarningPreference = 'SilentlyContinue'
                $grantParams = @{ ManagedIdentityPrincipalId = $principalId }
                if ($enableQR) { $grantParams.IncludeGroupRead = $true }
                & $grantScript @grantParams
                $WarningPreference = 'Continue'
            } else {
                $state.StepLabels[4] = "Graph Permission (skipped)"
            }

            # Step 5: Deploy Code
            $state.CurrentStep = 5
            $state.StepLabels[5] = "Deploy Function Code"
            $zipPath = Join-Path $env:TEMP 'autopilot-function.zip'
            if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
            $filesToZip = @('host.json', 'profile.ps1', 'requirements.psd1', 'Upload', 'Status', 'Health', 'Modules', 'Session', 'SessionStatus', 'SessionApprove', 'ApprovalPage')
            $existingPaths = $filesToZip | ForEach-Object { Join-Path $functionDir $_ } | Where-Object { Test-Path $_ }
            Compress-Archive -Path $existingPaths -DestinationPath $zipPath -Force
            Publish-AzWebApp -ResourceGroupName $rg -Name $functionAppName -ArchivePath $zipPath -Force -ErrorAction Stop | Out-Null

            # Step 6: App Registration (if QR enabled and auto-create checked)
            $autoClientId = $clientId
            $autoTenantId = $tenantId
            if ($deployAppReg) {
                $state.CurrentStep = 6
                $state.StepLabels[6] = "Create App Registration (sign-in popup may appear)"
                Import-Module Microsoft.Graph.Applications -ErrorAction Stop
                $WarningPreference = 'SilentlyContinue'
                Connect-MgGraph -Scopes 'Application.ReadWrite.All', 'DelegatedPermissionGrant.ReadWrite.All' -NoWelcome -ErrorAction Stop
                $WarningPreference = 'Continue'

                $appDisplayName = "$prefix-approval"
                $redirectUri = "$functionAppUrl/api/approve"

                $appBody = @{
                    displayName = $appDisplayName
                    signInAudience = 'AzureADMyOrg'
                    spa = @{
                        redirectUris = @($redirectUri)
                    }
                    requiredResourceAccess = @(@{
                        resourceAppId = '00000003-0000-0000-c000-000000000000'  # Microsoft Graph
                        resourceAccess = @(
                            @{ id = '37f7f235-527c-4136-accd-4a02d197296e'; type = 'Scope' }  # openid
                            @{ id = '14dad69e-099b-42c9-810b-d002981feec1'; type = 'Scope' }  # profile
                        )
                    })
                }

                $newApp = New-MgApplication -BodyParameter $appBody -ErrorAction Stop
                $autoClientId = $newApp.AppId
                $autoTenantId = (Get-MgContext).TenantId

                # Create service principal and grant admin consent for openid + profile
                $appSp = New-MgServicePrincipal -AppId $autoClientId -ErrorAction Stop
                $graphSp = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
                $delegatedScopes = ($graphSp.Oauth2PermissionScopes | Where-Object { $_.Value -in @('openid', 'profile') }).Value -join ' '
                New-MgOauth2PermissionGrant -BodyParameter @{
                    clientId    = $appSp.Id
                    consentType = 'AllPrincipals'
                    resourceId  = $graphSp.Id
                    scope       = $delegatedScopes
                } -ErrorAction Stop | Out-Null

                $state.StepLabels[6] = "App Registration ($appDisplayName)"
                $state.ResultAppClientId = $autoClientId
                $state.ResultTenantId = $autoTenantId
            }

            # Step 7: Security Group (if QR enabled and auto-create checked)
            $autoGroupId = $groupId
            if ($deploySecGroup) {
                $state.CurrentStep = 7
                $state.StepLabels[7] = "Create Security Group"
                Import-Module Microsoft.Graph.Groups -ErrorAction Stop
                $WarningPreference = 'SilentlyContinue'
                if (-not (Get-MgContext)) {
                    Connect-MgGraph -Scopes 'Group.ReadWrite.All' -NoWelcome -ErrorAction Stop
                }
                $WarningPreference = 'Continue'

                $groupDisplayName = 'AutopilotRegistrators'
                $existingGroup = Get-MgGroup -Filter "displayName eq '$groupDisplayName'" -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($existingGroup) {
                    $autoGroupId = $existingGroup.Id
                    $state.StepLabels[7] = "Security Group (exists: $groupDisplayName)"
                }
                else {
                    $newGroup = New-MgGroup -DisplayName $groupDisplayName `
                        -MailEnabled:$false -SecurityEnabled:$true -MailNickname 'AutopilotRegistrators' `
                        -Description 'Users authorized to approve Autopilot device registrations' `
                        -ErrorAction Stop
                    $autoGroupId = $newGroup.Id
                    $state.StepLabels[7] = "Security Group ($groupDisplayName)"
                }
                $state.ResultGroupId = $autoGroupId
            }

            # Step 8: Configure App Settings
            $state.CurrentStep = 8
            $state.StepLabels[8] = "Configure App Settings"
            $featureSettings = @{}
            if ($enableAuditLog) { $featureSettings['ENABLE_AUDIT_LOG'] = 'true' }
            if ($enableTeams -and $teamsWebhookUrl) { $featureSettings['TEAMS_WEBHOOK_URL'] = $teamsWebhookUrl }
            if ($enableQR) {
                $featureSettings['ENABLE_QR_AUTH'] = 'true'
                $featureSettings['ENTRA_TENANT_ID'] = $autoTenantId
                $featureSettings['ENTRA_CLIENT_ID'] = $autoClientId
                $featureSettings['SECURITY_GROUP_ID'] = $autoGroupId
                $featureSettings['TOKEN_SECRET'] = [guid]::NewGuid().ToString()
                $featureSettings['APPROVAL_PAGE_URL'] = "$functionAppUrl/api/approve"
            }
            if ($featureSettings.Count -gt 0) {
                Update-AzFunctionAppSetting -ResourceGroupName $rg -Name $functionAppName -AppSetting $featureSettings -ErrorAction Stop | Out-Null
            }

            $state.ResultUrl = $functionAppUrl
            $state.ResultKey = ''
            $state.ResultFunctionAppName = $functionAppName
            $state.CurrentStep = 9
            $state.Done = $true
        }
        catch {
            $state.Error = $_.Exception.Message
        }
    }) | Out-Null

    $asyncResult = $ps.BeginInvoke()

    $script:deployTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:deployTimer.Interval = [TimeSpan]::FromMilliseconds(500)
    $script:deployPs = $ps
    $script:deployAsync = $asyncResult
    $script:deployRunspace = $runspace

    $script:deployTimer.Add_Tick({
        Update-DeployStepUI

        if ($script:DeployState.Done -or $script:DeployState.Error) {
            $script:deployTimer.Stop()
            try {
                $script:deployPs.EndInvoke($script:deployAsync)
                $script:deployPs.Dispose()
                $script:deployRunspace.Dispose()
            } catch {}
        }
    })

    $script:deployTimer.Start()
})

# --- Tag management ---

function Sync-DefaultTagDropdown {
    $selected = $ui.txtDefaultTag.SelectedItem
    $ui.txtDefaultTag.Items.Clear()
    $ui.txtDefaultTag.Items.Add('(none)') | Out-Null
    foreach ($item in $ui.tagListBox.Items) {
        $ui.txtDefaultTag.Items.Add($item) | Out-Null
    }
    if ($selected -and $ui.txtDefaultTag.Items.Contains($selected)) {
        $ui.txtDefaultTag.SelectedItem = $selected
    } else {
        $ui.txtDefaultTag.SelectedIndex = 0
    }
}

Sync-DefaultTagDropdown

$ui.btnAddTag.Add_Click({
    $tag = $ui.txtNewTag.Text.Trim()
    if ($tag -and -not $ui.tagListBox.Items.Contains($tag)) {
        $ui.tagListBox.Items.Add($tag) | Out-Null
        $ui.txtNewTag.Text = ''
        Sync-DefaultTagDropdown
    }
})

$ui.btnRemoveTag.Add_Click({
    if ($ui.tagListBox.SelectedIndex -ge 0) {
        $ui.tagListBox.Items.RemoveAt($ui.tagListBox.SelectedIndex)
        Sync-DefaultTagDropdown
    }
})

$ui.btnTagUp.Add_Click({
    $idx = $ui.tagListBox.SelectedIndex
    if ($idx -gt 0) {
        $item = $ui.tagListBox.Items[$idx]
        $ui.tagListBox.Items.RemoveAt($idx)
        $ui.tagListBox.Items.Insert($idx - 1, $item)
        $ui.tagListBox.SelectedIndex = $idx - 1
        Sync-DefaultTagDropdown
    }
})

$ui.btnTagDown.Add_Click({
    $idx = $ui.tagListBox.SelectedIndex
    if ($idx -ge 0 -and $idx -lt $ui.tagListBox.Items.Count - 1) {
        $item = $ui.tagListBox.Items[$idx]
        $ui.tagListBox.Items.RemoveAt($idx)
        $ui.tagListBox.Items.Insert($idx + 1, $item)
        $ui.tagListBox.SelectedIndex = $idx + 1
        Sync-DefaultTagDropdown
    }
})

# --- Generate: Test connection ---
$ui.btnTestFinal.Add_Click({
    if (-not $script:FunctionUrl) {
        $ui.lblFinalTest.Text = 'No Function URL configured. Complete the Validate step first.'
        $ui.lblFinalTest.Foreground = [System.Windows.Media.Brushes]::Tomato
        return
    }
    $ui.lblFinalTest.Text = 'Testing...'
    $ui.lblFinalTest.Foreground = [System.Windows.Media.Brushes]::Gold
    $window.Dispatcher.Invoke([Action]{}, 'Render')
    try {
        $response = Invoke-RestMethod -Uri "$($script:FunctionUrl)/api/health" -Method GET -TimeoutSec 10
        if ($response.status -eq 'healthy') {
            $ui.lblFinalTest.Text = "Connected - v$($response.version), identity: $($response.identity)"
            $ui.lblFinalTest.Foreground = [System.Windows.Media.Brushes]::LimeGreen
        }
        else {
            $ui.lblFinalTest.Text = "Degraded: $($response.identity)"
            $ui.lblFinalTest.Foreground = [System.Windows.Media.Brushes]::Gold
        }
    }
    catch {
        $ui.lblFinalTest.Text = 'Connection failed'
        $ui.lblFinalTest.Foreground = [System.Windows.Media.Brushes]::Tomato
    }
})

# --- Generate Field Tool ---
$ui.btnGenerate.Add_Click({
    $company = $ui.txtCompanyName.Text.Trim()
    if (-not $company) {
        [System.Windows.MessageBox]::Show('Company name is required. Go to Branding & Tags step.', 'Validation', 'OK', 'Warning')
        return
    }
    if (-not $script:FunctionUrl -or $script:FunctionUrl -eq 'https://') {
        [System.Windows.MessageBox]::Show('Azure Function URL is required. Go to Backend step.', 'Validation', 'OK', 'Warning')
        return
    }
    if (-not $script:FunctionKey) {
        [System.Windows.MessageBox]::Show('Function Key is required. Go to Backend step.', 'Validation', 'OK', 'Warning')
        return
    }
    if ($ui.tagListBox.Items.Count -eq 0) {
        [System.Windows.MessageBox]::Show('At least one group tag is required. Go to Branding & Tags step.', 'Validation', 'OK', 'Warning')
        return
    }

    if (-not (Test-Path $templatePath)) {
        [System.Windows.MessageBox]::Show("Template not found:`n$templatePath", 'Error', 'OK', 'Error')
        return
    }

    $template = Get-Content $templatePath -Raw

    # Build tag array
    $tags = @()
    foreach ($item in $ui.tagListBox.Items) { $tags += "'$($item -replace "'", "''")'" }
    $tagArrayStr = "@($($tags -join ', '))"

    $qrEnabled = $ui.chkEnableQR.IsChecked -eq $true

    $configBlock = @"
`$Config = @{
    CompanyName  = '$($company -replace "'", "''")'
    FunctionUrl  = '$($script:FunctionUrl)'
    FunctionKey  = '$($script:FunctionKey)'
    GroupTags    = $tagArrayStr
    DefaultTag   = '$(if ($ui.txtDefaultTag.SelectedItem -and $ui.txtDefaultTag.SelectedItem -ne '(none)') { $ui.txtDefaultTag.SelectedItem -replace "'", "''" } else { '' })'
    EnableQR     = `$$($qrEnabled.ToString().ToLower())
    Version      = '2.0.0'
}
"@

    $output = $template -replace '(?s)\$Config = @\{.*?\}', $configBlock

    if (-not (Test-Path $outputDir)) { New-Item -Path $outputDir -ItemType Directory -Force | Out-Null }

    $companySlug = $company -replace '[^A-Za-z0-9]', '-'
    $outputFile = Join-Path $outputDir "AutopilotTool-$companySlug.ps1"
    $output | Out-File $outputFile -Encoding UTF8

    # Copy QRCoder.dll if QR is enabled
    $qrDllCopied = $false
    if ($qrEnabled) {
        $qrDllSource = Join-Path (Split-Path (Split-Path $templatePath)) 'field-tool\lib\QRCoder.dll'
        if (Test-Path $qrDllSource) {
            Copy-Item $qrDllSource -Destination (Join-Path $outputDir 'QRCoder.dll') -Force
            $qrDllCopied = $true
        }
        else {
            [System.Windows.MessageBox]::Show("QRCoder.dll not found at:`n$qrDllSource`n`nQR authentication will not work without this file.", 'Warning', 'OK', 'Warning')
        }
    }

    # Generate start.cmd
    $toolFilename = "AutopilotTool-$companySlug.ps1"
    $startCmd = "@echo off`r`npowershell -ExecutionPolicy Bypass -File `"%~dp0$toolFilename`"`r`n"
    $startCmdPath = Join-Path $outputDir 'start.cmd'
    [System.IO.File]::WriteAllText($startCmdPath, $startCmd, [System.Text.Encoding]::ASCII)

    # Generate instruction card
    $instructionHtml = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>$company - Autopilot Setup Instructions</title>
<style>
  @media print { body { margin: 0; } }
  body { font-family: 'Segoe UI', Arial, sans-serif; max-width: 600px; margin: 40px auto; color: #222; }
  h1 { font-size: 22px; border-bottom: 2px solid #0078d4; padding-bottom: 8px; color: #0078d4; }
  .step { display: flex; margin: 18px 0; align-items: flex-start; }
  .step-num { background: #0078d4; color: white; font-weight: bold; font-size: 18px;
    width: 36px; height: 36px; border-radius: 50%; display: flex; align-items: center;
    justify-content: center; flex-shrink: 0; margin-right: 14px; }
  .step-content { flex: 1; }
  .step-content p { margin: 4px 0; font-size: 15px; }
  .cmd { background: #1e1e1e; color: #d4d4d4; padding: 10px 14px; border-radius: 6px;
    font-family: 'Cascadia Mono', 'Consolas', monospace; font-size: 15px; margin: 8px 0; }
  .note { background: #fff3cd; border-left: 4px solid #ffc107; padding: 10px 14px;
    margin: 16px 0; font-size: 13px; border-radius: 0 6px 6px 0; }
  .footer { margin-top: 30px; padding-top: 12px; border-top: 1px solid #ddd;
    font-size: 12px; color: #888; }
</style>
</head>
<body>
<h1>$company - Autopilot Device Setup</h1>
<div class="step"><div class="step-num">1</div><div class="step-content">
  <p><strong>Turn on the computer</strong></p>
  <p>Wait until you see the screen where it asks you to choose your country or keyboard layout.</p>
</div></div>
<div class="step"><div class="step-num">2</div><div class="step-content">
  <p><strong>Insert the USB stick</strong></p>
</div></div>
<div class="step"><div class="step-num">3</div><div class="step-content">
  <p><strong>Open the command prompt</strong></p>
  <p>Hold <strong>Shift</strong> and press <strong>F10</strong> at the same time.</p>
</div></div>
<div class="step"><div class="step-num">4</div><div class="step-content">
  <p><strong>Find the USB drive and start the tool</strong></p>
  <p>Type the following and press <strong>Enter</strong> after each line:</p>
  <div class="cmd">d:</div>
  <div class="cmd">start.cmd</div>
  <p>If you see an error after typing <code>d:</code> try <code>e:</code> instead, then <code>f:</code></p>
</div></div>
<div class="step"><div class="step-num">5</div><div class="step-content">
  <p><strong>Use the Autopilot Tool</strong></p>
  <p>Select the correct <strong>group tag</strong> and click <strong>Upload</strong>.</p>
$(if ($qrEnabled) { @'
  <p>A <strong>QR code</strong> will appear on screen. Scan it with your phone to approve the registration.</p>
'@ })
  <p>Wait until you see the success message.</p>
</div></div>
<div class="step"><div class="step-num">6</div><div class="step-content">
  <p><strong>Restart the computer</strong></p>
  <p>Close the tool and the black window. The setup will restart automatically.</p>
</div></div>
<div class="note"><strong>Tip:</strong> The USB drive is usually <code>d:</code> but can sometimes be <code>e:</code> or <code>f:</code>.</div>
<div class="footer">Generated by Autopilot Tool Builder | $company | $(Get-Date -Format 'yyyy-MM-dd')</div>
</body>
</html>
"@
    $instructionPath = Join-Path $outputDir "Instructions-$companySlug.html"
    $instructionHtml | Out-File $instructionPath -Encoding UTF8

    # Set COMPANY_NAME on the Function App (if we have a connection)
    if ($script:FunctionUrl -and $company) {
        try {
            $funcAppName = ($script:FunctionUrl -replace 'https://', '').Split('.')[0]
            $rg = $ui.txtResourceGroup.Text.Trim()
            if ($rg) {
                Update-AzFunctionAppSetting -ResourceGroupName $rg -Name $funcAppName `
                    -AppSetting @{ 'COMPANY_NAME' = $company } -ErrorAction SilentlyContinue | Out-Null
            }
        }
        catch { } # Non-critical — approval page falls back to "Autopilot"
    }

    $script:StepCompleted[6] = $true

    $resultFiles = "Generated:`n  $outputFile`n  $startCmdPath`n  $instructionPath"
    if ($qrDllCopied) { $resultFiles += "`n  $(Join-Path $outputDir 'QRCoder.dll')" }
    $ui.lblGenResult.Text = $resultFiles
    $ui.lblGenResult.Foreground = [System.Windows.Media.Brushes]::LimeGreen

    Start-Process explorer.exe -ArgumentList $outputDir
})

# --- Initialize wizard on Welcome (step 0) ---
Set-WizardStep 0

# --- Show Window ---
$window.ShowDialog() | Out-Null
