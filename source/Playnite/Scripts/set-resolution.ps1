param(
    [Parameter(Mandatory = $true)][ValidateSet('Set', 'Restore')][string]$Action,
    [int]$Width = 0,
    [int]$Height = 0,
    [int]$Hz = 0,
    [Parameter(Mandatory = $true)][string]$SnapshotFile
)

# ============================================================
#  set-resolution.ps1  (lance par Playnite, silencieux)
#
#  -Action Set     : applique -Width x -Height / -Hz (> 0) sur l'ecran principal.
#                    L'etat precedent est ecrit dans -SnapshotFile.
#  -Action Restore : remet la resolution / frequence decrites par -SnapshotFile.
#
#  Avec une resolution, la mise a l'echelle de la carte est coupee (identite) et le signal envoye a cette taille.
#  Certaines cartes (Intel iGPU) ignorent cette demande et gardent le mode prefere de l'ecran (ex. 720p)
#  en y agrandissant l'image : on verifie alors le signal reel et on impose un timing natif
#  pris dans les modes annonces par l'ecran (EDID, via WMI).
#  Prerequis : module DisplayConfig.
#  Codes de sortie : 0 ok, 1 module DisplayConfig absent, 2 ecran principal introuvable.
# ============================================================

$LogFile = Join-Path (Split-Path -Parent $SnapshotFile) 'set-resolution.log'

