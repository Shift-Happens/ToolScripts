#requires -Version 3.0 -RunAsAdministrator
<#
.SYNOPSIS
    Sekwencyjnie restartuje zależne usługi Windows.
.DESCRIPTION
    Ten skrypt umożliwia bezpieczne, sekwencyjne restartowanie usług Windows 
    z uwzględnieniem ich zależności. Główne cechy skryptu:
    - Wykrywanie i respektowanie zależności między usługami
    - Tworzenie planu restartowania gwarantującego właściwą kolejność
    - Obsługa błędów i timeout'ów
    - Możliwość zapisania logu z procesu restartowania
    - Tryb testowy (bez faktycznego restartowania)

    ###
    Przykłady użycia:
    powershellCopy# Podstawowe użycie
    .\Restart-ServicesSequentially.ps1 -ServiceNames "Spooler"

    # Restartowanie usługi Windows Update z rejestrowaniem
    .\Restart-ServicesSequentially.ps1 -ServiceNames "wuauserv" -LogToFile

    # Restartowanie SQL Server z wydłużonymi timeoutami
    .\Restart-ServicesSequentially.ps1 -ServiceNames "MSSQLSERVER" -Timeout 120 -WaitBetweenServices 5

    # Tryb testowy - symulacja bez faktycznego restartu
    .\Restart-ServicesSequentially.ps1 -ServiceNames "W32Time" -TestMode

    # Restartowanie usługi wraz ze wszystkimi usługami, które od niej zależą
    .\Restart-ServicesSequentially.ps1 -ServiceNames "LanmanServer" -IncludeDependentServices
.EXAMPLE
    .\Restart-ServicesSequentially.ps1 -ServiceNames "Spooler","wuauserv"
    Restartuje usługę drukarki i usługę Windows Update wraz z ich zależnościami.
.EXAMPLE
    .\Restart-ServicesSequentially.ps1 -ServiceNames "SQLServer" -Timeout 120 -WaitBetweenServices 5
    Restartuje usługę SQL Server z wydłużonym czasem oczekiwania na zatrzymanie/uruchomienie
    i 5-sekundową przerwą między restartami poszczególnych usług.
.EXAMPLE
    .\Restart-ServicesSequentially.ps1 -ServiceNames "IIS" -TestMode
    Przeprowadza symulację restartowania usługi IIS bez faktycznego zatrzymania/uruchomienia.
.NOTES
    Nazwa:        Restart-ServicesSequentially.ps1
    Autor:        Arkadiusz Kubiszewski
    Wersja:       1.2
    Wymagania:    PowerShell 3.0 lub nowszy, uprawnienia administratora
#>

[CmdletBinding()]
param (
    # Nazwy usług do restartowania (można podać wiele usług oddzielonych przecinkami)
    [Parameter(Mandatory=$true, Position=0)]
    [string[]]$ServiceNames,
    
    # Maksymalny czas oczekiwania (w sekundach) na zatrzymanie lub uruchomienie usługi
    [Parameter()]
    [int]$Timeout = 60,
    
    # Czas oczekiwania (w sekundach) między restartowaniem poszczególnych usług
    [Parameter()]
    [int]$WaitBetweenServices = 2,
    
    # Czy zapisać log z procesu restartowania
    [Parameter()]
    [switch]$LogToFile,
    
    # Plik logu (domyślnie Desktop\ServiceRestartLog_data.log)
    [Parameter()]
    [string]$LogFile = "$env:USERPROFILE\Desktop\ServiceRestartLog_$(Get-Date -Format 'yyyyMMdd_HHmmss').log",
    
    # Tryb testowy (bez faktycznego restartowania)
    [Parameter()]
    [switch]$TestMode,
    
    # Czy restartować również usługi zależne od podanych
    [Parameter()]
    [switch]$IncludeDependentServices,
    
    # Czy wymusić zatrzymanie usług (ignorować błędy)
    [Parameter()]
    [switch]$Force
)

