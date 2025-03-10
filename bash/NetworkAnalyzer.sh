#!/bin/bash

# ==========================================
# Network Analyzer
# Autor: Arkadiusz Kubiszewski
# ==========================================

# Sprawdzenie uprawnień root
if [[ $EUID -ne 0 ]]; then
   echo "Ten skrypt wymaga uprawnień administratora (root)."
   echo "Uruchom ponownie używając sudo: sudo $0"
   exit 1
fi

# Utworzenie katalogu na wyniki analizy
OUTPUT_DIR="network_analysis_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUTPUT_DIR"
REPORT_FILE="$OUTPUT_DIR/network_report.txt"

# Nagłówek
echo "=============================================================" | tee "$REPORT_FILE"
echo "       RAPORT ANALIZY INFRASTRUKTURY SIECIOWEJ               " | tee -a "$REPORT_FILE"
echo "       $(hostname) - $(date)                                 " | tee -a "$REPORT_FILE"
echo "=============================================================" | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"

# Funkcja do oddzielania sekcji
section() {
  echo "" | tee -a "$REPORT_FILE"
  echo "===================== $1 =====================" | tee -a "$REPORT_FILE"
  echo "" | tee -a "$REPORT_FILE"
}

# Funkcja do wykonywania poleceń i zapisywania wyników
run_command() {
  local cmd="$1"
  local title="$2"
  
  echo "[INFO] Zbieranie informacji: $title..."
  
  echo "--- $title ---" >> "$REPORT_FILE"
  eval "$cmd" >> "$REPORT_FILE" 2>&1
  echo "" >> "$REPORT_FILE"
}

section "INFORMACJE O SYSTEMIE"
run_command "uname -a" "Informacje o jądrze"
run_command "cat /etc/os-release" "Dystrybucja systemu"
run_command "uptime" "Czas działania systemu"

section "INTERFEJSY SIECIOWE"
run_command "ip -c link show" "Lista wszystkich interfejsów sieciowych"
run_command "ip -c -s link" "Statystyki interfejsów"
run_command "ip -c -details link" "Szczegółowe informacje o interfejsach"

section "KONFIGURACJA IP"
run_command "ip -c addr show" "Adresy IP na interfejsach"
run_command "ip -c -4 addr show" "Adresy IPv4"
run_command "ip -c -6 addr show" "Adresy IPv6"

section "ROUTING"
run_command "ip -c route" "Tablica routingu IPv4"
run_command "ip -c -6 route" "Tablica routingu IPv6"
run_command "ip -c rule list" "Reguły routingu"

section "INTERFEJSY WIRTUALNE"
run_command "ip -c tunnel show" "Tunele"
run_command "ip -c vlan show" "Interfejsy VLAN"
run_command "ip -c tuntap show" "Tunele TUN/TAP"
run_command "ip -c link show type bridge" "Mosty sieciowe"
run_command "ip -c link show type bond" "Interfejsy bonding (agregacja łączy)"

section "SĄSIEDZTWO"
run_command "ip -c neigh show" "Tabela sąsiedztwa (ARP/NDP)"

section "POŁĄCZENIA SIECIOWE"
run_command "ss -tunapl" "Wszystkie połączenia sieciowe"
run_command "ss -tunap" "Wszystkie otwarte porty TCP/UDP"
run_command "ss -tan state established" "Aktywne połączenia TCP"

section "ZAPORA SIECIOWA"
run_command "which iptables && iptables -L -v -n" "Reguły iptables (IPv4)"
run_command "which ip6tables && ip6tables -L -v -n" "Reguły iptables (IPv6)"
run_command "which nft && nft list ruleset" "Reguły nftables (jeśli dostępne)"
run_command "which firewalld && firewall-cmd --list-all" "Konfiguracja firewalld (jeśli dostępna)"
run_command "which ufw && ufw status verbose" "Status UFW (jeśli dostępny)"

section "KONFIGURACJA DNS"
run_command "cat /etc/resolv.conf" "Konfiguracja resolv.conf"
run_command "which systemd-resolve && systemd-resolve --status" "Status systemd-resolved (jeśli dostępne)"
run_command "dig +short google.com" "Test rozwiązywania nazw DNS"

