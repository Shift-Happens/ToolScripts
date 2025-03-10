#requires -Version 3.0
<#
.SYNOPSIS
    Eksportuje dzienniki zdarzeń systemu Windows do plików z możliwością filtrowania.
.DESCRIPTION
    Ten skrypt eksportuje dzienniki zdarzeń systemu Windows (Application, System, Security, itp.)
    do plików w formatach CSV i HTML. Umożliwia filtrowanie zdarzeń według czasu, poziomów 
    ważności i konkretnych identyfikatorów zdarzeń.
    # Podstawowe użycie (eksport domyślnych dzienników z ostatnich 24h)
    .\ExportEventLogs.ps1

    # Eksport zdarzeń z dzienników System i Application z ostatnich 7 dni
    .\ExportEventLogs.ps1 -Days 7 -LogNames "System","Application"

    # Eksport błędów i krytycznych zdarzeń z dziennika Security z filtrami ID
    .\ExportEventLogs.ps1 -Days 3 -LogNames "Security" -Levels "Error","Critical" -EventIDs 4625,4624
.EXAMPLE
    .\ExportEventLogs.ps1
    Eksportuje domyślne dzienniki z ostatnich 24 godzin.
.EXAMPLE
    .\ExportEventLogs.ps1 -Days 7 -LogNames "System","Application"
    Eksportuje zdarzenia z dzienników System i Application z ostatnich 7 dni.
.EXAMPLE
    .\ExportEventLogs.ps1 -Days 3 -LogNames "Security" -Levels "Error","Critical" -EventIDs 4625,4624
    Eksportuje błędy i krytyczne zdarzenia z dziennika Security z ostatnich 3 dni, 
    filtrując tylko zdarzenia o ID 4625 i 4624 (logowanie i nieudane logowanie).
.NOTES
    Nazwa:        ExportEventLogs.ps1
    Autor:        Arkadiusz Kubiszewski
    Wersja:       1.0
#>

param (
    # Nazwy dzienników do eksportu
    [Parameter()]
    [string[]]$LogNames = @("Application", "System", "Security"),
    
    # Liczba dni wstecz, dla których eksportować zdarzenia
    [Parameter()]
    [int]$Days = 1,
    
    # Poziomy ważności zdarzeń do eksportu
    [Parameter()]
    [ValidateSet("Information", "Warning", "Error", "Critical", "Verbose")]
    [string[]]$Levels = @("Information", "Warning", "Error", "Critical"),
    
    # Konkretne ID zdarzeń do filtrowania (opcjonalne)
    [Parameter()]
    [int[]]$EventIDs = @(),
    
    # Folder docelowy dla eksportowanych plików
    [Parameter()]
    [string]$OutputFolder = "$env:USERPROFILE\Desktop\EventLogs_$(Get-Date -Format 'yyyyMMdd_HHmmss')",
    
    # Format eksportu (CSV, HTML lub oba)
    [Parameter()]
    [ValidateSet("CSV", "HTML", "Both")]
    [string]$ExportFormat = "Both",
    
    # Maksymalna liczba zdarzeń do eksportu z każdego dziennika
    [Parameter()]
    [int]$MaxEvents = 5000,
    
    # Przełącznik do automatycznego otwarcia folderu po zakończeniu
    [Parameter()]
    [switch]$OpenFolderWhenDone = $true
)

# Ustawienia błędów i ostrzeżeń
$ErrorActionPreference = "Continue"
$WarningPreference = "SilentlyContinue"

#-----------------------------------------------------------------------------------
# FUNKCJE POMOCNICZE
#-----------------------------------------------------------------------------------

# Funkcja do tworzenia struktury folderów
function Initialize-Environment {
    if (-not (Test-Path -Path $OutputFolder)) {
        New-Item -Path $OutputFolder -ItemType Directory | Out-Null
        Write-Host "Utworzono folder docelowy: $OutputFolder" -ForegroundColor Green
    }
    
    if (-not (Test-Path -Path "$OutputFolder\CSV") -and ($ExportFormat -eq "CSV" -or $ExportFormat -eq "Both")) {
        New-Item -Path "$OutputFolder\CSV" -ItemType Directory | Out-Null
    }
    
    if (-not (Test-Path -Path "$OutputFolder\HTML") -and ($ExportFormat -eq "HTML" -or $ExportFormat -eq "Both")) {
        New-Item -Path "$OutputFolder\HTML" -ItemType Directory | Out-Null
    }
}

