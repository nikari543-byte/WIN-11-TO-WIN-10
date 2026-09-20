<#
================================================================================
 Patch-Win10Downgrade.ps1  v5.0  (полная ревизия после ревью v4.2)
--------------------------------------------------------------------------------
 ЧТО ИСПРАВЛЕНО ОТНОСИТЕЛЬНО v4.2:
  1. Pre-flight ДО тяжёлых операций: место, pending-reboot, здоровье CBS, язык.
  2. Новая проверка: язык образа vs язык хоста (главная причина серой кнопки).
  3. SHA256-верификация всех копий (USB, бэкап) + манифест целостности .bak.
  4. Идемпотентность повторных запусков: prepatch.bak, версионные *.disabled.*,
     пред-unload verify-куста, уникальные имена кустов (GUID).
  5. Архитектура: нормализация типов (строка/код/enum) перед сравнением.
  6. -WhatIf переименован в -DryRun (Alias 'WhatIf' сохранён для совместимости).
  7. -ContinueOnError: падение одного индекса не гасит остальные; код выхода 2.
  8. DeepVerify монтирует с /ReadOnly.
  9. Stop-Transcript в finally защищён; Get-DriveFree null-safe.
 10. Прогресс длинных операций: DISM (%), копирование (стрим с прогрессом).
 11. Размер SWM-части — параметр -SwmSizeMB; после SWM валидация /Get-WimInfo.
 12. CleanupOnly добивает ВСЁ: кусты (включая залежи прошлых версий), каталоги
     монтирования, с -Force ещё и рабочую папку.
 13. JSON-аудит: logDir\report_*.json — хост, цель, изменения, статус индексов.
--------------------------------------------------------------------------------
 ВАЖНО (это фиксом не лечится — честные ограничения сценария):
  - Setup решает «сохранить ли всё» по compat-сканам; спуф реестра не гарантия.
  - <VERSION> в метаданных WIM остаётся честной (19045), реестр — спуфнут.
  - Миграция состояния Win11 на бинарники Win10 ломает часть UWP/Start/Widgets.
  - До отработки SetupComplete.cmd система числится спуфнутым билдом: сбой
    питания в этом окне = реестр «22631» на файлах «19045». Не выключай ПК.
  - СХОДИ НА VM СО СНАПШОТОМ, прежде чем трогать боевую систему.
--------------------------------------------------------------------------------
 ДЛЯ POWERSHELL 5.1: файл должен быть сохранён в UTF-8 *с BOM*, иначе русские
 строки могут отобразиться криво (кракозябры). В кодировке сомневаешься —
 открой в VSCode и «Save with Encoding -> UTF-8 with BOM».
================================================================================
#>

[CmdletBinding()]
param(
    [string]$WimPath,
    [string]$UsbPath,
    [int[]]$Indexes = @(),

    [ValidateSet('Basic','Full')]
    [string]$SpoofLevel = 'Full',

    [ValidateSet('HostMatch','Newer')]
    [string]$BuildStrategy = 'HostMatch',

    [string]$TargetBuild = '',
    [int]$TargetUbr = -1,

    [string]$WorkDrive = $env:SystemDrive,
    [string]$ScratchDir = '',

    [ValidateSet('Auto','Always','Never')]
    [string]$BackupMode = 'Auto',
    [switch]$NoBackup,

    [ValidateSet('fast','max','none')]
    [string]$Compress = 'fast',

    [switch]$ConvertEsd,
    [switch]$DeepVerify,
    [switch]$NoRestoreScript,

    [Alias('WhatIf')]
    [switch]$DryRun,

    [switch]$PrepUsb,
    [switch]$KeepEsd,
    [switch]$SanitizeUsb,
    [switch]$RenameAppraiser,
    [ValidateRange(500,4050)]
    [int]$SwmSizeMB = 3800,

    [switch]$WriteEiCfg,
    [string]$EiChannel = '',
    [string]$EiEdition = '',

    [int]$MinWin11Build = 22000,
    [switch]$AllowImageWin11,
    [switch]$ContinueOnError,
    [switch]$Force,
    [switch]$CleanupOnly
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'Continue'

if ($NoBackup) { $BackupMode = 'Never' }

# ---------------------------------------------------------------- helpers ----
function W-Step { param([string]$M) Write-Host "==> $M" -ForegroundColor Cyan }
function W-Ok   { param([string]$M) Write-Host "[OK] $M" -ForegroundColor Green }
function W-Warn { param([string]$M) Write-Host "[WARN] $M" -ForegroundColor Yellow }
function W-Die  { param([string]$M) Write-Host "[FAIL] $M" -ForegroundColor Red; exit 1 }

$script:LastToolOut = ''

function Invoke-Tool {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [string[]]$ToolArgs = @(),
        [switch]$AllowFail,
        [string]$Activity
    )

    # Буфер только под «хвост» для ошибки — не копим мегабайты вывода в память.
    $buf = New-Object System.Collections.Generic.List[string]
    $showProg = -not [string]::IsNullOrEmpty($Activity)

    try {
        & $Exe @ToolArgs 2>&1 | ForEach-Object {
            $line = "$_"
            $null = $buf.Add($line)
            if ($buf.Count -gt 40) { $buf.RemoveAt(0) }
            if ($showProg -and $line -match '(\d{1,3})(?:\.\d+)?\s*%') {
                $p = [math]::Min(100, [int]$Matches[1])
                Write-Progress -Activity $Activity -Status "$p%" -PercentComplete $p
            }
        }
    } finally {
        if ($showProg) { Write-Progress -Activity $Activity -Completed }
    }

    $code = $LASTEXITCODE
    $script:LastToolOut = ($buf | Where-Object { $_.Trim() }) -join "`n"

    if ($code -ne 0 -and -not $AllowFail) {
        $tail = ($buf | Where-Object { $_.Trim() } | Select-Object -Last 14) -join "`n"
        throw "$Exe завершился с кодом $code. Вывод:`n$tail"
    }
    return $code
}

