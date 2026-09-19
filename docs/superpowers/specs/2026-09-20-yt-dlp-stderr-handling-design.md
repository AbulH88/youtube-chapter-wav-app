# yt-dlp stderr handling design

## Problem

The worker sets PowerShell's global error preference to `Stop` and merges a native
tool's stderr into stdout. On some computers, a non-fatal yt-dlp warning written to
stderr is promoted to a terminating PowerShell error. The worker then reports a
failed conversion without checking yt-dlp's process exit code.

The screenshot demonstrates this with yt-dlp's warning that no supported
JavaScript runtime was found. The warning can mean some YouTube formats are
unavailable, but it does not by itself mean the command failed.

## Design

Add a small native-tool runner in `Worker.ps1` that:

1. Temporarily prevents PowerShell from promoting native stderr records to
   terminating errors.
2. Captures and logs stdout and stderr together so diagnostic messages remain
   visible in the app.
3. Restores the caller's error preferences after the native command completes.
4. Treats the command as failed only when its process exit code is nonzero.
5. Returns captured output when the caller needs to parse it, as with yt-dlp's
   metadata JSON.

Use this runner for both metadata extraction and audio downloading. Keep ffmpeg
on the same path so all bundled command-line tools have consistent behavior.

## User-visible error handling

Keep warnings in the progress log. For a genuine nonzero exit, log a concise
failure message plus the tool output. The existing conversion-failed dialog can
continue directing the user to the progress log.

## Scope

Do not bundle Deno or another JavaScript runtime in this change. That would
increase the shared app's size and maintenance burden, and it is not required to
correct the false failure. If YouTube later requires a runtime for a particular
video, yt-dlp will return a real nonzero exit and the app will preserve its full
diagnostic output.

## Verification

- Run a stub native executable that writes a warning to stderr and exits `0`;
  the worker must continue successfully.
- Run a stub that writes an error and exits nonzero; the worker must fail and log
  the output.
- Run metadata extraction for the URL from the screenshot and verify valid JSON
  is parsed.
- Perform a short download/conversion smoke test without downloading the entire
  multi-hour example video.

