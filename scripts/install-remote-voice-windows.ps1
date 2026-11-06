param(
    [string]$DeviceName = 'CABLE Input',
    [ValidateScript({ ($_ -ge 112 -and $_ -le 123) -or $_ -eq 164 })][int]$VoiceKey = 113,
    [switch]$BuildOnly,
    [switch]$Uninstall
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Get-OwnHiddenLauncher($Actions, [string]$Executable) {
    if (@($Actions).Count -ne 1) { return $null }
    $action = @($Actions)[0]
    $wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
    if ($action.Execute -ne $wscript) { return $null }
    $paths = [regex]::Matches($action.Arguments, '"([^"]+\.vbs)"|(?:^|\s)([^\s"]+\.vbs)(?=\s|$)')
    if ($paths.Count -ne 1) { return $null }
    $path = $paths[0].Groups[1].Value
    if (!$path) { $path = $paths[0].Groups[2].Value }
    if ([IO.Path]::GetFileName($path) -ne 'SayAllRemoteVoice-hidden.vbs') { return $null }
    $remaining = $action.Arguments.Remove($paths[0].Index, $paths[0].Length).Trim()
    if ($remaining -and @($remaining -split '\s+' | Where-Object { $_ -notmatch '^//?(?:B|Nologo)$' }).Count) { return $null }
    if (!(Test-Path -LiteralPath $path) -or (Get-Item -LiteralPath $path).Length -gt 16384) { return $null }
    $text = [IO.File]::ReadAllText($path)
    $allowed = @('^Option Explicit$', '^Dim shell, rc$', '^Set shell\s*=\s*CreateObject\("WScript\.Shell"\)$',
        '^shell\.CurrentDirectory\s*=\s*"[^"]+"$', '^rc\s*=\s*shell\.Run\(.*\)$', '^WScript\.Quit rc$')
    foreach ($line in ($text -split '\r?\n')) {
        $line = $line.Trim()
        if (!$line -or $line.StartsWith("'")) { continue }
        if (!@($allowed | Where-Object { $line -match $_ }).Count) { return $null }
    }
    $runs = [regex]::Matches($text, '(?im)^(\s*rc\s*=\s*shell\.Run\(\s*)"((?:[^"]|"")*)"(\s*,\s*0\s*,\s*True\s*\)\s*)$')
    if ($runs.Count -ne 1) { return $null }
    $command = $runs[0].Groups[2].Value.Replace('""', '"')
    $expected = '^"' + [regex]::Escape($Executable) + '"\s+--desktop\s+--device\s+"[^"\r\n]{1,128}"\s+--voice-key\s+(11[2-9]|12[0-3]|164)$'
    if ($command -notmatch $expected) { return $null }
    return [pscustomobject]@{ Path=$path; Text=$text; Run=$runs[0].Value; Prefix=$runs[0].Groups[1].Value; Suffix=$runs[0].Groups[3].Value; Command=$command }
}

# Permanent current-user receiver installer. No audio driver, firewall, or SSH changes.
if ($DeviceName.Length -gt 128 -or $DeviceName -match '["\r\n]') { throw 'Invalid virtual-device name' }
$installRoot = Join-Path $env:LOCALAPPDATA 'SayAllRemoteVoice'
$source = Join-Path $PSScriptRoot '..\Sources\WindowsRemoteVoice\Program.cs'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$exe = Join-Path $installRoot 'SayAllRemoteVoice.exe'
$taskName = 'SayAllRemoteVoice'
$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
$hiddenLauncher = if ($existing) { Get-OwnHiddenLauncher $existing.Actions $exe } else { $null }
if ($existing -and @($existing.Actions | Where-Object { $_.Execute -ne $exe }).Count -gt 0 -and !$hiddenLauncher) { throw 'Refusing to replace a different task' }
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
function Stop-OwnRelayProcesses {
    # The desktop lease owner has already stopped and released keys. Old SSH
    # relay/test workers cannot be allowed to keep the installed image locked.
    $workers = @(Get-CimInstance Win32_Process -Filter "Name='SayAllRemoteVoice.exe'" | Where-Object {
        $_.SessionId -eq 0 -and $_.ExecutablePath -eq $exe -and $_.CommandLine -match '(?:^|\s)--(?:relay|stdio-self-test)(?:\s|$)'
    })
    foreach ($worker in $workers) {
        try { $owner = Invoke-CimMethod -InputObject $worker -MethodName GetOwnerSid }
        catch {
            if (!(Get-Process -Id $worker.ProcessId -ErrorAction SilentlyContinue)) { continue }
            throw
        }
        if ($owner.Sid -ne $user.User.Value) { throw 'Refusing to stop another user relay' }
        Stop-Process -Id $worker.ProcessId -Force -ErrorAction SilentlyContinue
    }
}
if ($Uninstall) {
    Stop-OwnReceiver
    Stop-OwnRelayProcesses
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

$arguments = '--desktop --device "' + $DeviceName + '" --voice-key ' + $VoiceKey
try {
    Stop-OwnReceiver
    Stop-OwnRelayProcesses
    Copy-Item -LiteralPath $candidate -Destination $exe -Force
    if ($hiddenLauncher) {
        # Preserve an already-managed headless task, including its exit-code propagation.
        [IO.File]::WriteAllText((Join-Path $installRoot 'previous-launch-command.txt'), $hiddenLauncher.Command)
        $command = ('"' + $exe + '" ' + $arguments).Replace('"', '""')
        $line = $hiddenLauncher.Prefix + '"' + $command + '"' + $hiddenLauncher.Suffix
        [IO.File]::WriteAllText($hiddenLauncher.Path, $hiddenLauncher.Text.Replace($hiddenLauncher.Run, $line), [Text.Encoding]::Unicode)
        Start-ScheduledTask -TaskName $taskName
        Write-Output 'Updated verified current-user headless receiver; existing task action and settings preserved.'
        exit 0
    }
} catch {
    if ($existing) { Start-ScheduledTask -TaskName $taskName }
    throw
}
$action = New-ScheduledTaskAction -Execute $exe -Argument $arguments
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user.Name
$principal = New-ScheduledTaskPrincipal -UserId $user.Name -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $taskName
Write-Output 'Installed current-user SayAll remote voice receiver; no network listener or driver change.'
