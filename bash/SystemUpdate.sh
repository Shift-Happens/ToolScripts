#!/bin/bash

# ========================================================
# System Update Script dla różnych dystrybucji Linuxa
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
 _____           _                    _   _           _       _       
/  ___|         | |                  | | | |         | |     | |      
\ `--. _   _ ___| |_ ___ _ __ ___    | | | |_ __   __| | __ _| |_ ___ 
 `--. \ | | / __| __/ _ \ '_ ` _ \   | | | | '_ \ / _` |/ _` | __/ _ \
/\__/ / |_| \__ \ ||  __/ | | | | |  | |_| | |_) | (_| | (_| | ||  __/
\____/ \__, |___/\__\___|_| |_| |_|   \___/| .__/ \__,_|\__,_|\__\___|
        __/ |                              | |                         
       |___/                               |_|                         
EOF
echo -e "${NC}"

# Sprawdzanie uprawnień roota
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[!] Ten skrypt wymaga uprawnień administratora.${NC}"
  echo -e "${YELLOW}[*] Uruchom ponownie z sudo: sudo $0${NC}"
  exit 1
fi

# Funkcja do wykrywania menedżera pakietów
detect_package_manager() {
  if command -v apt &> /dev/null; then
    PM="apt"
    echo -e "${GREEN}[✓] Wykryto system oparty na Debianie (Debian/Ubuntu/Mint)${NC}"
  elif command -v dnf &> /dev/null; then
    PM="dnf"
    echo -e "${GREEN}[✓] Wykryto system oparty na RHEL (Fedora/CentOS/RHEL)${NC}"
  elif command -v yum &> /dev/null; then
    PM="yum"
    echo -e "${GREEN}[✓] Wykryto starszy system oparty na RHEL (CentOS/RHEL)${NC}"
  elif command -v pacman &> /dev/null; then
    PM="pacman"
    echo -e "${GREEN}[✓] Wykryto system Arch Linux${NC}"
  elif command -v zypper &> /dev/null; then
    PM="zypper"
    echo -e "${GREEN}[✓] Wykryto system openSUSE${NC}"
  else
    echo -e "${RED}[✗] Nie można wykryć menedżera pakietów. Skrypt nie jest kompatybilny z tą dystrybucją.${NC}"
    exit 1
  fi
}

# Funkcja do sprawdzania aktualizacji
check_updates() {
  echo -e "${BLUE}[*] Sprawdzanie dostępnych aktualizacji...${NC}"
  echo ""
  
  case $PM in
    apt)
      apt update -q
      UPDATES=$(apt list --upgradable 2>/dev/null | grep -v "Listing..." | wc -l)
      if [ "$UPDATES" -gt 0 ]; then
        echo -e "${YELLOW}[!] Dostępne aktualizacje: ${UPDATES}${NC}"
        echo -e "${CYAN}[*] Lista pakietów do aktualizacji:${NC}"
        apt list --upgradable 2>/dev/null | grep -v "Listing..." | awk -F/ '{print "  - " $1}'
      else
        echo -e "${GREEN}[✓] System jest aktualny.${NC}"
        exit 0
      fi
      ;;
    dnf|yum)
      UPDATES=$($PM check-update -q | grep -v "^$" | wc -l)
      if [ "$UPDATES" -gt 0 ]; then
        echo -e "${YELLOW}[!] Dostępne aktualizacje: ${UPDATES}${NC}"
        echo -e "${CYAN}[*] Lista pakietów do aktualizacji:${NC}"
        $PM check-update | grep -v "^Last metadata" | grep -v "^$" | awk '{print "  - " $1}'
      else
        echo -e "${GREEN}[✓] System jest aktualny.${NC}"
        exit 0
      fi
      ;;
    pacman)
      pacman -Sy >/dev/null
      UPDATES=$(pacman -Qu | wc -l)
      if [ "$UPDATES" -gt 0 ]; then
        echo -e "${YELLOW}[!] Dostępne aktualizacje: ${UPDATES}${NC}"
        echo -e "${CYAN}[*] Lista pakietów do aktualizacji:${NC}"
        pacman -Qu | awk '{print "  - " $1 " (" $2 " -> " $4 ")"}'
      else
        echo -e "${GREEN}[✓] System jest aktualny.${NC}"
        exit 0
      fi
      ;;
    zypper)
      zypper refresh >/dev/null
      UPDATES=$(zypper list-updates | grep "|" | grep -v "^v" | wc -l)
      if [ "$UPDATES" -gt 0 ]; then
        echo -e "${YELLOW}[!] Dostępne aktualizacje: ${UPDATES}${NC}"
        echo -e "${CYAN}[*] Lista pakietów do aktualizacji:${NC}"
        zypper list-updates | grep "|" | grep -v "^v" | awk -F"|" '{print "  - " $3 " (" $4 " -> " $5 ")"}'
      else
        echo -e "${GREEN}[✓] System jest aktualny.${NC}"
        exit 0
      fi
      ;;
  esac
}

# Funkcja do instalacji aktualizacji
install_updates() {
  echo ""
  echo -e "${MAGENTA}╔════════════════════════════════════════════╗${NC}"
  echo -e "${MAGENTA}║ Czy chcesz zainstalować aktualizacje? [T/n] ║${NC}"
  echo -e "${MAGENTA}╚════════════════════════════════════════════╝${NC}"
  read -r answer
  
  # Domyślnie tak jeśli użytkownik wciśnie Enter
  if [[ "$answer" =~ ^[Tt]$ ]] || [[ -z "$answer" ]]; then
    echo -e "${BLUE}[*] Rozpoczynanie aktualizacji...${NC}"
    echo ""
    
    case $PM in
      apt)
        apt upgrade -y
        ;;
      dnf|yum)
        $PM upgrade -y
        ;;
      pacman)
        pacman -Su --noconfirm
        ;;
      zypper)
        zypper update -y
        ;;
    esac
    
    echo ""
    echo -e "${GREEN}[✓] Aktualizacja zakończona pomyślnie.${NC}"
  else
    echo -e "${YELLOW}[!] Aktualizacja anulowana przez użytkownika.${NC}"
  fi
}

# Główna funkcja
main() {
  detect_package_manager
  check_updates
  install_updates
}

# Uruchomienie skryptu
main