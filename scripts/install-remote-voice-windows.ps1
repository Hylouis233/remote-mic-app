param(
    [string]$DeviceName = 'CABLE Input',
    [ValidateScript({ ($_ -ge 112 -and $_ -le 123) -or $_ -eq 164 })][int]$VoiceKey = 113,
    [switch]$BuildOnly,
    [switch]$Uninstall
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Permanent current-user receiver installer. No audio driver, firewall, or SSH changes.
if ($DeviceName.Length -gt 128 -or $DeviceName -match '["\r\n]') { throw 'Invalid virtual-device name' }
$installRoot = Join-Path $env:LOCALAPPDATA 'SayAllRemoteVoice'
$source = Join-Path $PSScriptRoot '..\Sources\WindowsRemoteVoice\Program.cs'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$exe = Join-Path $installRoot 'SayAllRemoteVoice.exe'
$taskName = 'SayAllRemoteVoice'
$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing -and @($existing.Actions | Where-Object { $_.Execute -ne $exe }).Count -gt 0) { throw 'Refusing to replace a different task' }
$user = [System.Security.Principal.WindowsIdentity]::GetCurrent()
if ($existing) {
    if ($existing.Principal.UserId -like 'S-1-*') { $ownerSid = $existing.Principal.UserId }
    else {
        $owner = New-Object System.Security.Principal.NTAccount($existing.Principal.UserId)
        $ownerSid = $owner.Translate([System.Security.Principal.SecurityIdentifier]).Value
    }
    if ($ownerSid -ne $user.User.Value) { throw 'Refusing to replace another user task' }
}
function Stop-OwnReceiver {
    $running = @(Get-Process -Name SayAllRemoteVoice -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe -and $_.SessionId -gt 0 })
    if ($running.Count -eq 0) { return }
    $eventName = 'Global\SayAllRemoteVoice.Stop.' + $user.User.Value
    $signal = [System.Threading.EventWaitHandle]::OpenExisting($eventName)
    try { $signal.Set() | Out-Null } finally { $signal.Dispose() }
    foreach ($process in $running) { if (!$process.WaitForExit(6000)) { throw 'Receiver is busy or could not safely release its voice key' } }
}
if ($Uninstall) {
    Stop-OwnReceiver
    if ($existing) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false }
    if (Test-Path $installRoot) {
        Add-Type -AssemblyName Microsoft.VisualBasic
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($installRoot, 'OnlyErrorDialogs', 'SendToRecycleBin')
    }
    Write-Output 'Removed current-user receiver task; component files moved to Recycle Bin.'
    exit 0
}
if (!(Test-Path $source) -or !(Test-Path $compiler)) { throw 'Receiver source or system C# compiler is unavailable' }
New-Item -ItemType Directory -Force $installRoot | Out-Null
$acl = New-Object System.Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true, $false)
$acl.SetOwner($user.User)
foreach ($sid in @($user.User, [System.Security.Principal.SecurityIdentifier]'S-1-5-18')) {
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $acl.AddAccessRule($rule)
}
Set-Acl -Path $installRoot -AclObject $acl
$staging = Join-Path $installRoot 'Staging'
New-Item -ItemType Directory -Force $staging | Out-Null
$candidate = Join-Path $staging 'SayAllRemoteVoice.exe'
& $compiler /nologo /target:exe /platform:x64 /optimize+ "/out:$candidate" /r:System.Core.dll /r:System.Windows.Forms.dll /r:System.Drawing.dll $source
if ($LASTEXITCODE -ne 0) { throw 'Receiver compilation failed' }
& $candidate --self-test
if ($LASTEXITCODE -ne 0) { throw 'Receiver regression failed' }
if ($BuildOnly) { & $candidate --list-devices; exit $LASTEXITCODE }

Stop-OwnReceiver
Copy-Item -LiteralPath $candidate -Destination $exe -Force
$arguments = '--desktop --device "' + $DeviceName + '" --voice-key ' + $VoiceKey
$action = New-ScheduledTaskAction -Execute $exe -Argument $arguments
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user.Name
$principal = New-ScheduledTaskPrincipal -UserId $user.Name -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $taskName
Write-Output 'Installed current-user SayAll remote voice receiver; no network listener or driver change.'
