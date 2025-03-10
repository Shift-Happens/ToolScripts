#!/bin/bash

# ========================================================
# DockerCleanup.sh - Skrypt do czyszczenia zasobów Docker
# ========================================================
## Tryb testowy - pokazuje co zostałoby usunięte
#./DockerCleanup.sh --dry-run
#
## Usunięcie starych kontenerów (ponad 7 dni)
#./DockerCleanup.sh --days 7
#
## Pełne czyszczenie (ostrożnie!)
#./DockerCleanup.sh --yes --networks --volumes --all-images

# Kolory do formatowania
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
ORANGE='\033[0;33m'
NC='\033[0m' # No Color

# Zmienne globalne
INTERACTIVE=true
DRY_RUN=false
FORCE_MODE=false
QUIET_MODE=false
PRUNE_NETWORKS=false
PRUNE_VOLUMES=false
DANGLING_ONLY=true
DELETE_ALL_IMAGES=false
DAYS_OLD=0

# Banner ASCII
print_banner() {
  echo -e "${BLUE}"
  cat << "EOF"
  _____             _                _____ _                               
 |  __ \           | |              / ____| |                              
 | |  | | ___   ___| | _____ _ __  | |    | | ___  __ _ _ __  _   _ _ __   
 | |  | |/ _ \ / __| |/ / _ \ '__| | |    | |/ _ \/ _` | '_ \| | | | '_ \  
 | |__| | (_) | (__|   <  __/ |    | |____| |  __/ (_| | | | | |_| | |_) | 
 |_____/ \___/ \___|_|\_\___|_|     \_____|_|\___|\__,_|_| |_|\__,_| .__/  
                                                                    | |     
                                                                    |_|     
EOF
  echo -e "${NC}"
  echo -e "${CYAN}Skrypt do czyszczenia zbędnych zasobów Docker${NC}"
  echo
}

# Funkcja wyświetlająca pomoc
show_help() {
  echo -e "${GREEN}DockerCleanup.sh${NC} - narzędzie do czyszczenia zasobów Docker"
  echo
  echo -e "${YELLOW}Użycie:${NC}"
  echo -e "  $0 [opcje]"
  echo
  echo -e "${YELLOW}Opcje:${NC}"
  echo -e "  ${GREEN}-n, --dry-run${NC}         Tryb testowy - pokazuje co zostałoby usunięte bez faktycznego usuwania"
  echo -e "  ${GREEN}-y, --yes${NC}             Automatycznie potwierdza wszystkie operacje (nieinteraktywny)"
  echo -e "  ${GREEN}-f, --force${NC}           Wymusza usuwanie (np. dla działających kontenerów)"
  echo -e "  ${GREEN}-q, --quiet${NC}           Cichy tryb - minimalna ilość komunikatów"
  echo -e "  ${GREEN}--networks${NC}            Wyczyść również sieci Docker"
  echo -e "  ${GREEN}--volumes${NC}             Wyczyść również wolumeny Docker (UWAGA: utrata danych!)"
  echo -e "  ${GREEN}--all-images${NC}          Usuń wszystkie obrazy, nie tylko niepodłączone"
  echo -e "  ${GREEN}--days DAYS${NC}           Usuń kontenery starsze niż DAYS dni"
  echo -e "  ${GREEN}-h, --help${NC}            Pokaż tę pomoc"
  echo
  echo -e "${YELLOW}Przykłady:${NC}"
  echo -e "  $0 --dry-run                      # Pokazuje co zostałoby usunięte"
  echo -e "  $0 --yes --networks --volumes     # Usuwa wszystko bez pytania (ostrożnie!)"
  echo -e "  $0 --days 7                       # Usuń kontenery starsze niż 7 dni"
  echo
}

# Parsowanie argumentów
parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      -h|--help)
        show_help
        exit 0
        ;;
      -n|--dry-run)
        DRY_RUN=true
        shift
        ;;
      -y|--yes)
        INTERACTIVE=false
        shift
        ;;
      -f|--force)
        FORCE_MODE=true
        shift
        ;;
      -q|--quiet)
        QUIET_MODE=true
        shift
        ;;
      --networks)
        PRUNE_NETWORKS=true
        shift
        ;;
      --volumes)
        PRUNE_VOLUMES=true
        shift
        ;;
      --all-images)
        DANGLING_ONLY=false
        shift
        ;;
      --days)
        DAYS_OLD="$2"
        shift 2
        ;;
      *)
        echo -e "${RED}Nieznana opcja: $1${NC}"
        show_help
        exit 1
        ;;
    esac
  done
}

