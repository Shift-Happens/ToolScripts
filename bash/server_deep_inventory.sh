#!/bin/bash
# server_deep_inventory.sh - Kompleksowa inwentaryzacja serwera
# Opis: Skrypt zbiera szczegółowe informacje o konfiguracji serwera do celów migracji po czym robi backup plików konfiguracyjnych i pakuje je do folderu.tar wraz z raportem w formacie .md


# Konfiguracja
OUTPUT_DIR="server_inventory_$(hostname)_$(date +%Y%m%d)"
MAIN_REPORT="$OUTPUT_DIR/main_report.md"
CONFIGS_DIR="$OUTPUT_DIR/configs"
PERFORMANCE_DIR="$OUTPUT_DIR/performance"

# Tworzenie struktury katalogów
mkdir -p "$OUTPUT_DIR" "$CONFIGS_DIR" "$PERFORMANCE_DIR"

# Funkcja do logowania
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$OUTPUT_DIR/inventory.log"
}

# Funkcja do sprawdzania i zapisywania wyjścia polecenia
run_command() {
    local cmd="$1"
    local output_file="$2"
    local description="$3"
    log "Wykonywanie: $description"
    if eval "$cmd" > "$output_file" 2>&1; then
        log "✅ Sukces: $description"
    else
        log "⚠️ Błąd wykonania: $description (kod: $?)"
    fi
}

# Rozpoczęcie inwentaryzacji
log "Rozpoczęcie inwentaryzacji serwera $(hostname)"

# ---------- RAPORT GŁÓWNY (MARKDOWN) ----------
cat > "$MAIN_REPORT" << EOL
# Raport inwentaryzacji serwera: $(hostname)

**Data wygenerowania:** $(date '+%Y-%m-%d %H:%M:%S')

