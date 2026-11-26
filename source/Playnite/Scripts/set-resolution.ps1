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
#  -Action Set     : applique -Width x -Height et/ou -Hz (0 = ne pas toucher) sur l'ecran principal.
#                    L'etat d'avant est ecrit dans -SnapshotFile (garde tel quel s'il existe deja
#                    pour le meme ecran : un Restore precedent a ete manque).
#  -Action Restore : remet l'ecran decrit par -SnapshotFile dans son mode d'origine, puis supprime le fichier.
#
#  Avec une resolution, la mise a l'echelle par la carte est coupee (identite). Certaines cartes gardent
#  pourtant l'ancien signal (ou le mode prefere de l'ecran) et y agrandissent l'image : le signal reel est
#  alors verifie et un timing natif annonce par l'ecran (EDID, via WMI) est impose.
#  Prerequis : module DisplayConfig.
#  Codes de sortie : 0 ok, 1 module DisplayConfig absent, 2 ecran principal introuvable, 3 erreur inattendue.
#  Journal : set-resolution.log, a cote de -SnapshotFile.
# ============================================================

# Les cmdlets DisplayConfig emettent des erreurs non terminantes : 'Stop' les rend capturables.
$ErrorActionPreference = 'Stop'

$LogFile = Join-Path (Split-Path -Parent $SnapshotFile) 'set-resolution.log'
$Clock = [Diagnostics.Stopwatch]::StartNew()

function Write-Log([string]$msg) {
    try { Add-Content -Path $LogFile -Value ('{0:yyyy-MM-dd HH:mm:ss} +{1,5}ms [{2}] {3}' -f (Get-Date), $Clock.ElapsedMilliseconds, $Action, $msg) } catch { }
}

# Attend qu'une condition soit vraie (sondage court) au lieu d'une pause fixe
function Wait-Until([scriptblock]$cond, [double]$maxSec, [int]$pollMs = 200) {
    $limit = (Get-Date).AddSeconds($maxSec)
    do {
        try { if (& $cond) { return $true } } catch { }
        Start-Sleep -Milliseconds $pollMs
    } while ((Get-Date) -lt $limit)
    return $false
}

# Execute une action ; $true si elle a reussi, sinon journalise l'erreur et renvoie $false
function Step([string]$what, [scriptblock]$code) {
    try   { & $code | Out-Null; return $true }
    catch { Write-Log "Echec ($what) : $($_.Exception.Message)"; return $false }
}

# ---------------- Signal reel (QueryDisplayConfig / SetDisplayConfig) ----------------
# Compile une fois dans .cache\ (nom = hash du source), puis seulement charge.
$SignalSource = @'
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

function Import-Signal {
    if ('HtpcSignal' -as [type]) { return $true }
    try {
        $sha  = [Security.Cryptography.SHA1]::Create()
        $hash = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($SignalSource))[0..5] | ForEach-Object { $_.ToString('x2') })
        $dir  = Join-Path $PSScriptRoot '.cache'
        $dll  = Join-Path $dir "HtpcSignal-$hash.dll"
        if (-not (Test-Path $dll)) {
            $null = New-Item -ItemType Directory -Force $dir
            try { Get-ChildItem $dir -Filter 'HtpcSignal-*.dll' | Remove-Item -Force } catch { }
            Add-Type -TypeDefinition $SignalSource -OutputAssembly $dll -OutputType Library
            Write-Log 'Classe HtpcSignal compilee'
        }
        if (-not ('HtpcSignal' -as [type])) { Add-Type -Path $dll }
        return $true
    }
    catch { Write-Log "Classe HtpcSignal indisponible : $($_.Exception.Message)"; return $false }
}

# ---------------- Ecrans ----------------