# Sprawdzenie czy Docker jest zainstalowany i działa
check_docker() {
  if ! command -v docker &> /dev/null; then
    echo -e "${RED}[✗] Docker nie jest zainstalowany.${NC}"
    exit 1
  fi

  if ! docker info &> /dev/null; then
    echo -e "${RED}[✗] Docker nie jest uruchomiony lub brak uprawnień do jego użycia.${NC}"
    echo -e "${YELLOW}[!] Uruchom ponownie z sudo lub dodaj użytkownika do grupy docker.${NC}"
    exit 1
  fi

  echo -e "${GREEN}[✓] Docker działa poprawnie.${NC}"
}

# Funkcja potwierdzenia
confirm_action() {
  local message=$1
  local default=${2:-"n"} # Domyślnie "n" (nie)
  
  if [ "$INTERACTIVE" = false ]; then
    return 0
  fi
  
  if [ "$default" = "y" ]; then
    read -p "$message [T/n]: " answer
    [[ -z "$answer" || "$answer" =~ ^[Tt]$ ]]
  else
    read -p "$message [t/N]: " answer
    [[ "$answer" =~ ^[Tt]$ ]]
  fi
}

# Funkcja formatująca rozmiar
format_size() {
  numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || echo "0B"
}

# Funkcja formatująca czas
format_time() {
  local seconds=$1
  
  if [ $seconds -lt 60 ]; then
    echo "${seconds}s"
  elif [ $seconds -lt 3600 ]; then
    echo "$((seconds / 60))m $((seconds % 60))s"
  elif [ $seconds -lt 86400 ]; then
    echo "$((seconds / 3600))h $(((seconds % 3600) / 60))m"
  else
    echo "$((seconds / 86400))d $((seconds % 86400 / 3600))h"
  fi
}

# Funkcja wykonująca komendę lub symulująca jej wykonanie w trybie dry-run
execute_command() {
  local command=$1
  local description=$2
  local force=${3:-false}
  
  if [ "$DRY_RUN" = true ]; then
    if [ "$QUIET_MODE" = false ]; then
      echo -e "${YELLOW}[DRY-RUN] Byłaby wykonana komenda:${NC} $command"
    fi
    return 0
  fi
  
  if [ "$force" = true ]; then
    command="$command --force"
  fi
  
  if [ "$QUIET_MODE" = false ]; then
    echo -e "${BLUE}[*] $description...${NC}"
  fi
  
  # Wykonaj komendę i sprawdź czy się powiodła
  if output=$(eval "$command" 2>&1); then
    if [ "$QUIET_MODE" = false ]; then
      echo -e "${GREEN}[✓] $description zakończone pomyślnie.${NC}"
      [ -n "$output" ] && echo "$output"
    fi
    return 0
  else
    if [ "$QUIET_MODE" = false ]; then
      echo -e "${RED}[✗] $description nie powiodło się.${NC}"
      [ -n "$output" ] && echo "$output"
    fi
    return 1
  fi
}