function Copy-FileWithProgress {
    param(
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$To,
        [string]$Activity = 'Копирование файла'
    )
    $src = [IO.File]::OpenRead($From)
    try {
        $dst = [IO.File]::Create($To)
        try {
            $chunk = New-Object byte[] (8MB)
            $total = [double]$src.Length
            $copied = 0L
            $sw = [Diagnostics.Stopwatch]::StartNew()
            while (($n = $src.Read($chunk, 0, $chunk.Length)) -gt 0) {
                $dst.Write($chunk, 0, $n)
                $copied += $n
                if ($sw.ElapsedMilliseconds -ge 400) {
                    $pct = [int][math]::Min(100, ($copied * 100.0) / $total)
                    Write-Progress -Activity $Activity -PercentComplete $pct `
                        -Status ("{0:N0} / {1:N0} МБ" -f ($copied/1MB), ($total/1MB))
                    $sw.Restart()
                }
            }
        } finally { $dst.Dispose() }
    } finally {
        $src.Dispose()
        Write-Progress -Activity $Activity -Completed
    }
}

function Test-Writable {
    # 3 попытки: антивирус может держать файл мгновение; Share=None при залочке
    # не должен превращаться в лишнюю копию на 6+ ГБ без повторной попытки.
    param([string]$P)
    foreach ($i in 1..3) {
        try {
            $fs = [IO.File]::Open($P, 'Open', 'ReadWrite', 'None')
            $fs.Close()
            return $true
        } catch [IO.IOException] {
            Start-Sleep -Milliseconds 800
        } catch {
            return $false   # UnauthorizedAccess и т.п. — точно не запишешь
        }
    }
    return $false
}

function Get-FsType {
    param([string]$P)
    $q = Split-Path -Qualifier $P
    if (-not $q) { return $null }
    $d = $q.TrimEnd(':')
    return (Get-Volume -DriveLetter $d -ErrorAction SilentlyContinue).FileSystem
}

function Get-DriveFree {
    param([string]$P)
    $q = Split-Path -Qualifier $P
    if (-not $q) { return $null }
    $d = $q.TrimEnd(':')
    return (Get-Volume -DriveLetter $d -ErrorAction SilentlyContinue).Free
}

function Unload-Hive {
    param([string]$Hive)
    foreach ($i in 1..6) {
        $code = Invoke-Tool reg.exe @('unload', $Hive) -AllowFail
        if ($code -eq 0) { return $true }
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        Start-Sleep -Seconds 2
    }
    return $false
}

function Invoke-DismCleanup {
    Invoke-Tool dism.exe @('/Cleanup-Mountpoints') -AllowFail | Out-Null
    Invoke-Tool dism.exe @('/Cleanup-Wim') -AllowFail | Out-Null
}

function Get-LocalVolumes {
    Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -match 'Fixed|Removable' }
}

function Get-HostArchCode {
    switch ($env:PROCESSOR_ARCHITECTURE) {
        'AMD64' { return 9 }
        'x86'   { return 0 }
        'ARM64' { return 12 }
        default { return -1 }
    }
}

function Get-NormArch {
    # FIXED: типы у сторон разные (int 9/0/12 у нас, enum/строка у Get-WindowsImage).
    param($A)
    $s = ("$A").Trim().ToLower()
    if ($s -match 'amd64|x64|^9$')      { return 'amd64' }
    if ($s -match 'arm64|^12$')         { return 'arm64' }
    if ($s -match 'x86|i386|^0$')       { return 'x86'   }
    return $s
}

function Get-HostLangHex {
    try {
        $v = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\Language' `
              -ErrorAction Stop).InstallLanguage
        if ($v) { return "$v".Trim().ToUpper() }
    } catch {}
    try { return ([Globalization.CultureInfo]::InstalledUICulture.LCID).ToString('X4') }
    catch { return $null }
}

function Get-ImageLangInfo {
    # Возвращает @{ Hex='0419'; Name='ru-RU' } по первым данным Get-WindowsImage.
    param($ImgInfo)
    $langs = @($ImgInfo.Languages) | Where-Object { $_ }
    if (-not $langs.Count) { return $null }
    $def = $langs | Where-Object { "$_" -match 'Default' } | Select-Object -First 1
    if (-not $def) { $def = $langs[0] }
    $m = [regex]::Match("$def", '([a-zA-Z]{2,3}(?:-[a-zA-Z]{2,4})?)')
    if (-not $m.Success) { return $null }
    $name = $m.Groups[1].Value
    try {
        $hex = ([Globalization.CultureInfo]::GetCultureInfo($name).LCID).ToString('X4')
        return @{ Hex = $hex; Name = $name }
    } catch { return $null }
}

function Test-PendingReboot {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($p in $paths) { if (Test-Path $p) { return $true } }
    return $false
}

function Disable-FileIfExist {
    # FIXED: больше не уничтожает предыдущий .disabled — версионируем суффиксом.
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $n = 1
    do { $disabled = "$Path.disabled.$n"; $n++ } while (Test-Path -LiteralPath $disabled)
    Move-Item -LiteralPath $Path -Destination $disabled -Force
    W-Ok "Отключён: $Path -> $disabled"
}

function Remove-SwmArtifacts {
    param([string]$Dir)
    # Сносим и текущие части, и .disabled-остатки (любой версии прошлых прогонов).
    foreach ($pattern in @('install*.swm', 'install*.swm.disabled*')) {
        Get-ChildItem -LiteralPath $Dir -Filter $pattern -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop
                W-Ok "Удалён артефакт: $($_.FullName)"
            } catch {
                W-Warn "Не удалось удалить $($_.FullName): $($_.Exception.Message)"
            }
        }
    }
}

function Save-BackupManifest {
    param([string]$BakPath,[string]$Hash)
    $manifest = "$BakPath.sha256"
    "{0}  {1}" -f $Hash, (Split-Path -Leaf $BakPath) | Set-Content -LiteralPath $manifest -Encoding ASCII
}