# Ecran actif par DevicePath (stable), a defaut par DisplayId (simple position, peut changer)
function Find-Display([string]$devicePath, $displayId) {
    $all = @(Get-DisplayInfo | Where-Object { $_.Active })
    if ($devicePath) { return $all | Where-Object { "$($_.DevicePath)" -eq $devicePath } | Select-Object -First 1 }
    return $all | Where-Object { $_.DisplayId -eq $displayId } | Select-Object -First 1
}

# "3840x2160@59.94 Hz" -> largeur, hauteur, frequence arrondie (0 si inconnu)
function Read-Mode($modeText) {
    $w = 0; $h = 0; $r = 0
    if ("$modeText" -match '(\d+)\s*x\s*(\d+)') { $w = [int]$Matches[1]; $h = [int]$Matches[2] }
    if ("$modeText" -match '@\s*([\d\.,]+)') { $r = [int][math]::Round([double]($Matches[1] -replace ',', '.')) }
    return [pscustomobject]@{ Width = $w; Height = $h; Hz = $r }
}

# Signal reel : DeskW/DeskH (bureau), Width/Height (signal), Scaling ; $null si inconnu
function Get-Signal([string]$devicePath) {
    try {
        $s = [HtpcSignal]::Get($devicePath)
        if (-not $s) { return $null }
        $v = $s -split ','
        return [pscustomobject]@{ DeskW = [int]$v[0]; DeskH = [int]$v[1]; Width = [int]$v[2]; Height = [int]$v[3]; Scaling = [int]$v[4] }
    }
    catch { return $null }
}

# Le mode courant correspond-il a la demande ? (signal natif inclus quand une resolution est demandee)
function Test-Mode([string]$devicePath, [int]$w, [int]$h, [int]$hz) {
    $d = Find-Display $devicePath
    if (-not $d) { return $false }
    $m = Read-Mode $d.Mode
    if ($hz -gt 0 -and [math]::Abs($m.Hz - $hz) -ge 1) { return $false }
    if ($w -le 0) { return $true }
    if ($m.Width -ne $w -or $m.Height -ne $h) { return $false }
    $sig = Get-Signal $devicePath
    return (-not $sig) -or ($sig.Width -eq $w -and $sig.Height -eq $h)
}

# Timings annonces par l'ecran (EDID, via WMI) pour w x h, les plus proches de $hz (60 si 0) a 1 Hz pres
# d'abord (59.94 = 60), puis detailles avant etablis VESA avant le reste. Chacun est propose avec la fraction de frequence de WMI
# (parfois arrondie) puis la fraction exacte horloge / (total H x total V) : certains pilotes n'acceptent que l'une.
function Get-EdidTimings([string]$devicePath, [int]$w, [int]$h, [int]$hz) {
    # \\?\DISPLAY#RTK4206#5&3605778&0&UID4355#{guid}  ->  DISPLAY\RTK4206\5&3605778&0&UID4355
    $inst = ($devicePath -replace '^\\\\\?\\', '' -replace '#\{[^}]+\}$', '') -replace '#', '\'
    $wmi = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorListedSupportedSourceModes -ErrorAction SilentlyContinue |
        Where-Object { ($_.InstanceName -replace '_\d+$', '') -eq $inst } | Select-Object -First 1
    if (-not $wmi) { return @() }
    $target = if ($hz -gt 0) { $hz } else { 60 }
    $rank = @{ 4 = 0; 1 = 1 }
    $modes = $wmi.MonitorSourceModes |
        Where-Object { $_.HorizontalActivePixels -eq $w -and $_.VerticalActivePixels -eq $h -and $_.VerticalRefreshRateDenominator -gt 0 } |
        ForEach-Object {
            [pscustomobject]@{
                PixelRate = [uint64]$_.PixelClockRate
                TotalW    = [uint32]($_.HorizontalActivePixels + $_.HorizontalBlankingPixels)
                TotalH    = [uint32]($_.VerticalActivePixels + $_.VerticalBlankingPixels)
                VN        = [uint32]$_.VerticalRefreshRateNumerator
                VD        = [uint32]$_.VerticalRefreshRateDenominator
                Rate      = $_.VerticalRefreshRateNumerator / $_.VerticalRefreshRateDenominator
                Rank      = $(if ($rank.ContainsKey([int]$_.TimingType)) { $rank[[int]$_.TimingType] } else { 2 })
            }
        } |
        Where-Object { $hz -le 0 -or [math]::Abs($_.Rate - $hz) -lt 1 } |
        Sort-Object @{ Expression = { [math]::Round([math]::Abs($_.Rate - $target)) } }, Rank

    $seen = @{}
    foreach ($t in $modes) {
        $exact = $t.TotalW * $t.TotalH
        foreach ($f in @(@($t.VN, $t.VD), @([uint32]$t.PixelRate, [uint32]$exact))) {
            $key = '{0},{1},{2},{3},{4}' -f $t.PixelRate, $t.TotalW, $t.TotalH, $f[0], $f[1]
            if ($seen[$key]) { continue }
            $seen[$key] = $true
            [pscustomobject]@{ PixelRate = $t.PixelRate; TotalW = $t.TotalW; TotalH = $t.TotalH; VN = [uint32]$f[0]; VD = [uint32]$f[1] }
        }
    }
}