#-----------------------------------------------------------------------------------
# FUNKCJE POMOCNICZE
#-----------------------------------------------------------------------------------

# Funkcja do logowania komunikatów
function Write-Log {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Message,
        
        [Parameter()]
        [ValidateSet("INFO", "WARNING", "ERROR", "SUCCESS")]
        [string]$Level = "INFO"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    # Określenie koloru na podstawie poziomu komunikatu
    $color = switch ($Level) {
        "INFO"    { "White" }
        "WARNING" { "Yellow" }
        "ERROR"   { "Red" }
        "SUCCESS" { "Green" }
        default   { "White" }
    }
    
    # Wyświetlenie komunikatu w konsoli
    Write-Host $logMessage -ForegroundColor $color
    
    # Zapisanie do pliku, jeśli włączono logowanie
    if ($LogToFile) {
        $logMessage | Out-File -FilePath $LogFile -Append -Encoding UTF8
    }
}

# Funkcja do pobierania zależności usługi
function Get-ServiceDependencies {
    param (
        [Parameter(Mandatory=$true)]
        [string]$ServiceName,
        
        [Parameter()]
        [System.Collections.ArrayList]$DependencyChain = (New-Object System.Collections.ArrayList),
        
        [Parameter()]
        [switch]$Reverse
    )
    
    try {
        $service = Get-Service -Name $ServiceName -ErrorAction Stop
        
        # Pobierz zależności w zależności od kierunku
        $dependencies = if ($Reverse) {
            # Usługi, które zależą od naszej usługi
            Get-Service | Where-Object { $_.ServicesDependedOn | Where-Object { $_.Name -eq $ServiceName } }
        } else {
            # Usługi, od których zależy nasza usługa
            $service.ServicesDependedOn
        }
        
        if ($dependencies -and $dependencies.Count -gt 0) {
            foreach ($dependency in $dependencies) {
                # Sprawdź, czy usługa nie jest już w łańcuchu zależności (by uniknąć zapętlenia)
                if ($DependencyChain -notcontains $dependency.Name) {
                    [void]$DependencyChain.Add($dependency.Name)
                    
                    # Rekurencyjnie zbierz dalsze zależności
                    Get-ServiceDependencies -ServiceName $dependency.Name -DependencyChain $DependencyChain -Reverse:$Reverse
                }
            }
        }
        
        return $DependencyChain
    } catch {
        Write-Log "Błąd podczas pobierania zależności dla usługi '$ServiceName': $_" -Level "ERROR"
        return $DependencyChain
    }
}

# Funkcja do tworzenia planu restartowania
function Get-RestartPlan {
    param (
        [Parameter(Mandatory=$true)]
        [string[]]$Services,
        
        [Parameter()]
        [switch]$IncludeDependent
    )
    
    $restartPlan = [ordered]@{}
    $processedServices = New-Object System.Collections.ArrayList
    
    foreach ($serviceName in $Services) {
        try {
            # Sprawdź, czy usługa istnieje
            $service = Get-Service -Name $serviceName -ErrorAction Stop
            
            # Dodaj główną usługę do planu, jeśli jeszcze jej nie ma
            if ($processedServices -notcontains $service.Name) {
                [void]$processedServices.Add($service.Name)
                $restartPlan[$service.Name] = @{
                    "DisplayName" = $service.DisplayName
                    "Status" = $service.Status
                    "StartType" = (Get-Service $service.Name).StartType
                    "Dependencies" = @()
                    "DependentServices" = @()
                }
                
                # Pobierz usługi, od których zależy nasza usługa
                $dependencies = Get-ServiceDependencies -ServiceName $service.Name
                if ($dependencies.Count -gt 0) {
                    foreach ($dependency in $dependencies) {
                        $depService = Get-Service -Name $dependency
                        
                        if ($processedServices -notcontains $dependency) {
                            [void]$processedServices.Add($dependency)
                            $restartPlan[$dependency] = @{
                                "DisplayName" = $depService.DisplayName
                                "Status" = $depService.Status
                                "StartType" = $depService.StartType
                                "Dependencies" = @()
                                "DependentServices" = @()
                            }
                        }
                        
                        # Dodaj do listy zależności
                        $restartPlan[$service.Name]["Dependencies"] += $dependency
                    }
                }
                
                # Jeśli włączono opcję, pobierz usługi zależne
                if ($IncludeDependent) {
                    $dependentServices = Get-ServiceDependencies -ServiceName $service.Name -Reverse
                    if ($dependentServices.Count -gt 0) {
                        foreach ($dependent in $dependentServices) {
                            $depService = Get-Service -Name $dependent
                            
                            if ($processedServices -notcontains $dependent) {
                                [void]$processedServices.Add($dependent)
                                $restartPlan[$dependent] = @{
                                    "DisplayName" = $depService.DisplayName
                                    "Status" = $depService.Status
                                    "StartType" = $depService.StartType
                                    "Dependencies" = @()
                                    "DependentServices" = @()
                                }
                            }
                            
                            # Dodaj do listy usług zależnych
                            $restartPlan[$service.Name]["DependentServices"] += $dependent
                        }
                    }
                }
            }
        } catch {
            Write-Log "Błąd podczas przygotowywania planu dla usługi '$serviceName': $_" -Level "ERROR"
        }
    }
    
    return $restartPlan
}