function Write-Log([string]$msg) {
    try { Add-Content -Path $LogFile -Value ('{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Action, $msg) } catch { }
}

# Execute un bloc, retourne $true / $false selon la reussite (les erreurs sont journalisees)
function Step([scriptblock]$code) {
    $Error.Clear()
    try   { & $code | Out-Null }
    catch { Write-Log "Echec: $($_.Exception.Message) :: $($code.ToString().Trim())"; return $false }
    if ($Error.Count -gt 0) { Write-Log "Erreur non bloquante: $($Error[0]) :: $($code.ToString().Trim())" }
    return $true
}

# Acces direct a QueryDisplayConfig / SetDisplayConfig : signal reel envoye a l'ecran
# et application d'un timing complet (source + cible), sans laisser Windows le modifier.
if (-not ('HtpcSignal' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class HtpcSignal
{
    [StructLayout(LayoutKind.Sequential)]
    struct PATH
    {
        public uint sAdLow; public int sAdHigh; public uint sId; public uint sModeIdx; public uint sFlags;
        public uint tAdLow; public int tAdHigh; public uint tId; public uint tModeIdx; public uint tTech;
        public uint tRot; public uint tScaling; public uint tRefN; public uint tRefD; public uint tScan;
        public int tAvail; public uint tFlags;
        public uint flags;
    }

    [StructLayout(LayoutKind.Explicit, Size = 64)]
    struct MODE
    {
        [FieldOffset(0)] public uint infoType;
        [FieldOffset(4)] public uint id;
        [FieldOffset(8)] public uint adLow;
        [FieldOffset(12)] public int adHigh;
        [FieldOffset(16)] public ulong pixelRate;
        [FieldOffset(24)] public uint hN;
        [FieldOffset(28)] public uint hD;
        [FieldOffset(32)] public uint vN;
        [FieldOffset(36)] public uint vD;
        [FieldOffset(40)] public uint aW;
        [FieldOffset(44)] public uint aH;
        [FieldOffset(48)] public uint tW;
        [FieldOffset(52)] public uint tH;
        [FieldOffset(56)] public uint vStd;
        [FieldOffset(60)] public uint scan;
        [FieldOffset(16)] public uint sW;
        [FieldOffset(20)] public uint sH;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct TARGET_NAME
    {
        public uint type; public uint size; public uint adLow; public int adHigh; public uint id;
        public uint flags; public uint tech; public ushort mfg; public ushort prod; public uint conn;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string friendly;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string path;
    }

    [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint np, out uint nm);
    [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint np, [Out] PATH[] p, ref uint nm, [Out] MODE[] m, IntPtr topo);
    [DllImport("user32.dll")] static extern int SetDisplayConfig(uint np, [In] PATH[] p, uint nm, [In] MODE[] m, uint flags);
    [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(ref TARGET_NAME t);

    static void Query(out PATH[] p, out MODE[] m)
    {
        uint np, nm;
        int r = GetDisplayConfigBufferSizes(2, out np, out nm);          // QDC_ONLY_ACTIVE_PATHS
        if (r != 0) throw new Exception("GetDisplayConfigBufferSizes " + r);
        p = new PATH[np]; m = new MODE[nm];
        r = QueryDisplayConfig(2, ref np, p, ref nm, m, IntPtr.Zero);
        if (r != 0) throw new Exception("QueryDisplayConfig " + r);
        Array.Resize(ref p, (int)np); Array.Resize(ref m, (int)nm);
    }

    static int Find(PATH[] p, string devicePath)
    {
        for (int i = 0; i < p.Length; i++)
        {
            var t = new TARGET_NAME();
            t.type = 2;                                                   // GET_TARGET_NAME
            t.size = (uint)Marshal.SizeOf(typeof(TARGET_NAME));
            t.adLow = p[i].tAdLow; t.adHigh = p[i].tAdHigh; t.id = p[i].tId;
            if (DisplayConfigGetDeviceInfo(ref t) == 0 &&
                string.Equals(t.path, devicePath, StringComparison.OrdinalIgnoreCase)) return i;
        }
        return -1;
    }

    // "bureauL,bureauH,signalL,signalH,scaling" ou "" si l'ecran n'est pas actif
    public static string Get(string devicePath)
    {
        PATH[] p; MODE[] m; Query(out p, out m);
        int i = Find(p, devicePath);
        if (i < 0) return "";
        var s = m[p[i].sModeIdx]; var t = m[p[i].tModeIdx];
        return s.sW + "," + s.sH + "," + t.aW + "," + t.aH + "," + p[i].tScaling;
    }

    // Bureau w x h, signal w x h avec le timing donne, mise a l'echelle identite. Retourne le code Win32 (0 = ok).
    public static int Set(string devicePath, uint w, uint h, ulong pixelRate, uint totalW, uint totalH, uint vN, uint vD)
    {
        PATH[] p; MODE[] m; Query(out p, out m);
        int i = Find(p, devicePath);
        if (i < 0) return -1;
        uint si = p[i].sModeIdx, ti = p[i].tModeIdx;
        m[si].sW = w; m[si].sH = h;
        m[ti].pixelRate = pixelRate;
        m[ti].hN = (uint)pixelRate; m[ti].hD = totalW;
        m[ti].vN = vN; m[ti].vD = vD;
        m[ti].aW = w; m[ti].aH = h; m[ti].tW = totalW; m[ti].tH = totalH;
        p[i].tScaling = 1;                                                // DISPLAYCONFIG_SCALING_IDENTITY
        p[i].tRefN = vN; p[i].tRefD = vD;
        // SDC_APPLY | SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_SAVE_TO_DATABASE (pas d'ALLOW_CHANGES)
        return SetDisplayConfig((uint)p.Length, p, (uint)m.Length, m, 0x80 | 0x20 | 0x200);
    }
}
'@
}

function Find-DisplayById($id) {
    Get-DisplayInfo | Where-Object { $_.DisplayId -eq $id } | Select-Object -First 1
}

# "3840x2160@120 Hz" -> largeur, hauteur, frequence (0 si inconnu)
function Read-Mode($modeText) {
    $w = 0; $h = 0; $r = 0
    if ("$modeText" -match '(\d+)\s*x\s*(\d+)') { $w = [int]$Matches[1]; $h = [int]$Matches[2] }
    if ("$modeText" -match '@\s*([\d\.,]+)') { $r = [int][math]::Round([double]($Matches[1] -replace ',', '.')) }
    return [pscustomobject]@{ Width = $w; Height = $h; Hz = $r }
}

# Signal reel envoye a l'ecran (taille active) ; $null si inconnu
function Get-Signal($display) {
    try {
        $s = [HtpcSignal]::Get("$($display.DevicePath)")
        if (-not $s) { return $null }
        $v = $s -split ','
        return [pscustomobject]@{ DeskW = [int]$v[0]; DeskH = [int]$v[1]; Width = [int]$v[2]; Height = [int]$v[3]; Scaling = [int]$v[4] }
    }
    catch { Write-Log "Lecture du signal impossible: $($_.Exception.Message)"; return $null }
}

# Le signal correspond-il au bureau demande (pas d'agrandissement par la carte) ?
function Test-SignalNative($display, [int]$w, [int]$h) {
    $sig = Get-Signal $display
    if (-not $sig) { return $true }    # inconnu : on ne force rien
    return ($sig.Width -eq $w -and $sig.Height -eq $h)
}

# Timings annonces par l'ecran pour w x h, du plus fiable au moins fiable
# (detaille EDID, puis etabli VESA, puis le reste), a la frequence la plus proche de $hz.
function Get-EdidTimings($display, [int]$w, [int]$h, [int]$hz) {
    # \\?\DISPLAY#RTK4206#4&29906b6&0&UID49#{guid}  ->  DISPLAY\RTK4206\4&29906b6&0&UID49
    $inst = ("$($display.DevicePath)" -replace '^\\\\\?\\', '' -replace '#\{[^}]+\}$', '') -replace '#', '\'
    $wmi = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorListedSupportedSourceModes -ErrorAction SilentlyContinue |
        Where-Object { ($_.InstanceName -replace '_\d+$', '') -eq $inst } | Select-Object -First 1
    if (-not $wmi) { return @() }
    $rank = @{ 4 = 0; 1 = 1 }
    @($wmi.MonitorSourceModes |
        Where-Object { $_.HorizontalActivePixels -eq $w -and $_.VerticalActivePixels -eq $h -and $_.VerticalRefreshRateDenominator -gt 0 } |
        ForEach-Object {
            $rate = $_.VerticalRefreshRateNumerator / $_.VerticalRefreshRateDenominator
            [pscustomobject]@{
                PixelRate = [uint64]$_.PixelClockRate
                TotalW    = [uint32]($_.HorizontalActivePixels + $_.HorizontalBlankingPixels)
                TotalH    = [uint32]($_.VerticalActivePixels + $_.VerticalBlankingPixels)
                VN        = [uint32]$_.VerticalRefreshRateNumerator
                VD        = [uint32]$_.VerticalRefreshRateDenominator
                Rate      = $rate
                Rank      = $(if ($rank.ContainsKey([int]$_.TimingType)) { $rank[[int]$_.TimingType] } else { 2 })
            }
        } |
        Where-Object { $hz -le 0 -or [math]::Abs($_.Rate - $hz) -lt 1 } |
        Sort-Object Rank, @{ Expression = { if ($hz -gt 0) { [math]::Abs($_.Rate - $hz) } else { [math]::Abs($_.Rate - 60) } } })
}

# Impose un signal natif w x h quand la carte a garde un autre mode en agrandissant l'image
function Repair-Signal($id, [int]$w, [int]$h, [int]$hz) {
    $cur = Find-DisplayById $id
    if (-not $cur -or (Test-SignalNative $cur $w $h)) { return }
    $sig = Get-Signal $cur
    Write-Log "Signal non natif: bureau ${w}x${h} mais signal $($sig.Width)x$($sig.Height) (scaling $($sig.Scaling)), on impose le timing"

    $timings = Get-EdidTimings $cur $w $h $hz
    if ($timings.Count -eq 0) { Write-Log "Aucun timing ${w}x${h} annonce par l'ecran : signal laisse tel quel"; return }
    foreach ($t in $timings) {
        $r = [HtpcSignal]::Set("$($cur.DevicePath)", $w, $h, $t.PixelRate, $t.TotalW, $t.TotalH, $t.VN, $t.VD)
        $desc = '{0}x{1} @ {2:N2} Hz ({3:N3} MHz, total {4}x{5})' -f $w, $h, $t.Rate, ($t.PixelRate / 1e6), $t.TotalW, $t.TotalH
        if ($r -eq 0) {
            Start-Sleep -Milliseconds 500
            $cur = Find-DisplayById $id
            if ($cur -and (Test-SignalNative $cur $w $h)) { Write-Log "Signal natif applique: $desc"; return }
        }
        Write-Log "Timing refuse ($r): $desc"
    }
    Write-Log 'Aucun timing accepte : signal laisse tel quel'
}

# Applique resolution et frequence (0 = ne pas toucher), verifie, repli si besoin
function Set-DisplayModeSafe($id, [int]$w, [int]$h, [int]$hz) {
    $useRes = ($w -gt 0 -and $h -gt 0)
    if (-not $useRes -and $hz -le 0) { return }

    $cur = Find-DisplayById $id
    if ($cur) {
        $m = Read-Mode $cur.Mode
        $resOk = (-not $useRes) -or ($m.Width -eq $w -and $m.Height -eq $h -and (Test-SignalNative $cur $w $h))
        $hzOk = ($hz -le 0) -or ([math]::Abs($m.Hz - $hz) -lt 1)
        if ($resOk -and $hzOk) { return }
    }

    Step {
        $cfg = Get-DisplayConfig
        if ($useRes) { $cfg = $cfg | Set-DisplayResolution -DisplayId $id -Width $w -Height $h }
        if ($hz -gt 0) { $cfg = $cfg | Set-DisplayRefreshRate -DisplayId $id -RefreshRate $hz }
        # Pas de mise a l'echelle par la carte: le mode envoye a l'ecran est exactement celui demande (quel que soit l'ecran)
        if ($useRes) {
            $cfg.SetDisplayScaling($id, 'DISPLAYCONFIG_SCALING_IDENTITY')
            $cfg.SetDisplayActiveSize($id, $w, $h)
            $cfg | Use-DisplayConfig -AllowChanges
        }
        else { $cfg | Use-DisplayConfig }
    } | Out-Null
    Start-Sleep -Seconds 2

    $cur = Find-DisplayById $id
    if ($cur -and $hz -gt 0 -and ([math]::Abs((Read-Mode $cur.Mode).Hz - $hz) -ge 1)) {
        if ($useRes) {
            Step { Set-DisplayResolution -DisplayId $id -Width $w -Height $h -AllowChanges } | Out-Null
            Start-Sleep -Seconds 1
        }
        Step { Set-DisplayRefreshRate -DisplayId $id -RefreshRate $hz } | Out-Null
        Start-Sleep -Seconds 1
    }

    if ($useRes) { Repair-Signal $id $w $h $hz }
}

if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt 200KB)) { Remove-Item $LogFile -Force -ErrorAction SilentlyContinue }
Write-Log "Demarrage: ${Width}x${Height} @ $Hz Hz, snapshot=$SnapshotFile (existe: $(Test-Path $SnapshotFile))"
try { Import-Module DisplayConfig -ErrorAction Stop } catch { Write-Log "Module DisplayConfig absent: $($_.Exception.Message)"; exit 1 }

if ($Action -eq 'Restore') {
    if (Test-Path $SnapshotFile) {
        $snap = Get-Content -Path $SnapshotFile -Raw | ConvertFrom-Json
        Set-DisplayModeSafe $snap.DisplayId $snap.Width $snap.Height $snap.Hz
        Remove-Item -Path $SnapshotFile -Force -ErrorAction SilentlyContinue
    }
    else { Write-Log 'Aucune photo a restaurer.' }
    exit 0
}

$target = Get-DisplayInfo | Where-Object { $_.Active -and $_.Primary } | Select-Object -First 1
if (-not $target) { Write-Log 'Ecran principal introuvable'; exit 2 }

$m = Read-Mode $target.Mode
[pscustomobject]@{ DisplayId = $target.DisplayId; Width = $m.Width; Height = $m.Height; Hz = $m.Hz } |
    ConvertTo-Json | Set-Content -Path $SnapshotFile -Encoding UTF8

Set-DisplayModeSafe $target.DisplayId $Width $Height $Hz
exit 0
