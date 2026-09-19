# Shared log concurrency design

## Problem

The GUI polls the worker log every 300 milliseconds with `Get-Content`, while the
worker appends each yt-dlp progress line with `Add-Content`. These independent
PowerShell file operations do not guarantee compatible file-sharing modes. During
rapid download progress, the reader can briefly block the writer. Because the
worker uses `ErrorActionPreference = Stop`, that logging collision aborts an
otherwise healthy download.

## Design

Use explicit .NET file streams on both sides of the log:

- The worker opens the file in append mode with `FileShare.ReadWrite`, writes one
  complete UTF-8 line, flushes it, and disposes the stream.
- Marker records use the same append function as ordinary log records.
- The GUI opens the file for reading with `FileShare.ReadWrite`, reads the current
  snapshot, and disposes the stream.
- The worker retries short-lived `IOException` failures with a small bounded delay
  to tolerate antivirus scanners or unrelated transient locks.
- If every retry fails, the worker preserves the existing failure behavior because
  it can no longer communicate status or output markers safely.

The existing polling interval, visible log format, marker encoding, and conversion
workflow remain unchanged.

## Verification

- Hold the log open for reading with read/write sharing and verify the worker can
  append a complete line.
- Repeatedly read snapshots while rapidly appending lines and verify no write
  fails and every line is present.
- Confirm marker lines still decode through the existing UI path.
- Parse both PowerShell files and rerun the native-tool regression suite.

