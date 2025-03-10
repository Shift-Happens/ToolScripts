#requires -Version 3.0
<#
.SYNOPSIS
    Zbiera szczegółowe informacje o sprzęcie i oprogramowaniu komputera.
.DESCRIPTION
    Ten skrypt gromadzi i zapisuje kompleksowe informacje o systemie, w tym dane o:
    - Sprzęcie (procesor, pamięć, płyta główna, dyski)
    - Systemie operacyjnym i jego konfiguracji
    - Zainstalowanym oprogramowaniu
    - Usługach systemowych
    - Konfiguracji sieci
    Wyniki są zapisywane do plików HTML i CSV w folderze z raportem.
.EXAMPLE
    .\GetSystemInventory.ps1
.NOTES
    Nazwa:        GetSystemInventory.ps1
    Autor:        Arkadiusz Kubiszewski
    Wersja:       1.1
#>

# Ustawienia skryptu
$ErrorActionPreference = "SilentlyContinue"
$ReportPath = "$env:USERPROFILE\Desktop\SystemInventory_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
$ComputerName = $env:COMPUTERNAME

# Utworzenie katalogu na raport
if (-not (Test-Path -Path $ReportPath)) {
    New-Item -Path $ReportPath -ItemType Directory | Out-Null
}

# Funkcja do zapisywania wyników do pliku CSV
function Export-ToCSV {
    param (
        [Parameter(Mandatory=$true)][Object]$Data,
        [Parameter(Mandatory=$true)][String]$FileName
    )
    
    $Data | Export-Csv -Path "$ReportPath\$FileName.csv" -NoTypeInformation -Encoding UTF8
}