section "TOPOLOGIA SIECI"
run_command "which nmap && nmap -sn $(ip -4 route get 1 | head -1 | awk '{print $7}')/24" "Wykrywanie urządzeń w sieci lokalnej (wymaga nmap)"

section "POŁĄCZENIA VPN"
run_command "ip -c link show type wireguard" "Interfejsy WireGuard (jeśli dostępne)"
run_command "which openvpn && ps aux | grep -v grep | grep openvpn" "Procesy OpenVPN (jeśli dostępne)"

section "USŁUGI SIECIOWE"
run_command "systemctl list-units --type=service --state=running | grep -i -E 'network|ssh|vpn|firewall|dns|dhcp'" "Działające usługi sieciowe"

section "TEST ŁĄCZNOŚCI"
run_command "ping -c 3 8.8.8.8" "Ping do Google DNS (8.8.8.8)"
run_command "ping -c 3 google.com" "Ping do google.com"
run_command "curl -s ifconfig.me" "Publiczny adres IP"
run_command "traceroute -n google.com" "Trasa do google.com"

section "PODSUMOWANIE INFRASTRUKTURY SIECIOWEJ"

{
  echo "Wykryte interfejsy fizyczne:"
  ip -br link | grep -v lo | awk '{print "  - " $1 " (" $2 ")"}'
  
  echo -e "\nKonfiguracja IP:"
  ip -br addr | grep -v "lo" | awk '{print "  - " $1 ": " $3}'
  
  echo -e "\nBrama domyślna:"
  ip route | grep default | awk '{print "  - " $3 " via " $5}'
  
  echo -e "\nGłówne połączenia sieciowe:"
  ss -tunap | grep ESTAB | head -5 | awk '{print "  - " $5 " <-> " $6}'
  
  echo -e "\nOtwarte porty nasłuchujące:"
  ss -tunapl | grep LISTEN | awk '{print "  - " $5 " (" $7 ")"}'
  
  echo -e "\nPodsumowanie topologii sieci:"
  echo "  System jest podłączony do sieci z następującymi charakterystykami:"
  echo "  - Liczba interfejsów: $(ip -br link | grep -v lo | wc -l)"
  echo "  - Liczba adresów IP: $(ip -br addr | grep -v lo | grep -v "scope link" | wc -l)"
  echo "  - Liczba aktywnych połączeń: $(ss -tunap | grep ESTAB | wc -l)"
  echo "  - Liczba portów nasłuchujących: $(ss -tunapl | grep LISTEN | wc -l)"
} | tee -a "$REPORT_FILE"

section "DIAGRAM SIECI (ASCII)"

{
  echo "                       Internet"
  echo "                          │"
  echo "                          ▼"
  echo "                     [Gateway]"
  echo "                          │"
  echo "        ┌─────────────────┼─────────────────┐"
  
  # Pobierz główny interfejs
  MAIN_IF=$(ip route | grep default | head -1 | awk '{print $5}')
  MAIN_IP=$(ip -br addr show $MAIN_IF | awk '{print $3}' | cut -d'/' -f1)
  
  echo "        │                  │                 │"
  echo "        ▼                  ▼                 ▼"
  
  # Lista interfejsów fizycznych (pomijamy lo i główny interfejs)
  INTERFACES=$(ip -br link | grep -v lo | grep -v "$MAIN_IF" | awk '{print $1}')
  
  echo "[Main: $MAIN_IF]      [Other interfaces]    [Local services]"
  echo "   $MAIN_IP"
  
  for iface in $INTERFACES; do
    IP=$(ip -br addr show $iface | awk '{print $3}' | cut -d'/' -f1)
    echo "                     ├─ $iface: $IP"
  done
  
  echo "                          │"
  echo "            ┌─────────────┼─────────────────┐"
  echo "            │             │                 │"
  echo "            ▼             ▼                 ▼"
  echo "      [Local hosts]  [Connected]      [Virtual interfaces]"
  echo "                      devices"
} | tee -a "$REPORT_FILE"

tar -czf "$OUTPUT_DIR.tar.gz" "$OUTPUT_DIR"

echo ""
echo "==========================================================="
echo "Analiza zakończona. Wyniki zapisano w:"
echo "Raport: $REPORT_FILE"
echo "Archiwum: $OUTPUT_DIR.tar.gz"
echo "==========================================================="