# Funkcja sprawdzająca zasoby Docker
check_docker_resources() {
  if [ "$QUIET_MODE" = false ]; then
    echo -e "\n${CYAN}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              ZASOBY DOCKER                        ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════╝${NC}"
  fi

  # Zatrzymane kontenery
  STOPPED_CONTAINERS=$(docker ps -q -f "status=exited" | wc -l)
  if [ "$QUIET_MODE" = false ]; then
    echo -e "${YELLOW}Zatrzymane kontenery:${NC} $STOPPED_CONTAINERS"
  fi

  # Nieużywane obrazy
  DANGLING_IMAGES=$(docker images -q -f "dangling=true" | wc -l)
  ALL_IMAGES=$(docker images -q | wc -l)
  if [ "$QUIET_MODE" = false ]; then
    echo -e "${YELLOW}Niepodłączone obrazy:${NC} $DANGLING_IMAGES"
    echo -e "${YELLOW}Wszystkie obrazy:${NC} $ALL_IMAGES"
  fi

  # Nieużywane wolumeny
  DANGLING_VOLUMES=$(docker volume ls -q -f "dangling=true" | wc -l)
  ALL_VOLUMES=$(docker volume ls -q | wc -l)
  if [ "$QUIET_MODE" = false ]; then
    echo -e "${YELLOW}Niepodłączone wolumeny:${NC} $DANGLING_VOLUMES"
    echo -e "${YELLOW}Wszystkie wolumeny:${NC} $ALL_VOLUMES"
  fi

  # Nieużywane sieci
  CUSTOM_NETWORKS=$(docker network ls --filter "type=custom" -q | wc -l)
  if [ "$QUIET_MODE" = false ]; then
    echo -e "${YELLOW}Niestandardowe sieci:${NC} $CUSTOM_NETWORKS"
  fi

  # Informacje o wykorzystaniu dysku
  if [ "$QUIET_MODE" = false ] && command -v docker &> /dev/null; then
    DISK_USAGE=$(docker system df -v 2>/dev/null)
    TOTAL_SIZE=$(echo "$DISK_USAGE" | grep "Total" | awk '{print $4}')
    
    if [ -n "$TOTAL_SIZE" ]; then
      echo -e "${YELLOW}Całkowite zużycie dysku:${NC} $TOTAL_SIZE"
    fi
  fi
}