# Funkcja do ustalania właściwej kolejności restartowania
function Get-RestartSequence {
    param (
        [Parameter(Mandatory=$true)]
        [System.Collections.Specialized.OrderedDictionary]$RestartPlan,
        
        [Parameter()]
        [switch]$Reverse
    )
    
    $visited = @{}
    $sequence = [System.Collections.ArrayList]@()
    
    # Funkcja pomocnicza do przeszukiwania w głąb (DFS)
    function Visit-Node {
        param (
            [Parameter(Mandatory=$true)]
            [string]$ServiceName
        )
        
        # Sprawdź, czy usługa już odwiedzona
        if ($visited.ContainsKey($ServiceName)) {
            return
        }
        
        # Oznacz jako odwiedzoną
        $visited[$ServiceName] = $true
        
        # Pobierz odpowiednie zależności w zależności od kierunku
        $dependencies = if ($Reverse) {
            $RestartPlan[$ServiceName]["DependentServices"]
        } else {
            $RestartPlan[$ServiceName]["Dependencies"]
        }
        
        # Rekurencyjnie odwiedź wszystkie zależności
        foreach ($dependency in $dependencies) {
            if ($RestartPlan.Contains($dependency) -and -not $visited.ContainsKey($dependency)) {
                Visit-Node -ServiceName $dependency
            }
        }
        
        # Dodaj usługę do sekwencji
        [void]$sequence.Add($ServiceName)
    }
    
    # Przejdź przez wszystkie usługi w planie
    foreach ($serviceName in $RestartPlan.Keys) {
        if (-not $visited.ContainsKey($serviceName)) {
            Visit-Node -ServiceName $serviceName
        }
    }
    
    # Jeśli uruchamiamy w kolejności odwrotnej, odwróć sekwencję
    if (-not $Reverse) {
        [array]::Reverse($sequence)
    }
    
    return $sequence
}

