param(
    [string]$Exe = ".\dist\XGrab\XGrab.exe",
    [string]$Url = "",
    [int]$WaitSeconds = 24,
    [int]$SettleSeconds = 14,
    [string]$OutFile = "ui_shot.png"
)

Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Cap {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
}
"@
[Cap]::SetProcessDPIAware() | Out-Null

$workdir = Split-Path $Exe
if ([string]::IsNullOrWhiteSpace($workdir)) { $workdir = $PWD.Path }
$proc = Start-Process -FilePath $Exe -ArgumentList @($Url) -WorkingDirectory $workdir -PassThru

$handle = [IntPtr]::Zero
$deadline = (Get-Date).AddSeconds($WaitSeconds)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 700
    $p = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
    if (-not $p) { Write-Error "l'exe a quitte"; exit 1 }
    $p.Refresh()
    if ($p.MainWindowHandle -ne 0) { $handle = $p.MainWindowHandle; break }
}
if ($handle -eq [IntPtr]::Zero) { Write-Error "aucune fenetre"; Stop-Process -Id $proc.Id -Force; exit 1 }

[Cap]::SetForegroundWindow($handle) | Out-Null
Start-Sleep -Seconds ([Math]::Max(2, $SettleSeconds))

$rect = New-Object Cap+RECT
[Cap]::GetWindowRect($handle, [ref]$rect) | Out-Null
$w = $rect.R - $rect.L
$h = $rect.B - $rect.T

$bitmap = New-Object System.Drawing.Bitmap $w, $h
$g = [System.Drawing.Graphics]::FromImage($bitmap)
$hdc = $g.GetHdc()
[Cap]::PrintWindow($handle, $hdc, 2) | Out-Null
$g.ReleaseHdc($hdc)
$g.Dispose()

$out = Join-Path $PWD $OutFile
$bitmap.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
$bitmap.Dispose()

Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
"screenshot: $out ($w x $h)"
