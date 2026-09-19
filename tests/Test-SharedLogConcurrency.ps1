$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$sharedLogModule = Join-Path $projectRoot 'SharedLog.ps1'
. $sharedLogModule

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("YouTubeChapterWavLogTest-" + [Guid]::NewGuid().ToString('N'))
$logPath = Join-Path $testRoot 'shared.log'
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    Initialize-SharedLog -Path $logPath

    $heldReader = New-Object System.IO.FileStream(
        $logPath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite
    )
    try {
        Add-SharedLogLine -Path $logPath -Line 'written while reader is open'
    }
    finally {
        $heldReader.Dispose()
    }

    $writerJob = Start-Job -ScriptBlock {
        param($ModulePath, $Path)
        $ErrorActionPreference = 'Stop'
        . $ModulePath
        for ($i = 1; $i -le 250; $i++) {
            Add-SharedLogLine -Path $Path -Line "stress line $i"
        }
    } -ArgumentList $sharedLogModule, $logPath

    while ($writerJob.State -in @('NotStarted', 'Running')) {
        [void]@(Read-SharedLogLines -Path $logPath)
        Start-Sleep -Milliseconds 5
        $writerJob = Get-Job -Id $writerJob.Id
    }
    Receive-Job -Job $writerJob -Wait -ErrorAction Stop
    if ($writerJob.State -ne 'Completed') {
        throw "Concurrent writer job ended in state $($writerJob.State)."
    }

    $lines = @(Read-SharedLogLines -Path $logPath)
    if ($lines.Count -ne 251) {
        throw "Expected 251 complete log lines, found $($lines.Count)."
    }
    if ($lines[0] -ne 'written while reader is open' -or $lines[-1] -ne 'stress line 250') {
        throw 'Concurrent log output was incomplete or out of order.'
    }

    $expectedMarkerValue = 'D:\Editing\Example video\WAV'
    $encodedMarkerValue = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($expectedMarkerValue))
    Add-SharedLogLine -Path $logPath -Line "::OUTPUT::$encodedMarkerValue"
    $markerLine = @(Read-SharedLogLines -Path $logPath)[-1]
    if ($markerLine -notmatch '^::OUTPUT::(.+)$') {
        throw 'The output marker record was not preserved.'
    }
    $decodedMarkerValue = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[1]))
    if ($decodedMarkerValue -ne $expectedMarkerValue) {
        throw 'The output marker value did not survive shared logging.'
    }

    Write-Output 'PASS: shared log supports concurrent polling, rapid appends, and marker records.'
}
finally {
    if ($writerJob) { Remove-Job -Job $writerJob -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
