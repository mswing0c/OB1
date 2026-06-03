# run-daily-sync.ps1
# Wrapper invoked by Windows Task Scheduler.
# Loads .env from the recipe folder, then runs import-claude-sessions.py
# with a 2-day rolling window so missed runs are recovered automatically.
# Exit code is forwarded so Task Scheduler history surfaces failures.

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir

$logPath = Join-Path $scriptDir 'claude-session-sync.log'
$envPath = Join-Path $scriptDir '.env'
$pyScript = Join-Path $scriptDir 'import-claude-sessions.py'

function Write-Log {
    param([string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'), $Message
    Add-Content -Path $logPath -Value $line -Encoding utf8
    Write-Output $line
}

Write-Log "=== Daily sync start ==="

if (-not (Test-Path $envPath)) {
    Write-Log "ERROR: .env not found at $envPath"
    exit 2
}

# Load .env into the process environment. Skips comments and blank lines.
Get-Content $envPath | ForEach-Object {
    $line = $_.Trim()
    if (-not $line -or $line.StartsWith('#')) { return }
    $eq = $line.IndexOf('=')
    if ($eq -lt 1) { return }
    $key = $line.Substring(0, $eq).Trim()
    $val = $line.Substring($eq + 1).Trim()
    [Environment]::SetEnvironmentVariable($key, $val, 'Process')
}

# Find a working Python. Order: explicit Python312 install, py launcher, PATH python.
$python = $null
$candidates = @(
    "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe",
    "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe"
)
foreach ($c in $candidates) {
    if (Test-Path $c) { $python = $c; break }
}
if (-not $python) {
    if (Get-Command py -ErrorAction SilentlyContinue) { $python = 'py -3' }
    elseif (Get-Command python -ErrorAction SilentlyContinue) { $python = 'python' }
}
if (-not $python) {
    Write-Log "ERROR: No Python interpreter found."
    exit 3
}
Write-Log "Using Python: $python"

# Run the import. Capture stdout/stderr to the log; forward exit code.
try {
    $args = @($pyScript, '--days', '2', '--source', 'both')
    if ($python -eq 'py -3') {
        $output = & py -3 @args 2>&1
    } else {
        $output = & $python @args 2>&1
    }
    $exit = $LASTEXITCODE
    $output | ForEach-Object { Add-Content -Path $logPath -Value $_ -Encoding utf8 }
    Write-Log "=== Daily sync end (exit $exit) ==="
    exit $exit
} catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    exit 1
}
