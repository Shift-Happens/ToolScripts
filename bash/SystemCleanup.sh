#!/bin/bash

# ========================================================
# SystemCleanup.sh - Skrypt do czyszczenia systemu Linux
# ========================================================

# Kolory do formatowania
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ASCII art
echo -e "${CYAN}"
cat << "EOF"
  _____           _                  _____ _                               
 / ____|         | |                / ____| |                              
| (___  _   _ ___| |_ ___ _ __ ___ | |    | | ___  __ _ _ __  _   _ _ __  
 \___ \| | | / __| __/ _ \ '_ ` _ \| |    | |/ _ \/ _` | '_ \| | | | '_ \ 
 ____) | |_| \__ \ ||  __/ | | | | | |____| |  __/ (_| | | | | |_| | |_) |
|_____/ \__, |___/\__\___|_| |_| |_|\_____|_|\___|\__,_|_| |_|\__,_| .__/ 
         __/ |                                                     | |    
        |___/                                                      |_|    
EOF
echo -e "${NC}"

# Sprawdzanie uprawnień roota
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[!] Ten skrypt wymaga uprawnień administratora.${NC}"
  echo -e "${YELLOW}[*] Uruchom ponownie z sudo: sudo $0${NC}"
  exit 1
fi

# Funkcja do wyświetlania menu
show_menu() {
  echo -e "${BLUE}╔════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║          WYBIERZ OPCJE CZYSZCZENIA         ║${NC}"
  echo -e "${BLUE}╠════════════════════════════════════════════╣${NC}"
  echo -e "${BLUE}║ ${NC}1. Wyczyść pamięć podręczną APT            ${BLUE}║${NC}"
  echo -e "${BLUE}║ ${NC}2. Wyczyść pamięć podręczną pakietów       ${BLUE}║${NC}"
  echo -e "${BLUE}║ ${NC}3. Usuń stare jądra systemu                ${BLUE}║${NC}"
  echo -e "${BLUE}║ ${NC}4. Wyczyść kosz                            ${BLUE}║${NC}"
  echo -e "${BLUE}║ ${NC}5. Wyczyść pliki tymczasowe                ${BLUE}║${NC}"
  echo -e "${BLUE}║ ${NC}6. Wyczyść logi systemowe                  ${BLUE}║${NC}"
  echo -e "${BLUE}║ ${NC}7. Wyczyść nieużywane pakiety (autoremove) ${BLUE}║${NC}"
  echo -e "${BLUE}║ ${NC}8. Wyczyść wszystko                        ${BLUE}║${NC}"
  echo -e "${BLUE}║ ${NC}9. Wyjdź                                   ${BLUE}║${NC}"
  echo -e "${BLUE}╚════════════════════════════════════════════╝${NC}"
  echo -e "${YELLOW}Wybierz opcję (1-9):${NC} "
  read -r option
}

# Funkcja do sprawdzania i wyświetlania rozmiaru przed czyszczeniem
check_size() {
  local path=$1
  local desc=$2
  
  if [ -e "$path" ]; then
    local size=$(du -sh "$path" 2>/dev/null | cut -f1)
    echo -e "${YELLOW}[!] Znaleziono ${desc}: ${size}${NC}"
    return 0
  else
    echo -e "${GREEN}[✓] Brak ${desc} do wyczyszczenia.${NC}"
    return 1
  fi
}

# Funkcja potwierdzenia
confirm_action() {
  local desc=$1
  echo -e "${MAGENTA}Czy na pewno chcesz wyczyścić ${desc}? [t/N]:${NC} "
  read -r answer
  
  if [[ "$answer" =~ ^[Tt]$ ]]; then
    return 0
  else
    echo -e "${YELLOW}[!] Pominięto czyszczenie ${desc}.${NC}"
    return 1
  fi
}

# Funkcja do wyświetlania postępu
show_progress() {
  local desc=$1
  echo -ne "${BLUE}[*] Czyszczenie ${desc}...${NC}"
  sleep 0.5
  echo -e "${GREEN} Zakończone!${NC}"
}

# Funkcja czyszczenia pamięci podręcznej APT
clean_apt_cache() {
  if check_size "/var/cache/apt/archives" "pamięci podręcznej APT"; then
    if confirm_action "pamięć podręczną APT"; then
      apt-get clean
      show_progress "pamięci podręcznej APT"
    fi
  fi
}