# Funkcja do eksportu zdarzeń do formatu CSV
function Export-EventsToCSV {
    param (
        [Parameter(Mandatory=$true)][Object]$Events,
        [Parameter(Mandatory=$true)][String]$LogName
    )
    
    $OutputPath = "$OutputFolder\CSV\$LogName.csv"
    
    $Events | Select-Object TimeCreated, Level, LevelDisplayName, LogName, Id, ProviderName, 
                            MachineName, UserId, Message, TaskDisplayName, 
                            @{Name="EventRecordID"; Expression={$_.RecordId}} |
    Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
    
    Write-Host "Wyeksportowano $($Events.Count) zdarzeń do pliku $OutputPath" -ForegroundColor Green
}

# Funkcja do eksportu zdarzeń do formatu HTML
function Export-EventsToHTML {
    param (
        [Parameter(Mandatory=$true)][Object]$Events,
        [Parameter(Mandatory=$true)][String]$LogName
    )
    
    $OutputPath = "$OutputFolder\HTML\$LogName.html"
    
    $HTMLHeader = @"
<!DOCTYPE html>
<html lang="pl">
<head>
    <meta charset="UTF-8">
    <title>Dziennik zdarzeń - $LogName</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; background-color: #f5f5f5; }
        h1 { color: #2c3e50; border-bottom: 2px solid #3498db; padding-bottom: 10px; }
        .summary { background-color: #e9f7fe; padding: 15px; border-radius: 5px; margin: 20px 0; border-left: 5px solid #3498db; }
        table { border-collapse: collapse; width: 100%; margin-top: 20px; background-color: white; }
        th { background-color: #3498db; color: white; text-align: left; padding: 12px 8px; position: sticky; top: 0; }
        td { border: 1px solid #ddd; padding: 8px; vertical-align: top; max-width: 500px; overflow: hidden; text-overflow: ellipsis; }
        tr:nth-child(even) { background-color: #f2f2f2; }
        tr:hover { background-color: #e3f2fd; }
        .error { background-color: #ffebee; }
        .warning { background-color: #fff8e1; }
        .critical { background-color: #ffcdd2; }
        .info { background-color: #f1f8e9; }
        .message { white-space: pre-wrap; max-height: 100px; overflow-y: auto; }
        .filters { background-color: #f8f9fa; padding: 10px; border-radius: 5px; margin: 10px 0; border: 1px solid #ddd; }
    </style>
</head>
<body>
    <h1>Dziennik zdarzeń - $LogName</h1>
    <div class="summary">
        <p><strong>Komputer:</strong> $env:COMPUTERNAME</p>
        <p><strong>Data eksportu:</strong> $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
        <p><strong>Okres:</strong> Ostatnie $Days $(if ($Days -eq 1) { "dzień" } elseif ($Days -ge 2 -and $Days -le 4) { "dni" } else { "dni" })</p>
        <p><strong>Liczba zdarzeń:</strong> $($Events.Count)</p>
    </div>
    <div class="filters">
        <p><strong>Zastosowane filtry:</strong></p>
        <ul>
            <li>Poziomy: $($Levels -join ", ")</li>
            $(if ($EventIDs.Count -gt 0) { "<li>Identyfikatory zdarzeń: $($EventIDs -join ", ")</li>" })
        </ul>
    </div>
"@

    $HTMLFooter = @"
</body>
</html>
"@

    # Przygotowanie danych do eksportu HTML
    $EventsHTML = $Events | Select-Object TimeCreated, Level, LevelDisplayName, LogName, Id, ProviderName, 
                                        MachineName, UserId, 
                                        @{Name="Message"; Expression={$_.Message -replace "`r`n", "<br>"}}, 
                                        TaskDisplayName, 
                                        @{Name="EventRecordID"; Expression={$_.RecordId}} |
                           ConvertTo-Html -Fragment
    
    # Dodanie klas CSS na podstawie poziomu zdarzenia
    $EventsHTML = $EventsHTML -replace '<tr><td>', '<tr class="info"><td>'
    $EventsHTML = $EventsHTML -replace '<tr class="info"><td>[^<]*</td><td>Warning', '<tr class="warning"><td>$&' -replace 'Warning[^<]*</td>', '$&'
    $EventsHTML = $EventsHTML -replace '<tr class="info"><td>[^<]*</td><td>Error', '<tr class="error"><td>$&' -replace 'Error[^<]*</td>', '$&'
    $EventsHTML = $EventsHTML -replace '<tr class="info"><td>[^<]*</td><td>Critical', '<tr class="critical"><td>$&' -replace 'Critical[^<]*</td>', '$&'
    
    # Dodanie klasy do pola Message dla lepszego formatowania
    $EventsHTML = $EventsHTML -replace '<td>((?!<td>).+Message</th>)', '<td class="message">$1'
    
    # Eksport do pliku HTML
    $HTMLHeader + $EventsHTML + $HTMLFooter | Out-File -FilePath $OutputPath -Encoding UTF8
    
    Write-Host "Wyeksportowano $($Events.Count) zdarzeń do pliku $OutputPath" -ForegroundColor Green
}

# Funkcja do tworzenia strony głównej HTML
function Create-IndexHTML {
    $OutputPath = "$OutputFolder\index.html"
    
    $HTMLFiles = Get-ChildItem -Path "$OutputFolder\HTML" -Filter "*.html" -ErrorAction SilentlyContinue
    $CSVFiles = Get-ChildItem -Path "$OutputFolder\CSV" -Filter "*.csv" -ErrorAction SilentlyContinue
    
    $HTMLHeader = @"
<!DOCTYPE html>
<html lang="pl">
<head>
    <meta charset="UTF-8">
    <title>Podsumowanie dzienników zdarzeń - $env:COMPUTERNAME</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; background-color: #f5f5f5; }
        h1, h2 { color: #2c3e50; border-bottom: 2px solid #3498db; padding-bottom: 10px; }
        .summary { background-color: #e9f7fe; padding: 15px; border-radius: 5px; margin: 20px 0; border-left: 5px solid #3498db; }
        .container { display: flex; flex-wrap: wrap; gap: 20px; }
        .section { flex: 1; min-width: 300px; background-color: white; padding: 15px; border-radius: 5px; box-shadow: 0 2px 5px rgba(0,0,0,0.1); }
        table { border-collapse: collapse; width: 100%; margin-top: 10px; }
        th { background-color: #3498db; color: white; text-align: left; padding: 8px; }
        td { border: 1px solid #ddd; padding: 8px; }
        tr:nth-child(even) { background-color: #f2f2f2; }
        tr:hover { background-color: #e3f2fd; }
        a { color: #3498db; text-decoration: none; }
        a:hover { text-decoration: underline; }
    </style>
</head>
<body>
    <h1>Podsumowanie dzienników zdarzeń - $env:COMPUTERNAME</h1>
    
    <div class="summary">
        <p><strong>Data eksportu:</strong> $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
        <p><strong>Wyeksportowane dzienniki:</strong> $($LogNames -join ", ")</p>
        <p><strong>Okres:</strong> Ostatnie $Days $(if ($Days -eq 1) { "dzień" } elseif ($Days -ge 2 -and $Days -le 4) { "dni" } else { "dni" })</p>
        <p><strong>Zastosowane filtry poziomów:</strong> $($Levels -join ", ")</p>
        $(if ($EventIDs.Count -gt 0) { "<p><strong>Filtrowane identyfikatory zdarzeń:</strong> $($EventIDs -join ", ")</p>" })
    </div>
    
    <div class="container">
"@

    $HTMLSections = ""
    
    if ($HTMLFiles.Count -gt 0) {
        $HTMLSection = @"
        <div class="section">
            <h2>Pliki HTML:</h2>
            <table>
                <tr>
                    <th>Dziennik</th>
                    <th>Liczba zdarzeń</th>
                </tr>

"@
        
        foreach ($file in $HTMLFiles) {
            $logName = $file.BaseName
            $eventCount = 0
            
            if ($ExportFormat -eq "Both" -or $ExportFormat -eq "CSV") {
                $csvPath = "$OutputFolder\CSV\$logName.csv"
                if (Test-Path $csvPath) {
                    $eventCount = (Import-Csv -Path $csvPath | Measure-Object).Count
                }
            } else {
                # Jeśli nie mamy CSV, szacujemy na podstawie rozmiaru pliku HTML
                $fileSize = (Get-Item $file.FullName).Length
                $eventCount = [Math]::Round($fileSize / 1000) # Przybliżona wartość
            }
            
            $HTMLSection += @"
                <tr>
                    <td><a href="HTML/$($file.Name)">$logName</a></td>
                    <td>$eventCount</td>
                </tr>

"@
        }
        
        $HTMLSection += @"
            </table>
        </div>

"@
        
        $HTMLSections += $HTMLSection
    }
    
    if ($CSVFiles.Count -gt 0) {
        $CSVSection = @"
        <div class="section">
            <h2>Pliki CSV:</h2>
            <table>
                <tr>
                    <th>Dziennik</th>
                </tr>

"@
        
        foreach ($file in $CSVFiles) {
            $CSVSection += @"
                <tr>
                    <td><a href="CSV/$($file.Name)">$($file.BaseName)</a></td>
                </tr>

"@
        }
        
        $CSVSection += @"
            </table>
        </div>

"@
        
        $HTMLSections += $CSVSection
    }
    
    $HTMLFooter = @"
    </div>
</body>
</html>
"@
    
    $HTMLHeader + $HTMLSections + $HTMLFooter | Out-File -FilePath $OutputPath -Encoding UTF8
    
    Write-Host "Utworzono stronę główną: $OutputPath" -ForegroundColor Green
}

#-----------------------------------------------------------------------------------
# GŁÓWNY PROCES
#-----------------------------------------------------------------------------------

$startTime = Get-Date
Write-Host "===== EKSPORT DZIENNIKÓW ZDARZEŃ WINDOWS =====" -ForegroundColor Cyan
Write-Host "Rozpoczęto: $startTime" -ForegroundColor Cyan
Write-Host "Przygotowywanie środowiska..." -ForegroundColor Yellow

# Inicjalizacja struktur folderów
Initialize-Environment

# Obliczenie daty początkowej na podstawie liczby dni
$startDate = (Get-Date).AddDays(-$Days)
Write-Host "Eksportowanie zdarzeń od: $startDate" -ForegroundColor Yellow

# Mapowanie poziomów ważności na wartości liczbowe używane przez Get-WinEvent
$levelMapping = @{
    "Critical" = 1
    "Error" = 2
    "Warning" = 3
    "Information" = 4
    "Verbose" = 5
}

# Konwersja poziomów tekstowych na wartości liczbowe
$levelValues = $Levels | ForEach-Object { $levelMapping[$_] }

# Główna pętla dla każdego dziennika
foreach ($logName in $LogNames) {
    Write-Host "`nPrzetwarzanie dziennika: $logName" -ForegroundColor Yellow
    
    try {
        # Budowanie filtra XPath
        $filterXPath = "*[System[TimeCreated[@SystemTime>='{0}']" -f $startDate.ToUniversalTime().ToString("o")
        
        # Dodanie filtra poziomów
        if ($levelValues.Count -gt 0) {
            $levelsXPath = " and (Level=" + ($levelValues -join " or Level=") + ")"
            $filterXPath += $levelsXPath
        }
        
        # Dodanie filtra identyfikatorów zdarzeń
        if ($EventIDs.Count -gt 0) {
            $eventIDsXPath = " and (EventID=" + ($EventIDs -join " or EventID=") + ")"
            $filterXPath += $eventIDsXPath
        }
        
        $filterXPath += "]]"
        
        # Pobranie zdarzeń
        Write-Host "Pobieranie zdarzeń z dziennika $logName..." -ForegroundColor Yellow
        Write-Host "Filtr XPath: $filterXPath" -ForegroundColor Gray
        
        $events = Get-WinEvent -LogName $logName -FilterXPath $filterXPath -MaxEvents $MaxEvents -ErrorAction SilentlyContinue
        
        if ($events -and $events.Count -gt 0) {
            Write-Host "Znaleziono $($events.Count) zdarzeń w dzienniku $logName" -ForegroundColor Green
            
            # Eksport do wybranych formatów
            if ($ExportFormat -eq "CSV" -or $ExportFormat -eq "Both") {
                Export-EventsToCSV -Events $events -LogName $logName
            }
            
            if ($ExportFormat -eq "HTML" -or $ExportFormat -eq "Both") {
                Export-EventsToHTML -Events $events -LogName $logName
            }
        } else {
            Write-Host "Nie znaleziono żadnych zdarzeń w dzienniku $logName spełniających kryteria" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "Błąd podczas przetwarzania dziennika $logName: $_" -ForegroundColor Red
    }
}

# Tworzenie strony głównej HTML
if ($ExportFormat -eq "HTML" -or $ExportFormat -eq "Both") {
    Write-Host "`nTworzenie strony głównej..." -ForegroundColor Yellow
    Create-IndexHTML
}

# Podsumowanie
$endTime = Get-Date
$duration = $endTime - $startTime
Write-Host "`n===== PODSUMOWANIE =====" -ForegroundColor Cyan
Write-Host "Eksport został zakończony w czasie: $([math]::Round($duration.TotalSeconds, 2)) sekund" -ForegroundColor Green
Write-Host "Wyniki zostały zapisane w folderze: $OutputFolder" -ForegroundColor Green

# Automatyczne otwarcie folderu
if ($OpenFolderWhenDone) {
    Write-Host "Otwieranie folderu z wynikami..." -ForegroundColor Yellow
    Start-Process "explorer.exe" -ArgumentList $OutputFolder
}