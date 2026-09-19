param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$url = [string]$config.Url
$outputRoot = [string]$config.OutputRoot
$toolDir = [string]$config.ToolDir
$jobDir = [string]$config.JobDir
$logPath = [string]$config.LogPath
$overwrite = [bool]$config.Overwrite
$ytDlp = Join-Path $toolDir 'yt-dlp.exe'
$ffmpeg = Join-Path $toolDir 'ffmpeg.exe'
$partialFiles = New-Object System.Collections.Generic.List[string]
$exitCode = 1

function Write-JobLog {
    param([string]$Message)
    $timestamp = Get-Date -Format 'HH:mm:ss'
    Add-Content -LiteralPath $logPath -Value "[$timestamp] $Message" -Encoding UTF8
}

function Write-Marker {
    param([string]$Name, [string]$Value)
    $bytes = [System.Text.Encoding]::Unicode.GetBytes($Value)
    $encoded = [Convert]::ToBase64String($bytes)
    Add-Content -LiteralPath $logPath -Value "::$Name::$encoded" -Encoding UTF8
}

function Get-SafeName {
    param([string]$Name, [int]$MaxLength = 120)
    $safe = $Name -replace '[<>:"/\\|?*\x00-\x1F]', '-'
    $safe = $safe -replace '\s+', ' '
    $safe = $safe.Trim().TrimEnd('.')
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'Untitled' }
    if ($safe.Length -gt $MaxLength) { $safe = $safe.Substring(0, $MaxLength).Trim().TrimEnd('.') }
    if ($safe -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') { $safe = "_$safe" }
    return $safe
}

function Invoke-LoggedTool {
    param(
        [string]$Executable,
        [string[]]$Arguments,
        [string]$FailureMessage,
        [switch]$CaptureOutput
    )

    # Windows PowerShell can promote any native stderr line (including a harmless
    # yt-dlp warning) to a terminating error when ErrorActionPreference is Stop.
    # Native tools report success through their process exit code, so capture all
    # output with promotion disabled and evaluate the exit code ourselves.
    $previousErrorActionPreference = $ErrorActionPreference
    $hasNativeErrorPreference = Test-Path -LiteralPath 'Variable:PSNativeCommandUseErrorActionPreference'
    if ($hasNativeErrorPreference) {
        $previousNativeErrorPreference = $PSNativeCommandUseErrorActionPreference
    }

    try {
        $ErrorActionPreference = 'Continue'
        if ($hasNativeErrorPreference) {
            $PSNativeCommandUseErrorActionPreference = $false
        }
        $toolOutput = @(& $Executable @Arguments 2>&1 | ForEach-Object { [string]$_ })
        $toolExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        if ($hasNativeErrorPreference) {
            $PSNativeCommandUseErrorActionPreference = $previousNativeErrorPreference
        }
    }

    # Captured output (the metadata JSON) can be very large. Keep successful
    # captured output out of the UI log, but always log normal tool output and
    # diagnostics from failed commands.
    if (-not $CaptureOutput -or $toolExitCode -ne 0) {
        foreach ($line in $toolOutput) {
            Write-JobLog ([string]$line)
        }
    }
    if ($toolExitCode -ne 0) {
        throw "$FailureMessage (exit code $toolExitCode)."
    }
    if ($CaptureOutput) {
        return $toolOutput
    }
}

