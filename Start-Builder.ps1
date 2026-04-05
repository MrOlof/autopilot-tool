# Autopilot Registration Tool - Builder Launcher
# Run this from the project root to start the Builder wizard.

# Hide the PowerShell console window
Add-Type -Name Win32 -Namespace Native -MemberDefinition '[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);'
$consoleHandle = (Get-Process -Id $PID).MainWindowHandle
if ($consoleHandle -ne [IntPtr]::Zero) {
    [Native.Win32]::ShowWindow($consoleHandle, 0) | Out-Null
}

& "$PSScriptRoot\builder\Build-AutopilotTool.ps1"
