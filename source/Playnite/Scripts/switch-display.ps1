# ============================================================
#  switch-display.ps1  (lance par Playnite, silencieux)
#
#  -Action Switch  : active l'ecran -DisplayId (sinon -DisplayName), eteint les autres, applique
#                    resolution / frequence si fournies (> 0), le met principal
#                    et bascule le son dessus. Une photo de l'etat precedent
#                    est ecrite dans -SnapshotFile.
#  -Action Restore : remet l'etat decrit par -SnapshotFile.
#
#  Le nom de l'ecran vient de screens.json (genere par Playnite).
#  L'echelle d'affichage n'est jamais modifiee.
#  Prerequis : modules DisplayConfig et AudioDeviceCmdlets.
#  Codes de sortie : 0 ok, 1 module DisplayConfig absent, 2 ecran introuvable.
# ============================================================
param(
    [Parameter(Mandatory = $true)][ValidateSet('Switch', 'Restore')][string]$Action,
    [string]$DisplayName = '',
    [int]$DisplayId = 0,
    [int]$Width = 0,
    [int]$Height = 0,
    [int]$Hz = 0,
    [Parameter(Mandatory = $true)][string]$SnapshotFile
)

$AudioSnapshotFile = "$SnapshotFile.audio"
$LogFile = Join-Path (Split-Path -Parent $SnapshotFile) 'switch-display.log'