# Funkcja czyszcząca stare kontenery
clean_old_containers() {
  if [ "$DAYS_OLD" -gt 0 ]; then
    echo -e "\n${CYAN}══════════════════════════════════════════${NC}"
    echo -e "${CYAN}   CZYSZCZENIE STARYCH KONTENERÓW (${DAYS_OLD} DNI)   ${NC}"
    echo -e "${CYAN}══════════════════════════════════════════${NC}"

    # Znajdź kontenery starsze niż X dni
    local cutoff_date=$(date -d "$DAYS_OLD days ago" +%s)
    local to_delete=()
    local container_details=$(docker ps -a --format "{{.ID}}|{{.CreatedAt}}|{{.Names}}|{{.Status}}")

    # Przetwarzaj wyniki linijka po linijce
    while IFS= read -r line; do
      container_id=$(echo "$line" | cut -d'|' -f1)
      created_at=$(echo "$line" | cut -d'|' -f2)
      name=$(echo "$line" | cut -d'|' -f3)
      status=$(echo "$line" | cut -d'|' -f4)
      
      # Konwertuj datę utworzenia na uniksowy znacznik czasu
      created_timestamp=$(date -d "$created_at" +%s 2>/dev/null)
      
      if [ -n "$created_timestamp" ] && [ "$created_timestamp" -lt "$cutoff_date" ]; then
        to_delete+=("$container_id")
        if [ "$QUIET_MODE" = false ]; then
          echo -e "${YELLOW}[!] Stary kontener:${NC} $name ($container_id) - $status, utworzony: $created_at"
        fi
      fi
    done <<< "$container_details"

    # Usuń znalezione stare kontenery
    if [ ${#to_delete[@]} -gt 0 ]; then
      if [ "$INTERACTIVE" = true ]; then
        if confirm_action "Czy chcesz usunąć ${#to_delete[@]} starych kontenerów?"; then
          for container_id in "${to_delete[@]}"; do
            force_param=""
            [ "$FORCE_MODE" = true ] && force_param="--force"
            execute_command "docker rm $container_id $force_param" "Usuwanie kontenera $container_id" "$FORCE_MODE"
          done
        else
          echo -e "${YELLOW}[!] Pomijam usuwanie starych kontenerów.${NC}"
        fi
      else
        for container_id in "${to_delete[@]}"; do
          force_param=""
          [ "$FORCE_MODE" = true ] && force_param="--force"
          execute_command "docker rm $container_id $force_param" "Usuwanie kontenera $container_id" "$FORCE_MODE"
        done
      fi
    else
      echo -e "${GREEN}[✓] Nie znaleziono kontenerów starszych niż ${DAYS_OLD} dni.${NC}"
    fi
  fi
}

# Funkcja czyszcząca zatrzymane kontenery
clean_stopped_containers() {
  echo -e "\n${CYAN}══════════════════════════════════════════${NC}"
  echo -e "${CYAN}       CZYSZCZENIE KONTENERÓW             ${NC}"
  echo -e "${CYAN}══════════════════════════════════════════${NC}"

  # Sprawdź, czy istnieją zatrzymane kontenery
  if [ "$(docker ps -q -f "status=exited" | wc -l)" -gt 0 ]; then
    # Lista zatrzymanych kontenerów
    if [ "$QUIET_MODE" = false ]; then
      echo -e "${YELLOW}[!] Zatrzymane kontenery:${NC}"
      docker ps -a -f "status=exited" --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Size}}"
    fi

    # Potwierdź i wykonaj czyszczenie
    if [ "$INTERACTIVE" = true ]; then
      if confirm_action "Czy chcesz usunąć zatrzymane kontenery?"; then
        force_param=""
        [ "$FORCE_MODE" = true ] && force_param="--force"
        execute_command "docker container prune $force_param -f" "Usuwanie zatrzymanych kontenerów" "$FORCE_MODE"
      else
        echo -e "${YELLOW}[!] Pomijam usuwanie zatrzymanych kontenerów.${NC}"
      fi
    else
      force_param=""
      [ "$FORCE_MODE" = true ] && force_param="--force"
      execute_command "docker container prune $force_param -f" "Usuwanie zatrzymanych kontenerów" "$FORCE_MODE"
    fi
  else
    echo -e "${GREEN}[✓] Brak zatrzymanych kontenerów do usunięcia.${NC}"
  fi

  # Sprawdź, czy istnieją kontenery w stanie created
  if [ "$(docker ps -q -f "status=created" | wc -l)" -gt 0 ]; then
    # Lista kontenerów w stanie created
    if [ "$QUIET_MODE" = false ]; then
      echo -e "${YELLOW}[!] Kontenery w stanie 'created':${NC}"
      docker ps -a -f "status=created" --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Size}}"
    fi

    # Potwierdź i wykonaj czyszczenie
    if [ "$INTERACTIVE" = true ]; then
      if confirm_action "Czy chcesz usunąć kontenery w stanie 'created'?"; then
        docker ps -q -f "status=created" | xargs -r docker rm
        echo -e "${GREEN}[✓] Usunięto kontenery w stanie 'created'.${NC}"
      else
        echo -e "${YELLOW}[!] Pomijam usuwanie kontenerów w stanie 'created'.${NC}"
      fi
    else
      docker ps -q -f "status=created" | xargs -r docker rm
      echo -e "${GREEN}[✓] Usunięto kontenery w stanie 'created'.${NC}"
    fi
  else
    echo -e "${GREEN}[✓] Brak kontenerów w stanie 'created' do usunięcia.${NC}"
  fi
}