## Spis treści
1. [Informacje podstawowe](#informacje-podstawowe)
2. [Sprzęt](#sprzęt)
3. [System operacyjny](#system-operacyjny)
4. [Zasoby](#zasoby)
5. [Sieć](#sieć)
6. [Usługi i aplikacje](#usługi-i-aplikacje)
7. [Bazy danych](#bazy-danych)
8. [Docker i kontenery](#docker-i-kontenery)
9. [Wirtualizacja](#wirtualizacja)
10. [Zainstalowane pakiety](#zainstalowane-pakiety)
11. [Zadania cron](#zadania-cron)
12. [Użytkownicy systemu](#użytkownicy-systemu)
13. [Wydajność](#wydajność)
14. [Zasoby WWW](#zasoby-www)
15. [Pliki konfiguracyjne](#pliki-konfiguracyjne)

## Informacje podstawowe
EOL

# ---------- 1. INFORMACJE PODSTAWOWE ----------
{
    echo "### Hostname i FQDN"
    echo '```'
    hostname
    hostname -f
    echo '```'
    echo "### Uptime"
    echo '```'
    uptime
    echo '```'
    echo "### Data i strefa czasowa"
    echo '```'
    date
    timedatectl
    echo '```'
} >> "$MAIN_REPORT"

# ---------- 2. SPRZĘT ----------
{
    echo -e "\n## Sprzęt"
    echo "### CPU"
    echo '```'
    lscpu
    echo '```'
    echo "### Pamięć"
    echo '```'
    free -h
    echo '```'
    echo "### Dyski"
    echo '```'
    lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,MODEL
    echo '```'
    echo "### Szczegóły dysku"
    echo '```'
    df -h
    echo '```'
    echo "### RAID (jeśli istnieje)"
    echo '```'
    if [ -e /proc/mdstat ]; then
        cat /proc/mdstat
        for md in $(ls /dev/md* 2>/dev/null); do
            echo "Szczegóły dla $md:"
            mdadm --detail $md 2>/dev/null
        done
    else
        echo "Brak software RAID."
    fi
    echo '```'
    echo "### PCI"
    echo '```'
    lspci
    echo '```'
} >> "$MAIN_REPORT"

# ---------- 3. SYSTEM OPERACYJNY ----------
{
    echo -e "\n## System operacyjny"
    echo "### Wersja OS"
    echo '```'
    cat /etc/os-release
    echo '```'
    echo "### Kernel"
    echo '```'
    uname -a
    echo '```'
    echo "### Ostatnie aktualizacje pakietów"
    echo '```'
    if command -v apt &> /dev/null; then
        ls -lt /var/log/apt/ | head -10
    elif command -v dnf &> /dev/null; then
        rpm -qa --last | head -10
    elif command -v yum &> /dev/null; then
        rpm -qa --last | head -10
    else
        echo "Nieznany system zarządzania pakietami"
    fi
    echo '```'
} >> "$MAIN_REPORT"

# ---------- 4. ZASOBY ----------
{
    echo -e "\n## Zasoby"
    echo "### Użycie procesora"
    echo '```'
    top -bn1 | head -20
    echo '```'
    echo "### Użycie pamięci"
    echo '```'
    vmstat -s
    echo '```'
    echo "### Przestrzeń dyskowa"
    echo '```'
    df -h
    echo '```'
    echo "### Używane inodes"
    echo '```'
    df -i
    echo '```'
    echo "### Największe katalogi"
    echo '```'
    du -h --max-depth=1 / 2>/dev/null | sort -hr | head -10
    echo '```'
    echo "### Największe pliki"
    echo '```'
    find / -type f -size +100M -exec ls -lh {} \; 2>/dev/null | sort -k5hr | head -10
    echo '```'
} >> "$MAIN_REPORT"

# ---------- 5. SIEĆ ----------
{
    echo -e "\n## Sieć"
    echo "### Interfejsy sieciowe"
    echo '```'
    ip a
    echo '```'
    echo "### Tabela routingu"
    echo '```'
    ip route
    echo '```'
    echo "### Nasłuchujące porty"
    echo '```'
    ss -tulpn
    echo '```'
    echo "### Aktywne połączenia"
    echo '```'
    ss -tan state established | head -20
    echo '```'
    echo "### Konfiguracja DNS"
    echo '```'
    cat /etc/resolv.conf
    echo '```'
    echo "### Konfiguracja firewall"
    echo '```'
    if command -v iptables &> /dev/null; then
        iptables -L -v -n
        iptables -t nat -L -v -n
    fi
    if command -v ufw &> /dev/null; then
        ufw status verbose
    fi
    if command -v firewall-cmd &> /dev/null; then
        firewall-cmd --list-all
    fi
    echo '```'
    echo "### Hosty"
    echo '```'
    cat /etc/hosts
    echo '```'
} >> "$MAIN_REPORT"

# ---------- 6. USŁUGI I APLIKACJE ----------
{
    echo -e "\n## Usługi i aplikacje"
    echo "### Uruchomione usługi systemd"
    echo '```'
    systemctl list-units --type=service --state=running
    echo '```'
    echo "### Apache (jeśli istnieje)"
    echo '```'
    if command -v apache2 &> /dev/null || command -v httpd &> /dev/null; then
        if command -v apache2 &> /dev/null; then
            apache2 -v
            apache2ctl -S 2>/dev/null
        elif command -v httpd &> /dev/null; then
            httpd -v
            httpd -S 2>/dev/null
        fi
        echo "Sprawdzanie modułów Apache..."
        if command -v apache2 &> /dev/null; then
            apache2ctl -M 2>/dev/null
        else
            httpd -M 2>/dev/null
        fi
    else
        echo "Apache nie został znaleziony."
    fi
    echo '```'
    echo "### Nginx (jeśli istnieje)"
    echo '```'
    if command -v nginx &> /dev/null; then
        nginx -v 2>&1
        echo "Konfiguracja Nginx:"
        nginx -T 2>/dev/null | grep -E 'server_name|listen|root|location' | head -50
    else
        echo "Nginx nie został znaleziony."
    fi
    echo '```'
    echo "### PHP (jeśli istnieje)"
    echo '```'
    if command -v php &> /dev/null; then
        php -v
        echo "Zainstalowane moduły PHP:"
        php -m
    else
        echo "PHP nie został znaleziony."
    fi
    echo '```'
    echo "### NodeJS (jeśli istnieje)"
    echo '```'
    if command -v node &> /dev/null; then
        node -v
        if command -v npm &> /dev/null; then
            echo "NPM wersja:"
            npm -v
            echo "Globalne pakiety NPM:"
            npm list -g --depth=0
        fi
    else
        echo "NodeJS nie został znaleziony."
    fi
    echo '```'
    echo "### Java (jeśli istnieje)"
    echo '```'
    if command -v java &> /dev/null; then
        java -version
    else
        echo "Java nie została znaleziona."
    fi
    echo '```'
    echo "### Python (jeśli istnieje)"
    echo '```'
    if command -v python3 &> /dev/null; then
        python3 --version
        echo "Zainstalowane pakiety Python3:"
        if command -v pip3 &> /dev/null; then
            pip3 list 2>/dev/null
        fi
    fi
    if command -v python2 &> /dev/null; then
        python2 --version
        echo "Zainstalowane pakiety Python2:"
        if command -v pip2 &> /dev/null; then
            pip2 list 2>/dev/null
        fi
    fi
    echo '```'
} >> "$MAIN_REPORT"

# ---------- 7. BAZY DANYCH ----------
{
    echo -e "\n## Bazy danych"
    echo "### MySQL/MariaDB (jeśli istnieje)"
    echo '```'
    if command -v mysql &> /dev/null; then
        mysql --version
        if mysqladmin ping 2>/dev/null; then
            echo "MySQL/MariaDB jest uruchomiona."
            # Próba wylistowania baz danych bez hasła
            if mysql -e "SHOW DATABASES" 2>/dev/null; then
                echo "Lista baz danych:"
                mysql -e "SHOW DATABASES"
                echo "Rozmiary baz danych:"
                mysql -e "SELECT table_schema AS 'Database', ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) AS 'Size (MB)' FROM information_schema.TABLES GROUP BY table_schema"
                echo "Lista użytkowników (tylko nazwy):"
                mysql -e "SELECT user,host FROM mysql.user"
            else
                echo "Nie można uzyskać dostępu do MySQL bez hasła."
            fi
        else
            echo "MySQL/MariaDB nie jest uruchomiona lub wymaga hasła."
        fi
    else
        echo "MySQL/MariaDB nie została znaleziona."
    fi
    echo '```'
    echo "### PostgreSQL (jeśli istnieje)"
    echo '```'
    if command -v psql &> /dev/null; then
        psql --version
        if command -v sudo &> /dev/null && id -u postgres > /dev/null 2>&1; then
            echo "Próba uruchomienia jako użytkownik postgres:"
            if sudo -u postgres psql -c "\l" 2>/dev/null; then
                echo "Lista baz danych:"
                sudo -u postgres psql -c "\l"
            else
                echo "Nie można uzyskać dostępu do PostgreSQL jako postgres."
            fi
        else
            echo "Użytkownik postgres nie istnieje lub brak sudo."
        fi
    else
        echo "PostgreSQL nie został znaleziony."
    fi
    echo '```'
    echo "### Redis (jeśli istnieje)"
    echo '```'
    if command -v redis-cli &> /dev/null; then
        redis-cli --version
        echo "Status Redis:"
        if redis-cli ping 2>/dev/null; then
            echo "Redis jest uruchomiony."
            redis-cli info | head -20
        else
            echo "Redis nie jest uruchomiony lub wymaga hasła."
        fi
    else
        echo "Redis nie został znaleziony."
    fi
    echo '```'
    echo "### MongoDB (jeśli istnieje)"
    echo '```'
    if command -v mongod &> /dev/null; then
        mongod --version
        if command -v mongo &> /dev/null || command -v mongosh &> /dev/null; then
            echo "Status MongoDB:"
            if command -v mongo &> /dev/null; then
                if mongo --eval "db.adminCommand('ping')" 2>/dev/null; then
                    echo "MongoDB jest uruchomiony."
                    mongo --eval "db.adminCommand('listDatabases')" 2>/dev/null || echo "Nie można wylistować baz danych."
                else
                    echo "MongoDB nie jest uruchomiony lub wymaga autoryzacji."
                fi
            elif command -v mongosh &> /dev/null; then
                if mongosh --eval "db.adminCommand('ping')" 2>/dev/null; then
                    echo "MongoDB jest uruchomiony."
                    mongosh --eval "db.adminCommand('listDatabases')" 2>/dev/null || echo "Nie można wylistować baz danych."
                else
                    echo "MongoDB nie jest uruchomiony lub wymaga autoryzacji."
                fi
            fi
        fi
    else
        echo "MongoDB nie został znaleziony."
    fi
    echo '```'
} >> "$MAIN_REPORT"

# ---------- 8. DOCKER I KONTENERY ----------
{
    echo -e "\n## Docker i kontenery"
    echo "### Docker (jeśli istnieje)"
    echo '```'
    if command -v docker &> /dev/null; then
        docker --version
        if docker info 2>/dev/null; then
            echo "Docker jest uruchomiony."
            echo -e "\nListę kontenerów:"
            docker ps -a
            echo -e "\nListę obrazów:"
            docker images
            echo -e "\nVolumeny Docker:"
            docker volume ls
            echo -e "\nSieci Docker:"
            docker network ls
            echo -e "\nStatystyki użycia zasobów:"
            docker stats --no-stream
            echo -e "\nInformacje o używanej przestrzeni dyskowej:"
            docker system df -v
        else
            echo "Docker nie jest uruchomiony lub brak uprawnień."
        fi
    else
        echo "Docker nie został znaleziony."
    fi
    echo '```'
    echo "### Docker Compose (jeśli istnieje)"
    echo '```'
    if command -v docker-compose &> /dev/null; then
        docker-compose --version
        echo "Pliki docker-compose.yml znalezione w systemie:"
        find / -name "docker-compose.yml" -type f 2>/dev/null
    else
        echo "Docker Compose nie został znaleziony."
    fi
    echo '```'
    echo "### Kubernetes (jeśli istnieje)"
    echo '```'
    if command -v kubectl &> /dev/null; then
        kubectl version --client
        if kubectl get nodes 2>/dev/null; then
            echo "Kubernetes jest skonfigurowany."
            echo -e "\nPody:"
            kubectl get pods --all-namespaces
            echo -e "\nUsługi:"
            kubectl get services --all-namespaces
            echo -e "\nDeployments:"
            kubectl get deployments --all-namespaces
        else
            echo "Kubectl nie jest skonfigurowany lub brak uprawnień."
        fi
    else
        echo "Kubernetes nie został znaleziony."
    fi
    echo '```'
} >> "$MAIN_REPORT"

# ---------- 9. WIRTUALIZACJA ----------
{
    echo -e "\n## Wirtualizacja"
    echo "### KVM/QEMU (jeśli istnieje)"
    echo '```'
    if command -v virsh &> /dev/null; then
        echo "Wersja libvirt:"
        virsh version
        echo -e "\nListę maszyn wirtualnych:"
        virsh list --all
        echo -e "\nListę sieci wirtualnych:"
        virsh net-list --all
        echo -e "\nListę puli pamięci masowej:"
        virsh pool-list --all
    else
        echo "KVM/QEMU (virsh) nie został znaleziony."
    fi
    echo '```'
    echo "### VirtualBox (jeśli istnieje)"
    echo '```'
    if command -v VBoxManage &> /dev/null; then
        VBoxManage --version
        echo -e "\nListę maszyn wirtualnych:"
        VBoxManage list vms
        echo -e "\nListę uruchomionych maszyn wirtualnych:"
        VBoxManage list runningvms
    else
        echo "VirtualBox nie został znaleziony."
    fi
    echo '```'
    echo "### Proxmox (jeśli istnieje)"
    echo '```'
    if [ -e /etc/pve ]; then
        echo "Wersja Proxmox VE:"
        pveversion 2>/dev/null || echo "Nie można określić wersji Proxmox."
        if command -v pvesh &> /dev/null; then
            echo -e "\nListę węzłów:"
            pvesh get /nodes
            echo -e "\nListę maszyn wirtualnych:"
            pvesh get /cluster/resources --type vm
            echo -e "\nListę kontenerów LXC:"
            pvesh get /cluster/resources --type ct
            echo -e "\nStan klastra:"
            pvesh get /cluster/status
        fi
    else
        echo "Proxmox VE nie został znaleziony."
    fi
    echo '```'
} >> "$MAIN_REPORT"

# ---------- 10. ZAINSTALOWANE PAKIETY ----------
{
    echo -e "\n## Zainstalowane pakiety"
    echo "### Lista pakietów"
    echo '```'
    if command -v dpkg &> /dev/null; then
        echo "Top 50 największych pakietów Debian/Ubuntu:"
        dpkg-query -Wf '${Installed-Size}\t${Package}\n' | sort -n | tail -50
    elif command -v rpm &> /dev/null; then
        echo "Top 50 największych pakietów RPM:"
        rpm -qa --queryformat '%{size} %{name}-%{version}-%{release}\n' | sort -n | tail -50
    else
        echo "Nieznany system zarządzania pakietami."
    fi
    echo '```'
    echo "### Pakiety związane z aplikacjami web"
    echo '```'
    if command -v dpkg &> /dev/null; then
        dpkg -l | grep -E 'apache|nginx|php|mysql|mariadb|postgresql|redis|memcached|varnish|haproxy'
    elif command -v rpm &> /dev/null; then
        rpm -qa | grep -E 'apache|nginx|php|mysql|mariadb|postgresql|redis|memcached|varnish|haproxy'
    else
        echo "Nieznany system zarządzania pakietami."
    fi
    echo '```'
    echo "### Pakiety CI/CD i narzędzia deweloperskie"
    echo '```'
    if command -v dpkg &> /dev/null; then
        dpkg -l | grep -E 'jenkins|gitlab|docker|kubernetes|ansible|puppet|chef|terraform|vagrant'
    elif command -v rpm &> /dev/null; then
        rpm -qa | grep -E 'jenkins|gitlab|docker|kubernetes|ansible|puppet|chef|terraform|vagrant'
    else
        echo "Nieznany system zarządzania pakietami."
    fi
    echo '```'
} >> "$MAIN_REPORT"

# ---------- 11. ZADANIA CRON ----------
{
    echo -e "\n## Zadania cron"
    echo "### Crontab użytkowników"
    echo '```'
    for user in $(cut -f1 -d: /etc/passwd); do
        echo "Crontab dla użytkownika $user:"
        crontab -l -u "$user" 2>/dev/null || echo "  Brak zadań lub brak dostępu."
        echo ""
    done
    echo '```'
    echo "### Skrypty systemowe cron"
    echo '```'
    ls -la /etc/cron.d/ 2>/dev/null
    ls -la /etc/cron.daily/ 2>/dev/null
    ls -la /etc/cron.hourly/ 2>/dev/null
    ls -la /etc/cron.monthly/ 2>/dev/null
    ls -la /etc/cron.weekly/ 2>/dev/null
    echo '```'
    echo "### Zawartość /etc/crontab"
    echo '```'
    cat /etc/crontab 2>/dev/null
    echo '```'
} >> "$MAIN_REPORT"

# ---------- 12. UŻYTKOWNICY SYSTEMU ----------
{
    echo -e "\n## Użytkownicy systemu"
    echo "### Użytkownicy z UID >= 1000"
    echo '```'
    awk -F: '$3 >= 1000 && $3 != 65534 {print $1, $3, $4, $6, $7}' /etc/passwd
    echo '```'
    echo "### Grupy"
    echo '```'
    getent group | grep -E ":[1-9][0-9]{3}"
    echo '```'
    echo "### Zalogowani użytkownicy"
    echo '```'
    who
    echo '```'
    echo "### Historia logowań"
    echo '```'
    last | head -20
    echo '```'
    echo "### Aktywne sesje SSH"
    echo '```'
    ps aux | grep -i ssh | grep -v grep
    echo '```'
} >> "$MAIN_REPORT"

# ---------- 13. WYDAJNOŚĆ ----------
{
    echo -e "\n## Wydajność"
    echo "### Metryki obciążenia CPU"
    echo '```'
    # Zapisz wynik do pliku w katalogu wydajności
    mpstat 1 5 > "$PERFORMANCE_DIR/mpstat.txt" 2>/dev/null || echo "Narzędzie mpstat niedostępne"
    echo "Zapisano szczegółowy raport do $PERFORMANCE_DIR/mpstat.txt"
    echo '```'
    echo "### Metryki obciążenia pamięci"
    echo '```'
    # Zapisz wynik do pliku w katalogu wydajności
    vmstat 1 5 > "$PERFORMANCE_DIR/vmstat.txt" 2>/dev/null || echo "Narzędzie vmstat niedostępne"
    echo "Zapisano szczegółowy raport do $PERFORMANCE_DIR/vmstat.txt"
    echo '```'
    echo "### Metryki obciążenia dysku"
    echo '```'
    # Zapisz wynik do pliku w katalogu wydajności
    iostat -xdh 1 5 > "$PERFORMANCE_DIR/iostat.txt" 2>/dev/null || echo "Narzędzie iostat niedostępne"
    echo "Zapisano szczegółowy raport do $PERFORMANCE_DIR/iostat.txt"
    echo '```'
    echo "### Procesy używające najwięcej CPU"
    echo '```'
    ps aux --sort=-%cpu | head -10
    echo '```'
    echo "### Procesy używające najwięcej pamięci"
    echo '```'
    ps aux --sort=-%mem | head -10
    echo '```'
} >> "$MAIN_REPORT"

# ---------- 14. ZASOBY WWW ----------
{
    echo -e "\n## Zasoby WWW"

    echo "### Wirtualne hosty Apache (jeśli istnieją)"
    echo '```'
    if [ -d /etc/apache2/sites-enabled ]; then
        echo "Skonfigurowane witryny Apache2:"
        ls -la /etc/apache2/sites-enabled/
        for site in /etc/apache2/sites-enabled/*; do
            echo -e "\n--- $site ---"
            grep -E 'ServerName|ServerAlias|DocumentRoot' "$site" 2>/dev/null
        done
    elif [ -d /etc/httpd/conf.d ]; then
        echo "Skonfigurowane witryny httpd (CentOS/RHEL):"
        ls -la /etc/httpd/conf.d/
        for site in /etc/httpd/conf.d/*.conf; do
            echo -e "\n--- $site ---"
            grep -E 'ServerName|ServerAlias|DocumentRoot' "$site" 2>/dev/null
        done
    else
        echo "Nie znaleziono konfiguracji Apache."
    fi
    echo '```'

    echo "### Konfiguracje Nginx (jeśli istnieją)"
    echo '```'
    if [ -d /etc/nginx/sites-enabled ]; then
        echo "Skonfigurowane witryny Nginx:"
        ls -la /etc/nginx/sites-enabled/
        for site in /etc/nginx/sites-enabled/*; do
            echo -e "\n--- $site ---"
            grep -E 'server_name|root|location|proxy_pass' "$site" 2>/dev/null
        done
    elif [ -d /etc/nginx/conf.d ]; then
        echo "Skonfigurowane witryny Nginx (conf.d):"
        ls -la /etc/nginx/conf.d/
        for site in /etc/nginx/conf.d/*.conf; do
            echo -e "\n--- $site ---"
            grep -E 'server_name|root|location|proxy_pass' "$site" 2>/dev/null
        done
    else
        echo "Nie znaleziono konfiguracji Nginx."
    fi
    echo '```'

    echo "### Struktura katalogów WWW"
    echo '```'
    # Typowe lokalizacje dla stron WWW
    for www_dir in /var/www /usr/share/nginx/html /var/www/html /srv/www; do
        if [ -d "$www_dir" ]; then
            echo "Zawartość $www_dir:"
            ls -la "$www_dir"
            echo "Największe podkatalogi w $www_dir:"
            du -h --max-depth=1 "$www_dir" 2>/dev/null | sort -hr | head -10
        fi
    done
    echo '```'
} >> "$MAIN_REPORT"

# ---------- 15. PLIKI KONFIGURACYJNE ----------
{
    echo -e "\n## Pliki konfiguracyjne"

    # Funkcja do kopiowania plików konfiguracyjnych
    copy_config() {
        local source="$1"
        local dest="$2"
        if [ -f "$source" ]; then
            mkdir -p "$(dirname "$dest")"
            cp "$source" "$dest"
            echo "Skopiowano: $source -> $dest"
        fi
    }

    # Kopiowanie ważnych plików konfiguracyjnych
    copy_config "/etc/ssh/sshd_config" "$CONFIGS_DIR/ssh/sshd_config"

    # Apache
    if [ -d /etc/apache2 ]; then
        mkdir -p "$CONFIGS_DIR/apache2"
        cp -r /etc/apache2/sites-enabled "$CONFIGS_DIR/apache2/" 2>/dev/null
        cp /etc/apache2/apache2.conf "$CONFIGS_DIR/apache2/" 2>/dev/null
    elif [ -d /etc/httpd ]; then
        mkdir -p "$CONFIGS_DIR/httpd"
        cp -r /etc/httpd/conf.d "$CONFIGS_DIR/httpd/" 2>/dev/null
        cp /etc/httpd/conf/httpd.conf "$CONFIGS_DIR/httpd/" 2>/dev/null
    fi

    # Nginx
    if [ -d /etc/nginx ]; then
        mkdir -p "$CONFIGS_DIR/nginx"
        cp -r /etc/nginx/sites-enabled "$CONFIGS_DIR/nginx/" 2>/dev/null
        cp -r /etc/nginx/conf.d "$CONFIGS_DIR/nginx/" 2>/dev/null
        cp /etc/nginx/nginx.conf "$CONFIGS_DIR/nginx/" 2>/dev/null
    fi

    # PHP
    if [ -d /etc/php ]; then
        mkdir -p "$CONFIGS_DIR/php"
        find /etc/php -name "php.ini" -exec cp {} "$CONFIGS_DIR/php/" \; 2>/dev/null
    fi

    # MySQL/MariaDB
    copy_config "/etc/mysql/my.cnf" "$CONFIGS_DIR/mysql/my.cnf"
    copy_config "/etc/my.cnf" "$CONFIGS_DIR/mysql/my.cnf"

    # PostgreSQL
    if [ -d /etc/postgresql ]; then
        mkdir -p "$CONFIGS_DIR/postgresql"
        find /etc/postgresql -name "postgresql.conf" -exec cp {} "$CONFIGS_DIR/postgresql.conf" ; 2>/dev/null find /etc/postgresql -name "pg_hba.conf" -exec cp {} "$CONFIGS_DIR/postgresql/" ; 2>/dev/null 
	fi

	# Docker
	if [ -d /etc/docker ]; then
		mkdir -p "$CONFIGS_DIR/docker"
		cp -r /etc/docker/* "$CONFIGS_DIR/docker/" 2>/dev/null
	fi

	# Firewall
	copy_config "/etc/iptables/rules.v4" "$CONFIGS_DIR/firewall/iptables_v4.rules"
	copy_config "/etc/iptables/rules.v6" "$CONFIGS_DIR/firewall/iptables_v6.rules"

	# UFW
	if command -v ufw &> /dev/null; then
		mkdir -p "$CONFIGS_DIR/ufw"
		ufw status verbose > "$CONFIGS_DIR/ufw/ufw_status.txt"
		cp -r /etc/ufw/* "$CONFIGS_DIR/ufw/" 2>/dev/null
	fi

	# Firewalld
	if command -v firewall-cmd &> /dev/null; then
		mkdir -p "$CONFIGS_DIR/firewalld"
		firewall-cmd --list-all > "$CONFIGS_DIR/firewalld/firewalld_config.txt"
	fi

	# System services
	if [ -d /etc/systemd ]; then
		mkdir -p "$CONFIGS_DIR/systemd"
		cp -r /etc/systemd/system/*.service "$CONFIGS_DIR/systemd/" 2>/dev/null
		cp -r /etc/systemd/system/*.timer "$CONFIGS_DIR/systemd/" 2>/dev/null
	fi

	echo "Lista skopiowanych plików konfiguracyjnych:"
	find "$CONFIGS_DIR" -type f | sort
    echo '```'
} >> "$MAIN_REPORT"

# ---------- KOMPRESJA WYNIKÓW ----------
log "Pakowanie wyników inwentaryzacji..."
tar -czf "${OUTPUT_DIR}.tar.gz" "$OUTPUT_DIR"

# ---------- PODSUMOWANIE ----------
log "Inwentaryzacja zakończona. Wyniki zostały zapisane w katalogu $OUTPUT_DIR i spakowane do ${OUTPUT_DIR}.tar.gz"
echo "=============================================="
echo "Inwentaryzacja serwera zakończona pomyślnie!"
echo "=============================================="
echo "Wyniki zostały zapisane w katalogu: $OUTPUT_DIR"
echo "Spakowana kopia: ${OUTPUT_DIR}.tar.gz"
echo "Główny raport: $MAIN_REPORT"
echo "=============================================="