try {
    New-Item -ItemType Directory -Path $jobDir -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $logPath) -Force | Out-Null
    Set-Content -LiteralPath $logPath -Value '' -Encoding UTF8

    if (-not (Test-Path -LiteralPath $ytDlp -PathType Leaf)) { throw 'yt-dlp.exe is missing from the app tools folder.' }
    if (-not (Test-Path -LiteralPath $ffmpeg -PathType Leaf)) { throw 'ffmpeg.exe is missing from the app tools folder.' }

    Write-JobLog 'Reading video title and chapter information...'
    $metadataOutput = @(Invoke-LoggedTool -Executable $ytDlp -Arguments @('--dump-single-json', '--skip-download', '--no-playlist', '--quiet', '--no-warnings', '--', $url) -FailureMessage 'Could not read the YouTube video information' -CaptureOutput)
    $metadata = ($metadataOutput -join [Environment]::NewLine) | ConvertFrom-Json
    $title = [string]$metadata.title
    $videoId = [string]$metadata.id
    $videoFolderName = Get-SafeName "$title [$videoId]" 140
    $videoFolder = Join-Path $outputRoot $videoFolderName
    $wavDir = Join-Path $videoFolder 'WAV'

    if ((Test-Path -LiteralPath $wavDir) -and (Get-ChildItem -LiteralPath $wavDir -File -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        if (-not $overwrite) {
            Write-Marker 'OVERWRITE_REQUIRED' $wavDir
            Write-JobLog 'The destination already contains files. Waiting for overwrite confirmation.'
            $exitCode = 22
            exit 22
        }
        Write-JobLog 'Removing the previously confirmed destination WAV folder...'
        Remove-Item -LiteralPath $wavDir -Recurse -Force
    }

    New-Item -ItemType Directory -Path $wavDir -Force | Out-Null
    Write-JobLog 'Downloading the best available audio to temporary storage...'
    $sourceTemplate = Join-Path $jobDir 'source.%(ext)s'
    Invoke-LoggedTool -Executable $ytDlp -Arguments @('--no-playlist', '--newline', '-f', 'ba/b', '-o', $sourceTemplate, '--', $url) -FailureMessage 'Audio download failed'
    $source = Get-ChildItem -LiteralPath $jobDir -File | Where-Object { $_.Name -like 'source.*' } | Sort-Object Length -Descending | Select-Object -First 1
    if (-not $source) { throw 'The downloaded temporary audio file could not be found.' }

    $chapters = @($metadata.chapters)
    if ($chapters.Count -eq 0 -or $null -eq $metadata.chapters) {
        Write-JobLog 'No chapter markers were found; creating one WAV file for the full video.'
        $finalName = '01 - ' + (Get-SafeName $title 150) + '.wav'
        $finalPath = Join-Path $wavDir $finalName
        $partialPath = Join-Path $wavDir ($finalName -replace '\.wav$', '.partial.wav')
        $partialFiles.Add($partialPath)
        Invoke-LoggedTool -Executable $ffmpeg -Arguments @('-hide_banner', '-loglevel', 'error', '-y', '-i', $source.FullName, '-vn', '-map', '0:a:0', '-c:a', 'pcm_s16le', $partialPath) -FailureMessage 'WAV conversion failed'
        Move-Item -LiteralPath $partialPath -Destination $finalPath -Force
        $partialFiles.Remove($partialPath) | Out-Null
    }
    else {
        Write-JobLog "Converting $($chapters.Count) chapters to lossless WAV..."
        for ($i = 0; $i -lt $chapters.Count; $i++) {
            $chapter = $chapters[$i]
            $number = ($i + 1).ToString('00')
            $chapterTitle = Get-SafeName ([string]$chapter.title) 150
            $finalName = "$number - $chapterTitle.wav"
            $finalPath = Join-Path $wavDir $finalName
            $partialPath = Join-Path $wavDir "$number - $chapterTitle.partial.wav"
            $partialFiles.Add($partialPath)
            $start = [double]$chapter.start_time
            if ($null -ne $chapter.end_time) {
                $end = [double]$chapter.end_time
            }
            elseif ($null -ne $metadata.duration) {
                $end = [double]$metadata.duration
            }
            else {
                $end = 0
            }
            $duration = $end - $start
            Write-JobLog "[$($i + 1)/$($chapters.Count)] $chapterTitle"
            $ffmpegArgs = @('-hide_banner', '-loglevel', 'error', '-y', '-ss', $start.ToString([Globalization.CultureInfo]::InvariantCulture), '-i', $source.FullName)
            if ($duration -gt 0) {
                $ffmpegArgs += @('-t', $duration.ToString([Globalization.CultureInfo]::InvariantCulture))
            }
            $ffmpegArgs += @('-vn', '-map', '0:a:0', '-c:a', 'pcm_s16le', $partialPath)
            Invoke-LoggedTool -Executable $ffmpeg -Arguments $ffmpegArgs -FailureMessage "WAV conversion failed for chapter $number"
            Move-Item -LiteralPath $partialPath -Destination $finalPath -Force
            $partialFiles.Remove($partialPath) | Out-Null
        }
    }

    $finalFiles = @(Get-ChildItem -LiteralPath $wavDir -File -Filter '*.wav' | Where-Object { $_.Name -notlike '*.partial.wav' })
    if ($finalFiles.Count -eq 0) { throw 'No completed WAV files were produced.' }
    Write-JobLog "Completed successfully: $($finalFiles.Count) WAV file(s)."
    Write-Marker 'OUTPUT' $wavDir
    $exitCode = 0
}
catch {
    Write-JobLog "ERROR: $($_.Exception.Message)"
    $exitCode = 1
}
finally {
    foreach ($partial in $partialFiles) {
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $jobDir -Recurse -Force -ErrorAction SilentlyContinue
}

exit $exitCode