function Test-BackupValid {
    # FIXED: «бэкап существует» != «бэкап цел». Проверяем манифест + хэш.
    param([string]$BakPath,[long]$SrcLength)
    $manifest = "$BakPath.sha256"
    if (-not (Test-Path -LiteralPath $BakPath)) { return $false }
    if ((Get-Item -LiteralPath $BakPath).Length -ne $SrcLength) { return $false }
    if (-not (Test-Path -LiteralPath $manifest)) { return $false }
    $expect = ((Get-Content -LiteralPath $manifest -Raw) -split '\s+')[0]
    if (-not $expect) { return $false }
    W-Step 'Бэкап уже есть — проверяю целостность по манифесту...'
    $actual = (Get-FileHash -LiteralPath $BakPath -Algorithm SHA256).Hash
    return ($actual -eq $expect)
}

# ---------------------------------------------------------------- preflight --
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    W-Die 'Нужен запуск от имени администратора.'
}

W-Warn 'ОГРАНИЧЕНИЯ СЦЕНАРИЯ (фиксом не лечатся):'
W-Warn ' 1) Setup может не принять спуф — кнопка «Сохранить всё» останется серой.'
W-Warn ' 2) Метаданные WIM честнее реестра: VERSION внутри WIM не патчится.'
W-Warn ' 3) Миграция 11->10 ломает часть UWP/Start/Widgets из природы вещей.'
W-Warn ' 4) До SetupComplete.cmd система «числится» спуфнутой — не выключай ПК.'
W-Warn 'Сначала проверь весь пайплайн на VM со снапшотом.'
W-Warn 'Сторонние антивирусы могут блокировать reg unload — при ошибке выгрузки'
W-Warn 'куста отключи АВ или перезагрузись и запусти с -CleanupOnly.'
Write-Host ''

