$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$workerPath = Join-Path $projectRoot 'Worker.ps1'
$workerSource = Get-Content -LiteralPath $workerPath -Raw
$functionStart = $workerSource.IndexOf('function Invoke-LoggedTool')
$tryStart = $workerSource.IndexOf("`r`ntry {", $functionStart)
if ($tryStart -lt 0) {
    $tryStart = $workerSource.IndexOf("`ntry {", $functionStart)
}
if ($functionStart -lt 0 -or $tryStart -lt 0) {
    throw 'Could not isolate Invoke-LoggedTool from Worker.ps1.'
}

$script:loggedLines = New-Object System.Collections.Generic.List[string]
function Write-JobLog {
    param([string]$Message)
    $script:loggedLines.Add($Message)
}

Invoke-Expression $workerSource.Substring($functionStart, $tryStart - $functionStart)

$shell = (Get-Process -Id $PID).Path
$warningCommand = "[Console]::Error.WriteLine('non-fatal warning'); exit 0"
Invoke-LoggedTool -Executable $shell -Arguments @('-NoProfile', '-Command', $warningCommand) -FailureMessage 'Unexpected failure'
if ($script:loggedLines -notcontains 'non-fatal warning') {
    throw 'A successful tool warning was not logged.'
}

$captureCommand = "Write-Output 'metadata payload'; exit 0"
$lineCountBeforeCapture = $script:loggedLines.Count
$captured = @(Invoke-LoggedTool -Executable $shell -Arguments @('-NoProfile', '-Command', $captureCommand) -FailureMessage 'Unexpected capture failure' -CaptureOutput)
if ($captured -notcontains 'metadata payload') {
    throw 'Successful output requested by the caller was not captured.'
}
if ($script:loggedLines.Count -ne $lineCountBeforeCapture) {
    throw 'Large successful captured output should not be copied to the visible log.'
}

$failureCommand = "[Console]::Error.WriteLine('real failure'); exit 7"
$failedAsExpected = $false
try {
    Invoke-LoggedTool -Executable $shell -Arguments @('-NoProfile', '-Command', $failureCommand) -FailureMessage 'Expected failure'
}
catch {
    $failedAsExpected = $_.Exception.Message -eq 'Expected failure (exit code 7).'
}
if (-not $failedAsExpected) {
    throw 'A nonzero native exit was not reported correctly.'
}
if ($script:loggedLines -notcontains 'real failure') {
    throw 'A failed tool message was not logged.'
}

Write-Output 'PASS: native stderr is logged without causing false failures, and nonzero exits still fail.'
