Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:appDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:workerPath = Join-Path $script:appDir 'Worker.ps1'
$script:toolDir = Join-Path $script:appDir 'tools'
$script:activeProcess = $null
$script:activeJobDir = $null
$script:activeLogPath = $null
$script:lastLogLineCount = 0
$script:outputPath = $null
$script:overwritePath = $null

function Decode-MarkerValue {
    param([string]$Encoded)
    try {
        return [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Encoded))
    }
    catch { return $null }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'YouTube Chapter WAV'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(720, 500)
$form.MinimumSize = New-Object System.Drawing.Size(650, 440)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'YouTube Chapter WAV Extractor'
$title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 16)
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(20, 16)
$form.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = 'Paste a YouTube link to create numbered, lossless WAV chapter files.'
$subtitle.AutoSize = $true
$subtitle.ForeColor = [System.Drawing.Color]::DimGray
$subtitle.Location = New-Object System.Drawing.Point(23, 51)
$form.Controls.Add($subtitle)

$urlLabel = New-Object System.Windows.Forms.Label
$urlLabel.Text = 'YouTube URL'
$urlLabel.AutoSize = $true
$urlLabel.Location = New-Object System.Drawing.Point(22, 88)
$form.Controls.Add($urlLabel)

$urlBox = New-Object System.Windows.Forms.TextBox
$urlBox.Anchor = 'Top,Left,Right'
$urlBox.Location = New-Object System.Drawing.Point(24, 108)
$urlBox.Size = New-Object System.Drawing.Size(672, 24)
$form.Controls.Add($urlBox)

$folderLabel = New-Object System.Windows.Forms.Label
$folderLabel.Text = 'Output folder'
$folderLabel.AutoSize = $true
$folderLabel.Location = New-Object System.Drawing.Point(22, 146)
$form.Controls.Add($folderLabel)

$folderBox = New-Object System.Windows.Forms.TextBox
$folderBox.Anchor = 'Top,Left,Right'
$folderBox.Location = New-Object System.Drawing.Point(24, 166)
$folderBox.Size = New-Object System.Drawing.Size(574, 24)
$folderBox.Text = [Environment]::GetFolderPath('MyMusic')
$form.Controls.Add($folderBox)

$browseButton = New-Object System.Windows.Forms.Button
$browseButton.Anchor = 'Top,Right'
$browseButton.Text = 'Browse...'
$browseButton.Location = New-Object System.Drawing.Point(608, 164)
$browseButton.Size = New-Object System.Drawing.Size(88, 28)
$form.Controls.Add($browseButton)

$startButton = New-Object System.Windows.Forms.Button
$startButton.Text = 'Start conversion'
$startButton.BackColor = [System.Drawing.Color]::FromArgb(32, 115, 190)
$startButton.ForeColor = [System.Drawing.Color]::White
$startButton.FlatStyle = 'Flat'
$startButton.Location = New-Object System.Drawing.Point(24, 207)
$startButton.Size = New-Object System.Drawing.Size(140, 34)
$form.Controls.Add($startButton)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = 'Ready'
$statusLabel.AutoSize = $true
$statusLabel.Location = New-Object System.Drawing.Point(178, 216)
$form.Controls.Add($statusLabel)

$logBox = New-Object System.Windows.Forms.RichTextBox
$logBox.Anchor = 'Top,Bottom,Left,Right'
$logBox.Location = New-Object System.Drawing.Point(24, 257)
$logBox.Size = New-Object System.Drawing.Size(672, 218)
$logBox.ReadOnly = $true
$logBox.BackColor = [System.Drawing.Color]::FromArgb(248, 249, 250)
$logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$form.Controls.Add($logBox)

$folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
$folderDialog.Description = 'Choose where the WAV chapter folder will be created'
$folderDialog.ShowNewFolderButton = $true

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 300

function Set-BusyState {
    param([bool]$Busy)
    $startButton.Enabled = -not $Busy
    $browseButton.Enabled = -not $Busy
    $urlBox.ReadOnly = $Busy
    $folderBox.ReadOnly = $Busy
    if ($Busy) { $statusLabel.Text = 'Working...' }
}

function Add-VisibleLogLine {
    param([string]$Line)
    if ($Line -match '^::OUTPUT::(.+)$') {
        $script:outputPath = Decode-MarkerValue $Matches[1]
        return
    }
    if ($Line -match '^::OVERWRITE_REQUIRED::(.+)$') {
        $script:overwritePath = Decode-MarkerValue $Matches[1]
        return
    }
    if (-not [string]::IsNullOrWhiteSpace($Line)) {
        $logBox.AppendText($Line + [Environment]::NewLine)
        $logBox.SelectionStart = $logBox.TextLength
        $logBox.ScrollToCaret()
        if ($Line -match '\] (.+)$') { $statusLabel.Text = $Matches[1] }
    }
}

function Read-NewLogLines {
    if (-not $script:activeLogPath -or -not (Test-Path -LiteralPath $script:activeLogPath)) { return }
    try {
        $lines = @(Get-Content -LiteralPath $script:activeLogPath -ErrorAction Stop)
        if ($lines.Count -gt $script:lastLogLineCount) {
            for ($i = $script:lastLogLineCount; $i -lt $lines.Count; $i++) {
                Add-VisibleLogLine ([string]$lines[$i])
            }
            $script:lastLogLineCount = $lines.Count
        }
    }
    catch { }
}

