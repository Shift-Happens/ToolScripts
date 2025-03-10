#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
api_tester.py - Skrypt do automatycznego testowania endpointów API
DOKUMENTACJA:
Główne funkcje skryptu:

Automatyczne testowanie wielu endpointów API
Wsparcie dla różnych metod HTTP (GET, POST, PUT, PATCH, DELETE)
Walidacja statusu odpowiedzi i zawartości JSON
Kolorowe wyświetlanie wyników w terminalu
Równoległe wykonywanie testów
Możliwość zapisania wyników do pliku JSON

Jak uruchomić skrypt:
bashCopy# Instalacja wymaganych bibliotek
pip install requests colorama

# Nadanie uprawnień do wykonania
chmod +x api_tester.py

# Uruchomienie z plikiem konfiguracyjnym
./api_tester.py -c przykład_konfiguracji.json

# Lub z bezpośrednim podaniem URL bazy
./api_tester.py -u https://api.example.com/v1 -c przykład_konfiguracji.json

# Dodatkowe opcje
./api_tester.py -c przykład_konfiguracji.json -v -o wyniki.json -t 15


#Opcje wiersza poleceń:

-c, --config - ścieżka do pliku konfiguracyjnego JSON
-u, --url - bazowy URL API
-t, --timeout - timeout żądań w sekundach (domyślnie 10)
-v, --verbose - tryb szczegółowy (wyświetla fragmenty odpowiedzi)
-o, --output - plik wyjściowy dla wyników testów

Struktura pliku konfiguracyjnego:
Skrypt używa pliku JSON z przykładem, który również utworzyłem. Możesz go dostosować do swoich potrzeb, definiując:

base_url - bazowy URL dla wszystkich endpointów
endpoints - tablica obiektów opisujących poszczególne endpointy do testowania

Dla każdego endpointu możesz zdefiniować:

name - nazwa testu (dla celów raportowania)
path - ścieżka endpointu (zostanie dodana do base_url)
method - metoda HTTP (GET, POST, PUT, PATCH, DELETE)
expected_status - oczekiwany kod statusu HTTP
headers - nagłówki HTTP do wysłania
payload - dane JSON do wysłania (dla POST, PUT, PATCH)
validate - zasady walidacji odpowiedzi JSON

Dostępne zasady walidacji:

