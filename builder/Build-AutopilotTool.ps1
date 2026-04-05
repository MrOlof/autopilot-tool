<#
.SYNOPSIS
    Autopilot Tool Builder - Admin Configuration GUI (WPF)
    Generates a configured field tool with company branding and Azure Function settings.

.NOTES
    Version: 2.0.0
    License: MIT
#>

#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

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
$script:CurrentStep = 1
$script:StepCompleted = @{ 1 = $false; 2 = $false; 3 = $false; 4 = $false }

$xamlString = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Autopilot Tool Builder"
        Width="900" Height="640"
        WindowStartupLocation="CenterScreen"
        ResizeMode="NoResize"
        Background="#1b1b1f">

    <Window.Resources>
        <SolidColorBrush x:Key="AccentBrush" Color="#4da3ff"/>
        <SolidColorBrush x:Key="AccentHoverBrush" Color="#6bb5ff"/>
        <SolidColorBrush x:Key="AccentPressedBrush" Color="#3a8ee6"/>
        <SolidColorBrush x:Key="CardBgBrush" Color="#2b2d31"/>
        <SolidColorBrush x:Key="InputBgBrush" Color="#383a3e"/>
        <SolidColorBrush x:Key="InputBorderBrush" Color="#4a4c50"/>
        <SolidColorBrush x:Key="TextBrush" Color="#f0f0f0"/>
        <SolidColorBrush x:Key="TextMutedBrush" Color="#a0a0a0"/>
        <SolidColorBrush x:Key="SuccessBrush" Color="#4caf50"/>
        <SolidColorBrush x:Key="WarningBrush" Color="#ffb74d"/>
        <SolidColorBrush x:Key="ErrorBrush" Color="#ef5350"/>
        <SolidColorBrush x:Key="StepPendingBrush" Color="#555559"/>
        <SolidColorBrush x:Key="StepLineBrush" Color="#3a3c40"/>

        <!-- TextBox style -->
        <Style TargetType="TextBox">
            <Setter Property="Background" Value="{StaticResource InputBgBrush}"/>
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="BorderBrush" Value="{StaticResource InputBorderBrush}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="8,6"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
            <Setter Property="CaretBrush" Value="White"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <Border Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="4">
                            <ScrollViewer x:Name="PART_ContentHost" Margin="0"/>
                        </Border>
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
            <Setter Property="Padding" Value="8,6"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="CaretBrush" Value="White"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="PasswordBox">
                        <Border Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="4">
                            <ScrollViewer x:Name="PART_ContentHost" Margin="0"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Default button style -->
        <Style x:Key="DefaultButton" TargetType="Button">
            <Setter Property="Background" Value="#3a3c40"/>
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
                                CornerRadius="4"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#4a4c50"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#2e3034"/>
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
            <Setter Property="BorderBrush" Value="{StaticResource AccentBrush}"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="0"
                                CornerRadius="4"
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
                                CornerRadius="4"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#2e3034"/>
                                <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#252529"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Opacity" Value="0.4"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- RadioButton style -->
        <Style TargetType="RadioButton">
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Margin" Value="0,4"/>
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
                                        <Border Background="{StaticResource InputBgBrush}"
                                                BorderBrush="{StaticResource InputBorderBrush}"
                                                BorderThickness="1" CornerRadius="4">
                                            <Grid>
                                                <Grid.ColumnDefinitions>
                                                    <ColumnDefinition/>
                                                    <ColumnDefinition Width="28"/>
                                                </Grid.ColumnDefinitions>
                                                <Border Grid.Column="1">
                                                    <Path x:Name="Arrow" Fill="#a0a0a0" HorizontalAlignment="Center"
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
                                              TextBlock.Foreground="White"/>
                            <Popup x:Name="PART_Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}"
                                   AllowsTransparency="True" Focusable="False" PopupAnimation="Slide">
                                <Grid x:Name="DropDown" SnapsToDevicePixels="True"
                                      MinWidth="{TemplateBinding ActualWidth}"
                                      MaxHeight="{TemplateBinding MaxDropDownHeight}">
                                    <Border Background="#2b2d31" BorderBrush="#4a4c50" BorderThickness="1"
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
        <Style TargetType="ComboBoxItem">
            <Setter Property="Background" Value="#2b2d31"/>
            <Setter Property="Foreground" Value="#f0f0f0"/>
            <Setter Property="Padding" Value="8,6"/>
            <Setter Property="FontSize" Value="13"/>
            <Style.Triggers>
                <Trigger Property="IsHighlighted" Value="True">
                    <Setter Property="Background" Value="#4da3ff"/>
                    <Setter Property="Foreground" Value="White"/>
                </Trigger>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="#3a3c40"/>
                    <Setter Property="Foreground" Value="White"/>
                </Trigger>
            </Style.Triggers>
        </Style>
    </Window.Resources>

    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="72"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="56"/>
        </Grid.RowDefinitions>

        <!-- Step Indicator Bar -->
        <Border Grid.Row="0" Background="#222226" BorderBrush="#2e3034" BorderThickness="0,0,0,1">
            <Grid VerticalAlignment="Center" HorizontalAlignment="Center" Width="560">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>

                <!-- Step 1: Azure Backend -->
                <StackPanel Grid.Column="0" Orientation="Horizontal" HorizontalAlignment="Center" Name="stepIndicator1" Cursor="Hand">
                    <Border Name="stepCircle1" Width="28" Height="28" CornerRadius="14"
                            Background="#4da3ff" BorderThickness="0" Margin="0,0,8,0">
                        <TextBlock Name="stepText1" Text="1" Foreground="White" FontWeight="Bold"
                                   FontSize="13" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                    <TextBlock Name="stepLabel1" Text="Backend" Foreground="#f0f0f0" FontSize="12"
                               FontWeight="SemiBold" VerticalAlignment="Center"/>
                </StackPanel>

                <Border Grid.Column="1" Height="2" Width="40" Background="#3a3c40" VerticalAlignment="Center"
                        Name="stepLine1" Margin="2,0"/>

                <!-- Step 2: Validate -->
                <StackPanel Grid.Column="2" Orientation="Horizontal" HorizontalAlignment="Center" Name="stepIndicator2" Cursor="Hand">
                    <Border Name="stepCircle2" Width="28" Height="28" CornerRadius="14"
                            Background="#555559" BorderThickness="0" Margin="0,0,8,0">
                        <TextBlock Name="stepText2" Text="2" Foreground="#a0a0a0" FontWeight="Bold"
                                   FontSize="13" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                    <TextBlock Name="stepLabel2" Text="Validate" Foreground="#a0a0a0" FontSize="12"
                               VerticalAlignment="Center"/>
                </StackPanel>

                <Border Grid.Column="3" Height="2" Width="40" Background="#3a3c40" VerticalAlignment="Center"
                        Name="stepLine2" Margin="2,0"/>

                <!-- Step 3: Branding -->
                <StackPanel Grid.Column="4" Orientation="Horizontal" HorizontalAlignment="Center" Name="stepIndicator3" Cursor="Hand">
                    <Border Name="stepCircle3" Width="28" Height="28" CornerRadius="14"
                            Background="#555559" BorderThickness="0" Margin="0,0,8,0">
                        <TextBlock Name="stepText3" Text="3" Foreground="#a0a0a0" FontWeight="Bold"
                                   FontSize="13" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                    <TextBlock Name="stepLabel3" Text="Branding" Foreground="#a0a0a0" FontSize="12"
                               VerticalAlignment="Center"/>
                </StackPanel>

                <Border Grid.Column="5" Height="2" Width="40" Background="#3a3c40" VerticalAlignment="Center"
                        Name="stepLine3" Margin="2,0"/>

                <!-- Step 4: Generate -->
                <StackPanel Grid.Column="6" Orientation="Horizontal" HorizontalAlignment="Center" Name="stepIndicator4" Cursor="Hand">
                    <Border Name="stepCircle4" Width="28" Height="28" CornerRadius="14"
                            Background="#555559" BorderThickness="0" Margin="0,0,8,0">
                        <TextBlock Name="stepText4" Text="4" Foreground="#a0a0a0" FontWeight="Bold"
                                   FontSize="13" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                    <TextBlock Name="stepLabel4" Text="Generate" Foreground="#a0a0a0" FontSize="12"
                               VerticalAlignment="Center"/>
                </StackPanel>
            </Grid>
        </Border>

        <!-- Content Area -->
        <Grid Grid.Row="1">

            <!-- Step 1: Azure Backend -->
            <Border Name="pageStep1" Visibility="Visible" Margin="24,8,24,4">
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <StackPanel>
                        <TextBlock Text="Azure Function Backend" FontSize="16" FontWeight="Bold"
                                   Foreground="{StaticResource AccentBrush}" Margin="0,0,0,2"/>
                        <TextBlock Text="Set up the Azure Function that proxies requests to Graph API, or connect to an existing one."
                                   Foreground="{StaticResource TextMutedBrush}" FontSize="11" Margin="0,0,0,10"
                                   TextWrapping="Wrap"/>

                        <RadioButton Name="radioExisting" Content="I already have an Azure Function deployed"
                                     IsChecked="True" GroupName="AzureSetup" Margin="0,0,0,4"/>
                        <RadioButton Name="radioNew" Content="Automated setup (deploys everything for you)"
                                     GroupName="AzureSetup" Margin="0,0,0,4"/>
                        <RadioButton Name="radioManual" Content="Manual setup (step-by-step CLI guide)"
                                     GroupName="AzureSetup" Margin="0,0,0,10"/>

                        <!-- Panel: Existing Function -->
                        <Border Name="panelExisting" Background="{StaticResource CardBgBrush}"
                                CornerRadius="6" Padding="14" Margin="0,0,0,6">
                            <StackPanel>
                                <Grid Margin="0,0,0,12">
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="110"/>
                                        <ColumnDefinition Width="*"/>
                                    </Grid.ColumnDefinitions>
                                    <Label Content="Function URL:" Grid.Column="0"/>
                                    <TextBox Name="txtExistingUrl" Text="https://" Grid.Column="1"/>
                                </Grid>
                                <Grid Margin="0,0,0,14">
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="110"/>
                                        <ColumnDefinition Width="*"/>
                                    </Grid.ColumnDefinitions>
                                    <Label Content="Function Key:" Grid.Column="0"/>
                                    <PasswordBox Name="txtExistingKey" Grid.Column="1"/>
                                </Grid>
                                <StackPanel Orientation="Horizontal">
                                    <Button Name="btnTestExisting" Content="Test Connection"
                                            Style="{StaticResource DefaultButton}"/>
                                    <TextBlock Name="lblTestExisting" Text="" VerticalAlignment="Center"
                                               Margin="14,0,0,0" FontSize="12"/>
                                </StackPanel>
                            </StackPanel>
                        </Border>

                        <!-- Panel: Automated Setup (two-column layout) -->
                        <Border Name="panelNew" Background="{StaticResource CardBgBrush}"
                                CornerRadius="6" Padding="14" Margin="0,0,0,6" Visibility="Collapsed">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="16"/>
                                    <ColumnDefinition Width="280"/>
                                </Grid.ColumnDefinitions>

                                <!-- Left: Sign in + Config -->
                                <StackPanel Grid.Column="0">
                                    <StackPanel Orientation="Horizontal" Margin="0,0,0,12">
                                        <Button Name="btnSignIn" Content="Sign in to Azure"
                                                Style="{StaticResource PrimaryButton}" Padding="14,7"/>
                                        <TextBlock Name="lblSignInStatus" Text="" VerticalAlignment="Center"
                                                   Margin="12,0,0,0" FontSize="11"/>
                                    </StackPanel>

                                    <StackPanel Name="panelDeployConfig" Visibility="Collapsed">
                                        <Grid Margin="0,0,0,8">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="100"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <Label Content="Subscription:" Grid.Column="0" FontSize="12"/>
                                            <ComboBox Name="cmbSubscription" Grid.Column="1" MaxDropDownHeight="250"/>
                                        </Grid>
                                        <Grid Margin="0,0,0,8">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="100"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <Label Content="Resource Group:" Grid.Column="0" FontSize="12"/>
                                            <TextBox Name="txtResourceGroup" Text="rg-autopilot-tool" Grid.Column="1"/>
                                        </Grid>
                                        <Grid Margin="0,0,0,8">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="100"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <Label Content="Location:" Grid.Column="0" FontSize="12"/>
                                            <ComboBox Name="cmbLocation" Grid.Column="1" SelectedIndex="0" MaxDropDownHeight="300">
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
                                        </Grid>
                                        <Grid Margin="0,0,0,12">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="100"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <Label Content="Name Prefix:" Grid.Column="0" FontSize="12"/>
                                            <TextBox Name="txtPrefix" Text="autopilot-tool" Grid.Column="1"/>
                                        </Grid>
                                        <Button Name="btnDeploy" Content="Deploy Azure Function"
                                                Style="{StaticResource PrimaryButton}" Padding="14,10"
                                                FontSize="13" HorizontalAlignment="Stretch"/>
                                    </StackPanel>
                                </StackPanel>

                                <!-- Right: Progress steps -->
                                <Border Grid.Column="2" Background="#1b1b1f" CornerRadius="6" Padding="14">
                                    <StackPanel>
                                        <TextBlock Text="PROGRESS" FontWeight="SemiBold" FontSize="11"
                                                   Foreground="{StaticResource AccentBrush}" Margin="0,0,0,10"/>
                                        <StackPanel Name="panelSteps">
                                            <Grid Margin="0,4,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="22"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                                <TextBlock Name="icoStep1" Text="&#x25CB;" Grid.Column="0" FontSize="13" Foreground="{StaticResource TextMutedBrush}" VerticalAlignment="Center"/>
                                                <TextBlock Name="lblStep1" Text="Resource Group" Grid.Column="1" FontSize="11" Foreground="{StaticResource TextMutedBrush}" VerticalAlignment="Center"/>
                                            </Grid>
                                            <Grid Margin="0,4,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="22"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                                <TextBlock Name="icoStep2" Text="&#x25CB;" Grid.Column="0" FontSize="13" Foreground="{StaticResource TextMutedBrush}" VerticalAlignment="Center"/>
                                                <TextBlock Name="lblStep2" Text="Storage Account" Grid.Column="1" FontSize="11" Foreground="{StaticResource TextMutedBrush}" VerticalAlignment="Center"/>
                                            </Grid>
                                            <Grid Margin="0,4,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="22"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                                <TextBlock Name="icoStep3" Text="&#x25CB;" Grid.Column="0" FontSize="13" Foreground="{StaticResource TextMutedBrush}" VerticalAlignment="Center"/>
                                                <TextBlock Name="lblStep3" Text="App Service Plan" Grid.Column="1" FontSize="11" Foreground="{StaticResource TextMutedBrush}" VerticalAlignment="Center"/>
                                            </Grid>
                                            <Grid Margin="0,4,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="22"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                                <TextBlock Name="icoStep4" Text="&#x25CB;" Grid.Column="0" FontSize="13" Foreground="{StaticResource TextMutedBrush}" VerticalAlignment="Center"/>
                                                <TextBlock Name="lblStep4" Text="Function App" Grid.Column="1" FontSize="11" Foreground="{StaticResource TextMutedBrush}" VerticalAlignment="Center"/>
                                            </Grid>
                                            <Grid Margin="0,4,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="22"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                                <TextBlock Name="icoStep5" Text="&#x25CB;" Grid.Column="0" FontSize="13" Foreground="{StaticResource TextMutedBrush}" VerticalAlignment="Center"/>
                                                <TextBlock Name="lblStep5" Text="Graph Permission" Grid.Column="1" FontSize="11" Foreground="{StaticResource TextMutedBrush}" VerticalAlignment="Center"/>
                                            </Grid>
                                            <Grid Margin="0,4,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="22"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                                <TextBlock Name="icoStep6" Text="&#x25CB;" Grid.Column="0" FontSize="13" Foreground="{StaticResource TextMutedBrush}" VerticalAlignment="Center"/>
                                                <TextBlock Name="lblStep6" Text="Deploy Code" Grid.Column="1" FontSize="11" Foreground="{StaticResource TextMutedBrush}" VerticalAlignment="Center"/>
                                            </Grid>
                                        </StackPanel>
                                        <TextBlock Name="lblDeployError" Text="" FontSize="10"
                                                   Foreground="{StaticResource ErrorBrush}"
                                                   TextWrapping="Wrap" Margin="0,10,0,0"/>
                                    </StackPanel>
                                </Border>
                            </Grid>
                        </Border>

                        <!-- Panel: Manual Setup Guide -->
                        <Border Name="panelManual" Background="{StaticResource CardBgBrush}"
                                CornerRadius="6" Padding="14" Margin="0,0,0,6" Visibility="Collapsed">
                            <StackPanel>
                                <TextBlock Text="Run these commands in PowerShell or Azure CLI. After completing, switch to 'I already have an Azure Function deployed' and enter your URL and key."
                                           Foreground="{StaticResource TextMutedBrush}" FontSize="12"
                                           TextWrapping="Wrap" Margin="0,0,0,14"/>
                                <TextBox Name="txtCliCommands" Height="220" IsReadOnly="True"
                                         TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"
                                         FontFamily="Cascadia Mono,Consolas" FontSize="11"
                                         Background="#17171b" BorderThickness="0" Padding="10"
                                         AcceptsReturn="True"/>
                                <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                                    <Button Name="btnCopyCommands" Content="Copy to Clipboard"
                                            Style="{StaticResource DefaultButton}"/>
                                    <TextBlock Name="lblCopied" Text="" VerticalAlignment="Center"
                                               Margin="14,0,0,0" FontSize="12"
                                               Foreground="{StaticResource SuccessBrush}"/>
                                </StackPanel>
                            </StackPanel>
                        </Border>
                    </StackPanel>
                </ScrollViewer>
            </Border>

            <!-- Step 2: Validate Connection -->
            <Border Name="pageStep2" Visibility="Collapsed" Margin="24,16,24,8">
                <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center" Width="500">
                    <TextBlock Text="Validate Connection" FontSize="16" FontWeight="Bold"
                               Foreground="{StaticResource AccentBrush}" Margin="0,0,0,4"/>
                    <TextBlock Text="Enter your Azure Function URL and key, then test the connection before continuing."
                               Foreground="{StaticResource TextMutedBrush}" FontSize="11" Margin="0,0,0,24"
                               TextWrapping="Wrap"/>

                    <Grid Margin="0,0,0,12">
                        <Grid.ColumnDefinitions><ColumnDefinition Width="100"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                        <Label Content="Function URL:" Grid.Column="0" FontSize="12"/>
                        <TextBox Name="txtValidateUrl" Text="https://" Grid.Column="1"/>
                    </Grid>
                    <Grid Margin="0,0,0,16">
                        <Grid.ColumnDefinitions><ColumnDefinition Width="100"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                        <Label Content="Function Key:" Grid.Column="0" FontSize="12"/>
                        <PasswordBox Name="txtValidateKey" Grid.Column="1"/>
                    </Grid>

                    <StackPanel Orientation="Horizontal" Margin="0,0,0,16">
                        <Button Name="btnValidateTest" Content="Test Connection"
                                Style="{StaticResource DefaultButton}" Padding="14,8"/>
                        <TextBlock Name="lblValidateStatus" Text="" VerticalAlignment="Center"
                                   Margin="14,0,0,0" FontSize="12"/>
                    </StackPanel>

                    <Border Background="#2b2d31" CornerRadius="6" Padding="16" Margin="0,8,0,0">
                        <TextBlock Text="The Function URL and key can be found in the Azure Portal:&#x0a;Function App > Overview > Default domain (URL)&#x0a;Function App > App keys > default (Key)"
                                   Foreground="{StaticResource TextMutedBrush}" FontSize="11"
                                   TextWrapping="Wrap" LineHeight="20"/>
                    </Border>
                </StackPanel>
            </Border>

            <!-- Step 3: Branding & Tags -->
            <Border Name="pageStep3" Visibility="Collapsed" Margin="24,16,24,8">
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <StackPanel>
                        <TextBlock Text="Branding &amp; Group Tags" FontSize="18" FontWeight="Bold"
                                   Foreground="{StaticResource AccentBrush}" Margin="0,0,0,4"/>
                        <TextBlock Text="Configure how the field tool looks and what group tags are available."
                                   Foreground="{StaticResource TextMutedBrush}" FontSize="12" Margin="0,0,0,18"
                                   TextWrapping="Wrap"/>

                        <!-- Company -->
                        <TextBlock Text="COMPANY" FontWeight="SemiBold" FontSize="12"
                                   Foreground="{StaticResource AccentBrush}" Margin="0,0,0,10"/>
                        <Grid Margin="0,0,0,12">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="110"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>
                            <Label Content="Company Name:" Grid.Column="0"/>
                            <TextBox Name="txtCompanyName" Text="Your Company" Grid.Column="1"/>
                        </Grid>
                        <!-- Group Tags -->
                        <TextBlock Text="GROUP TAGS" FontWeight="SemiBold" FontSize="12"
                                   Foreground="{StaticResource AccentBrush}" Margin="0,0,0,10"/>
                        <Grid Margin="0,0,0,10">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="110"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <Label Content="Available Tags:" Grid.Column="0" VerticalAlignment="Top"/>
                            <ListBox Name="tagListBox" Grid.Column="1" Height="120" Margin="0,0,8,0"/>
                            <StackPanel Grid.Column="2" VerticalAlignment="Top">
                                <Button Name="btnTagUp" Content="&#x25B2;" Style="{StaticResource DefaultButton}"
                                        Padding="8,4" Margin="0,0,0,4" FontSize="11"/>
                                <Button Name="btnTagDown" Content="&#x25BC;" Style="{StaticResource DefaultButton}"
                                        Padding="8,4" FontSize="11"/>
                            </StackPanel>
                        </Grid>
                        <Grid Margin="110,0,0,12">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <TextBox Name="txtNewTag" Grid.Column="0" Margin="0,0,6,0"/>
                            <Button Name="btnAddTag" Content="Add" Grid.Column="1"
                                    Style="{StaticResource DefaultButton}" Padding="12,6" Margin="0,0,4,0"/>
                            <Button Name="btnRemoveTag" Content="Remove" Grid.Column="2"
                                    Style="{StaticResource DefaultButton}" Padding="12,6"/>
                        </Grid>
                        <Grid Margin="0,0,0,10">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="110"/>
                                <ColumnDefinition Width="200"/>
                            </Grid.ColumnDefinitions>
                            <Label Content="Default Tag:" Grid.Column="0"/>
                            <ComboBox Name="txtDefaultTag" Grid.Column="1" MaxDropDownHeight="200"/>
                        </Grid>
                    </StackPanel>
                </ScrollViewer>
            </Border>

            <!-- Step 4: Generate -->
            <Border Name="pageStep4" Visibility="Collapsed" Margin="24,16,24,8">
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <StackPanel>
                        <TextBlock Text="Generate Field Tool" FontSize="18" FontWeight="Bold"
                                   Foreground="{StaticResource AccentBrush}" Margin="0,0,0,4"/>
                        <TextBlock Text="Review your configuration and generate the field tool for USB deployment."
                                   Foreground="{StaticResource TextMutedBrush}" FontSize="12" Margin="0,0,0,18"
                                   TextWrapping="Wrap"/>

                        <!-- Summary -->
                        <TextBlock Text="CONFIGURATION SUMMARY" FontWeight="SemiBold" FontSize="12"
                                   Foreground="{StaticResource AccentBrush}" Margin="0,0,0,10"/>
                        <TextBox Name="txtSummary" Height="130" IsReadOnly="True" TextWrapping="Wrap"
                                 VerticalScrollBarVisibility="Auto" FontFamily="Cascadia Mono,Consolas"
                                 FontSize="12" Background="#17171b" BorderThickness="0" Padding="12"
                                 AcceptsReturn="True" Margin="0,0,0,16"/>

                        <!-- Test -->
                        <StackPanel Orientation="Horizontal" Margin="0,0,0,18">
                            <Button Name="btnTestFinal" Content="Test Connection"
                                    Style="{StaticResource DefaultButton}"/>
                            <TextBlock Name="lblFinalTest" Text="" VerticalAlignment="Center"
                                       Margin="14,0,0,0" FontSize="12"/>
                        </StackPanel>

                        <!-- Generate -->
                        <Button Name="btnGenerate" Content="Generate Field Tool"
                                Style="{StaticResource PrimaryButton}" Padding="16,14"
                                FontSize="15" HorizontalAlignment="Stretch" Margin="0,0,0,16"/>

                        <TextBlock Name="lblGenResult" Text="" TextWrapping="Wrap"
                                   Foreground="{StaticResource SuccessBrush}" FontSize="12"/>
                    </StackPanel>
                </ScrollViewer>
            </Border>

        </Grid>

        <!-- Navigation Bar -->
        <Border Grid.Row="2" Background="#222226" BorderBrush="#2e3034" BorderThickness="0,1,0,0">
            <Grid Margin="24,0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>

                <Button Name="btnSkip" Content="Skip" Grid.Column="0"
                        Style="{StaticResource GhostButton}" Padding="16,8"
                        VerticalAlignment="Center"/>

                <Button Name="btnBack" Content="Back" Grid.Column="2"
                        Style="{StaticResource DefaultButton}" Padding="20,8"
                        VerticalAlignment="Center" Margin="0,0,10,0" Visibility="Collapsed"/>

                <Button Name="btnNext" Content="Next &#x2192;" Grid.Column="3"
                        Style="{StaticResource PrimaryButton}" Padding="24,8"
                        VerticalAlignment="Center" FontSize="13"/>
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
    'stepIndicator1','stepCircle1','stepText1','stepLabel1',
    'stepIndicator2','stepCircle2','stepText2','stepLabel2',
    'stepIndicator3','stepCircle3','stepText3','stepLabel3',
    'stepLine1','stepLine2',
    'pageStep1','pageStep2','pageStep3','pageStep4',
    'txtValidateUrl','txtValidateKey','btnValidateTest','lblValidateStatus',
    'stepIndicator4','stepCircle4','stepText4','stepLabel4','stepLine3',
    'radioExisting','radioNew','radioManual','panelExisting','panelNew','panelManual',
    'txtExistingUrl','txtExistingKey','btnTestExisting','lblTestExisting',
    'btnSignIn','lblSignInStatus','panelDeployConfig','cmbSubscription',
    'txtResourceGroup','cmbLocation','txtPrefix','btnDeploy',
    'panelSteps','icoStep1','lblStep1','icoStep2','lblStep2','icoStep3','lblStep3',
    'icoStep4','lblStep4','icoStep5','lblStep5','icoStep6','lblStep6',
    'lblDeployError',
    'txtCliCommands','btnCopyCommands','lblCopied',
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
.\setup\Grant-GraphPermission.ps1 -ManagedIdentityPrincipalId "<principalId>"

