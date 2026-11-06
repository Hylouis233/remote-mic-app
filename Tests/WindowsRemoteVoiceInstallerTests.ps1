$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot '..\scripts\install-remote-voice-windows.ps1'
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Installer parse failed' }
$definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-OwnHiddenLauncher' }, $true)
if (!$definition) { throw 'Missing launcher verifier' }
# Load only the pure verifier, never the installer's top-level operations.
Invoke-Expression $definition.Extent.Text
$root = Join-Path ([IO.Path]::GetTempPath()) ('sayall-launcher-test-' + [guid]::NewGuid())
New-Item -ItemType Directory $root | Out-Null
try {
    $exe = Join-Path $root 'SayAllRemoteVoice.exe'
    $script = Join-Path $root 'SayAllRemoteVoice-hidden.vbs'
    $command = ('"' + $exe + '" --desktop --device "VB-Audio Virtual Cable" --voice-key 113').Replace('"', '""')
    $body = "Option Explicit`nDim shell, rc`nSet shell = CreateObject(`"WScript.Shell`")`nshell.CurrentDirectory = `"$root`"`nrc = shell.Run(`"$command`", 0, True)`nWScript.Quit rc"
    [IO.File]::WriteAllText($script, $body)
    $action = [pscustomobject]@{ Execute=(Join-Path $env:WINDIR 'System32\wscript.exe'); Arguments=('"' + $script + '"') }
    if (!(Get-OwnHiddenLauncher @($action) $exe)) { throw 'Valid own hidden launcher rejected' }
    if (Get-OwnHiddenLauncher @($action) ($exe + '.other')) { throw 'Different executable accepted' }
    [IO.File]::WriteAllText($script, $body + "`nshell.Run `"other.exe`", 0, True")
    if (Get-OwnHiddenLauncher @($action) $exe) { throw 'Extra command accepted' }
    [IO.File]::WriteAllText($script, $body)
    $action.Arguments = '//E:jscript "' + $script + '"'
    if (Get-OwnHiddenLauncher @($action) $exe) { throw 'Alternate script engine accepted' }
    Write-Output 'PASS headless launcher ownership, foreign-target rejection, extra-command rejection and engine bounds; no tasks changed'
} finally { Remove-Item -LiteralPath $root -Recurse -Force }
