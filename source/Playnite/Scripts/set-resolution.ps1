# ============================================================
#  set-resolution.ps1  (lance par Playnite, silencieux)
#
#  -Action Set     : applique -Width x -Height / -Hz (> 0) sur l'ecran principal.
#                    L'etat precedent est ecrit dans -SnapshotFile.
#  -Action Restore : remet la resolution / frequence decrites par -SnapshotFile.
#
#  L'echelle d'affichage n'est jamais modifiee.
#  Prerequis : module DisplayConfig.
#  Codes de sortie : 0 ok, 1 module DisplayConfig absent, 2 ecran principal introuvable.
# ============================================================
param(
    [Parameter(Mandatory = $true)][ValidateSet('Set', 'Restore')][string]$Action,
    [int]$Width = 0,
    [int]$Height = 0,
    [int]$Hz = 0,
    [Parameter(Mandatory = $true)][string]$SnapshotFile
)

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

# Applique resolution et frequence (0 = ne pas toucher), verifie, repli si besoin
function Set-DisplayModeSafe($id, [int]$w, [int]$h, [int]$hz) {
    $useRes = ($w -gt 0 -and $h -gt 0)
    if (-not $useRes -and $hz -le 0) { return }

    $cur = Find-DisplayById $id
    # RetroTINK (EDID RTK, ou @@@ si inconnu): pas de mise a l'echelle par la carte, le mode envoye est vraiment celui demande
    $isRetro = ($cur -and "$($cur.DevicePath)" -match '#(RTK|@@@)\w{4}#')
    if ($cur) {
        $m = Read-Mode $cur.Mode
        $resOk = (-not $useRes) -or ($m.Width -eq $w -and $m.Height -eq $h)
        $hzOk = ($hz -le 0) -or ([math]::Abs($m.Hz - $hz) -lt 1)
        if ($resOk -and $hzOk) { return }
    }

    if ($isRetro) { Write-Log "Ecran RetroTINK detecte ($($cur.DevicePath)): mise a l'echelle identite, taille active ${w}x${h}" }
    Step {
        $cfg = Get-DisplayConfig
        if ($useRes) { $cfg = $cfg | Set-DisplayResolution -DisplayId $id -Width $w -Height $h }
        if ($hz -gt 0) { $cfg = $cfg | Set-DisplayRefreshRate -DisplayId $id -RefreshRate $hz }
        if ($useRes -and $isRetro) {
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