# Funkcja czyszcząca nieużywane obrazy
clean_unused_images() {
  echo -e "\n${CYAN}══════════════════════════════════════════${NC}"
  echo -e "${CYAN}          CZYSZCZENIE OBRAZÓW             ${NC}"
  echo -e "${CYAN}══════════════════════════════════════════${NC}"

  # Sprawdź, czy istnieją niepodłączone obrazy
  if [ "$DANGLING_ONLY" = true ]; then
    if [ "$(docker images -q -f "dangling=true" | wc -l)" -gt 0 ]; then
      # Lista niepodłączonych obrazów
      if [ "$QUIET_MODE" = false ]; then
        echo -e "${YELLOW}[!] Niepodłączone obrazy (dangling):${NC}"
        docker images -f "dangling=true" --format "table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}"
      fi

      # Potwierdź i wykonaj czyszczenie
      if [ "$INTERACTIVE" = true ]; then
        if confirm_action "Czy chcesz usunąć niepodłączone obrazy?"; then
          execute_command "docker image prune -f" "Usuwanie niepodłączonych obrazów"
        else
          echo -e "${YELLOW}[!] Pomijam usuwanie niepodłączonych obrazów.${NC}"
        fi
      else
        execute_command "docker image prune -f" "Usuwanie niepodłączonych obrazów"
      fi
    else
      echo -e "${GREEN}[✓] Brak niepodłączonych obrazów do usunięcia.${NC}"
    fi
  else
    # Lista wszystkich obrazów
    if [ "$QUIET_MODE" = false ]; then
      echo -e "${YELLOW}[!] Wszystkie obrazy:${NC}"
      docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}"
    fi

    # Sprawdź, czy są jakiekolwiek obrazy
    if [ "$(docker images -q | wc -l)" -gt 0 ]; then
      # Potwierdź i wykonaj czyszczenie wszystkich obrazów
      if [ "$INTERACTIVE" = true ]; then
        if confirm_action "Czy chcesz usunąć WSZYSTKIE obrazy?"; then
          execute_command "docker image prune -a -f" "Usuwanie wszystkich nieużywanych obrazów"
        else
          echo -e "${YELLOW}[!] Pomijam usuwanie wszystkich obrazów.${NC}"
        fi
      else
        execute_command "docker image prune -a -f" "Usuwanie wszystkich nieużywanych obrazów"
      fi
    else
      echo -e "${GREEN}[✓] Brak obrazów do usunięcia.${NC}"
    fi
  fi
}

# Funkcja czyszcząca nieużywane wolumeny
clean_unused_volumes() {
  if [ "$PRUNE_VOLUMES" = true ]; then
    echo -e "\n${CYAN}══════════════════════════════════════════${NC}"
    echo -e "${CYAN}         CZYSZCZENIE WOLUMENÓW            ${NC}"
    echo -e "${CYAN}══════════════════════════════════════════${NC}"
    
    # Sprawdź, czy istnieją niepodłączone wolumeny
    if [ "$(docker volume ls -q -f "dangling=true" | wc -l)" -gt 0 ]; then
      # Lista niepodłączonych wolumenów
      if [ "$QUIET_MODE" = false ]; then
        echo -e "${YELLOW}[!] Niepodłączone wolumeny:${NC}"
        docker volume ls -f "dangling=true"
      fi

      # Potwierdź i wykonaj czyszczenie
      if [ "$INTERACTIVE" = true ]; then
        echo -e "${RED}[!] UWAGA: Usunięcie wolumenów spowoduje trwałą utratę danych!${NC}"
        if confirm_action "Czy na pewno chcesz usunąć niepodłączone wolumeny?"; then
          execute_command "docker volume prune -f" "Usuwanie niepodłączonych wolumenów"
        else
          echo -e "${YELLOW}[!] Pomijam usuwanie niepodłączonych wolumenów.${NC}"
        fi
      else
        # Nawet w trybie nieinteraktywnym pokażmy ostrzeżenie
        echo -e "${RED}[!] UWAGA: Usuwanie wolumenów - spowoduje to trwałą utratę danych!${NC}"
        execute_command "docker volume prune -f" "Usuwanie niepodłączonych wolumenów"
      fi
    else
      echo -e "${GREEN}[✓] Brak niepodłączonych wolumenów do usunięcia.${NC}"
    fi
  fi
}

