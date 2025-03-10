#!/bin/bash

# ========================================================
# FindDuplicateFiles.sh - Skrypt do wyszukiwania duplikatów
# ========================================================

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
SEARCH_DIR="$HOME"
MIN_SIZE=1 # Minimalna wielkość pliku w KB
OUTPUT_FILE=""
INTERACTIVE=false
SHOW_PROGRESS=true
DELETE_MODE=false
SHOW_ALL=false
SORT_BY="size" # size, name, count

# ASCII art
print_banner() {
  echo -e "${CYAN}"
  cat << "EOF"
  ______ _           _   _____             _ _           _            
 |  ____(_)         | | |  __ \           | (_)         | |           
 | |__   _ _ __   __| | | |  | |_   _ _ __| |_  ___ __ _| |_ ___  ___ 
 |  __| | | '_ \ / _` | | |  | | | | | '__| | |/ __/ _` | __/ _ \/ __|
 | |    | | | | | (_| | | |__| | |_| | |  | | | (_| (_| | ||  __/\__ \
 |_|    |_|_| |_|\__,_| |_____/ \__,_|_|  |_|_|\___\__,_|\__\___||___/
                                                                       
EOF
  echo -e "${NC}"
}

# Funkcja wyświetlająca pomoc
show_help() {
  echo -e "${GREEN}FindDuplicateFiles.sh${NC} - narzędzie do wyszukiwania duplikatów plików"
  echo
  echo -e "${YELLOW}Użycie:${NC}"
  echo -e "  $0 [opcje]"
  echo
  echo -e "${YELLOW}Opcje:${NC}"
  echo -e "  ${GREEN}-d, --directory DIR${NC}    Katalog, który ma być przeszukany (domyślnie: $HOME)"
  echo -e "  ${GREEN}-s, --size SIZE${NC}        Minimalna wielkość pliku w KB (domyślnie: 1KB)"
  echo -e "  ${GREEN}-o, --output FILE${NC}      Zapisz wyniki do pliku"
  echo -e "  ${GREEN}-i, --interactive${NC}      Tryb interaktywny - pyta co zrobić z każdym duplikatem"
  echo -e "  ${GREEN}-q, --quiet${NC}            Nie pokazuj paska postępu i szczegółów"
  echo -e "  ${GREEN}--delete${NC}               Aktywuj tryb usuwania (wymaga potwierdzenia)"
  echo -e "  ${GREEN}--all${NC}                  Pokaż wszystkie pliki w grupach, nie tylko duplikaty"
  echo -e "  ${GREEN}--sort-by TYPE${NC}         Sortuj wyniki: size (rozmiar), name (nazwa), count (ilość)"
  echo -e "  ${GREEN}-h, --help${NC}             Pokaż tę pomoc"
  echo
  echo -e "${YELLOW}Przykłady:${NC}"
  echo -e "  $0 -d /home/user/Documents -s 100 -o results.txt    # Znajdź duplikaty większe niż 100KB"
  echo -e "  $0 -d /home/user/Pictures --interactive             # Interaktywne wyszukiwanie duplikatów"
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
      -d|--directory)
        SEARCH_DIR="$2"
        shift 2
        ;;
      -s|--size)
        MIN_SIZE="$2"
        shift 2
        ;;
      -o|--output)
        OUTPUT_FILE="$2"
        shift 2
        ;;
      -i|--interactive)
        INTERACTIVE=true
        shift
        ;;
      -q|--quiet)
        SHOW_PROGRESS=false
        shift
        ;;
      --delete)
        DELETE_MODE=true
        shift
        ;;
      --all)
        SHOW_ALL=true
        shift
        ;;
      --sort-by)
        SORT_BY="$2"
        shift 2
        ;;
      *)
        echo -e "${RED}Nieznana opcja: $1${NC}"
        show_help
        exit 1
        ;;
    esac
  done

  # Sprawdzanie, czy katalog istnieje
  if [ ! -d "$SEARCH_DIR" ]; then
    echo -e "${RED}Błąd: Katalog '$SEARCH_DIR' nie istnieje.${NC}"
    exit 1
  fi
}

# Funkcja do wyświetlania paska postępu
progress_bar() {
  local current=$1
  local total=$2
  local width=50
  
  if [ "$SHOW_PROGRESS" = false ]; then
    return
  fi
  
  # Oblicz procent ukończenia
  local percent=$((current * 100 / total))
  local completed=$((width * current / total))
  
  # Wyświetl pasek postępu
  printf "\r[%-${width}s] %d%% (%d/%d)" "$(printf '#%.0s' $(seq 1 $completed))" "$percent" "$current" "$total"
}

# Funkcja do formatowania rozmiaru pliku
format_size() {
  local size=$1
  
  if [ $size -ge 1073741824 ]; then
    printf "%.2f GB" "$(echo "scale=2; $size / 1073741824" | bc)"
  elif [ $size -ge 1048576 ]; then
    printf "%.2f MB" "$(echo "scale=2; $size / 1048576" | bc)"
  elif [ $size -ge 1024 ]; then
    printf "%.2f KB" "$(echo "scale=2; $size / 1024" | bc)"
  else
    printf "%d B" "$size"
  fi
}

# Funkcja do znajdowania i grupowania plików według sum kontrolnych MD5
find_duplicates() {
  local search_dir="$1"
  local min_size="$2"
  local tempfile
  
  # Komunikat początkowy
  echo -e "${BLUE}[*] Rozpoczynam wyszukiwanie plików większych niż ${MIN_SIZE}KB w katalogu: ${search_dir}${NC}"
  
  # Tymczasowy plik dla wyników
  tempfile=$(mktemp)
  
  # Znajdź wszystkie pliki większe niż określona wielkość i nie będące katalogami symbolicznymi
  if [ "$SHOW_PROGRESS" = true ]; then
    echo -e "${YELLOW}[!] Zbieranie listy plików...${NC}"
  fi
  
  # Liczba znalezionych plików
  local file_list=()
  while IFS= read -r -d $'\0' file; do
    file_list+=("$file")
  done < <(find "$search_dir" -type f -size +"${min_size}"k -not -path "*/\.*" -print0 2>/dev/null)
  
  local total_files=${#file_list[@]}
  
  if [ $total_files -eq 0 ]; then
    echo -e "${RED}[!] Nie znaleziono żadnych plików większych niż ${min_size}KB.${NC}"
    rm "$tempfile"
    exit 0
  fi
  
  echo -e "${GREEN}[✓] Znaleziono ${total_files} plików do sprawdzenia.${NC}"
  
  # Obliczanie sum kontrolnych
  if [ "$SHOW_PROGRESS" = true ]; then
    echo -e "${YELLOW}[!] Obliczanie sum kontrolnych...${NC}"
  fi
  
  local counter=0
  for file in "${file_list[@]}"; do
    # Aktualizuj licznik i pasek postępu
    ((counter++))
    progress_bar "$counter" "$total_files"
    
    # Oblicz sumę kontrolną tylko jeśli mamy dostęp do pliku
    if [ -r "$file" ]; then
      md5=$(md5sum "$file" 2>/dev/null | cut -d' ' -f1)
      if [ -n "$md5" ]; then
        filesize=$(stat -c%s "$file" 2>/dev/null)
        echo "$md5|$filesize|$file" >> "$tempfile"
      fi
    fi
  done
  
  if [ "$SHOW_PROGRESS" = true ]; then
    echo # Nowa linia po pasku postępu
  fi
  
  # Sortowanie i grupowanie plików
  if [ "$SHOW_PROGRESS" = true ]; then
    echo -e "${YELLOW}[!] Sortowanie i analiza wyników...${NC}"
  fi
  
  # Grupowanie według sum kontrolnych
  if [ "$SORT_BY" = "size" ]; then
    # Sortowanie według rozmiaru (malejąco)
    sort -t'|' -k2,2nr -k1,1 -k3,3 "$tempfile" > "${tempfile}.sorted"
  elif [ "$SORT_BY" = "name" ]; then
    # Sortowanie według nazwy pliku
    sort -t'|' -k3,3 -k1,1 "$tempfile" > "${tempfile}.sorted"
  else
    # Domyślne sortowanie według sumy kontrolnej
    sort -t'|' -k1,1 -k2,2nr "$tempfile" > "${tempfile}.sorted"
  fi
  
  mv "${tempfile}.sorted" "$tempfile"
  
  # Grupowanie i wyświetlanie duplikatów
  display_results "$tempfile"
  
  # Czyszczenie
  rm "$tempfile"
}

# Funkcja do wyświetlania wyników
display_results() {
  local result_file="$1"
  local current_md5=""
  local group_files=()
  local group_count=0
  local duplicate_groups=0
  local duplicate_files=0
  local total_size=0
  local results_text=""
  
  # Przetwarzanie wyników
  while IFS="|" read -r md5 size file; do
    if [ "$current_md5" != "$md5" ]; then
      # Wyświetl poprzednią grupę jeśli mamy duplikaty lub opcja --all jest włączona
      if [ ${#group_files[@]} -gt 1 ] || [ "$SHOW_ALL" = true -a ${#group_files[@]} -gt 0 ]; then
        group_text=$(display_group "${group_files[@]}")
        results_text+="$group_text"
        
        if [ ${#group_files[@]} -gt 1 ]; then
          ((duplicate_groups++))
          duplicate_files=$((duplicate_files + ${#group_files[@]} - 1))
          # Dodaj rozmiar tylko raz dla każdej grupy (zaoszczędzona przestrzeń)
          if [ ${#group_files[@]} -gt 0 ]; then
            IFS="|" read -r _ first_size _ <<< "${group_files[0]}"
            total_size=$((total_size + first_size * (${#group_files[@]} - 1)))
          fi
        fi
      fi
      
      # Zacznij nową grupę
      current_md5="$md5"
      group_files=()
    fi
    
    # Dodaj obecny plik do grupy
    group_files+=("$md5|$size|$file")
  done < "$result_file"
  
  # Wyświetl ostatnią grupę
  if [ ${#group_files[@]} -gt 1 ] || [ "$SHOW_ALL" = true -a ${#group_files[@]} -gt 0 ]; then
    group_text=$(display_group "${group_files[@]}")
    results_text+="$group_text"
    
    if [ ${#group_files[@]} -gt 1 ]; then
      ((duplicate_groups++))
      duplicate_files=$((duplicate_files + ${#group_files[@]} - 1))
      # Dodaj rozmiar tylko raz dla każdej grupy (zaoszczędzona przestrzeń)
      if [ ${#group_files[@]} -gt 0 ]; then
        IFS="|" read -r _ first_size _ <<< "${group_files[0]}"
        total_size=$((total_size + first_size * (${#group_files[@]} - 1)))
      fi
    fi
  fi
  
  # Podsumowanie
  local summary=""
  summary+="${GREEN}╔═════════════════════════════════════════════════════════════╗${NC}\n"
  summary+="${GREEN}║                     PODSUMOWANIE                            ║${NC}\n"
  summary+="${GREEN}╠═════════════════════════════════════════════════════════════╣${NC}\n"
  summary+="${GREEN}║${NC} Znaleziono grup duplikatów: ${YELLOW}$duplicate_groups${NC}\n"
  summary+="${GREEN}║${NC} Znaleziono plików duplikatów: ${YELLOW}$duplicate_files${NC}\n"
  summary+="${GREEN}║${NC} Potencjalne zaoszczędzone miejsce: ${YELLOW}$(format_size $total_size)${NC}\n"
  summary+="${GREEN}╚═════════════════════════════════════════════════════════════╝${NC}\n"
  
  # Wyświetl podsumowanie na początku
  echo -e "$summary"
  
  # Jeśli nie ma duplikatów
  if [ $duplicate_groups -eq 0 ]; then
    echo -e "${YELLOW}[!] Nie znaleziono żadnych duplikatów.${NC}"
    return
  fi
  
  # Wyświetl wyniki lub zapisz do pliku
  if [ -n "$OUTPUT_FILE" ]; then
    echo -e "$summary$results_text" > "$OUTPUT_FILE"
    echo -e "${GREEN}[✓] Wyniki zostały zapisane do pliku: $OUTPUT_FILE${NC}"
  else
    echo -e "$results_text"
  fi
  
  # Pytanie o usunięcie duplikatów w trybie interaktywnym
  if [ "$INTERACTIVE" = true ] && [ $duplicate_groups -gt 0 ]; then
    ask_for_deletions
  fi
}

# Funkcja do wyświetlania grupy duplikatów
display_group() {
  local files=("$@")
  local output=""
  
  if [ ${#files[@]} -lt 1 ]; then
    return
  fi
  
  # Pobierz informacje o pierwszym pliku
  IFS="|" read -r md5 size _ <<< "${files[0]}"
  
  # Nagłówek grupy
  output+="${BLUE}════════════════════════════════════════════════════════════════${NC}\n"
  output+="${YELLOW}Grupa plików MD5: ${md5} | Rozmiar: $(format_size $size) | Liczba plików: ${#files[@]}${NC}\n"
  output+="${BLUE}────────────────────────────────────────────────────────────────${NC}\n"
  
  # Wypisz wszystkie pliki w grupie
  local counter=1
  for entry in "${files[@]}"; do
    IFS="|" read -r _ _ file <<< "$entry"
    output+="${CYAN}$counter.${NC} $file\n"
    ((counter++))
  done
  
  output+="${BLUE}════════════════════════════════════════════════════════════════${NC}\n\n"
  echo -e "$output"
}

# Funkcja do interaktywnego usuwania duplikatów
ask_for_deletions() {
  echo -e "${YELLOW}╔════════════════════════════════════════════════════╗${NC}"
  echo -e "${YELLOW}║  Czy chcesz przejść do zarządzania duplikatami?    ║${NC}"
  echo -e "${YELLOW}╚════════════════════════════════════════════════════╝${NC}"
  echo -e "${MAGENTA}Opcje:${NC}"
  echo -e "  ${GREEN}1${NC} - Usuń wybrane pliki interaktywnie"
  echo -e "  ${GREEN}2${NC} - Zachowaj tylko 1 kopię z każdej grupy (automatycznie)"
  echo -e "  ${GREEN}0${NC} - Anuluj (nie usuwaj niczego)"
  
  read -p "Twój wybór [0-2]: " choice
  
  case $choice in
    1)
      interactive_deletion
      ;;
    2)
      auto_deletion
      ;;
    *)
      echo -e "${YELLOW}[!] Anulowano usuwanie.${NC}"
      ;;
  esac
}

# Funkcja do interaktywnego usuwania
interactive_deletion() {
  echo -e "${YELLOW}[!] Rozpoczynam interaktywne usuwanie duplikatów...${NC}"
  echo -e "${RED}[!] UWAGA: Usunięte pliki NIE trafią do kosza!${NC}"
  
  # Ta funkcja jest szkicem - wymagałaby ponownego przetworzenia plików
  echo -e "${RED}[!] Ta funkcja nie jest zaimplementowana w tej wersji skryptu.${NC}"
  echo -e "${YELLOW}[!] W pełnej wersji, pozwoliłaby na interaktywne wybieranie plików do usunięcia.${NC}"
}

# Funkcja do automatycznego usuwania duplikatów (zachowuje tylko 1 kopię z każdej grupy)
auto_deletion() {
  echo -e "${YELLOW}[!] Rozpoczynam automatyczne usuwanie duplikatów...${NC}"
  echo -e "${RED}[!] UWAGA: Usunięte pliki NIE trafią do kosza!${NC}"
  
  # Ta funkcja jest szkicem - wymagałaby ponownego przetworzenia plików
  echo -e "${RED}[!] Ta funkcja nie jest zaimplementowana w tej wersji skryptu.${NC}"
  echo -e "${YELLOW}[!] W pełnej wersji, zachowałaby tylko pierwszą kopię z każdej grupy duplikatów.${NC}"
}

# Główna funkcja
main() {
  # Wyświetl baner
  print_banner
  
  # Parsuj argumenty
  parse_arguments "$@"
  
  # Potwierdź, jeśli tryb usuwania jest włączony
  if [ "$DELETE_MODE" = true ]; then
    echo -e "${RED}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  UWAGA: Tryb usuwania jest włączony!               ║${NC}"
    echo -e "${RED}║  Usunięte pliki NIE trafią do kosza!               ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════╝${NC}"
    read -p "Czy na pewno chcesz kontynuować? [t/N]: " confirm
    
    if [[ ! "$confirm" =~ ^[Tt]$ ]]; then
      echo -e "${YELLOW}[!] Anulowano.${NC}"
      exit 0
    fi
  fi
  
  # Wyszukiwanie duplikatów
  find_duplicates "$SEARCH_DIR" "$MIN_SIZE"
}

# Uruchomienie skryptu
main "$@"