# Funkcja czyszczenia pamięci podręcznej pakietów
clean_package_cache() {
  # Sprawdzenie menedżera pakietów
  if command -v apt &> /dev/null; then
    if check_size "/var/lib/apt/lists" "list pakietów APT"; then
      if confirm_action "listy pakietów APT"; then
        apt-get update --fix-missing
        show_progress "list pakietów APT"
      fi
    fi
  elif command -v pacman &> /dev/null; then
    if check_size "/var/cache/pacman/pkg" "pamięci podręcznej pacman"; then
      if confirm_action "pamięci podręcznej pacman"; then
        pacman -Sc --noconfirm
        show_progress "pamięci podręcznej pacman"
      fi
    fi
  elif command -v dnf &> /dev/null || command -v yum &> /dev/null; then
    if command -v dnf &> /dev/null; then
      if confirm_action "pamięci podręcznej DNF"; then
        dnf clean all
        show_progress "pamięci podręcznej DNF"
      fi
    else
      if confirm_action "pamięci podręcznej YUM"; then
        yum clean all
        show_progress "pamięci podręcznej YUM"
      fi
    fi
  else
    echo -e "${YELLOW}[!] Nie rozpoznano systemu pakietów do czyszczenia.${NC}"
  fi
}

# Funkcja usuwania starych jąder systemu
clean_old_kernels() {
  if command -v apt &> /dev/null && command -v dpkg &> /dev/null; then
    current_kernel=$(uname -r)
    old_kernels=$(dpkg --list | grep linux-image | grep -v "$current_kernel" | awk '{print $2}')
    
    if [ -n "$old_kernels" ]; then
      echo -e "${YELLOW}[!] Znaleziono stare jądra systemu:${NC}"
      echo "$old_kernels" | while read -r kernel; do
        echo -e "${CYAN}  - $kernel${NC}"
      done
      
      if confirm_action "stare jądra systemu"; then
        echo "$old_kernels" | while read -r kernel; do
          echo -e "${BLUE}[*] Usuwanie ${kernel}...${NC}"
          apt-get purge -y "$kernel"
        done
        
        apt-get autoremove -y
        update-grub 2>/dev/null || true
        show_progress "starych jąder systemu"
      fi
    else
      echo -e "${GREEN}[✓] Brak starych jąder systemu do usunięcia.${NC}"
    fi
  else
    echo -e "${YELLOW}[!] Automatyczne usuwanie starych jąder nie jest obsługiwane w tej dystrybucji.${NC}"
  fi
}