function Start-Conversion {
    param([bool]$Overwrite = $false)

    $url = $urlBox.Text.Trim()
    $outputRoot = $folderBox.Text.Trim()
    if ($url -notmatch '^https?://') {
        [System.Windows.Forms.MessageBox]::Show('Enter a valid YouTube URL.', 'Invalid URL', 'OK', 'Warning') | Out-Null
        return
    }
    if ([string]::IsNullOrWhiteSpace($outputRoot)) {
        [System.Windows.Forms.MessageBox]::Show('Choose an output folder.', 'Output folder required', 'OK', 'Warning') | Out-Null
        return
    }
    try { New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null }
    catch {
        [System.Windows.Forms.MessageBox]::Show("The output folder cannot be created:`n$($_.Exception.Message)", 'Folder error', 'OK', 'Error') | Out-Null
        return
    }

    $ytDlp = Join-Path $script:toolDir 'yt-dlp.exe'
    $ffmpeg = Join-Path $script:toolDir 'ffmpeg.exe'
    if (-not (Test-Path -LiteralPath $ytDlp) -or -not (Test-Path -LiteralPath $ffmpeg)) {
        [System.Windows.Forms.MessageBox]::Show('The app tools are missing. Keep the tools folder beside the app script.', 'Missing tools', 'OK', 'Error') | Out-Null
        return
    }

    $id = [Guid]::NewGuid().ToString('N')
    $baseTemp = Join-Path ([IO.Path]::GetTempPath()) 'YouTubeChapterWavApp'
    $script:activeJobDir = Join-Path $baseTemp "job-$id"
    $logDir = Join-Path $baseTemp 'logs'
    New-Item -ItemType Directory -Path $script:activeJobDir -Force | Out-Null
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    $script:activeLogPath = Join-Path $logDir "job-$id.log"
    $configPath = Join-Path $script:activeJobDir 'config.json'
    @{
        Url = $url
        OutputRoot = [IO.Path]::GetFullPath($outputRoot)
        ToolDir = $script:toolDir
        JobDir = $script:activeJobDir
        LogPath = $script:activeLogPath
        Overwrite = $Overwrite
    } | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8

    $script:lastLogLineCount = 0
    $script:outputPath = $null
    $script:overwritePath = $null
    if (-not $Overwrite) { $logBox.Clear() }
    Set-BusyState $true

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$script:workerPath`" -ConfigPath `"$configPath`""
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $script:activeProcess = New-Object System.Diagnostics.Process
    $script:activeProcess.StartInfo = $psi
    try {
        $script:activeProcess.Start() | Out-Null
        $timer.Start()
    }
    catch {
        Set-BusyState $false
        $statusLabel.Text = 'Failed to start'
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Start error', 'OK', 'Error') | Out-Null
    }
}

$browseButton.Add_Click({
    if (Test-Path -LiteralPath $folderBox.Text) { $folderDialog.SelectedPath = $folderBox.Text }
    if ($folderDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $folderBox.Text = $folderDialog.SelectedPath
    }
})

$startButton.Add_Click({ Start-Conversion $false })

$timer.Add_Tick({
    Read-NewLogLines
    if ($script:activeProcess -and $script:activeProcess.HasExited) {
        Read-NewLogLines
        $exitCode = $script:activeProcess.ExitCode
        $timer.Stop()
        $script:activeProcess.Dispose()
        $script:activeProcess = $null
        Set-BusyState $false

        if ($exitCode -eq 0) {
            $statusLabel.Text = 'Complete'
            $message = "WAV chapters created successfully."
            if ($script:outputPath) { $message += "`n`n$script:outputPath" }
            [System.Windows.Forms.MessageBox]::Show($message, 'Conversion complete', 'OK', 'Information') | Out-Null
        }
        elseif ($exitCode -eq 22 -and $script:overwritePath) {
            $statusLabel.Text = 'Confirmation required'
            $answer = [System.Windows.Forms.MessageBox]::Show("This destination already contains files:`n`n$script:overwritePath`n`nReplace that WAV folder?", 'Confirm overwrite', 'YesNo', 'Warning')
            if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
                Start-Conversion $true
            }
            else { $statusLabel.Text = 'Cancelled' }
        }
        else {
            $statusLabel.Text = 'Failed'
            [System.Windows.Forms.MessageBox]::Show('The conversion failed. See the progress log for details.', 'Conversion failed', 'OK', 'Error') | Out-Null
        }
    }
})

$form.Add_FormClosing({
    param($sender, $eventArgs)
    if ($script:activeProcess -and -not $script:activeProcess.HasExited) {
        $answer = [System.Windows.Forms.MessageBox]::Show('A conversion is still running. Cancel it and close the app?', 'Conversion in progress', 'YesNo', 'Warning')
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            $eventArgs.Cancel = $true
            return
        }
        try { $script:activeProcess.Kill() } catch { }
        if ($script:activeJobDir) {
            Remove-Item -LiteralPath $script:activeJobDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
})

[void]$form.ShowDialog()
