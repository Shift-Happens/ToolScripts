#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
certificate_lifecycle_manager.py - Monitorowanie i odnawianie certyfikatów SSL/TLS

OPIS:
    Skrypt służy do zarządzania cyklem życia certyfikatów SSL/TLS. Umożliwia monitorowanie 
    daty wygaśnięcia, automatyczne odnawianie przy użyciu certbota/Let's Encrypt, 
    wysyłanie powiadomień oraz generowanie raportów. Może pracować jako usługa systemowa 
    regularnie sprawdzająca certyfikaty.

UŻYCIE:
    ./certificate_lifecycle_manager.py [opcje]
    ./certificate_lifecycle_manager.py --config plik_konfiguracyjny.json
    ./certificate_lifecycle_manager.py --scan --notify --threshold 30
    ./certificate_lifecycle_manager.py --renew example.com,subdomain.example.org
    ./certificate_lifecycle_manager.py --daemon --interval 86400

OPCJE:
    -h, --help                      Wyświetla pomoc
    -c, --config PLIK               Użyj pliku konfiguracyjnego
    -s, --scan                      Skanuj certyfikaty i sprawdź datę wygaśnięcia
    -r, --renew DOMENY              Odnów certyfikaty dla podanych domen (rozdzielone przecinkami)
    -a, --renew-all                 Odnów wszystkie certyfikaty, które wygasają w okresie threshold
    -f, --force-renew               Wymuś odnowienie certyfikatów nawet jeśli nie wygasają
    -t, --threshold DNI             Próg w dniach do wygaśnięcia (domyślnie 30)
    -n, --notify                    Wyślij powiadomienia o wygasających certyfikatach
    -o, --output PLIK               Zapisz raport do pliku
    -d, --daemon                    Uruchom jako daemon
    -i, --interval SEKUNDY          Interwał sprawdzania w sekundach (dla daemon, domyślnie 86400 - 24h)
    -v, --verbose                   Tryb gadatliwy - więcej informacji
    -q, --quiet                     Tryb cichy - tylko błędy
    --log PLIK                      Zapisz log operacji do pliku

KONFIGURACJA:
    Skrypt może być konfigurowany przy użyciu pliku JSON. Przykładowa struktura:

    {
        "certificates": [
            {
                "domain": "example.com",
                "path": "/etc/letsencrypt/live/example.com/fullchain.pem",
                "auto_renew": true,
                "notify_days": [30, 14, 7, 3, 1]
            },
            {
                "domain": "subdomain.example.org",
                "path": "/etc/ssl/certs/subdomain.example.org.pem",
                "key_path": "/etc/ssl/private/subdomain.example.org.key",
                "auto_renew": false
            }
        ],
        "notification": {
            "email": {
                "enabled": true,
                "smtp_server": "smtp.example.com",
                "smtp_port": 587,
                "username": "admin",
                "password": "password",
                "from_email": "admin@example.com",
                "to_email": ["admin@example.com", "security@example.com"]
            },
            "slack": {
                "enabled": false,
                "webhook_url": "https://hooks.slack.com/services/XXXXX/YYYYY/ZZZZZ"
            }
        },
        "certbot": {
            "path": "/usr/bin/certbot",
            "args": "--post-hook 'systemctl reload nginx'",
            "method": "webroot",
            "webroot_path": "/var/www/html"
        },
        "general": {
            "threshold_days": 30,
            "scan_interval": 86400,
            "log_file": "/var/log/cert_manager.log"
        }
    }