# Funkcja do restartowania usługi
function Restart-ServiceSafely {
    param (
        [Parameter(Mandatory=$true)]
        [string]$ServiceName,
        
        [Parameter()]
        [int]$Timeout,
        
        [Parameter()]
        [switch]$IsTest,
        
        [Parameter()]
        [switch]$ForceStop
    )
    
    try {
        $service = Get-Service -Name $ServiceName -ErrorAction Stop
        $displayName = $service.DisplayName
        
        # Jeśli usługa jest już zatrzymana, tylko ją uruchom
        if ($service.Status -eq "Stopped") {
            Write-Log "Usługa '$displayName' jest już zatrzymana." -Level "INFO"
        } else {
            Write-Log "Zatrzymywanie usługi '$displayName'..." -Level "INFO"
            
            if (-not $IsTest) {
                # Użyj parametru -Force jeśli został określony
                if ($ForceStop) {
                    Stop-Service -Name $ServiceName -Force -ErrorAction Stop
                } else {
                    Stop-Service -Name $ServiceName -ErrorAction Stop
                }
                
                # Czekaj na zatrzymanie z timeoutem
                $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                while ($service.Status -ne "Stopped" -and $stopwatch.Elapsed.TotalSeconds -lt $Timeout) {
                    Start-Sleep -Milliseconds 500
                    $service.Refresh()
                }
                $stopwatch.Stop()
                
                if ($service.Status -ne "Stopped") {
                    throw "Nie udało się zatrzymać usługi w określonym czasie ($Timeout s)."
                }
                
                Write-Log "Usługa '$displayName' została zatrzymana." -Level "SUCCESS"
            } else {
                Write-Log "[TRYB TESTOWY] Usługa '$displayName' zostałaby zatrzymana." -Level "INFO"
            }
        }
        
        # Uruchom usługę, jeśli jest skonfigurowana do automatycznego startu lub ręcznego
        if ($service.StartType -ne "Disabled") {
            Write-Log "Uruchamianie usługi '$displayName'..." -Level "INFO"
            
            if (-not $IsTest) {
                Start-Service -Name $ServiceName -ErrorAction Stop
                
                # Czekaj na uruchomienie z timeoutem
                $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                while ($service.Status -ne "Running" -and $stopwatch.Elapsed.TotalSeconds -lt $Timeout) {
                    Start-Sleep -Milliseconds 500
                    $service.Refresh()
                }
                $stopwatch.Stop()
                
                if ($service.Status -ne "Running") {
                    throw "Nie udało się uruchomić usługi w określonym czasie ($Timeout s)."
                }
                
                Write-Log "Usługa '$displayName' została uruchomiona." -Level "SUCCESS"
            } else {
                Write-Log "[TRYB TESTOWY] Usługa '$displayName' zostałaby uruchomiona." -Level "INFO"
            }
        } else {
            Write-Log "Usługa '$displayName' jest wyłączona (Disabled) i nie zostanie uruchomiona." -Level "WARNING"
        }
        
        return $true
    } catch {
        Write-Log "Błąd podczas restartowania usługi '$ServiceName': $_" -Level "ERROR"
        return $false
    }
}

#-----------------------------------------------------------------------------------
# GŁÓWNY PROCES
#-----------------------------------------------------------------------------------

$startTime = Get-Date
Write-Log "===== SEKWENCYJNE RESTARTOWANIE USŁUG =====" -Level "INFO"
Write-Log "Rozpoczęto: $startTime" -Level "INFO"

if ($TestMode) {
    Write-Log "URUCHOMIONO W TRYBIE TESTOWYM - usługi nie zostaną faktycznie zrestartowane." -Level "WARNING"
}

# Inicjalizacja pliku logu, jeśli włączono logowanie
if ($LogToFile) {
    try {
        # Utwórz katalog dla pliku logu, jeśli nie istnieje
        $logDir = Split-Path -Path $LogFile -Parent
        if (-not (Test-Path -Path $logDir)) {
            New-Item -Path $logDir -ItemType Directory -Force | Out-Null
        }
        
        # Utwórz plik logu i zapisz nagłówek
        $logHeader = "===== LOG RESTARTOWANIA USŁUG =====`r`n"
        $logHeader += "Data: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`r`n"
        $logHeader += "Komputer: $env:COMPUTERNAME`r`n"
        $logHeader += "Usługi do restartowania: $($ServiceNames -join ', ')`r`n"
        $logHeader += "Tryb testowy: $TestMode`r`n"
        $logHeader += "Timeout: $Timeout s`r`n"
        $logHeader += "Uwzględnij usługi zależne: $IncludeDependentServices`r`n"
        $logHeader += "Wymuś zatrzymanie: $Force`r`n"
        $logHeader += "========================================`r`n"
        
        $logHeader | Out-File -FilePath $LogFile -Encoding UTF8 -Force
        Write-Log "Log będzie zapisywany do: $LogFile" -Level "INFO"
    } catch {
        Write-Log "Błąd podczas inicjalizacji pliku logu: $_. Kontynuuję bez logowania do pliku." -Level "ERROR"
        $LogToFile = $false
    }
}