# Bureau au bon mode mais signal different (agrandi par la carte) : impose un timing natif
function Repair-Signal([string]$devicePath, [int]$w, [int]$h, [int]$hz) {
    if (-not (Import-Signal)) { return }
    $sig = Get-Signal $devicePath
    if (-not $sig -or $sig.DeskW -ne $w -or $sig.DeskH -ne $h) { return }
    if ($sig.Width -eq $w -and $sig.Height -eq $h) { return }
    Write-Log "Signal non natif : bureau ${w}x${h}, signal $($sig.Width)x$($sig.Height) (scaling $($sig.Scaling))"

    $timings = @(Get-EdidTimings $devicePath $w $h $hz)
    if ($timings.Count -eq 0) { Write-Log "Aucun timing ${w}x${h} annonce par l'ecran : signal laisse tel quel"; return }
    foreach ($t in $timings) {
        $desc = '{0}x{1} @ {2:N3} Hz ({3:N3} MHz, total {4}x{5}, {6}/{7})' -f $w, $h, ($t.VN / $t.VD), ($t.PixelRate / 1e6), $t.TotalW, $t.TotalH, $t.VN, $t.VD
        $r = -1
        try { $r = [HtpcSignal]::Set($devicePath, $w, $h, $t.PixelRate, $t.TotalW, $t.TotalH, $t.VN, $t.VD) } catch { }
        if ($r -eq 0 -and (Wait-Until { $s = Get-Signal $devicePath; $s -and $s.Width -eq $w -and $s.Height -eq $h } 2)) {
            Write-Log "Signal natif applique : $desc"; return
        }
        Write-Log "Timing refuse ($r) : $desc"
    }
    Write-Log 'Aucun timing accepte : signal laisse tel quel'
}