# 6. Deploy function code
cd azure-function
func azure functionapp publish <functionAppName>

# 7. Get the function key
az functionapp keys list --name <functionAppName> `
  --resource-group rg-autopilot-tool `
  --query "functionKeys.default" -o tsv
"@
$ui.txtCliCommands.Text = $cliCommands

# --- Wizard Navigation Logic ---
function Set-WizardStep {
    param([int]$Step)

    $script:CurrentStep = $Step

    # Hide all pages
    $ui.pageStep1.Visibility = 'Collapsed'
    $ui.pageStep2.Visibility = 'Collapsed'
    $ui.pageStep3.Visibility = 'Collapsed'
    $ui.pageStep4.Visibility = 'Collapsed'

    # Show current page
    switch ($Step) {
        1 { $ui.pageStep1.Visibility = 'Visible' }
        2 {
            $ui.pageStep2.Visibility = 'Visible'
            # Pre-fill URL from deploy if available
            if ($script:FunctionUrl -and $ui.txtValidateUrl.Text -eq 'https://') {
                $ui.txtValidateUrl.Text = $script:FunctionUrl
            }
        }
        3 { $ui.pageStep3.Visibility = 'Visible' }
        4 {
            $ui.pageStep4.Visibility = 'Visible'
            Update-Summary
        }
    }

    # Update step indicators (4 steps)
    for ($i = 1; $i -le 4; $i++) {
        $circle = $ui["stepCircle$i"]
        $text = $ui["stepText$i"]
        $label = $ui["stepLabel$i"]

        if ($script:StepCompleted[$i] -and $i -ne $Step) {
            $circle.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#4caf50')
            $text.Text = [string][char]0x2713
            $text.Foreground = [System.Windows.Media.Brushes]::White
            $label.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#4caf50')
            $label.FontWeight = 'Normal'
        }
        elseif ($i -eq $Step) {
            $circle.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#4da3ff')
            $text.Text = "$i"
            $text.Foreground = [System.Windows.Media.Brushes]::White
            $label.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#f0f0f0')
            $label.FontWeight = 'SemiBold'
        }
        else {
            $circle.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#555559')
            $text.Text = "$i"
            $text.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#a0a0a0')
            $label.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#a0a0a0')
            $label.FontWeight = 'Normal'
        }
    }

    # Update connector lines
    $lines = @{ 1 = 'stepLine1'; 2 = 'stepLine2'; 3 = 'stepLine3' }
    foreach ($ln in $lines.Keys) {
        $color = if ($script:StepCompleted[$ln]) { '#4caf50' } else { '#3a3c40' }
        $ui[$lines[$ln]].Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($color)
    }

    # Navigation buttons
    $ui.btnBack.Visibility = if ($Step -eq 1) { 'Collapsed' } else { 'Visible' }
    $ui.btnSkip.Visibility = if ($Step -eq 1) { 'Visible' } else { 'Collapsed' }
    $ui.btnNext.Content = if ($Step -eq 4) { 'Generate' } else { "Next $([char]0x2192)" }
}