# Funkcja do eksportu danych do HTML
function Export-ToHTML {
    param (
        [Parameter(Mandatory=$true)][Object]$Data,
        [Parameter(Mandatory=$true)][String]$FileName,
        [Parameter(Mandatory=$true)][String]$Title
    )
    
    $HTMLHeader = @"
<!DOCTYPE html>
<html>
<head>
    <title>$Title</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        h1 { color: #2c3e50; border-bottom: 2px solid #3498db; padding-bottom: 10px; }
        table { border-collapse: collapse; width: 100%; margin-top: 20px; }
        th { background-color: #3498db; color: white; text-align: left; padding: 8px; }
        td { border: 1px solid #ddd; padding: 8px; }
        tr:nth-child(even) { background-color: #f2f2f2; }
        tr:hover { background-color: #e3f2fd; }
    </style>
</head>
<body>
    <h1>$Title - $ComputerName</h1>
    <p>Wygenerowano: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
"@

    $HTMLFooter = @"
</body>
</html>
"@

    $Data | ConvertTo-Html -Head $HTMLHeader -PostContent $HTMLFooter | Out-File -FilePath "$ReportPath\$FileName.html" -Encoding UTF8
}

function Create-IndexHTML {
    $reportFiles = Get-ChildItem -Path $ReportPath -Filter "*.html" | Where-Object { $_.Name -ne "index.html" }
    
    $HTMLHeader = @"
<!DOCTYPE html>
<html>
<head>
    <title>Raport systemowy - $ComputerName</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        h1 { color: #2c3e50; border-bottom: 2px solid #3498db; padding-bottom: 10px; }
        ul { list-style-type: none; padding: 0; }
        li { margin: 10px 0; }
        a { color: #3498db; text-decoration: none; padding: 8px 16px; background-color: #f8f9fa; 
            border-radius: 4px; display: block; transition: all 0.3s; }
        a:hover { background-color: #e3f2fd; }
        .summary { background-color: #f8f9fa; padding: 15px; border-radius: 4px; margin: 20px 0; }
    </style>
</head>
<body>
    <h1>Raport systemowy - $ComputerName</h1>
    <div class="summary">
        <p>Wygenerowano: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
        <p>Liczba raportów: $($reportFiles.Count)</p>
    </div>
    <ul>
"@

    $HTMLContent = ""
    foreach ($file in $reportFiles) {
        $name = $file.Name.Replace(".html", "")
        $displayName = $name -replace '([a-z])([A-Z])', '$1 $2'
        $HTMLContent += "        <li><a href='./$($file.Name)'>$displayName</a></li>`n"
    }

    $HTMLFooter = @"
    </ul>
</body>
</html>
"@

    $HTMLHeader + $HTMLContent + $HTMLFooter | Out-File -FilePath "$ReportPath\index.html" -Encoding UTF8
}

#-----------------------------------------------------------------------------------
# 1. INFORMACJE O SYSTEMIE
#-----------------------------------------------------------------------------------
Write-Host "Zbieranie informacji o systemie operacyjnym..." -ForegroundColor Green

$OSInfo = Get-CimInstance -ClassName Win32_OperatingSystem | Select-Object @{Name="Nazwa komputera"; Expression={$_.CSName}},
    @{Name="System operacyjny"; Expression={$_.Caption}},
    @{Name="Wersja"; Expression={$_.Version}},
    @{Name="Architektura"; Expression={$_.OSArchitecture}},
    @{Name="Zainstalowano"; Expression={$_.InstallDate}},
    @{Name="Ostatni restart"; Expression={$_.LastBootUpTime}},
    @{Name="Czas działania (dni)"; Expression={[math]::Round(($_.LocalDateTime - $_.LastBootUpTime).TotalDays, 2)}},
    @{Name="Folder systemowy"; Expression={$_.WindowsDirectory}}

Export-ToCSV -Data $OSInfo -FileName "SystemInfo"
Export-ToHTML -Data $OSInfo -FileName "SystemInfo" -Title "Informacje o systemie"

#-----------------------------------------------------------------------------------
# 2. INFORMACJE O SPRZĘCIE
#-----------------------------------------------------------------------------------
Write-Host "Zbieranie informacji o sprzęcie..." -ForegroundColor Green

# Procesor
$CPUInfo = Get-CimInstance -ClassName Win32_Processor | Select-Object @{Name="Procesor"; Expression={$_.Name}},
    @{Name="Producent"; Expression={$_.Manufacturer}},
    @{Name="Architektura"; Expression={
        switch($_.Architecture) {
            0 {"x86"}
            1 {"MIPS"}
            2 {"Alpha"}
            3 {"PowerPC"}
            5 {"ARM"}
            6 {"Itanium"}
            9 {"x64"}
            default {"Nieznany"}
        }
    }},
    @{Name="Rdzenie/wątki"; Expression={"$($_.NumberOfCores)/$($_.NumberOfLogicalProcessors)"}},
    @{Name="Prędkość (MHz)"; Expression={$_.MaxClockSpeed}},
    @{Name="Cache L2 (KB)"; Expression={$_.L2CacheSize}},
    @{Name="Cache L3 (KB)"; Expression={$_.L3CacheSize}}

Export-ToCSV -Data $CPUInfo -FileName "CPUInfo"
Export-ToHTML -Data $CPUInfo -FileName "CPUInfo" -Title "Informacje o procesorze"

# Płyta główna
$MotherboardInfo = Get-CimInstance -ClassName Win32_BaseBoard | Select-Object @{Name="Producent"; Expression={$_.Manufacturer}},
    @{Name="Model"; Expression={$_.Product}},
    @{Name="Numer seryjny"; Expression={$_.SerialNumber}}

Export-ToCSV -Data $MotherboardInfo -FileName "MotherboardInfo" 
Export-ToHTML -Data $MotherboardInfo -FileName "MotherboardInfo" -Title "Informacje o płycie głównej"

# BIOS
$BIOSInfo = Get-CimInstance -ClassName Win32_BIOS | Select-Object @{Name="Producent"; Expression={$_.Manufacturer}},
    @{Name="Wersja"; Expression={$_.Version}},
    @{Name="Data"; Expression={$_.ReleaseDate}},
    @{Name="Numer seryjny"; Expression={$_.SerialNumber}}

Export-ToCSV -Data $BIOSInfo -FileName "BIOSInfo" 
Export-ToHTML -Data $BIOSInfo -FileName "BIOSInfo" -Title "Informacje o BIOS"

# Pamięć RAM
$RAMModules = Get-CimInstance -ClassName Win32_PhysicalMemory | 
    Select-Object @{Name="Slot"; Expression={$_.DeviceLocator}},
    @{Name="Producent"; Expression={$_.Manufacturer}},
    @{Name="Numer seryjny"; Expression={$_.SerialNumber}},
    @{Name="Pojemność (GB)"; Expression={[math]::Round($_.Capacity / 1GB, 2)}},
    @{Name="Prędkość (MHz)"; Expression={$_.Speed}},
    @{Name="Typ"; Expression={$_.MemoryType}}

$RAMSummary = @{
    "Całkowita pamięć (GB)" = [math]::Round((Get-CimInstance -ClassName Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 2)
    "Liczba modułów" = ($RAMModules | Measure-Object).Count
}

Export-ToCSV -Data $RAMModules -FileName "RAMInfo"
Export-ToHTML -Data $RAMModules -FileName "RAMInfo" -Title "Informacje o pamięci RAM"

# Dyski twarde
$DiskDrives = Get-CimInstance -ClassName Win32_DiskDrive | 
    Select-Object @{Name="Model"; Expression={$_.Model}},
    @{Name="Interfejs"; Expression={$_.InterfaceType}},
    @{Name="Pojemność (GB)"; Expression={[math]::Round($_.Size / 1GB, 2)}},
    @{Name="Numer seryjny"; Expression={$_.SerialNumber}},
    @{Name="Partycje"; Expression={$_.Partitions}}

Export-ToCSV -Data $DiskDrives -FileName "DisksInfo"
Export-ToHTML -Data $DiskDrives -FileName "DisksInfo" -Title "Informacje o dyskach fizycznych"

# Partycje
$LogicalDisks = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" | 
    Select-Object @{Name="Dysk"; Expression={$_.DeviceID}},
    @{Name="Etykieta"; Expression={$_.VolumeName}},
    @{Name="System plików"; Expression={$_.FileSystem}},
    @{Name="Pojemność (GB)"; Expression={[math]::Round($_.Size / 1GB, 2)}},
    @{Name="Wolne miejsce (GB)"; Expression={[math]::Round($_.FreeSpace / 1GB, 2)}},
    @{Name="Wolne miejsce (%)"; Expression={[math]::Round(($_.FreeSpace / $_.Size) * 100, 2)}}

Export-ToCSV -Data $LogicalDisks -FileName "PartitionsInfo"
Export-ToHTML -Data $LogicalDisks -FileName "PartitionsInfo" -Title "Informacje o partycjach"

# Karta graficzna
$GPUInfo = Get-CimInstance -ClassName Win32_VideoController | 
    Select-Object @{Name="Nazwa"; Expression={$_.Name}},
    @{Name="Producent"; Expression={$_.VideoProcessor}},
    @{Name="Pamięć RAM (GB)"; Expression={[math]::Round($_.AdapterRAM / 1GB, 2)}},
    @{Name="Rozdzielczość"; Expression={"$($_.CurrentHorizontalResolution) x $($_.CurrentVerticalResolution)"}},
    @{Name="Odświeżanie (Hz)"; Expression={$_.CurrentRefreshRate}},
    @{Name="Sterownik"; Expression={$_.DriverVersion}},
    @{Name="Data sterownika"; Expression={$_.DriverDate}}

Export-ToCSV -Data $GPUInfo -FileName "GPUInfo"
Export-ToHTML -Data $GPUInfo -FileName "GPUInfo" -Title "Informacje o karcie graficznej"

#-----------------------------------------------------------------------------------
# 3. SIEĆ
#-----------------------------------------------------------------------------------
Write-Host "Zbieranie informacji o sieci..." -ForegroundColor Green

# Adaptery sieciowe
$NetworkAdapters = Get-CimInstance -ClassName Win32_NetworkAdapter | 
    Where-Object { $_.PhysicalAdapter -eq $true } |
    Select-Object @{Name="Nazwa"; Expression={$_.Name}},
    @{Name="Producent"; Expression={$_.Manufacturer}},
    @{Name="MAC"; Expression={$_.MACAddress}},
    @{Name="Typ"; Expression={$_.AdapterType}},
    @{Name="Stan"; Expression={if($_.NetEnabled) {"Włączony"} else {"Wyłączony"}}}

Export-ToCSV -Data $NetworkAdapters -FileName "NetworkAdaptersInfo"
Export-ToHTML -Data $NetworkAdapters -FileName "NetworkAdaptersInfo" -Title "Informacje o adapterach sieciowych"

# Konfiguracja IP
$IPConfiguration = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration | 
    Where-Object { $_.IPEnabled -eq $true } |
    Select-Object @{Name="Nazwa"; Expression={(Get-CimInstance -ClassName Win32_NetworkAdapter | Where-Object {$_.DeviceID -eq $_.Index}).Name}},
    @{Name="DHCP"; Expression={$_.DHCPEnabled}},
    @{Name="Adres IP"; Expression={$_.IPAddress[0]}},
    @{Name="Maska podsieci"; Expression={$_.IPSubnet[0]}},
    @{Name="Brama"; Expression={$_.DefaultIPGateway -join ", "}},
    @{Name="DNS"; Expression={$_.DNSServerSearchOrder -join ", "}}

Export-ToCSV -Data $IPConfiguration -FileName "IPConfigInfo"
Export-ToHTML -Data $IPConfiguration -FileName "IPConfigInfo" -Title "Konfiguracja IP"

#-----------------------------------------------------------------------------------
# 4. OPROGRAMOWANIE
#-----------------------------------------------------------------------------------
Write-Host "Zbieranie informacji o zainstalowanym oprogramowaniu..." -ForegroundColor Green

# Zainstalowane programy
$InstalledSoftware = Get-ItemProperty -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
                                     "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
                                     "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*" |
    Where-Object { $_.DisplayName -ne $null } |
    Select-Object @{Name="Nazwa"; Expression={$_.DisplayName}},
    @{Name="Wersja"; Expression={$_.DisplayVersion}},
    @{Name="Producent"; Expression={$_.Publisher}},
    @{Name="Data instalacji"; Expression={$_.InstallDate}},
    @{Name="Rozmiar (MB)"; Expression={[math]::Round($_.EstimatedSize / 1024, 2)}},
    @{Name="Lokalizacja"; Expression={$_.InstallLocation}} |
    Sort-Object -Property Nazwa

Export-ToCSV -Data $InstalledSoftware -FileName "InstalledSoftwareInfo"
Export-ToHTML -Data $InstalledSoftware -FileName "InstalledSoftwareInfo" -Title "Zainstalowane oprogramowanie"

# Windows Updates
$WindowsUpdates = Get-HotFix | 
    Select-Object @{Name="Identyfikator"; Expression={$_.HotFixID}},
    @{Name="Opis"; Expression={$_.Description}},
    @{Name="Data instalacji"; Expression={$_.InstalledOn}},
    @{Name="Zainstalowane przez"; Expression={$_.InstalledBy}} |
    Sort-Object -Property "Data instalacji" -Descending

Export-ToCSV -Data $WindowsUpdates -FileName "WindowsUpdatesInfo"
Export-ToHTML -Data $WindowsUpdates -FileName "WindowsUpdatesInfo" -Title "Zainstalowane aktualizacje Windows"

#-----------------------------------------------------------------------------------
# 5. USŁUGI WINDOWS
#-----------------------------------------------------------------------------------
Write-Host "Zbieranie informacji o usługach systemowych..." -ForegroundColor Green

$Services = Get-CimInstance -ClassName Win32_Service | 
    Select-Object @{Name="Nazwa"; Expression={$_.Name}},
    @{Name="Wyświetlana nazwa"; Expression={$_.DisplayName}},
    @{Name="Opis"; Expression={$_.Description}},
    @{Name="Stan"; Expression={$_.State}},
    @{Name="Typ startu"; Expression={$_.StartMode}},
    @{Name="Konto"; Expression={$_.StartName}},
    @{Name="Ścieżka"; Expression={$_.PathName}} |
    Sort-Object -Property Nazwa

Export-ToCSV -Data $Services -FileName "ServicesInfo"
Export-ToHTML -Data $Services -FileName "ServicesInfo" -Title "Usługi systemowe"

#-----------------------------------------------------------------------------------
# 6. UŻYTKOWNICY I GRUPY
#-----------------------------------------------------------------------------------
Write-Host "Zbieranie informacji o użytkownikach i grupach lokalnych..." -ForegroundColor Green

$LocalUsers = Get-LocalUser | 
    Select-Object @{Name="Nazwa"; Expression={$_.Name}},
    @{Name="Pełna nazwa"; Expression={$_.FullName}},
    @{Name="Opis"; Expression={$_.Description}},
    @{Name="Aktywne"; Expression={$_.Enabled}},
    @{Name="Konto zablokowane"; Expression={$_.PasswordExpires}},
    @{Name="Ostatnie logowanie"; Expression={$_.LastLogon}}

Export-ToCSV -Data $LocalUsers -FileName "LocalUsersInfo"
Export-ToHTML -Data $LocalUsers -FileName "LocalUsersInfo" -Title "Użytkownicy lokalni"

$LocalGroups = Get-LocalGroup | 
    Select-Object @{Name="Nazwa"; Expression={$_.Name}},
    @{Name="Opis"; Expression={$_.Description}},
    @{Name="SID"; Expression={$_.SID}}

Export-ToCSV -Data $LocalGroups -FileName "LocalGroupsInfo"
Export-ToHTML -Data $LocalGroups -FileName "LocalGroupsInfo" -Title "Grupy lokalne"

#-----------------------------------------------------------------------------------
# 7. PODSUMOWANIE RAPORTU
#-----------------------------------------------------------------------------------
Write-Host "Tworzenie podsumowania raportu..." -ForegroundColor Green

# Tworzenie strony głównej z linkami do wszystkich raportów
Create-IndexHTML

# Wyświetlenie informacji końcowej
Write-Host "`nRaport został pomyślnie wygenerowany i zapisany w: $ReportPath" -ForegroundColor Green
Write-Host "Otwórz plik 'index.html' w przeglądarce, aby zobaczyć pełny raport." -ForegroundColor Green

# Otwarcie folderu z raportem
explorer.exe $ReportPath