field_exists - sprawdza, czy określone pole istnieje
field_value - sprawdza wartość pola
array_length - sprawdza długość tablicy
"""

import argparse
import json
import os
import requests
import sys
import time
from datetime import datetime
from colorama import init, Fore, Style
from concurrent.futures import ThreadPoolExecutor

# Inicjalizacja kolorów w terminalu
init(autoreset=True)

class APITester:
    def __init__(self, config_file=None, base_url=None, timeout=10, verbose=False, output=None):
        self.base_url = base_url
        self.timeout = timeout
        self.verbose = verbose
        self.output_file = output
        self.results = []
        self.config = {}
        
        if config_file:
            self.load_config(config_file)
        
    def load_config(self, config_file):
        """Ładowanie konfiguracji z pliku JSON"""
        try:
            with open(config_file, 'r') as f:
                self.config = json.load(f)
                
            if not self.base_url and 'base_url' in self.config:
                self.base_url = self.config['base_url']
                
            print(f"{Fore.GREEN}Załadowano konfigurację z {config_file}")
        except Exception as e:
            print(f"{Fore.RED}Błąd podczas ładowania konfiguracji: {e}")
            sys.exit(1)
            
    def run_tests(self):
        """Uruchomienie wszystkich testów"""
        if not self.base_url:
            print(f"{Fore.RED}Brak adresu podstawowego API (base_url)")
            sys.exit(1)
            
        if not self.config.get('endpoints'):
            print(f"{Fore.RED}Brak zdefiniowanych endpointów w konfiguracji")
            sys.exit(1)
            
        print(f"{Fore.CYAN}Rozpoczynam testowanie API: {self.base_url}")
        start_time = time.time()
        
        # Równoległe wykonanie testów
        with ThreadPoolExecutor(max_workers=10) as executor:
            for endpoint in self.config['endpoints']:
                executor.submit(self.test_endpoint, endpoint)
                
        duration = time.time() - start_time
        self.print_summary(duration)
        
        if self.output_file:
            self.save_results()
            
    def test_endpoint(self, endpoint_config):
        """Test pojedynczego endpointu"""
        endpoint = endpoint_config.get('path', '')
        method = endpoint_config.get('method', 'GET')
        expected_status = endpoint_config.get('expected_status', 200)
        headers = endpoint_config.get('headers', {})
        payload = endpoint_config.get('payload', None)
        name = endpoint_config.get('name', endpoint)
        validate = endpoint_config.get('validate', None)
        
        url = f"{self.base_url.rstrip('/')}/{endpoint.lstrip('/')}"
        
        try:
            print(f"{Fore.CYAN}Testowanie: {method} {name} ({url})")
            
            response = self.make_request(method, url, headers, payload)
            status_code = response.status_code
            
            # Walidacja statusu
            status_ok = status_code == expected_status
            
            # Walidacja zawartości odpowiedzi
            validation_ok = True
            validation_error = None
            
            if status_ok and validate:
                try:
                    response_json = response.json()
                    validation_ok, validation_error = self.validate_response(response_json, validate)
                except json.JSONDecodeError:
                    validation_ok = False
                    validation_error = "Odpowiedź nie jest prawidłowym JSON"
                except Exception as e:
                    validation_ok = False
                    validation_error = str(e)
            
            # Tworzenie wyniku testu
            result = {
                'name': name,
                'url': url,
                'method': method,
                'status_code': status_code,
                'expected_status': expected_status,
                'status_ok': status_ok,
                'validation_ok': validation_ok,
                'validation_error': validation_error,
                'timestamp': datetime.now().isoformat(),
                'response_time_ms': round(response.elapsed.total_seconds() * 1000, 2)
            }
            
            self.results.append(result)
            
            # Wyświetlenie wyniku
            if status_ok and validation_ok:
                print(f"{Fore.GREEN}✓ {name}: {status_code} ({result['response_time_ms']} ms)")
            else:
                error_msg = f"Oczekiwano {expected_status}, otrzymano {status_code}"
                if validation_error:
                    error_msg += f", walidacja: {validation_error}"
                print(f"{Fore.RED}✗ {name}: {error_msg}")
                
            if self.verbose:
                print(f"  Odpowiedź: {response.text[:200]}{'...' if len(response.text) > 200 else ''}")
                
        except requests.RequestException as e:
            print(f"{Fore.RED}✗ {name}: Błąd żądania: {e}")
            self.results.append({
                'name': name,
                'url': url,
                'method': method,
                'error': str(e),
                'timestamp': datetime.now().isoformat()
            })
            
    def make_request(self, method, url, headers, payload):
        """Wykonanie żądania HTTP"""
        method = method.upper()
        
        if method == 'GET':
            return requests.get(url, headers=headers, timeout=self.timeout)
        elif method == 'POST':
            return requests.post(url, headers=headers, json=payload, timeout=self.timeout)
        elif method == 'PUT':
            return requests.put(url, headers=headers, json=payload, timeout=self.timeout)
        elif method == 'PATCH':
            return requests.patch(url, headers=headers, json=payload, timeout=self.timeout)
        elif method == 'DELETE':
            return requests.delete(url, headers=headers, timeout=self.timeout)
        else:
            raise ValueError(f"Nieobsługiwana metoda HTTP: {method}")
            
    def validate_response(self, response_data, validate_rules):
        """Walidacja odpowiedzi na podstawie zasad"""
        for rule in validate_rules:
            rule_type = rule.get('type', '')
            
            if rule_type == 'field_exists':
                field = rule.get('field', '')
                if not self._check_field_exists(response_data, field):
                    return False, f"Brak pola '{field}'"
                    
            elif rule_type == 'field_value':
                field = rule.get('field', '')
                expected = rule.get('value')
                if not self._check_field_value(response_data, field, expected):
                    return False, f"Nieprawidłowa wartość pola '{field}'"
                    
            elif rule_type == 'array_length':
                field = rule.get('field', '')
                min_length = rule.get('min', 0)
                max_length = rule.get('max', float('inf'))
                
                if not self._check_array_length(response_data, field, min_length, max_length):
                    return False, f"Nieprawidłowa długość tablicy '{field}'"
                    
        return True, None
        
    def _check_field_exists(self, data, field_path):
        """Sprawdzenie czy pole istnieje w odpowiedzi"""
        parts = field_path.split('.')
        current = data
        
        for part in parts:
            if isinstance(current, dict) and part in current:
                current = current[part]
            else:
                return False
                
        return True
        
    def _check_field_value(self, data, field_path, expected_value):
        """Sprawdzenie wartości pola"""
        parts = field_path.split('.')
        current = data
        
        for part in parts:
            if isinstance(current, dict) and part in current:
                current = current[part]
            else:
                return False
                
        return current == expected_value
        
    def _check_array_length(self, data, field_path, min_length, max_length):
        """Sprawdzenie długości tablicy"""
        parts = field_path.split('.')
        current = data
        
        for part in parts:
            if isinstance(current, dict) and part in current:
                current = current[part]
            else:
                return False
                
        if not isinstance(current, list):
            return False
            
        length = len(current)
        return min_length <= length <= max_length
        
    def print_summary(self, duration):
        """Wyświetlenie podsumowania testów"""
        total = len(self.results)
        successful = sum(1 for r in self.results if r.get('status_ok', False) and r.get('validation_ok', True))
        failed = total - successful
        
        print("\n" + "=" * 50)
        print(f"{Fore.CYAN}PODSUMOWANIE TESTÓW API")
        print("=" * 50)
        print(f"Łączna liczba testów: {total}")
        print(f"Udane testy: {Fore.GREEN}{successful}")
        print(f"Nieudane testy: {Fore.RED}{failed}")
        print(f"Czas wykonania: {duration:.2f} sekund")
        print("=" * 50)
        
    def save_results(self):
        """Zapis wyników do pliku JSON"""
        try:
            with open(self.output_file, 'w') as f:
                json.dump({
                    'base_url': self.base_url,
                    'timestamp': datetime.now().isoformat(),
                    'results': self.results
                }, f, indent=2)
                
            print(f"{Fore.GREEN}Zapisano wyniki do pliku {self.output_file}")
        except Exception as e:
            print(f"{Fore.RED}Błąd podczas zapisywania wyników: {e}")


def main():
    parser = argparse.ArgumentParser(description='Narzędzie do automatycznego testowania endpointów API')
    parser.add_argument('-c', '--config', help='Ścieżka do pliku konfiguracyjnego JSON')
    parser.add_argument('-u', '--url', help='Bazowy URL API')
    parser.add_argument('-t', '--timeout', type=int, default=10, help='Timeout żądań (sekundy)')
    parser.add_argument('-v', '--verbose', action='store_true', help='Tryb szczegółowy')
    parser.add_argument('-o', '--output', help='Plik wyjściowy dla wyników testów')
    
    args = parser.parse_args()
    
    if not args.config and not args.url:
        parser.print_help()
        sys.exit(1)
        
    tester = APITester(
        config_file=args.config,
        base_url=args.url,
        timeout=args.timeout,
        verbose=args.verbose,
        output=args.output
    )
    
    tester.run_tests()

if __name__ == '__main__':
    main()