function Update-Summary {
    $keyPreview = if ($script:FunctionKey) {
        "$($script:FunctionKey.Substring(0, [Math]::Min(8, $script:FunctionKey.Length)))..."
    } else { '(not configured)' }
    $tagList = ($ui.tagListBox.Items | ForEach-Object { $_ }) -join ', '
    $ui.txtSummary.Text = @"
Company:       $($ui.txtCompanyName.Text)
Function URL:  $(if ($script:FunctionUrl) { $script:FunctionUrl } else { '(not configured)' })
Function Key:  $keyPreview
Group Tags:    $tagList
Default Tag:   $(if ($ui.txtDefaultTag.SelectedItem -and $ui.txtDefaultTag.SelectedItem -ne '(none)') { $ui.txtDefaultTag.SelectedItem } else { '(none)' })
"@
}

# --- Navigation button events ---
$ui.btnNext.Add_Click({
    if ($script:CurrentStep -eq 1) {
        $script:StepCompleted[1] = $true
        Set-WizardStep 2
    }
    elseif ($script:CurrentStep -eq 2) {
        # Validate connection before proceeding
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
        $script:StepCompleted[2] = $true
        Set-WizardStep 3
    }
    elseif ($script:CurrentStep -eq 3) {
        $script:StepCompleted[3] = $true
        Set-WizardStep 4
    }
    elseif ($script:CurrentStep -eq 4) {
        # Do nothing here — the Generate button on the page handles it
        # Just prevent navigation
        return
    }
})