# Funkcja czyszcząca nieużywane sieci
clean_unused_networks() {
  if [ "$PRUNE_NETWORKS" = true ]; then
    echo -e "\n${CYAN}══════════════════════════════════════════${NC}"
    echo -e "${CYAN}           CZYSZCZENIE SIECI              ${NC}"
    echo -e "${CYAN}══════════════════════════════════════════${NC}"
    
    # Sprawdź, czy istnieją nieużywane sieci
    if [ "$(docker network ls --filter "type=custom" --format "{{.ID}}" | wc -l)" -gt 0 ]; then
      # Lista nieużywanych sieci
      if [ "$QUIET_MODE" = false ]; then
        echo -e "${YELLOW}[!] Niestandardowe sieci:${NC}"
        docker network ls --filter "type=custom"
      fi

      # Potwierdź i wykonaj czyszczenie
      if [ "$INTERACTIVE" = true ]; then
        if confirm_action "Czy chcesz usunąć nieużywane sieci?"; then
          execute_command "docker network prune -f" "Usuwanie nieużywanych sieci"
        else
          echo -e "${YELLOW}[!] Pomijam usuwanie nieużywanych sieci.${NC}"
        fi
      else
        execute_command "docker network prune -f" "Usuwanie nieużywanych sieci"
      fi
    else
      echo -e "${GREEN}[✓] Brak nieużywanych sieci do usunięcia.${NC}"
    fi
  fi
}

# Funkcja czyszcząca budowniczych (build cache)
clean_build_cache() {
  echo -e "\n${CYAN}══════════════════════════════════════════${NC}"
  echo -e "${CYAN}        CZYSZCZENIE CACHE BUDOWANIA       ${NC}"
  echo -e "${CYAN}══════════════════════════════════════════${NC}"
  
  # Sprawdź, czy komenda jest dostępna (Docker >= 17.06)
  if docker builder &>/dev/null; then
    # Pokaż aktualny rozmiar cache
    if [ "$QUIET_MODE" = false ]; then
      local cache_info=$(docker builder prune -f --keep-storage 999999G 2>&1 | grep "Total:")
      if [ -n "$cache_info" ]; then
        local cache_size=$(echo "$cache_info" | grep -oE "[0-9.]+\s?[KMGTP]?B")
        echo -e "${YELLOW}[!] Rozmiar cache budowania:${NC} $cache_size"
      fi
    fi

    # Potwierdź i wykonaj czyszczenie
    if [ "$INTERACTIVE" = true ]; then
      if confirm_action "Czy chcesz wyczyścić cache budowania?"; then
        execute_command "docker builder prune -f" "Czyszczenie cache budowania"
      else
        echo -e "${YELLOW}[!] Pomijam czyszczenie cache budowania.${NC}"
      fi
    else
      execute_command "docker builder prune -f" "Czyszczenie cache budowania"
    fi
  else
    echo -e "${YELLOW}[!] Czyszczenie cache budowania nie jest dostępne w tej wersji Docker.${NC}"
  fi
}

# Główna funkcja
main() {
  # Wyświetl banner
  print_banner

  # Parsuj argumenty
  parse_arguments "$@"

  # Sprawdź czy Docker jest dostępny
  check_docker

  # Sprawdź aktualne zasoby Docker
  check_docker_resources

  # Specjalne ostrzeżenie w trybie dry-run
  if [ "$DRY_RUN" = true ]; then
    echo -e "\n${YELLOW}[!] Działanie w trybie testowym (dry-run) - żadne zmiany nie będą wprowadzone.${NC}"
  fi

  # Ostrzeżenie w trybie force
  if [ "$FORCE_MODE" = true ]; then
    echo -e "\n${RED}[!] Tryb wymuszony (force) jest włączony - będzie próbować usunąć nawet działające kontenery.${NC}"
  fi

  # Czyszczenie zasobów Docker
  clean_old_containers
  clean_stopped_containers
  clean_unused_images
  clean_unused_volumes
  clean_unused_networks
  clean_build_cache

  # Końcowe informacje
  if [ "$DRY_RUN" = false ] && [ "$QUIET_MODE" = false ]; then
    echo -e "\n${GREEN}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║      CZYSZCZENIE ZAKOŃCZONE POMYŚLNIE              ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════╝${NC}"
    
    # Pokaż zaoszczędzone miejsce
    echo -e "${BLUE}[*] Sprawdzanie aktualnego stanu zasobów...${NC}"
    check_docker_resources
  fi
}

# Uruchomienie skryptu
main "$@"