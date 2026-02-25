#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Monitor Alignment Fixer — snaps misaligned monitors to consistent positions.

.DESCRIPTION
    Reads the most recent monitor configuration from the registry, detects
    monitors whose positions are "almost" aligned (within a configurable
    threshold), groups them into alignment clusters, and offers to snap
    them to a consistent value.

    Works with any number/combination of monitors.

.NOTES
    Registry path: HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Configuration
    Run as Administrator.
#>

param(
    [int]$Threshold = 10
)

# --- Helpers ---

function Convert-ToInt32 ($Value) {
    # Registry may return the value as signed or unsigned depending on context
    try { return [int32]$Value }
    catch {
        return [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]$Value), 0)
    }
}

function Get-MonitorEntries {
    param([Microsoft.Win32.RegistryKey]$ConfigKey)

    $monitors = @()
    # Each config key has numbered subkeys (00, 01, ...) with position values directly
    foreach ($subkeyName in $ConfigKey.GetSubKeyNames()) {
        $subkey = $ConfigKey.OpenSubKey($subkeyName)
        if ($null -eq $subkey) { continue }

        $cx = $subkey.GetValue("Position.cx")
        $cy = $subkey.GetValue("Position.cy")
        $width = $subkey.GetValue("PrimSurfSize.cx")
        $height = $subkey.GetValue("PrimSurfSize.cy")

        if ($null -ne $cx -and $null -ne $cy) {
            $monitors += [PSCustomObject]@{
                Name      = $subkeyName
                RegKey    = $subkey
                RegPath   = $subkey.Name
                X         = Convert-ToInt32 $cx
                Y         = Convert-ToInt32 $cy
                Width     = if ($width) { [int]$width } else { 0 }
                Height    = if ($height) { [int]$height } else { 0 }
            }
        }
    }
    return $monitors
}

function Find-AlignmentClusters {
    param(
        [array]$Values,
        [int]$Threshold
    )

    # Group values that are within $Threshold of each other
    $sorted = $Values | Sort-Object
    $clusters = @()
    $current = @($sorted[0])

    for ($i = 1; $i -lt $sorted.Count; $i++) {
        if (($sorted[$i] - $current[-1]) -le $Threshold) {
            $current += $sorted[$i]
        } else {
            $clusters += ,@($current)
            $current = @($sorted[$i])
        }
    }
    $clusters += ,@($current)
    return $clusters
}

# --- Main ---

$basePath = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Configuration"

# Find the most recent configuration by Timestamp
$configs = Get-ChildItem -Path $basePath
$newest = $null
$newestTime = [long]0

foreach ($cfg in $configs) {
    $ts = (Get-Item -Path $cfg.PSPath).GetValue("Timestamp")
    if ($null -ne $ts -and [long]$ts -gt $newestTime) {
        $newestTime = [long]$ts
        $newest = $cfg
    }
}

if ($null -eq $newest) {
    Write-Host "No configuration entries found." -ForegroundColor Red
    exit 1
}

$dt = [DateTime]::FromFileTime($newestTime).ToString("dd.MM.yyyy HH:mm:ss")
Write-Host "Most recent config: $($newest.PSChildName)" -ForegroundColor Cyan
Write-Host "Timestamp: $dt`n"

# Read monitor entries
$regKey = (Get-Item -Path $newest.PSPath).OpenSubKey("")
$monitors = Get-MonitorEntries -ConfigKey $regKey

if ($monitors.Count -lt 2) {
    Write-Host "Only $($monitors.Count) monitor(s) found, nothing to align."
    exit 0
}

Write-Host "Found $($monitors.Count) monitors:`n"
$i = 0
foreach ($m in $monitors) {
    $i++
    $res = if ($m.Width -gt 0) { "$($m.Width)x$($m.Height)" } else { "unknown res" }
    Write-Host "  [$i] $($m.Name) — $res @ ($($m.X), $($m.Y))"
}

# Check X alignment
$xValues = $monitors | ForEach-Object { $_.X }
$yValues = $monitors | ForEach-Object { $_.Y }

$fixes = @()

foreach ($axis in @("X", "Y")) {
    $values = if ($axis -eq "X") { $xValues } else { $yValues }
    $unique = $values | Sort-Object -Unique

    if ($unique.Count -le 1) { continue }

    $clusters = Find-AlignmentClusters -Values $unique -Threshold $Threshold

    foreach ($cluster in $clusters) {
        if ($cluster.Count -le 1) { continue }

        # This cluster has monitors that are close but not identical
        $median = ($cluster | Sort-Object)[([Math]::Floor($cluster.Count / 2))]

        $affected = $monitors | Where-Object {
            $val = if ($axis -eq "X") { $_.X } else { $_.Y }
            $cluster -contains $val -and $val -ne $median
        }

        foreach ($m in $affected) {
            $oldVal = if ($axis -eq "X") { $m.X } else { $m.Y }
            $fixes += [PSCustomObject]@{
                Monitor  = $m
                Axis     = $axis
                OldValue = $oldVal
                NewValue = $median
                Delta    = $median - $oldVal
            }
        }
    }
}

if ($fixes.Count -eq 0) {
    Write-Host "`nAll monitors are properly aligned (threshold: ${Threshold}px). Nothing to do." -ForegroundColor Green
    exit 0
}

Write-Host "`n=== Proposed corrections (threshold: ${Threshold}px) ===`n" -ForegroundColor Yellow

foreach ($fix in $fixes) {
    $axisLabel = if ($fix.Axis -eq "X") { "horizontal" } else { "vertical" }
    $sign = if ($fix.Delta -gt 0) { "+$($fix.Delta)" } else { "$($fix.Delta)" }
    Write-Host "  $($fix.Monitor.Name): $axisLabel $($fix.OldValue) -> $($fix.NewValue) (${sign}px)"
}

Write-Host ""
$confirm = Read-Host "Apply these corrections? (y/n)"

if ($confirm -ne "y") {
    Write-Host "Aborted."
    exit 0
}

foreach ($fix in $fixes) {
    $propName = "Position.c$($fix.Axis.ToLower())"
    $regPath = $fix.Monitor.RegPath -replace "^HKEY_LOCAL_MACHINE\\", "HKLM:\"

    # Convert signed int32 to bytes and write as DWORD-compatible value
    $bytes = [BitConverter]::GetBytes([int32]$fix.NewValue)
    $dword = [BitConverter]::ToUInt32($bytes, 0)

    # Set-ItemProperty with DWORD needs the raw bytes approach for large uint32 values
    $regKeyObj = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
        ($fix.Monitor.RegPath -replace "^HKEY_LOCAL_MACHINE\\", ""),
        $true  # writable
    )
    $regKeyObj.SetValue($propName, [int32]$fix.NewValue, [Microsoft.Win32.RegistryValueKind]::DWord)
    $regKeyObj.Close()
    Write-Host "  Fixed: $($fix.Monitor.Name) $propName = $($fix.NewValue)" -ForegroundColor Green
}

Write-Host "`nDone. You may need to log out/in or reboot for changes to take effect." -ForegroundColor Cyan