$ui.btnBack.Add_Click({
    if ($script:CurrentStep -gt 1) {
        Set-WizardStep ($script:CurrentStep - 1)
    }
})

$ui.btnSkip.Add_Click({
    # Skip Azure Backend (step 1) - mark as completed and go to step 2
    $script:StepCompleted[1] = $true
    Set-WizardStep 2
})

# --- Step indicator click handlers ---
$ui.stepIndicator1.Add_MouseLeftButtonDown({
    Set-WizardStep 1
})
$ui.stepIndicator2.Add_MouseLeftButtonDown({
    Set-WizardStep 2
})
$ui.stepIndicator3.Add_MouseLeftButtonDown({
    Set-WizardStep 3
})
$ui.stepIndicator4.Add_MouseLeftButtonDown({
    Set-WizardStep 4
})

# --- Step 1: Toggle panels (hide all, show selected) ---
$hideAllPanels = {
    $ui.panelExisting.Visibility = 'Collapsed'
    $ui.panelNew.Visibility = 'Collapsed'
    $ui.panelManual.Visibility = 'Collapsed'
}
$ui.radioExisting.Add_Checked({ & $hideAllPanels; $ui.panelExisting.Visibility = 'Visible' })
$ui.radioNew.Add_Checked({ & $hideAllPanels; $ui.panelNew.Visibility = 'Visible' })
$ui.radioManual.Add_Checked({ & $hideAllPanels; $ui.panelManual.Visibility = 'Visible' })