function Write-Log([string]$msg) {
    try { Add-Content -Path $LogFile -Value ('{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Action, $msg) } catch { }
}

function Write-State([string]$title) {
    try {
        $t = Get-DisplayInfo | Format-Table DisplayId, DisplayName, Active, Primary, Mode -AutoSize | Out-String -Width 200
        Write-Log "$title`r`n$t"
    } catch { Write-Log "$title : etat illisible ($($_.Exception.Message))" }
}

# Execute un bloc, retourne $true / $false selon la reussite (les erreurs sont journalisees)
function Step([scriptblock]$code) {
    $Error.Clear()
    try   { & $code | Out-Null }
    catch { Write-Log "Echec: $($_.Exception.Message) :: $($code.ToString().Trim())"; return $false }
    if ($Error.Count -gt 0) { Write-Log "Erreur non bloquante: $($Error[0]) :: $($code.ToString().Trim())" }
    return $true
}

function Find-Display([string]$name) {
    $pattern = [regex]::Escape($name)
    Get-DisplayInfo | Where-Object { $_.DisplayName -match $pattern -and $_.DisplayName -notmatch 'Default' } | Select-Object -First 1
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
    if ($cur) {
        $m = Read-Mode $cur.Mode
        $resOk = (-not $useRes) -or ($m.Width -eq $w -and $m.Height -eq $h)
        $hzOk = ($hz -le 0) -or ([math]::Abs($m.Hz - $hz) -lt 1)
        if ($resOk -and $hzOk) { return }
    }

    Step {
        $cfg = Get-DisplayConfig
        if ($useRes) { $cfg = $cfg | Set-DisplayResolution -DisplayId $id -Width $w -Height $h }
        if ($hz -gt 0) { $cfg = $cfg | Set-DisplayRefreshRate -DisplayId $id -RefreshRate $hz }
        $cfg | Use-DisplayConfig
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
Write-Log "Demarrage: DisplayName='$DisplayName' ${Width}x${Height} @ $Hz Hz, snapshot=$SnapshotFile (existe: $(Test-Path $SnapshotFile))"
try { Import-Module DisplayConfig -ErrorAction Stop } catch { Write-Log "Module DisplayConfig absent: $($_.Exception.Message)"; exit 1 }
$haveAudio = $true
try { Import-Module AudioDeviceCmdlets -ErrorAction Stop } catch { $haveAudio = $false }

# ============================================================
#  Restore
# ============================================================
if ($Action -eq 'Restore') {
    Write-State 'Etat avant restauration'
    if (Test-Path $SnapshotFile) {
        $snap = @(Get-Content -Path $SnapshotFile -Raw | ConvertFrom-Json)
        $wantActive = @($snap | Where-Object { $_.Active })

        foreach ($s in $wantActive) {
            $cur = Find-DisplayById $s.DisplayId
            if ($cur -and -not $cur.Active) {
                Step { Enable-Display -DisplayId $s.DisplayId } | Out-Null
                Start-Sleep -Seconds 2
            }
        }
        foreach ($c in @(Get-DisplayInfo | Where-Object { $_.Active })) {
            if (-not ($wantActive | Where-Object { $_.DisplayId -eq $c.DisplayId })) {
                Step { Disable-Display -DisplayId $c.DisplayId } | Out-Null
            }
        }
        Start-Sleep -Seconds 2

        foreach ($s in $wantActive) { Set-DisplayModeSafe $s.DisplayId $s.Width $s.Height $s.Hz }

        $p = $wantActive | Where-Object { $_.Primary } | Select-Object -First 1
        if ($p) {
            $cur = Find-DisplayById $p.DisplayId
            if ($cur -and -not $cur.Primary) { Step { Set-DisplayPrimary -DisplayId $p.DisplayId } | Out-Null }
        }
        Remove-Item -Path $SnapshotFile -Force -ErrorAction SilentlyContinue
    }
    else { Write-Log 'Aucune photo a restaurer.' }

    if (Test-Path $AudioSnapshotFile) {
        if ($haveAudio) {
            $id = (Get-Content -Path $AudioSnapshotFile -Raw).Trim()
            if ($id) { Step { Set-AudioDevice -ID $id } | Out-Null }
        }
        Remove-Item -Path $AudioSnapshotFile -Force -ErrorAction SilentlyContinue
    }
    Write-State 'Etat apres restauration'
    exit 0
}

# ============================================================
#  Switch
# ============================================================
Write-State 'Etat avant switch'
$target = $null
if ($DisplayId -gt 0) { $target = Find-DisplayById $DisplayId }
if (-not $target) { $target = Find-Display $DisplayName }
if (-not $target) { Write-Log "Ecran introuvable: $DisplayName (id $DisplayId)"; exit 2 }

# Photo de l'etat actuel (ecrans, principal, resolution, frequence, sortie audio)
$snap = @(Get-DisplayInfo | ForEach-Object {
    $m = Read-Mode $_.Mode
    [pscustomobject]@{
        DisplayId = $_.DisplayId
        Active    = [bool]$_.Active
        Primary   = [bool]$_.Primary
        Width     = $m.Width
        Height    = $m.Height
        Hz        = $m.Hz
    }
})
$snap | ConvertTo-Json -Depth 3 | Set-Content -Path $SnapshotFile -Encoding UTF8
if ($haveAudio) {
    try { Set-Content -Path $AudioSnapshotFile -Value (Get-AudioDevice -Playback).ID -Encoding UTF8 } catch { }
}

# 1. Activer la cible ET eteindre un autre ecran en une seule operation (jamais zero ecran actif)
$others = @(Get-DisplayInfo | Where-Object { $_.Active -and $_.DisplayId -ne $target.DisplayId })
$first = $others | Select-Object -First 1
$ok = $true
if ($first) {
    $ok = Step { Enable-Display -DisplayId $target.DisplayId -DisplayIdToDisable $first.DisplayId }
}
elseif (-not $target.Active) {
    $ok = Step { Enable-Display -DisplayId $target.DisplayId }
}
if (-not $ok) {
    Step { Enable-Display -DisplayId $target.DisplayId } | Out-Null
}
Start-Sleep -Seconds 2

# Eteindre ce qui reste actif a part la cible
foreach ($o in @(Get-DisplayInfo | Where-Object { $_.Active -and $_.DisplayId -ne $target.DisplayId })) {
    Step { Disable-Display -DisplayId $o.DisplayId } | Out-Null
}
Start-Sleep -Seconds 2

# 2. Resolution + frequence (seulement si le jeu les definit)
Set-DisplayModeSafe $target.DisplayId $Width $Height $Hz

# 3. Ecran principal
$target = Find-DisplayById $target.DisplayId
if ($target -and -not $target.Primary) {
    Step { Set-DisplayPrimary -DisplayId $target.DisplayId } | Out-Null
}

# 4. Sortie audio (on attend l'apparition du peripherique, 8 s max)
if ($haveAudio) {
    $pattern = [regex]::Escape($DisplayName)
    $deadline = (Get-Date).AddSeconds(8)
    $done = $false
    while ((Get-Date) -lt $deadline -and -not $done) {
        $dev = Get-AudioDevice -List | Where-Object { $_.Type -eq 'Playback' -and $_.Name -match $pattern } | Select-Object -First 1
        if ($dev) {
            Step { Set-AudioDevice -ID $dev.ID } | Out-Null
            $done = $true
        }
        else {
            Start-Sleep -Milliseconds 500
        }
    }
    if (-not $done) { Write-Log "Peripherique audio introuvable pour: $DisplayName" }
}
Write-State 'Etat apres switch'
exit 0