# Sprawdź, czy podane usługi istnieją
$validServices = @()
foreach ($serviceName in $ServiceNames) {
    try {
        $service = Get-Service -Name $serviceName -ErrorAction Stop
        $validServices += $serviceName
        Write-Log "Usługa '$($service.DisplayName)' ($serviceName) została znaleziona." -Level "INFO"
    } catch {
        Write-Log "Usługa '$serviceName' nie została znaleziona. Zostanie pominięta." -Level "ERROR"
    }
}

if ($validServices.Count -eq 0) {
    Write-Log "Nie znaleziono żadnej z podanych usług. Skrypt zostanie zakończony." -Level "ERROR"
    exit 1
}

# Utwórz plan restartowania
Write-Log "Tworzenie planu restartowania..." -Level "INFO"
$restartPlan = Get-RestartPlan -Services $validServices -IncludeDependent:$IncludeDependentServices

# Pokaż podsumowanie planu
$totalServices = $restartPlan.Count
Write-Log "Plan restartowania zawiera $totalServices usług." -Level "INFO"

# Określ kolejność zatrzymywania (najpierw usługi zależne, potem te, od których zależą)
Write-Log "Ustalanie kolejności zatrzymywania usług..." -Level "INFO"
$stopSequence = Get-RestartSequence -RestartPlan $restartPlan -Reverse

# Wyświetl kolejność zatrzymywania
Write-Log "Kolejność zatrzymywania:" -Level "INFO"
for ($i = 0; $i -lt $stopSequence.Count; $i++) {
    $serviceName = $stopSequence[$i]
    $displayName = $restartPlan[$serviceName]["DisplayName"]
    Write-Log "  $($i+1). $displayName ($serviceName)" -Level "INFO"
}

# Zatrzymaj usługi w ustalonej kolejności
Write-Log "`nRozpoczynanie zatrzymywania usług..." -Level "INFO"
$stoppedServices = New-Object System.Collections.ArrayList

foreach ($serviceName in $stopSequence) {
    $displayName = $restartPlan[$serviceName]["DisplayName"]
    Write-Log "Przetwarzanie usługi: $displayName ($serviceName)" -Level "INFO"
    
    $result = Restart-ServiceSafely -ServiceName $serviceName -Timeout $Timeout -IsTest:$TestMode -ForceStop:$Force
    
    if ($result) {
        [void]$stoppedServices.Add($serviceName)
    }
    
    # Poczekaj określony czas między restartami usług
    if ($WaitBetweenServices -gt 0 -and $serviceName -ne $stopSequence[-1]) {
        Write-Log "Oczekiwanie $WaitBetweenServices sekund przed przejściem do następnej usługi..." -Level "INFO"
        Start-Sleep -Seconds $WaitBetweenServices
    }
}

# Podsumowanie
$endTime = Get-Date
$duration = $endTime - $startTime
Write-Log "`n===== PODSUMOWANIE =====" -Level "INFO"
Write-Log "Operacja zakończona w czasie: $([math]::Round($duration.TotalSeconds, 2)) sekund" -Level "INFO"
Write-Log "Łącznie przetworzono usług: $($stoppedServices.Count)/$totalServices" -Level "INFO"

if ($LogToFile) {
    Write-Log "Log został zapisany w pliku: $LogFile" -Level "INFO"
}

if ($TestMode) {
    Write-Log "Skrypt działał w trybie testowym - żadne usługi nie zostały faktycznie zrestartowane." -Level "WARNING"
}