# --- Step 1: Test existing connection ---
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

# --- Step 2: Validate Connection ---
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

# --- Step 1: Copy CLI commands ---
$ui.btnCopyCommands.Add_Click({
    [System.Windows.Clipboard]::SetText($cliCommands)
    $ui.lblCopied.Text = 'Copied!'
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds(2)
    $timer.Add_Tick({ $ui.lblCopied.Text = ''; $timer.Stop() })
    $timer.Start()
})

# --- Step 1: Sign In & Load Subscriptions ---
$ui.btnSignIn.Add_Click({
    $ui.btnSignIn.IsEnabled = $false
    $ui.lblSignInStatus.Text = 'Signing in...'
    $ui.lblSignInStatus.Foreground = [System.Windows.Media.Brushes]::Gold
    $window.Dispatcher.Invoke([Action]{}, 'Render')

    try {
        Connect-AzAccount -ErrorAction Stop | Out-Null

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

# --- Step 1: Deploy (Step-by-step, background runspace) ---

# Shared state for background worker communication
$script:DeployState = [hashtable]::Synchronized(@{
    CurrentStep = 0
    StepLabels  = @{}
    Error       = ''
    Done        = $false
    ResultUrl   = ''
    ResultKey   = ''
})

# Helper: update deploy step UI from dispatcher
function Update-DeployStepUI {
    $state = $script:DeployState
    for ($i = 1; $i -le 6; $i++) {
        $ico = $ui["icoStep$i"]
        $lbl = $ui["lblStep$i"]
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
        $ui.lblDeployError.Text = "Deployment complete!`nURL: $($state.ResultUrl)`n`nGet your Function Key from Azure Portal:`nFunction App > $appName > App keys > default`n`nThen switch to 'I already have an Azure Function' and enter the URL + key, or click Next."
    }
}

$ui.btnDeploy.Add_Click({
    $ui.btnDeploy.IsEnabled = $false
    $ui.panelSteps.Visibility = 'Visible'
    $ui.lblDeployError.Text = ''

    # Collect params from UI (must be done on UI thread)
    $rg = $ui.txtResourceGroup.Text.Trim()
    $loc = ($ui.cmbLocation.SelectedItem).Content
    $prefix = $ui.txtPrefix.Text.Trim()
    $selectedIdx = $ui.cmbSubscription.SelectedIndex
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

    $ps = [powershell]::Create()
    $ps.Runspace = $runspace
    $ps.AddScript({
        $ErrorActionPreference = 'Stop'
        try {
            Import-Module Az.Accounts -ErrorAction Stop
            Import-Module Az.Resources -ErrorAction Stop
            Import-Module Az.Storage -ErrorAction Stop
            Import-Module Az.Websites -ErrorAction Stop
            Import-Module Az.Functions -ErrorAction Stop

            # Set subscription
            Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null

            # Step 1: Resource Group
            $state.CurrentStep = 1
            $state.StepLabels[1] = "Create Resource Group ($rg)"
            New-AzResourceGroup -Name $rg -Location $loc -Force -ErrorAction Stop | Out-Null

            # Step 2: Storage Account
            $state.CurrentStep = 2
            $state.StepLabels[2] = "Create Storage Account ($storageAccountName)"
            New-AzStorageAccount -ResourceGroupName $rg -Name $storageAccountName -Location $loc -SkuName 'Standard_LRS' -Kind 'StorageV2' -MinimumTlsVersion 'TLS1_2' -AllowBlobPublicAccess $false -ErrorAction Stop | Out-Null

            # Step 3: App Service Plan
            $state.CurrentStep = 3
            $state.StepLabels[3] = "Create App Service Plan ($planName)"
            New-AzAppServicePlan -ResourceGroupName $rg -Name $planName -Location $loc -Tier 'Dynamic' -ErrorAction Stop | Out-Null

            # Step 4: Function App
            $state.CurrentStep = 4
            $state.StepLabels[4] = "Create Function App ($functionAppName)"
            New-AzFunctionApp -ResourceGroupName $rg -Name $functionAppName -Location $loc `
                -StorageAccountName $storageAccountName -Runtime 'PowerShell' -RuntimeVersion '7.2' `
                -FunctionsVersion 4 -OSType 'Windows' -ErrorAction Stop | Out-Null
            Update-AzFunctionApp -ResourceGroupName $rg -Name $functionAppName -IdentityType 'SystemAssigned' -Force -ErrorAction Stop | Out-Null
            $funcApp = Get-AzWebApp -ResourceGroupName $rg -Name $functionAppName -ErrorAction Stop
            $functionAppUrl = "https://$($funcApp.DefaultHostName)"
            $principalId = $funcApp.Identity.PrincipalId
            $state.StepLabels[4] = "Create Function App ($functionAppName)"

            # Step 5: Grant Graph Permission
            $state.CurrentStep = 5
            $state.StepLabels[5] = "Grant Graph API Permission"
            & $grantScript -ManagedIdentityPrincipalId $principalId

            # Step 6: Deploy Code
            $state.CurrentStep = 6
            $state.StepLabels[6] = "Deploy Function Code"
            $zipPath = Join-Path $env:TEMP 'autopilot-function.zip'
            if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
            $filesToZip = @('host.json', 'profile.ps1', 'requirements.psd1', 'Upload', 'Status', 'Health')
            Compress-Archive -Path ($filesToZip | ForEach-Object { Join-Path $functionDir $_ }) -DestinationPath $zipPath -Force
            Publish-AzWebApp -ResourceGroupName $rg -Name $functionAppName -ArchivePath $zipPath -Force -ErrorAction Stop | Out-Null

            # Done — URL is known, key must be retrieved manually from Azure Portal
            $state.ResultUrl = $functionAppUrl
            $state.ResultKey = ''
            $state.ResultFunctionAppName = $functionAppName
            $state.CurrentStep = 7
            $state.Done = $true
        }
        catch {
            $state.Error = $_.Exception.Message
        }
    }) | Out-Null

    $asyncResult = $ps.BeginInvoke()

    # Timer to poll background state and update UI
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


# --- Step 3: Tag management ---

# Helper: sync Default Tag dropdown with Available Tags list
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

# Initialize default tag dropdown
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

# --- Step 3: Test connection ---
$ui.btnTestFinal.Add_Click({
    if (-not $script:FunctionUrl) {
        $ui.lblFinalTest.Text = 'No Function URL configured. Complete Azure Backend step first.'
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

# --- Step 3: Generate ---
$ui.btnGenerate.Add_Click({
    $company = $ui.txtCompanyName.Text.Trim()
    if (-not $company) {
        [System.Windows.MessageBox]::Show('Company name is required. Go to Branding & Tags step.', 'Validation', 'OK', 'Warning')
        return
    }
    if (-not $script:FunctionUrl -or $script:FunctionUrl -eq 'https://') {
        [System.Windows.MessageBox]::Show('Azure Function URL is required. Go to Azure Backend step.', 'Validation', 'OK', 'Warning')
        return
    }
    if (-not $script:FunctionKey) {
        [System.Windows.MessageBox]::Show('Function Key is required. Go to Azure Backend step.', 'Validation', 'OK', 'Warning')
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

    $configBlock = @"
`$Config = @{
    CompanyName  = '$($company -replace "'", "''")'
    FunctionUrl  = '$($script:FunctionUrl)'
    FunctionKey  = '$($script:FunctionKey)'
    GroupTags    = $tagArrayStr
    DefaultTag   = '$(if ($ui.txtDefaultTag.SelectedItem -and $ui.txtDefaultTag.SelectedItem -ne '(none)') { $ui.txtDefaultTag.SelectedItem -replace "'", "''" } else { '' })'
    Version      = '1.0.0'
}
"@

    $output = $template -replace '(?s)\$Config = @\{.*?\}', $configBlock

    if (-not (Test-Path $outputDir)) { New-Item -Path $outputDir -ItemType Directory -Force | Out-Null }

    $companySlug = $company -replace '[^A-Za-z0-9]', '-'
    $outputFile = Join-Path $outputDir "AutopilotTool-$companySlug.ps1"
    $output | Out-File $outputFile -Encoding UTF8

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

    $script:StepCompleted[4] = $true

    $ui.lblGenResult.Text = "Generated:`n  $outputFile`n  $startCmdPath`n  $instructionPath"
    $ui.lblGenResult.Foreground = [System.Windows.Media.Brushes]::LimeGreen

    Start-Process explorer.exe -ArgumentList $outputDir
})

# --- Initialize wizard on step 1 ---
Set-WizardStep 1

# --- Show Window ---
$window.ShowDialog() | Out-Null
