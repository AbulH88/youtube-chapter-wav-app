$script:sharedLogEncoding = New-Object System.Text.UTF8Encoding($false)

function Initialize-SharedLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $stream = $null
    try {
        $stream = New-Object System.IO.FileStream(
            $Path,
            [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::ReadWrite
        )
    }
    finally {
        if ($stream) { $stream.Dispose() }
    }
}

function Add-SharedLogLine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [AllowEmptyString()]
        [string]$Line,
        [int]$RetryCount = 10,
        [int]$RetryDelayMilliseconds = 25
    )

    for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
        $stream = $null
        $writer = $null
        try {
            $stream = New-Object System.IO.FileStream(
                $Path,
                [System.IO.FileMode]::Append,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::ReadWrite
            )
            $writer = New-Object System.IO.StreamWriter($stream, $script:sharedLogEncoding)
            $writer.WriteLine($Line)
            $writer.Flush()
            return
        }
        catch [System.IO.IOException] {
            if ($attempt -eq $RetryCount) { throw }
        }
        finally {
            if ($writer) {
                $writer.Dispose()
                $stream = $null
            }
            if ($stream) { $stream.Dispose() }
        }
        Start-Sleep -Milliseconds $RetryDelayMilliseconds
    }
}

function Read-SharedLogLines {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $stream = $null
    $reader = $null
    try {
        $stream = New-Object System.IO.FileStream(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)
        $content = $reader.ReadToEnd()
    }
    finally {
        if ($reader) {
            $reader.Dispose()
            $stream = $null
        }
        if ($stream) { $stream.Dispose() }
    }

    # Return only newline-terminated records. If a snapshot catches a write in
    # progress, the incomplete tail will be returned by the next poll instead.
    $matches = [System.Text.RegularExpressions.Regex]::Matches($content, '([^\r\n]*)(?:\r\n|\n)')
    foreach ($match in $matches) {
        [string]$match.Groups[1].Value
    }
}