WYMAGANIA:
    - Python 3.6 lub nowszy
    - OpenSSL
    - Certbot (dla automatycznego odnawiania certyfikatów Let's Encrypt)
    - Biblioteki: cryptography, requests, pyyaml

INSTALACJA WYMAGANYCH BIBLIOTEK:
    pip install cryptography requests pyyaml
"""

import argparse
import datetime
import json
import logging
import os
import re
import shutil
import signal
import smtplib
import socket
import ssl
import subprocess
import sys
import time
from datetime import datetime, timedelta
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from pathlib import Path
from typing import Dict, List, Any, Tuple, Optional, Set, Union

try:
    from cryptography import x509
    from cryptography.hazmat.backends import default_backend
    from cryptography.x509.oid import NameOID
except ImportError:
    print("Biblioteka 'cryptography' nie jest zainstalowana.")
    print("Zainstaluj za pomocą: pip install cryptography")
    sys.exit(1)

try:
    import requests
except ImportError:
    print("Biblioteka 'requests' nie jest zainstalowana.")
    print("Zainstaluj za pomocą: pip install requests")
    sys.exit(1)


class CertificateInfo:
    """Klasa przechowująca informacje o certyfikacie."""
    
    def __init__(self, domain: str, path: str, key_path: Optional[str] = None):
        self.domain = domain
        self.path = path
        self.key_path = key_path
        self.not_before = None
        self.not_after = None
        self.issuer = None
        self.subject = None
        self.alt_names = []
        self.serial_number = None
        self.error = None
        self.is_valid = False
        self.days_to_expiry = -1
        
    def load_from_file(self) -> bool:
        """
        Ładuje informacje o certyfikacie z pliku.
        
        Returns:
            bool: True jeśli się powiodło, False w przeciwnym razie
        """
        try:
            with open(self.path, 'rb') as cert_file:
                cert_data = cert_file.read()
                
            cert = x509.load_pem_x509_certificate(cert_data, default_backend())
            
            self.not_before = cert.not_valid_before
            self.not_after = cert.not_valid_after
            self.issuer = cert.issuer.get_attributes_for_oid(NameOID.COMMON_NAME)[0].value
            self.subject = cert.subject.get_attributes_for_oid(NameOID.COMMON_NAME)[0].value
            self.serial_number = cert.serial_number
            
            # Pobierz alternatywne nazwy, jeśli są dostępne
            try:
                ext = cert.extensions.get_extension_for_oid(x509.oid.ExtensionOID.SUBJECT_ALTERNATIVE_NAME)
                self.alt_names = [name.value for name in ext.value]
            except x509.extensions.ExtensionNotFound:
                self.alt_names = []
            
            # Oblicz pozostałą liczbę dni
            self.days_to_expiry = (self.not_after - datetime.now()).days
            self.is_valid = True
            
            return True
        except Exception as e:
            self.error = str(e)
            return False
            
    def load_from_server(self, port: int = 443) -> bool:
        """
        Ładuje informacje o certyfikacie bezpośrednio z serwera.
        
        Args:
            port: Port do połączenia (domyślnie 443 dla HTTPS)
            
        Returns:
            bool: True jeśli się powiodło, False w przeciwnym razie
        """
        try:
            context = ssl.create_default_context()
            with socket.create_connection((self.domain, port)) as sock:
                with context.wrap_socket(sock, server_hostname=self.domain) as ssock:
                    cert_der = ssock.getpeercert(True)
                    cert = x509.load_der_x509_certificate(cert_der, default_backend())
                    
                    self.not_before = cert.not_valid_before
                    self.not_after = cert.not_valid_after
                    self.issuer = cert.issuer.get_attributes_for_oid(NameOID.COMMON_NAME)[0].value
                    self.subject = cert.subject.get_attributes_for_oid(NameOID.COMMON_NAME)[0].value
                    self.serial_number = cert.serial_number
                    
                    # Pobierz alternatywne nazwy, jeśli są dostępne
                    try:
                        ext = cert.extensions.get_extension_for_oid(x509.oid.ExtensionOID.SUBJECT_ALTERNATIVE_NAME)
                        self.alt_names = [name.value for name in ext.value]
                    except x509.extensions.ExtensionNotFound:
                        self.alt_names = []
                    
                    # Oblicz pozostałą liczbę dni
                    self.days_to_expiry = (self.not_after - datetime.now()).days
                    self.is_valid = True
                    
                    return True
        except Exception as e:
            self.error = str(e)
            return False
            
    def is_expiring_soon(self, threshold_days: int) -> bool:
        """
        Sprawdza czy certyfikat wygasa wkrótce.
        
        Args:
            threshold_days: Próg w dniach
            
        Returns:
            bool: True jeśli certyfikat wygasa w ciągu threshold_days, False w przeciwnym razie
        """
        if not self.is_valid:
            return False
            
        return self.days_to_expiry <= threshold_days


class CertificateManager:
    """Główna klasa zarządzająca certyfikatami."""
    
    def __init__(self, config: Dict[str, Any]):
        """
        Inicjalizacja managera certyfikatów.
        
        Args:
            config: Słownik z konfiguracją
        """
        self.config = config
        self.certificates = []
        self.logger = self._setup_logging()
        self.certbot_path = self._get_certbot_path()
        
    def _setup_logging(self) -> logging.Logger:
        """
        Konfiguruje system logowania.
        
        Returns:
            Logger: Skonfigurowany obiekt loggera
        """
        general_config = self.config.get('general', {})
        log_file = general_config.get('log_file')
        verbose = general_config.get('verbose', False)
        quiet = general_config.get('quiet', False)
        
        # Ustaw poziom logowania
        log_level = logging.INFO
        if verbose:
            log_level = logging.DEBUG
        elif quiet:
            log_level = logging.ERROR
            
        # Stwórz logger
        logger = logging.getLogger('cert_manager')
        logger.setLevel(log_level)
        logger.handlers = []  # Usuń istniejące handlery
        
        # Dodaj handler konsoli
        console_handler = logging.StreamHandler()
        console_handler.setLevel(log_level)
        formatter = logging.Formatter('%(asctime)s - %(name)s - %(levelname)s - %(message)s')
        console_handler.setFormatter(formatter)
        logger.addHandler(console_handler)
        
        # Dodaj handler pliku jeśli podano
        if log_file:
            try:
                file_handler = logging.FileHandler(log_file)
                file_handler.setLevel(log_level)
                file_handler.setFormatter(formatter)
                logger.addHandler(file_handler)
                logger.debug(f"Logowanie do pliku: {log_file}")
            except Exception as e:
                logger.error(f"Nie można skonfigurować logowania do pliku: {str(e)}")
                
        return logger
        
    def _get_certbot_path(self) -> str:
        """
        Znajduje ścieżkę do certbota.
        
        Returns:
            str: Ścieżka do certbota
        """
        certbot_config = self.config.get('certbot', {})
        path = certbot_config.get('path')
        
        if path and os.path.exists(path):
            return path
            
        # Szukaj certbota w PATH
        certbot_path = shutil.which('certbot')
        if certbot_path:
            return certbot_path
            
        # Szukaj w typowych lokalizacjach
        common_paths = [
            '/usr/bin/certbot',
            '/usr/local/bin/certbot',
            '/opt/certbot/bin/certbot'
        ]
        
        for p in common_paths:
            if os.path.exists(p):
                return p
                
        self.logger.warning("Nie znaleziono ścieżki do certbota. Automatyczne odnawianie może nie działać.")
        return 'certbot'  # Zwróć domyślną nazwę, może będzie dostępna w PATH
        
    def load_certificates(self) -> None:
        """Ładuje informacje o certyfikatach."""
        self.certificates = []
        
        cert_configs = self.config.get('certificates', [])
        
        for cert_config in cert_configs:
            domain = cert_config.get('domain')
            path = cert_config.get('path')
            key_path = cert_config.get('key_path')
            
            if domain and path:
                cert_info = CertificateInfo(domain, path, key_path)
                if os.path.exists(path):
                    if cert_info.load_from_file():
                        self.logger.info(f"Załadowano certyfikat dla {domain} (wygasa za {cert_info.days_to_expiry} dni)")
                    else:
                        self.logger.error(f"Nie można załadować certyfikatu dla {domain}: {cert_info.error}")
                else:
                    self.logger.warning(f"Plik certyfikatu nie istnieje: {path}")
                    # Spróbuj pobrać dane z serwera
                    if cert_info.load_from_server():
                        self.logger.info(f"Pobrano certyfikat z serwera dla {domain} (wygasa za {cert_info.days_to_expiry} dni)")
                    else:
                        self.logger.error(f"Nie można pobrać certyfikatu z serwera dla {domain}: {cert_info.error}")
                        
                self.certificates.append(cert_info)
            else:
                self.logger.warning(f"Nieprawidłowa konfiguracja certyfikatu: brak domeny lub ścieżki")
                
    def scan_certificates(self, threshold_days: int = 30) -> List[CertificateInfo]:
        """
        Skanuje certyfikaty i zwraca listę wygasających.
        
        Args:
            threshold_days: Próg w dniach
            
        Returns:
            List[CertificateInfo]: Lista certyfikatów wygasających w ciągu threshold_days
        """
        self.load_certificates()
        
        expiring_certs = []
        for cert in self.certificates:
            if cert.is_valid and cert.is_expiring_soon(threshold_days):
                expiring_certs.append(cert)
                self.logger.warning(f"Certyfikat dla {cert.domain} wygasa za {cert.days_to_expiry} dni")
                
        return expiring_certs
        
    def renew_certificates(self, domains: List[str] = None, force: bool = False, threshold_days: int = 30) -> Dict[str, bool]:
        """
        Odnawia certyfikaty dla podanych domen lub wszystkie wygasające.
        
        Args:
            domains: Lista domen do odnowienia (None = wszystkie wygasające)
            force: Wymuś odnowienie nawet jeśli nie wygasają
            threshold_days: Próg w dniach
            
        Returns:
            Dict[str, bool]: Słownik {domena: status} z wynikami odnawiania
        """
        results = {}
        to_renew = []
        
        # Skanuj certyfikaty jeśli jeszcze nie są załadowane
        if not self.certificates:
            self.load_certificates()
            
        # Przygotuj listę certyfikatów do odnowienia
        if domains:
            domain_set = set(domains)
            to_renew = [cert for cert in self.certificates 
                       if cert.domain in domain_set or 
                       any(d in domain_set for d in cert.alt_names)]
        else:
            # Odnów wszystkie wygasające lub wszystkie jeśli force=True
            to_renew = [cert for cert in self.certificates 
                       if force or cert.is_expiring_soon(threshold_days)]
                       
        if not to_renew:
            self.logger.info("Brak certyfikatów do odnowienia")
            return results
            
        # Pobierz konfigurację certbota
        certbot_config = self.config.get('certbot', {})
        webroot_path = certbot_config.get('webroot_path')
        certbot_args = certbot_config.get('args', '')
        method = certbot_config.get('method', 'webroot')
        
        # Odnawianie pojedynczo
        for cert in to_renew:
            try:
                # Sprawdź, czy certyfikat jest zarządzany przez certbota
                is_managed = (cert.path and 'letsencrypt' in cert.path) or ('certbot' in cert.path)
                cert_config = next((c for c in self.config.get('certificates', []) if c.get('domain') == cert.domain), {})
                auto_renew = cert_config.get('auto_renew', is_managed)
                
                if not auto_renew:
                    self.logger.info(f"Pomijanie odnowienia dla {cert.domain} (auto_renew=False)")
                    results[cert.domain] = None
                    continue
                    
                self.logger.info(f"Odnawianie certyfikatu dla {cert.domain}...")
                
                # Przygotuj komendę
                cmd = [self.certbot_path]
                
                if is_managed:
                    # Dla certyfikatów zarządzanych przez certbota użyj komendy renew
                    cmd.extend(['renew', '--cert-name', cert.domain])
                    if force:
                        cmd.append('--force-renewal')
                else:
                    # Dla innych certyfikatów użyj komendy certonly
                    cmd.extend(['certonly', '--non-interactive'])
                    
                    # Dodaj metodę uwierzytelniania
                    if method == 'webroot' and webroot_path:
                        cmd.extend(['--webroot', '-w', webroot_path])
                    elif method == 'standalone':
                        cmd.append('--standalone')
                    elif method == 'dns':
                        cmd.append('--dns-cloudflare')  # Domyślnie CloudFlare, można dostosować
                    
                    # Dodaj domeny
                    cmd.extend(['-d', cert.domain])
                    for alt_name in cert.alt_names:
                        if isinstance(alt_name, str) and alt_name != cert.domain:
                            cmd.extend(['-d', alt_name])
                
                # Dodaj dodatkowe argumenty
                if certbot_args:
                    cmd.extend(certbot_args.split())
                    
                # Wykonaj komendę
                self.logger.debug(f"Wykonywanie komendy: {' '.join(cmd)}")
                result = subprocess.run(cmd, capture_output=True, text=True)
                
                if result.returncode == 0:
                    self.logger.info(f"Pomyślnie odnowiono certyfikat dla {cert.domain}")
                    results[cert.domain] = True
                else:
                    self.logger.error(f"Błąd podczas odnawiania certyfikatu dla {cert.domain}: {result.stderr}")
                    results[cert.domain] = False
                    
            except Exception as e:
                self.logger.error(f"Wyjątek podczas odnawiania certyfikatu dla {cert.domain}: {str(e)}")
                results[cert.domain] = False
                
        return results
        
    def send_notifications(self, expiring_certs: List[CertificateInfo]) -> bool:
        """
        Wysyła powiadomienia o wygasających certyfikatach.
        
        Args:
            expiring_certs: Lista wygasających certyfikatów
            
        Returns:
            bool: True jeśli powiadomienia zostały wysłane, False w przeciwnym razie
        """
        if not expiring_certs:
            self.logger.info("Brak certyfikatów do powiadomienia")
            return True
            
        notification_config = self.config.get('notification', {})
        
        # Wyślij email jeśli skonfigurowany
        email_config = notification_config.get('email', {})
        if email_config.get('enabled', False):
            return self._send_email_notification(expiring_certs, email_config)
            
        # Wyślij powiadomienie Slack jeśli skonfigurowane
        slack_config = notification_config.get('slack', {})
        if slack_config.get('enabled', False):
            return self._send_slack_notification(expiring_certs, slack_config)
            
        self.logger.warning("Brak skonfigurowanych metod powiadamiania")
        return False
        
    def _send_email_notification(self, expiring_certs: List[CertificateInfo], email_config: Dict[str, Any]) -> bool:
        """
        Wysyła powiadomienie email o wygasających certyfikatach.
        
        Args:
            expiring_certs: Lista wygasających certyfikatów
            email_config: Konfiguracja email
            
        Returns:
            bool: True jeśli email został wysłany, False w przeciwnym razie
        """
        try:
            smtp_server = email_config.get('smtp_server')
            smtp_port = email_config.get('smtp_port', 587)
            username = email_config.get('username')
            password = email_config.get('password')
            from_email = email_config.get('from_email')
            to_emails = email_config.get('to_email', [])
            
            if not all([smtp_server, username, password, from_email, to_emails]):
                self.logger.error("Niepełna konfiguracja email")
                return False
                
            # Przygotuj treść wiadomości
            subject = f"[UWAGA] Wygasające certyfikaty SSL/TLS - {len(expiring_certs)} certyfikatów"
            
            # HTML wersja
            html_content = f"""
            <html>
            <head>
                <style>
                    body {{ font-family: Arial, sans-serif; }}
                    table {{ border-collapse: collapse; width: 100%; }}
                    th, td {{ border: 1px solid #ddd; padding: 8px; text-align: left; }}
                    th {{ background-color: #f2f2f2; }}
                    .danger {{ color: red; }}
                    .warning {{ color: orange; }}
                    .ok {{ color: green; }}
                </style>
            </head>
            <body>
                <h2>Wygasające certyfikaty SSL/TLS</h2>
                <p>Poniższe certyfikaty wygasają wkrótce i wymagają odnowienia:</p>
                <table>
                    <tr>
                        <th>Domena</th>
                        <th>Dni do wygaśnięcia</th>
                        <th>Data wygaśnięcia</th>
                        <th>Wystawca</th>
                    </tr>
            """
            
            for cert in expiring_certs:
                # Ustal klasę CSS na podstawie liczby dni
                css_class = "danger" if cert.days_to_expiry <= 7 else "warning"
                
                html_content += f"""
                    <tr>
                        <td>{cert.domain}</td>
                        <td class="{css_class}">{cert.days_to_expiry}</td>
                        <td>{cert.not_after.strftime('%Y-%m-%d %H:%M:%S')}</td>
                        <td>{cert.issuer}</td>
                    </tr>
                """
                
                # Dodaj alternatywne nazwy jeśli są
                if cert.alt_names:
                    html_content += f"""
                    <tr>
                        <td colspan="4">Alternatywne nazwy: {', '.join(cert.alt_names)}</td>
                    </tr>
                    """
                    
            html_content += """
                </table>
                <p>Proszę podjąć odpowiednie działania w celu odnowienia certyfikatów.</p>
            </body>
            </html>
            """
            
            # Wersja tekstowa
            text_content = f"Wygasające certyfikaty SSL/TLS\n\n"
            text_content += "Poniższe certyfikaty wygasają wkrótce i wymagają odnowienia:\n\n"
            
            for cert in expiring_certs:
                text_content += f"Domena: {cert.domain}\n"
                text_content += f"Dni do wygaśnięcia: {cert.days_to_expiry}\n"
                text_content += f"Data wygaśnięcia: {cert.not_after.strftime('%Y-%m-%d %H:%M:%S')}\n"
                text_content += f"Wystawca: {cert.issuer}\n"
                if cert.alt_names:
                    text_content += f"Alternatywne nazwy: {', '.join(cert.alt_names)}\n"
                text_content += "\n"
                
            text_content += "Proszę podjąć odpowiednie działania w celu odnowienia certyfikatów."
            
            # Utwórz wiadomość
            msg = MIMEMultipart('alternative')
            msg['Subject'] = subject
            msg['From'] = from_email
            msg['To'] = ", ".join(to_emails)
            
            # Dodaj obie wersje
            msg.attach(MIMEText(text_content, 'plain'))
            msg.attach(MIMEText(html_content, 'html'))
            
            # Wyślij email
            with smtplib.SMTP(smtp_server, smtp_port) as server:
                server.starttls()
                server.login(username, password)
                server.send_message(msg)
                
            self.logger.info(f"Wysłano powiadomienie email do {', '.join(to_emails)}")
            return True
            
        except Exception as e:
            self.logger.error(f"Błąd podczas wysyłania emaila: {str(e)}")
            return False
            
    def _send_slack_notification(self, expiring_certs: List[CertificateInfo], slack_config: Dict[str, Any]) -> bool:
        """
        Wysyła powiadomienie Slack o wygasających certyfikatach.
        
        Args:
            expiring_certs: Lista wygasających certyfikatów
            slack_config: Konfiguracja Slack
            
        Returns:
            bool: True jeśli powiadomienie zostało wysłane, False w przeciwnym razie
        """
        try:
            webhook_url = slack_config.get('webhook_url')
            
            if not webhook_url:
                self.logger.error("Brak URL webhooka Slack")
                return False
                
            # Przygotuj wiadomość
            blocks = [
                {
                    "type": "header",
                    "text": {
                        "type": "plain_text",
                        "text": f":warning: Wygasające certyfikaty SSL/TLS - {len(expiring_certs)} certyfikatów",
                        "emoji": True
                    }
                },
                {
                    "type": "section",
                    "text": {
                        "type": "mrkdwn",
                        "text": "Poniższe certyfikaty wygasają wkrótce i wymagają odnowienia:"
                    }
                }
            ]
            
            for cert in expiring_certs:
                # Ustal emoji na podstawie liczby dni
                emoji = ":red_circle:" if cert.days_to_expiry <= 7 else ":warning:"
                
                block = {
                    "type": "section",
                    "text": {
                        "type": "mrkdwn",
                        "text": f"{emoji} *{cert.domain}*\n" +
                               f"Dni do wygaśnięcia: *{cert.days_to_expiry}*\n" +
                               f"Data wygaśnięcia: {cert.not_after.strftime('%Y-%m-%d %H:%M:%S')}\n" +
                               f"Wystawca: {cert.issuer}"
                    }
                }
                
                blocks.append(block)
                
                # Dodaj alternatywne nazwy jeśli są
                if cert.alt_names:
                    alt_names_block = {
                        "type": "section",
                        "text": {
                            "type": "mrkdwn",
                            "text": f"Alternatywne nazwy: {', '.join(cert.alt_names)}"
                        }
                    }
                    blocks.append(alt_names_block)
                    
                # Dodaj separator
                blocks.append({"type": "divider"})
                
            # Dodaj podsumowanie
            blocks.append({
                "type": "section",
                "text": {
                    "type": "mrkdwn",
                    "text": "Proszę podjąć odpowiednie działania w celu odnowienia certyfikatów."
                }
            })
            
            # Przygotuj payload
            payload = {
                "blocks": blocks
            }
            
            # Wyślij powiadomienie
            response = requests.post(webhook_url, json=payload)
            
            if response.status_code == 200:
                self.logger.info("Wysłano powiadomienie Slack")
                return True
            else:
                self.logger.error(f"Błąd podczas wysyłania powiadomienia Slack: {response.status_code} {response.text}")
                return False
                
        except Exception as e:
            self.logger.error(f"Błąd podczas wysyłania powiadomienia Slack: {str(e)}")
            return False
            
    def generate_report(self, expiring_certs: List[CertificateInfo], output_file: str = None) -> str:
        """
        Generuje raport o wygasających certyfikatach.
        
        Args:
            expiring_certs: Lista wygasających certyfikatów
            output_file: Opcjonalna ścieżka do pliku wyjściowego
            
        Returns:
            str: Zawartość raportu
        """
        report = []
        report.append("=== RAPORT CERTYFIKATÓW SSL/TLS ===")
        report.append(f"Data wygenerowania: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
        report.append(f"Liczba monitorowanych certyfikatów: {len(self.certificates)}")
        report.append(f"Liczba wygasających certyfikatów: {len(expiring_certs)}")
        report.append("")
        
        if expiring_certs:
            report.append("WYGASAJĄCE CERTYFIKATY:")
            report.append("-" * 80)
            
            for cert in expiring_certs:
                report.append(f"Domena: {cert.domain}")
                report.append(f"Dni do wygaśnięcia: {cert.days_to_expiry}")
                report.append(f"Data wygaśnięcia: {cert.not_after.strftime('%Y-%m-%d %H:%M:%S')}")
                report.append(f"Wystawca: {cert.issuer}")
                
                if cert.alt_names:
                    report.append(f"Alternatywne nazwy: {', '.join(cert.alt_names)}")
                    
                report.append("-" * 80)
        else:
            report.append("Brak wygasających certyfikatów.")
            
        report.append("")
        report.append("PODSUMOWANIE WSZYSTKICH CERTYFIKATÓW:")
        report.append("-" * 80)
        report.append(f"{'Domena':<30} {'Wygasa za (dni)':<15} {'Status':<10}")
        report.append("-" * 80)
        
        for cert in sorted(self.certificates, key=lambda c: c.days_to_expiry if c.is_valid else -1):
            status = "OK"
            if not cert.is_valid:
                status = "BŁĄD"
            elif cert.days_to_expiry <= 7:
                status = "KRYTYCZNY"
            elif cert.days_to_expiry <= 30:
                status = "OSTRZEŻENIE"
                
            report.append(f"{cert.domain:<30} {cert.days_to_expiry:<15} {status:<10}")
            
        report_content = "\n".join(report)
        
        # Zapisz do pliku jeśli podano
        if output_file:
            try:
                with open(output_file, 'w', encoding='utf-8') as f:
                    f.write(report_content)
                self.logger.info(f"Raport zapisany do pliku: {output_file}")
            except Exception as e:
                self.logger.error(f"Błąd podczas zapisywania raportu: {str(e)}")
                
        return report_content
        
    def run_as_daemon(self, interval: int = 86400) -> None:
        """
        Uruchamia manager jako daemon, regularnie sprawdzając certyfikaty.
        
        Args:
            interval: Interwał sprawdzania w sekundach (domyślnie 86400 = 24h)
        """
        self.logger.info(f"Uruchamianie w trybie daemon z interwałem {interval} sekund")
        
        # Obsługa sygnałów
        def handle_signal(signum, frame):
            self.logger.info("Otrzymano sygnał zakończenia, zamykanie...")
            sys.exit(0)
            
        signal.signal(signal.SIGTERM, handle_signal)
        signal.signal(signal.SIGINT, handle_signal)
        
        # Pobierz konfigurację
        general_config = self.config.get('general', {})
        threshold_days = general_config.get('threshold_days', 30)
        
        while True:
            try:
                self.logger.info("Sprawdzanie certyfikatów...")
                
                # Skanuj certyfikaty
                expiring_certs = self.scan_certificates(threshold_days)
                
                # Wyślij powiadomienia jeśli są wygasające certyfikaty
                if expiring_certs:
                    self.send_notifications(expiring_certs)
                    
                    # Odnów certyfikaty z auto_renew=True
                    auto_renew_domains = []
                    for cert in expiring_certs:
                        cert_config = next((c for c in self.config.get('certificates', []) 
                                         if c.get('domain') == cert.domain), {})
                        if cert_config.get('auto_renew', False):
                            auto_renew_domains.append(cert.domain)
                            
                    if auto_renew_domains:
                        self.logger.info(f"Automatyczne odnawianie certyfikatów: {', '.join(auto_renew_domains)}")
                        self.renew_certificates(auto_renew_domains)
                
                self.logger.info(f"Następne sprawdzenie za {interval} sekund")
                
            except Exception as e:
                self.logger.error(f"Wyjątek podczas pracy daemona: {str(e)}")
                
            # Śpij przez określony interwał
            time.sleep(interval)


def load_config_file(config_path: str) -> Dict[str, Any]:
    """
    Ładuje konfigurację z pliku JSON.
    
    Args:
        config_path: Ścieżka do pliku konfiguracyjnego
        
    Returns:
        Dict[str, Any]: Słownik z konfiguracją
    """
    try:
        with open(config_path, 'r', encoding='utf-8') as f:
            config = json.load(f)
        return config
    except Exception as e:
        print(f"Błąd podczas ładowania pliku konfiguracyjnego: {str(e)}")
        sys.exit(1)


def generate_config_template() -> str:
    """
    Generuje szablon pliku konfiguracyjnego.
    
    Returns:
        str: Szablon konfiguracji w formacie JSON
    """
    config = {
        "certificates": [
            {
                "domain": "example.com",
                "path": "/etc/letsencrypt/live/example.com/fullchain.pem",
                "key_path": "/etc/letsencrypt/live/example.com/privkey.pem",
                "auto_renew": True,
                "notify_days": [30, 14, 7, 3, 1]
            },
            {
                "domain": "subdomain.example.org",
                "path": "/etc/ssl/certs/subdomain.example.org.pem",
                "key_path": "/etc/ssl/private/subdomain.example.org.key",
                "auto_renew": False
            }
        ],
        "notification": {
            "email": {
                "enabled": True,
                "smtp_server": "smtp.example.com",
                "smtp_port": 587,
                "username": "admin",
                "password": "password",
                "from_email": "admin@example.com",
                "to_email": ["admin@example.com", "security@example.com"]
            },
            "slack": {
                "enabled": False,
                "webhook_url": "https://hooks.slack.com/services/XXXXX/YYYYY/ZZZZZ"
            }
        },
        "certbot": {
            "path": "/usr/bin/certbot",
            "args": "--post-hook 'systemctl reload nginx'",
            "method": "webroot",
            "webroot_path": "/var/www/html"
        },
        "general": {
            "threshold_days": 30,
            "scan_interval": 86400,
            "log_file": "/var/log/cert_manager.log",
            "verbose": True
        }
    }
    
    return json.dumps(config, indent=4)


def main() -> None:
    """Główna funkcja programu."""
    parser = argparse.ArgumentParser(
        description="Narzędzie do monitorowania i odnawiania certyfikatów SSL/TLS.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__.split("UŻYCIE:")[0]  # Używa części dokumentacji jako epilog
    )
    
    parser.add_argument("-c", "--config", help="Ścieżka do pliku konfiguracyjnego")
    parser.add_argument("-s", "--scan", action="store_true", help="Skanuj certyfikaty")
    parser.add_argument("-r", "--renew", help="Odnów certyfikaty dla podanych domen (rozdzielone przecinkami)")
    parser.add_argument("-a", "--renew-all", action="store_true", 
                        help="Odnów wszystkie certyfikaty, które wygasają w okresie threshold")
    parser.add_argument("-f", "--force-renew", action="store_true", 
                        help="Wymuś odnowienie certyfikatów nawet jeśli nie wygasają")
    parser.add_argument("-t", "--threshold", type=int, default=30, 
                        help="Próg w dniach do wygaśnięcia (domyślnie 30)")
    parser.add_argument("-n", "--notify", action="store_true", 
                        help="Wyślij powiadomienia o wygasających certyfikatach")
    parser.add_argument("-o", "--output", help="Zapisz raport do pliku")
    parser.add_argument("-d", "--daemon", action="store_true", help="Uruchom jako daemon")
    parser.add_argument("-i", "--interval", type=int, default=86400, 
                        help="Interwał sprawdzania w sekundach (dla daemon, domyślnie 86400 - 24h)")
    parser.add_argument("-v", "--verbose", action="store_true", help="Tryb gadatliwy - więcej informacji")
    parser.add_argument("-q", "--quiet", action="store_true", help="Tryb cichy - tylko błędy")
    parser.add_argument("--log", help="Zapisz log operacji do pliku")
    parser.add_argument("--generate-config", action="store_true", 
                        help="Wygeneruj przykładowy plik konfiguracyjny")
    
    args = parser.parse_args()
    
    # Generowanie przykładowego pliku konfiguracyjnego
    if args.generate_config:
        config_template = generate_config_template()
        print(config_template)
        return
    
    # Ładowanie konfiguracji
    config = {}
    
    if args.config:
        config = load_config_file(args.config)
    else:
        # Minimalna konfiguracja z parametrów
        config = {
            "general": {
                "threshold_days": args.threshold,
                "verbose": args.verbose,
                "quiet": args.quiet,
                "log_file": args.log
            }
        }
    
    # Aktualizuj konfigurację na podstawie parametrów
    if "general" not in config:
        config["general"] = {}
        
    if args.verbose:
        config["general"]["verbose"] = True
    if args.quiet:
        config["general"]["quiet"] = True
    if args.log:
        config["general"]["log_file"] = args.log
    if args.threshold:
        config["general"]["threshold_days"] = args.threshold
        
    # Inicjalizacja managera
    manager = CertificateManager(config)
    
    # Uruchom w trybie daemon
    if args.daemon:
        manager.run_as_daemon(args.interval)
        return
    
    # Skanuj certyfikaty
    if args.scan or args.notify or args.renew_all or args.output:
        expiring_certs = manager.scan_certificates(args.threshold)
        
        # Wyślij powiadomienia
        if args.notify and expiring_certs:
            manager.send_notifications(expiring_certs)
            
        # Generuj raport
        if args.output:
            manager.generate_report(expiring_certs, args.output)
            
        # Odnów wszystkie wygasające certyfikaty
        if args.renew_all:
            manager.renew_certificates(force=args.force_renew, threshold_days=args.threshold)
            
    # Odnów konkretne certyfikaty
    if args.renew:
        domains = [d.strip() for d in args.renew.split(',')]
        manager.renew_certificates(domains, force=args.force_renew)
        
    # Jeśli nie podano żadnej akcji, wyświetl pomoc
    if not (args.scan or args.notify or args.renew or args.renew_all or args.output or args.daemon or args.generate_config):
        parser.print_help()


if __name__ == "__main__":
    main()