# Applique resolution et/ou frequence (0 = ne pas toucher), verifie, repli commande par commande si besoin
function Set-Mode($display, [int]$w, [int]$h, [int]$hz) {
    $useRes = ($w -gt 0 -and $h -gt 0)
    if (-not $useRes) { $w = 0; $h = 0 }
    if (-not $useRes -and $hz -le 0) { return }
    $path = "$($display.DevicePath)"
    $id = $display.DisplayId
    $null = Import-Signal
    if (Test-Mode $path $w $h $hz) { Write-Log 'Deja dans le bon mode'; return }

    $null = Step 'configuration groupee' {
        $cfg = Get-DisplayConfig
        if ($useRes) { $cfg = $cfg | Set-DisplayResolution -DisplayId $id -Width $w -Height $h }
        if ($hz -gt 0) { $cfg = $cfg | Set-DisplayRefreshRate -DisplayId $id -RefreshRate $hz }
        if ($useRes) {
            # Pas de mise a l'echelle par la carte : le signal doit etre exactement le mode demande
            $cfg.SetDisplayScaling($id, 'DISPLAYCONFIG_SCALING_IDENTITY')
            $cfg.SetDisplayActiveSize($id, $w, $h)
            $cfg | Use-DisplayConfig -AllowChanges
        }
        else { $cfg | Use-DisplayConfig }
    }
    # Bureau et frequence (le signal natif est traite apres par Repair-Signal)
    $deskOk = {
        $d = Find-Display $path
        if (-not $d) { return $false }
        $m = Read-Mode $d.Mode
        ((-not $useRes) -or ($m.Width -eq $w -and $m.Height -eq $h)) -and (($hz -le 0) -or [math]::Abs($m.Hz - $hz) -lt 1)
    }
    if (-not (Wait-Until $deskOk 3)) {
        Write-Log 'Mode incomplet apres la configuration groupee : commandes une par une'
        if ($useRes) { $null = Step 'resolution' { Set-DisplayResolution -DisplayId $id -Width $w -Height $h -AllowChanges } }
        if ($hz -gt 0) { $null = Step 'frequence' { Set-DisplayRefreshRate -DisplayId $id -RefreshRate $hz } }
        if (-not (Wait-Until $deskOk 3)) { Write-Log "Mode toujours incorrect : $((Find-Display $path).Mode)" }
    }

    if ($useRes) { Repair-Signal $path $w $h $hz }
    Write-Log "Mode final : $((Find-Display $path).Mode)"
}

# ---------------- Principal ----------------
try {
    if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt 200KB)) { Remove-Item $LogFile -Force -ErrorAction SilentlyContinue }
    Write-Log "Demarrage : ${Width}x${Height} @ $Hz Hz, snapshot=$SnapshotFile (existe : $(Test-Path $SnapshotFile))"
    try { Import-Module DisplayConfig } catch { Write-Log "Module DisplayConfig absent : $($_.Exception.Message)"; exit 1 }

    $snap = $null
    if (Test-Path $SnapshotFile) {
        try { $snap = Get-Content -Path $SnapshotFile -Raw | ConvertFrom-Json } catch { Write-Log "Snapshot illisible : $($_.Exception.Message)" }
    }

    if ($Action -eq 'Restore') {
        if (-not $snap) { Write-Log 'Aucun snapshot a restaurer'; exit 0 }
        $display = Find-Display "$($snap.DevicePath)" $snap.DisplayId
        if ($display) { Set-Mode $display $snap.Width $snap.Height $snap.Hz }
        else { Write-Log 'Ecran du snapshot inactif ou absent : rien a restaurer' }
        Remove-Item -Path $SnapshotFile -Force -ErrorAction SilentlyContinue
        exit 0
    }

    $display = Get-DisplayInfo | Where-Object { $_.Active -and $_.Primary } | Select-Object -First 1
    if (-not $display) { Write-Log 'Ecran principal introuvable'; exit 2 }

    if ($snap -and "$($snap.DevicePath)" -eq "$($display.DevicePath)") {
        Write-Log "Snapshot existant garde ($($snap.Width)x$($snap.Height) @ $($snap.Hz) Hz) : Restore precedent manque"
    }
    else {
        $m = Read-Mode $display.Mode
        [pscustomobject]@{ DevicePath = "$($display.DevicePath)"; DisplayId = $display.DisplayId; Width = $m.Width; Height = $m.Height; Hz = $m.Hz } |
            ConvertTo-Json | Set-Content -Path $SnapshotFile -Encoding UTF8
    }

    Set-Mode $display $Width $Height $Hz
    exit 0
}
catch {
    Write-Log "Erreur inattendue : $($_.Exception.Message) (ligne $($_.InvocationInfo.ScriptLineNumber))"
    exit 3
}