# --- Лог ---
$logDir = Join-Path $env:TEMP 'Win10Downgrade'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir ("patch_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
try { Start-Transcript -Path $logFile -Force | Out-Null } catch { W-Warn "Не удалось начать лог: $($_.Exception.Message)" }

$script:Results = New-Object System.Collections.Generic.List[object]

# ------------------------- Глобальный try/finally ----------------------------
try {

    # --- CleanupOnly: добиваем ВСЁ (FIXED) ---
    if ($CleanupOnly) {
        W-Step 'Чищу зомби-монтирования DISM...'
        Invoke-DismCleanup

        W-Step 'Выгружаю кусты реестра, оставшиеся от прошлых прогонов...'
        Get-ChildItem 'HKLM:\' | Where-Object {
            $_.PSChildName -match '^(WimPatch|WimVerify)'
        } | ForEach-Object {
            if (Unload-Hive ("HKLM\" + $_.PSChildName)) { W-Ok "Выгружен куст: $($_.PSChildName)" }
        }

        W-Step 'Удаляю каталоги монтирования (M_*/V_*)...'
        foreach ($base in @($WorkDrive, $env:SystemDrive) | Select-Object -Unique) {
            $root = $base.TrimEnd('\') + '\'
            Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^[MV]_\w+_[0-9a-f]{6}$' } |
                ForEach-Object {
                    Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                    W-Ok "Удалён каталог: $($_.FullName)"
                }
        }

        if ($Force) {
            $wr = Join-Path $WorkDrive 'Win10DowngradeWork'
            if (Test-Path -LiteralPath $wr) {
                Remove-Item -LiteralPath $wr -Recurse -Force -ErrorAction SilentlyContinue
                W-Ok "Рабочая папка удалена: $wr"
            }
        } else {
            Write-Host "Подсказка: рабочая папка '$WorkDrive\Win10DowngradeWork' не тронута."
            Write-Host 'Добавь -Force к -CleanupOnly, чтобы и её снести.'
        }

        W-Ok 'Очистка завершена. Если проблема осталась — перезагрузи ПК и повтори.'
        exit 0
    }

    foreach ($t in @('dism.exe','reg.exe')) {
        if (-not (Get-Command $t -ErrorAction SilentlyContinue)) { W-Die "Не найден $t." }
    }

    # --- Pending reboot (FIXED: до тяжёлых операций) ---
    if (Test-PendingReboot) {
        W-Warn 'Обнаружен ожидающий перезагрузки сервисинг (CBS/WindowsUpdate).'
        if (-not $Force) { W-Die 'Перезагрузи ПК и повтори. Либо -Force на свой риск.' }
    }

    # --- Здоровье хранилища компонентов хоста (мягкая проверка) ---
    Invoke-Tool dism.exe @('/Online','/Cleanup-Image','/CheckHealth') -AllowFail | Out-Null
    if ($script:LastToolOut -match 'repairable') {
        W-Warn 'CBS хоста помечен как требующий восстановления (repairable).'
        W-Warn 'Рекомендуется: dism /Online /Cleanup-Image /RestoreHealth, потом продолжить.'
    }

    # --- Инфо о хосте ---
    $cvPath  = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $hostCv  = Get-ItemProperty -LiteralPath $cvPath
    $hostBuild = [int]$hostCv.CurrentBuild
    $hostUbr   = if ($hostCv.UBR) { [int]$hostCv.UBR } else { 0 }
    $hostArch  = Get-NormArch (Get-HostArchCode)
    $hostLangHex = Get-HostLangHex

    if ($hostBuild -lt $MinWin11Build) {
        W-Warn "Хост имеет билд $hostBuild. Это не похоже на Windows 11."
        if (-not $Force) { W-Die 'Если всё равно хочешь продолжить — используй -Force.' }
    }

    W-Step "Хост: билд $hostBuild, UBR $hostUbr, $($hostCv.ProductName), $($hostCv.EditionID), $($hostCv.DisplayVersion), lang=$hostLangHex"

    # --- Поиск образа ---
    if (-not $WimPath) {
        $candidates = @()
        foreach ($vol in Get-LocalVolumes) {
            foreach ($name in @('install.wim','install.esd','install.swm')) {
                $p = "{0}:\sources\{1}" -f $vol.DriveLetter, $name
                if (Test-Path -LiteralPath $p) { $candidates += $p }
            }
        }
        if ($candidates.Count -eq 1)      { $WimPath = $candidates[0]; W-Step "Найден образ: $WimPath" }
        elseif ($candidates.Count -gt 1)  { W-Die "Найдено несколько образов: $($candidates -join '; '). Укажи -WimPath явно." }
        else                              { W-Die 'Автоматически не найден install.wim/install.esd/install.swm. Укажи -WimPath.' }
    }

    try { $WimPath = (Resolve-Path -LiteralPath $WimPath).Path } catch { W-Die 'Не удалось найти указанный образ.' }
    if (-not (Test-Path -LiteralPath $WimPath)) { W-Die 'Файл образа не существует.' }

    if ($WimPath -match '\.(esd|swm)$' -and $DryRun) {
        W-Die 'DryRun для ESD/SWM не работает напрямую: сначала конвертируй в WIM без -DryRun.'
    }

    $workRoot = Join-Path $WorkDrive 'Win10DowngradeWork'
    New-Item -ItemType Directory -Force -Path $workRoot | Out-Null

    if ($ScratchDir) {
        if (-not (Test-Path -LiteralPath $ScratchDir)) { W-Die 'Каталог -ScratchDir не существует.' }
        if (-not (Test-Writable (Join-Path $ScratchDir ([guid]::NewGuid().ToString('N') + '.tmp')))) {
            # файла может не быть — проверим через создание
            try { New-Item -ItemType File -Path (Join-Path $ScratchDir '.wtest') -Force | Out-Null; Remove-Item (Join-Path $ScratchDir '.wtest') -Force } catch { W-Die 'ScratchDir недоступен на запись.' }
        } else {
            Remove-Item (Join-Path $ScratchDir '*.tmp') -Force -ErrorAction SilentlyContinue
        }
    }

    # --- ОЦЕНКА МЕСТА ДО ТЯЖЁЛЫХ ОПЕРАЦИЙ (FIXED) ---
    $srcLen0 = (Get-Item -LiteralPath $WimPath).Length
    if ($WimPath -match '\.(esd|swm)$' -and $ConvertEsd) {
        # Экспорт fast/max раздувает ESD примерно в 2.5–3.5 раза; берём с запасом.
        $estNeed = [long]($srcLen0 * 3.5) + 12GB
        $free0 = Get-DriveFree $workRoot
        if ($null -ne $free0 -and $free0 -lt $estNeed) {
            W-Die ("Мало места для экспорта: надо ~{0:N1} ГБ, свободно {1:N1} ГБ." -f ($estNeed/1GB), ($free0/1GB))
        }
    }

    # --- Конвертация ESD/SWM в WIM ---
    if ($WimPath -match '\.(esd|swm)$') {
        if (-not $ConvertEsd) { W-Die 'Образ в ESD/SWM. Добавь -ConvertEsd, чтобы экспортировать его в install.wim.' }

        $newWim = Join-Path $workRoot 'install.wim'
        if (Test-Path -LiteralPath $newWim) { Remove-Item -LiteralPath $newWim -Force }
        $srcImages = Get-WindowsImage -ImagePath $WimPath
        W-Step "Экспортирую $($srcImages.Count) образов в $newWim..."

        foreach ($im in $srcImages) {
            Invoke-Tool dism.exe @(
                '/Export-Image',
                "/SourceImageFile:$WimPath",
                ("/SourceIndex:{0}" -f $im.ImageIndex),
                "/DestinationImageFile:$newWim",
                "/Compress:$Compress"
            ) -Activity ("Экспорт индекса {0}" -f $im.ImageIndex) | Out-Null
        }
        $WimPath = $newWim
        W-Ok 'Экспорт завершён.'
    }

    # --- Read-only / занят файл (FIXED: ретраи, снятие атрибута) ---
    $wimItem = Get-Item -LiteralPath $WimPath -Force
    if ($wimItem.IsReadOnly) {
        try { $wimItem.IsReadOnly = $false; W-Ok 'Снят атрибут «только чтение».' }
        catch { W-Warn 'Не удалось снять атрибут «только чтение».' }
    }
    if (-not (Test-Writable $WimPath)) {
        W-Warn 'Файл образа недоступен на запись (read-only носитель или занят). Копирую в рабочую папку.'
        $copyPath = Join-Path $workRoot 'install.wim'
        Copy-FileWithProgress -From $WimPath -To $copyPath -Activity 'Копия образа в рабочую папку'
        $WimPath = $copyPath
    }

    # --- Проверка носителя и места ---
    $wimLen = (Get-Item -LiteralPath $WimPath).Length
    foreach ($p in @($WimPath, $workRoot)) {
        if ((Get-FsType $p) -eq 'FAT32' -and $wimLen -gt 4GB) {
            W-Die "Файл больше 4 ГБ, а $p находится на FAT32. NTFS/exFAT или SWM на USB."
        }
    }

    $workFree = Get-DriveFree $workRoot
    $needNoBackup   = $wimLen + 12GB
    $needWithBackup = ($wimLen * 2) + 12GB
    $doBackup = $false

    switch ($BackupMode) {
        'Always' {
            # FIXED: null-safe — UNC вернёт null, и это не «0 байт свободно».
            if ($null -ne $workFree -and $workFree -lt $needWithBackup) { W-Die 'Для BackupMode=Always недостаточно места.' }
            if ($null -eq $workFree) { W-Warn 'Не смог измерить свободное место (UNC?). Осторожнее.' }
            $doBackup = $true
        }
        'Auto' {
            if ($null -ne $workFree -and $workFree -ge $needWithBackup) { $doBackup = $true }
            elseif ($null -ne $workFree -and $workFree -lt $needNoBackup) { W-Die 'Совсем мало места даже без бэкапа.' }
            else { W-Warn 'Места для полной копии мало (или неизвестно). Продолжаю без бэкапа.' }
        }
        'Never' { $doBackup = $false }
    }

    # --- Бэкап с верификацией (FIXED) ---
    if ($doBackup -and -not $DryRun) {
        $bak = "$WimPath.bak"
        if (Test-BackupValid -BakPath $bak -SrcLength $wimLen) {
            W-Ok 'Бэкап уже существует и прошёл проверку манифеста.'
        } else {
            if (Test-Path -LiteralPath $bak) { W-Warn 'Старый бэкап не прошёл проверку — пересоздаю.'; Remove-Item -LiteralPath $bak -Force }
            W-Step 'Создаю резервную копию образа...'
            Copy-FileWithProgress -From $WimPath -To $bak -Activity 'Резервная копия'
            $srcHash = (Get-FileHash -LiteralPath $WimPath -Algorithm SHA256).Hash
            $bakHash = (Get-FileHash -LiteralPath $bak    -Algorithm SHA256).Hash
            if ($srcHash -ne $bakHash) { W-Die 'Бэкап не совпал по SHA256 с источником. Носитель барахлит — остановка.' }
            Save-BackupManifest -BakPath $bak -Hash $bakHash
            W-Ok "Бэкап создан и верифицирован: $bak"
            Write-Host "SHA256: $bakHash (манифест: $bak.sha256)"
        }
    }

    # --- Список индексов ---
    $images = Get-WindowsImage -ImagePath $WimPath
    if ($Indexes.Count -eq 0) { $Indexes = @($images.ImageIndex) }

    foreach ($idx in $Indexes) {
        if (-not ($images.ImageIndex -contains $idx)) { W-Die "Индекс $idx не найден в образе." }
    }

    # --- Валидация EiEdition по фактическим изданиям образа (FIXED) ---
    if ($WriteEiCfg -and $EiEdition) {
        $realEditions = @($images | ForEach-Object { "$($_.EditionID)" } | Where-Object { $_ } | Select-Object -Unique)
        if ($realEditions.Count -and ($realEditions -notcontains $EiEdition)) {
            W-Die "EiEdition '$EiEdition' нет в образе. Доступные: $($realEditions -join ', ')."
        }
    }

    # --- Целевой билд ---
    if ($TargetBuild) { $tBuild = [int]$TargetBuild }
    else { $tBuild = $(if ($BuildStrategy -eq 'HostMatch') { $hostBuild } else { $hostBuild + 1 }) }

    if ($TargetUbr -ge 0) { $tUbr = [int]$TargetUbr }
    else { $tUbr = $(if ($BuildStrategy -eq 'HostMatch') { $hostUbr } else { 0 }) }

    if ($tBuild -lt $hostBuild -and -not $Force) {
        W-Die 'Целевой билд ниже текущего хоста. Для сохранения данных это недопустимо.'
    }

    W-Step "Стратегия: $BuildStrategy. Целевой билд: $tBuild, UBR: $tUbr, SpoofLevel: $SpoofLevel."

    # --- Основной цикл патча ---
    foreach ($idx in $Indexes) {
        W-Step "=== Обработка индекса $idx ==="

        $imgInfo = $images | Where-Object { $_.ImageIndex -eq $idx } | Select-Object -First 1

        # FIXED: нормализованное сравнение типов архитектур.
        if ($imgInfo) {
            $imgArch = Get-NormArch $imgInfo.Architecture
            if ($hostArch -and $imgArch -and $imgArch -ne $hostArch) {
                $msg = "Архитектура образа ($imgArch) не совпадает с хостом ($hostArch)."
                if ($ContinueOnError) { $Results.Add([pscustomobject]@{Index=$idx;Status='FAIL';Error=$msg}); W-Warn "$msg Продолжаю."; continue }
                W-Die $msg
            }
        }

        $shortGuid = [guid]::NewGuid().ToString('N').Substring(0, 6)
        $mount = Join-Path $WorkDrive ("M_{0}_{1}" -f $idx, $shortGuid)
        New-Item -ItemType Directory -Force -Path $mount | Out-Null

        # FIXED: уникальные имена кустов — параллельные прогоны не конфликтуют.
        $hiveId = $shortGuid
        $hive   = "HKLM\WimPatch_$hiveId"
        $hivePs = "HKLM:\WimPatch_$hiveId"
        $mounted = $false; $hiveLoaded = $false
        $changes = [ordered]@{}

        $mountArgs = if ($ScratchDir) { @("/ScratchDir:$ScratchDir") } else { @() }

        try {
            Invoke-Tool dism.exe (@(
                '/Mount-Wim',
                "/WimFile:$WimPath",
                "/Index:$idx",
                "/MountDir:$mount"
            ) + $mountArgs) | Out-Null
            $mounted = $true

            $imgNt = Join-Path $mount 'Windows\System32\ntoskrnl.exe'
            if (Test-Path -LiteralPath $imgNt) {
                $imgNtVer  = (Get-Item -LiteralPath $imgNt).VersionInfo.FileVersion
                $hostNtVer = (Get-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\ntoskrnl.exe')).VersionInfo.FileVersion
                if ($imgNtVer -ne $hostNtVer) {
                    W-Warn "Версия ядра образа отличается: $imgNtVer против хостовой $hostNtVer."
                    W-Warn 'Если Setup проверяет не только реестр, но и версии файлов, спуф может не помочь.'
                }
            }

            $softHive = Join-Path $mount 'Windows\System32\config\SOFTWARE'
            if (-not (Test-Path -LiteralPath $softHive)) { throw 'В образе отсутствует куст SOFTWARE.' }

            Invoke-Tool reg.exe @('unload', $hive) -AllowFail | Out-Null
            Invoke-Tool reg.exe @('load', $hive, $softHive) | Out-Null
            $hiveLoaded = $true

            $key   = "$hive\Microsoft\Windows NT\CurrentVersion"
            $keyPs = "$hivePs\Microsoft\Windows NT\CurrentVersion"
            $o = Get-ItemProperty -LiteralPath $keyPs
            $origBuild = [int]$o.CurrentBuild

            if ($hostBuild -ge $MinWin11Build -and $origBuild -lt $MinWin11Build -and -not $Force) {
                throw "Попытка даунгрейда 11 -> 10 (образ < $MinWin11Build). Добавь -Force, если это осознанный неподдерживаемый сценарий."
            }
            if ($origBuild -ge $MinWin11Build -and -not $AllowImageWin11) {
                throw "Образ уже похож на Windows 11. Патч не нужен. Используй -AllowImageWin11, если понимаешь зачем."
            }
            if ($o.EditionID -ne $hostCv.EditionID -and -not $Force) {
                throw "EditionID образа '$($o.EditionID)' != EditionID хоста '$($hostCv.EditionID)'. Кнопка сохранения будет серой."
            }
            if ($o.InstallationType -ne 'Client') {
                throw "InstallationType = '$($o.InstallationType)', ожидался Client."
            }
            if ($o.CurrentVersion -ne '6.3') {
                W-Warn "CurrentVersion = '$($o.CurrentVersion)', ожидалась 6.3."
            }
            if ($hostCv.CompositionEditionID -and $o.CompositionEditionID -and $o.CompositionEditionID -ne $hostCv.CompositionEditionID) {
                W-Warn "CompositionEditionID отличается: $($o.CompositionEditionID) против $($hostCv.CompositionEditionID)."
            }

            # FIXED: НОВАЯ проверка языка — типовая причина серой кнопки.
            if ($imgInfo) {
                $il = Get-ImageLangInfo $imgInfo
                if ($il -and $hostLangHex -and ($il.Hex -ne $hostLangHex)) {
                    $msg = "Язык образа ($($il.Name)/$($il.Hex)) != языка хоста ($hostLangHex). «Сохранить всё» будет недоступно."
                    if (-not $Force) { throw $msg } else { W-Warn $msg }
                } elseif (-not $il) {
                    W-Warn 'Не удалось определить язык образа из метаданных — проверь вручную.'
                } else {
                    W-Ok "Язык совпадает: $($il.Name)."
                }
            }

            $changes['CurrentBuild']       = @{ T = 'REG_SZ';    V = "$tBuild"; O = $o.CurrentBuild }
            $changes['CurrentBuildNumber'] = @{ T = 'REG_SZ';    V = "$tBuild"; O = $o.CurrentBuildNumber }
            $changes['UBR']                = @{ T = 'REG_DWORD'; V = "$tUbr";   O = $o.UBR }

            if ($SpoofLevel -eq 'Full') {
                if ($BuildStrategy -eq 'HostMatch') {
                    if ($hostCv.BuildLab)       { $changes['BuildLab']       = @{ T='REG_SZ'; V=$hostCv.BuildLab;       O=$o.BuildLab } }
                    if ($hostCv.BuildLabEx)     { $changes['BuildLabEx']     = @{ T='REG_SZ'; V=$hostCv.BuildLabEx;     O=$o.BuildLabEx } }
                    if ($hostCv.BuildBranch)    { $changes['BuildBranch']    = @{ T='REG_SZ'; V=$hostCv.BuildBranch;    O=$o.BuildBranch } }
                    if ($hostCv.DisplayVersion) { $changes['DisplayVersion'] = @{ T='REG_SZ'; V=$hostCv.DisplayVersion; O=$o.DisplayVersion } }
                    if ($hostCv.ProductName)    { $changes['ProductName']    = @{ T='REG_SZ'; V=$hostCv.ProductName;    O=$o.ProductName } }
                    if ($hostCv.ReleaseId)      { $changes['ReleaseId']      = @{ T='REG_SZ'; V=$hostCv.ReleaseId;      O=$o.ReleaseId } }
                } else {
                    if ($o.BuildLab)   { $changes['BuildLab']   = @{ T='REG_SZ'; V=($o.BuildLab   -replace '^\d+',          "$tBuild");                 O=$o.BuildLab } }
                    if ($o.BuildLabEx) { $changes['BuildLabEx'] = @{ T='REG_SZ'; V=($o.BuildLabEx -replace '^\d+\.\d+',     ("{0}.{1}" -f $tBuild,$tUbr)); O=$o.BuildLabEx } }
                    if ($hostCv.BuildBranch)    { $changes['BuildBranch']    = @{ T='REG_SZ'; V=$hostCv.BuildBranch;    O=$o.BuildBranch } }
                    if ($hostCv.DisplayVersion) { $changes['DisplayVersion'] = @{ T='REG_SZ'; V=$hostCv.DisplayVersion; O=$o.DisplayVersion } }
                    if ($hostCv.ProductName)    { $changes['ProductName']    = @{ T='REG_SZ'; V=$hostCv.ProductName;    O=$o.ProductName } }
                    if ($hostCv.ReleaseId)      { $changes['ReleaseId']      = @{ T='REG_SZ'; V=$hostCv.ReleaseId;      O=$o.ReleaseId } }
                }
            }

            if ($DryRun) {
                W-Warn 'DryRun: изменения не применяются.'
                foreach ($k in $changes.Keys) { Write-Host ("  {0}: '{1}' -> '{2}'" -f $k, $changes[$k].O, $changes[$k].V) }
            } else {
                foreach ($k in $changes.Keys) {
                    Invoke-Tool reg.exe @('add', $key, '/v', $k, '/t', $changes[$k].T, '/d', "$($changes[$k].V)", '/f') | Out-Null
                }

                $r = Get-ItemProperty -LiteralPath $keyPs
                $bad = @(); foreach ($k in $changes.Keys) { if ("$($r.$k)" -ne "$($changes[$k].V)") { $bad += $k } }
                if ($bad.Count) { throw "Не сошлась верификация до коммита: $($bad -join ', ')." }
                W-Ok "Индекс ${idx}: значения записаны и проверены до коммита."

                if (-not $NoRestoreScript) {
                    $scDir = Join-Path $mount 'Windows\Setup\Scripts'
                    New-Item -ItemType Directory -Force -Path $scDir | Out-Null
                    $sc   = Join-Path $scDir 'SetupComplete.cmd'
                    $orig = Join-Path $scDir 'SetupComplete.cmd.downgrade_orig'

                    if (Test-Path -LiteralPath $sc) {
                        if (-not (Test-Path -LiteralPath $orig)) { Move-Item -LiteralPath $sc -Destination $orig -Force }
                        else { Remove-Item -LiteralPath $sc -Force }
                    }

                    $lines = @('@echo off', 'rem Downgrade identity restore wrapper (v5)')
                    foreach ($k in $changes.Keys) {
                        if ($null -ne $changes[$k].O) {
                            $lines += ('reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v {0} /t {1} /d "{2}" /f' -f $k, $changes[$k].T, $changes[$k].O)
                        } else {
                            $lines += ('reg delete "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v {0} /f' -f $k)
                        }
                    }
                    if (Test-Path -LiteralPath $orig) {
                        $lines += 'if exist "%~dp0SetupComplete.cmd.downgrade_orig" call "%~dp0SetupComplete.cmd.downgrade_orig"'
                    }
                    $lines += 'del /f /q "%~f0"'
                    Set-Content -LiteralPath $sc -Value $lines -Encoding ASCII
                    W-Ok "Индекс ${idx}: SetupComplete-восстановление добавлено."
                }
            }

            [GC]::Collect(); [GC]::WaitForPendingFinalizers(); Start-Sleep -Seconds 2

            if (-not (Unload-Hive $hive)) {
                throw 'Не удалось выгрузить куст реестра. Перезагрузи ПК и запусти с -CleanupOnly.'
            }
            $hiveLoaded = $false

            if ($DryRun) {
                Invoke-Tool dism.exe @('/Unmount-Wim', "/MountDir:$mount", '/Discard') | Out-Null
            } else {
                Invoke-Tool dism.exe @('/Unmount-Wim', "/MountDir:$mount", '/Commit') | Out-Null
                W-Ok "Индекс ${idx}: изменения сохранены."
            }
            $mounted = $false

            if ($DeepVerify -and -not $DryRun) {
                $shortGuid2 = [guid]::NewGuid().ToString('N').Substring(0, 6)
                $vdir = Join-Path $WorkDrive ("V_{0}_{1}" -f $idx, $shortGuid2)
                New-Item -ItemType Directory -Force -Path $vdir | Out-Null

                # FIXED: /ReadOnly + уникальное имя + пред-unload.
                $vHive   = "HKLM\WimVerify_$shortGuid2"
                $vHivePs = "HKLM:\WimVerify_$shortGuid2"
                $vMounted = $false; $vLoaded = $false
                try {
                    Invoke-Tool dism.exe (@(
                        '/Mount-Wim', "/WimFile:$WimPath", "/Index:$idx",
                        "/MountDir:$vdir", '/ReadOnly'
                    ) + $mountArgs) -Activity "DeepVerify: монтирование $idx" | Out-Null
                    $vMounted = $true

                    Invoke-Tool reg.exe @('unload', $vHive) -AllowFail | Out-Null
                    Invoke-Tool reg.exe @('load', $vHive, (Join-Path $vdir 'Windows\System32\config\SOFTWARE')) | Out-Null
                    $vLoaded = $true

                    $r2 = Get-ItemProperty -LiteralPath "$vHivePs\Microsoft\Windows NT\CurrentVersion"
                    $bad2 = @(); foreach ($k in $changes.Keys) { if ("$($r2.$k)" -ne "$($changes[$k].V)") { $bad2 += $k } }
                    if ($bad2.Count) { W-Warn "DeepVerify: после коммита не совпало: $($bad2 -join ', ')." }
                    else             { W-Ok  "DeepVerify: индекс $idx проверен после коммита." }
                }
                finally {
                    if ($vLoaded)  { [GC]::Collect(); [GC]::WaitForPendingFinalizers(); Unload-Hive $vHive | Out-Null }
                    if ($vMounted) { Invoke-Tool dism.exe @('/Unmount-Wim', "/MountDir:$vdir", '/Discard') -AllowFail | Out-Null }
                    if (Test-Path -LiteralPath $vdir) {
                        Invoke-DismCleanup
                        Remove-Item -LiteralPath $vdir -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }
            }

            if ($DryRun) { $Results.Add([pscustomobject]@{Index=$idx; Status='DRYRUN'; Error=''}) }
            else         { $Results.Add([pscustomobject]@{Index=$idx; Status='OK';     Error=''}) }
        }
        catch {
            $msg = $_.Exception.Message
            # FIXED: сначала DISM-cleanup, потом снос каталога (правильный порядок).
            if ($hiveLoaded) { [GC]::Collect(); [GC]::WaitForPendingFinalizers(); Unload-Hive $hive | Out-Null }
            if ($mounted)    { Invoke-Tool dism.exe @('/Unmount-Wim', "/MountDir:$mount", '/Discard') -AllowFail | Out-Null }
            Invoke-DismCleanup
            Remove-Item -LiteralPath $mount -Recurse -Force -ErrorAction SilentlyContinue

            if ($ContinueOnError) {
                $Results.Add([pscustomobject]@{Index=$idx; Status='FAIL'; Error=$msg})
                W-Warn "Индекс ${idx}: $msg — продолжаю с остальными."
            } else {
                W-Die "Индекс ${idx}: $msg"
            }
        }
        finally {
            Remove-Item -LiteralPath $mount -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # --- Отчёт по индексам + JSON-аудит (FIXED) ---
    $failCount = (@($Results | Where-Object { $_.Status -eq 'FAIL' })).Count
    Write-Host ''
    W-Step 'Итог по индексам:'
    $Results | Format-Table Index, Status, Error -AutoSize | Out-String | Write-Host

    try {
        $report = [ordered]@{
            Time         = (Get-Date).ToString('s')
            Script       = 'Patch-Win10Downgrade.ps1 v5.0'
            Host         = @{ Build=$hostBuild; UBR=$hostUbr; EditionID=$hostCv.EditionID; Arch=$hostArch; Lang=$hostLangHex }
            Target       = @{ Build=$tBuild; UBR=$tUbr; Strategy=$BuildStrategy; SpoofLevel=$SpoofLevel }
            Image        = $WimPath
            DryRun       = [bool]$DryRun
            Results      = @($Results)
        }
        $reportFile = Join-Path $logDir ("report_{0:yyyyMMdd_HHmmss}.json" -f (Get-Date))
        $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $reportFile -Encoding UTF8
        W-Ok "Аудит сохранён: $reportFile"
    } catch { W-Warn "Не удалось записать JSON-аудит: $($_.Exception.Message)" }

    # --- Подготовка USB ---
    if (($PrepUsb -or $UsbPath) -and -not $DryRun) {
        if (-not $UsbPath) { W-Die 'Указан -PrepUsb, но нет -UsbPath.' }
        if ($failCount -and -not $ContinueOnError) { W-Die 'Есть упавшие индексы — на USB не пишу.' }

        $src = Join-Path $UsbPath 'sources'
        if (-not (Test-Path -LiteralPath $src)) { W-Die "На $UsbPath нет папки sources." }

        $usbFs   = Get-FsType $src
        $usbFree = Get-DriveFree $src
        $wimSize = (Get-Item -LiteralPath $WimPath).Length

        if ($null -ne $usbFree -and $usbFree -lt ($wimSize + 1GB)) {
            W-Die 'На USB недостаточно места для записи образа.'
        }

        $dst = Join-Path $src 'install.wim'

        if ($usbFs -eq 'FAT32' -and $wimSize -gt 4GB) {
            W-Step "Флешка в FAT32, образ >4ГБ. Разбиваю на части по $SwmSizeMB МБ..."
            Disable-FileIfExist $dst
            Remove-SwmArtifacts $src

            $swmBase = Join-Path $src 'install.swm'
            Invoke-Tool dism.exe @(
                '/Split-Image', "/ImageFile:$WimPath", "/SWMFile:$swmBase", "/FileSize:$SwmSizeMB"
            ) -Activity 'Разбивка образа на SWM' | Out-Null

            # FIXED: валидируем цепочку SWM чтением метаданных — битая флешка вскроется здесь.
            Invoke-Tool dism.exe @('/Get-WimInfo', "/WimFile:$swmBase") -Activity 'Проверка SWM-цепочки' | Out-Null
            W-Ok 'Образ разбит и цепочка SWM валидна (install.swm, install2.swm...).'
        }
        else {
            $resolvedWim = (Resolve-Path -LiteralPath $WimPath).Path
            $resolvedDst = if (Test-Path -LiteralPath $dst) { (Resolve-Path -LiteralPath $dst).Path } else { $dst }

            if ($resolvedWim -ne $resolvedDst) {
                if (Test-Path -LiteralPath $dst) {
                    # FIXED: сначала снести старый .prepatch.bak — второй запуск не падает.
                    $old = "$dst.prepatch.bak"
                    if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force }
                    Move-Item -LiteralPath $dst -Destination $old -Force
                }
                Copy-FileWithProgress -From $WimPath -To $dst -Activity 'Копия пропатченного WIM на USB'
                W-Ok 'Пропатченный WIM скопирован на USB.'
            }

            # FIXED: верификация копии по SHA256 — флешки бьют большие файлы.
            W-Step 'Сверяю SHA256 источника и копии на USB...'
            $h1 = (Get-FileHash -LiteralPath $WimPath -Algorithm SHA256).Hash
            $h2 = (Get-FileHash -LiteralPath $dst     -Algorithm SHA256).Hash
            if ($h1 -ne $h2) { W-Die 'Копия на USB не совпала по SHA256. Флешка/контроллер барахлит — запись не доверяю.' }
            W-Ok 'SHA256 совпал — копия честная.'

            Remove-SwmArtifacts $src
        }

        if (-not $KeepEsd) { Disable-FileIfExist (Join-Path $src 'install.esd') }

        if ($SanitizeUsb) {
            Disable-FileIfExist (Join-Path $src 'ei.cfg')
            Disable-FileIfExist (Join-Path $src 'pid.txt')
            Disable-FileIfExist (Join-Path $UsbPath 'AutoUnattend.xml')
            Disable-FileIfExist (Join-Path $UsbPath 'unattend.xml')
            W-Warn 'Оригиналы получили версионные суффиксы *.disabled.N и лежат рядом — при надобности верни имя.'
        }

        if ($WriteEiCfg) {
            if (-not $EiChannel -or -not $EiEdition) {
                W-Die 'Параметр -WriteEiCfg требует указания И -EiChannel, И -EiEdition.'
            }
            $vl  = if ($EiChannel -like 'Volume*') { 1 } else { 0 }
            $ei  = @('[EditionID]', $EiEdition, '[Channel]', $EiChannel, '[VL]', $vl, '') -join "`r`n"
            Set-Content -LiteralPath (Join-Path $src 'ei.cfg') -Value $ei -Encoding ASCII
            W-Ok 'ei.cfg создан.'
        }

        if ($RenameAppraiser) {
            W-Warn 'Переименование appraiserres.dll помогает лишь против части проверок и может сломать новые сборки.'
            Disable-FileIfExist (Join-Path $src 'appraiserres.dll')
        }
    }

    foreach ($n in @('$Windows.~BT','$Windows.~WS')) {
        $p = Join-Path $env:SystemDrive $n
        if (Test-Path -LiteralPath $p) {
            W-Warn "Найдена папка $n. Скрипт её не трогает. При проблемах — штатная «Очистка диска»."
        }
    }

    Write-Host ''
    if ($DryRun)   { W-Ok 'DryRun завершён. Изменения не применялись.' }
    elseif ($failCount) { W-Warn "Завершено с ошибками: $failCount из $($Indexes.Count) индексов не пропатчены. Код выхода 2." }
    else           { W-Ok 'Готово.' }

    Write-Host 'Рекомендуемый запуск установки: интерактивно выполни  X:\setup.exe'
    Write-Host 'Чтобы Setup не подтянул свежий динамический контент: X:\setup.exe /DynamicUpdate disable'
    Write-Host 'Если пункт «Сохранить личные файлы и приложения» серый — ОСТАНОВИСЬ: Setup спуф не принял.'
    Write-Host 'Не выключай и не перезагружай ПК после финальной перезагрузки Setup, пока не отработает SetupComplete.'

    if ($failCount) { exit 2 } else { exit 0 }

} finally {
    # FIXED: Stop-Transcript защищён — не маскирует исходную ошибку.
    try { Stop-Transcript | Out-Null } catch {}
}