# Funkcja czyszczenia kosza
clean_trash() {
  # Sprawdzamy różne lokalizacje kosza
  trash_locations=(
    "/home/*/.local/share/Trash"
    "/root/.local/share/Trash"
  )
  
  found=false
  for loc in "${trash_locations[@]}"; do
    for dir in $loc; do
      if [ -d "$dir" ]; then
        size=$(du -sh "$dir" 2>/dev/null | cut -f1)
        echo -e "${YELLOW}[!] Znaleziono kosz: ${dir} (${size})${NC}"
        found=true
      fi
    done
  done
  
  if [ "$found" = true ]; then
    if confirm_action "zawartość kosza"; then
      for loc in "${trash_locations[@]}"; do
        for dir in $loc; do
          if [ -d "$dir/files" ]; then
            rm -rf "${dir}/files"/* 2>/dev/null
          fi
          if [ -d "$dir/info" ]; then
            rm -rf "${dir}/info"/* 2>/dev/null
          fi
        done
      done
      show_progress "kosza"
    fi
  else
    echo -e "${GREEN}[✓] Kosz jest już pusty.${NC}"
  fi
}

# Funkcja czyszczenia plików tymczasowych
clean_temp_files() {
  temp_locations=(
    "/tmp"
    "/var/tmp"
  )
  
  for loc in "${temp_locations[@]}"; do
    if check_size "$loc" "plików tymczasowych w $loc"; then
      if confirm_action "pliki tymczasowe w $loc"; then
        # Nie usuwamy samego katalogu, tylko jego zawartość
        find "$loc" -type f -delete 2>/dev/null
        find "$loc" -type d -empty -delete 2>/dev/null
        show_progress "plików tymczasowych w $loc"
      fi
    fi
  done
}

# Funkcja czyszczenia logów systemowych
clean_system_logs() {
  if check_size "/var/log" "logów systemowych"; then
    if confirm_action "logi systemowe"; then
      # Bezpieczne czyszczenie logów (pozostawiamy puste pliki)
      find /var/log -type f -name "*.log" -exec truncate -s 0 {} \; 2>/dev/null
      find /var/log -type f -name "*.gz" -delete 2>/dev/null
      find /var/log -type f -name "*.old" -delete 2>/dev/null
      find /var/log -type f -name "*.1" -delete 2>/dev/null
      journalctl --vacuum-time=1d 2>/dev/null || true
      show_progress "logów systemowych"
    fi
  fi
}

# Funkcja usuwania nieużywanych pakietów
clean_unused_packages() {
  if command -v apt &> /dev/null; then
    echo -e "${BLUE}[*] Sprawdzanie nieużywanych pakietów...${NC}"
    unused_packages=$(apt-get --dry-run autoremove | grep -Po '^Remv \K[^ ]+')
    
    if [ -n "$unused_packages" ]; then
      echo -e "${YELLOW}[!] Znaleziono nieużywane pakiety:${NC}"
      echo "$unused_packages" | while read -r package; do
        echo -e "${CYAN}  - $package${NC}"
      done
      
      if confirm_action "nieużywane pakiety"; then
        apt-get autoremove -y
        show_progress "nieużywanych pakietów"
      fi
    else
      echo -e "${GREEN}[✓] Brak nieużywanych pakietów do usunięcia.${NC}"
    fi
  elif command -v pacman &> /dev/null; then
    if confirm_action "osierocone pakiety (pacman)"; then
      pacman -Rns $(pacman -Qtdq) 2>/dev/null || echo -e "${GREEN}[✓] Brak osieroconych pakietów.${NC}"
      show_progress "osieroconych pakietów"
    fi
  elif command -v dnf &> /dev/null; then
    if confirm_action "nieużywane pakiety (dnf)"; then
      dnf autoremove -y
      show_progress "nieużywanych pakietów"
    fi
  else
    echo -e "${YELLOW}[!] Czyszczenie nieużywanych pakietów nie jest obsługiwane w tej dystrybucji.${NC}"
  fi
}

# Funkcja czyszczenia wszystkiego
clean_all() {
  echo -e "${MAGENTA}╔════════════════════════════════════════════╗${NC}"
  echo -e "${MAGENTA}║  Czy na pewno chcesz wyczyścić WSZYSTKO?   ║${NC}"
  echo -e "${MAGENTA}║  Zostaną wykonane wszystkie operacje.      ║${NC}"
  echo -e "${MAGENTA}╚════════════════════════════════════════════╝${NC}"
  echo -e "${RED}UWAGA: To może usunąć ważne pliki, jeśli nie wiesz co robisz!${NC}"
  echo -e "${MAGENTA}Kontynuować? [t/N]:${NC} "
  read -r answer
  
  if [[ "$answer" =~ ^[Tt]$ ]]; then
    clean_apt_cache
    clean_package_cache
    clean_old_kernels
    clean_trash
    clean_temp_files
    clean_system_logs
    clean_unused_packages
    
    echo -e "${GREEN}╔════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║      Czyszczenie systemu zakończone!       ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════╝${NC}"
  else
    echo -e "${YELLOW}[!] Anulowano czyszczenie wszystkiego.${NC}"
  fi
}

# Główna funkcja
main() {
  while true; do
    show_menu
    
    case $option in
      1)
        clean_apt_cache
        ;;
      2)
        clean_package_cache
        ;;
      3)
        clean_old_kernels
        ;;
      4)
        clean_trash
        ;;
      5)
        clean_temp_files
        ;;
      6)
        clean_system_logs
        ;;
      7)
        clean_unused_packages
        ;;
      8)
        clean_all
        ;;
      9)
        echo -e "${GREEN}Do widzenia!${NC}"
        exit 0
        ;;
      *)
        echo -e "${RED}[!] Nieprawidłowa opcja. Spróbuj ponownie.${NC}"
        ;;
    esac
    
    echo ""
    echo -e "${YELLOW}Naciśnij Enter, aby kontynuować...${NC}"
    read -r
    clear
  done
}

# Uruchomienie skryptu
main