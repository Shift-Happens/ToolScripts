#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
database_migrator.py - Migracja danych między różnymi bazami danych

OPIS:
    Skrypt służy do migracji danych między różnymi systemami baz danych,
    np. MySQL, PostgreSQL, SQLite, MS SQL Server. Umożliwia selektywny
    transfer tabel, transformację danych podczas migracji oraz
    mapowanie typów danych między systemami.

UŻYCIE:
    ./database_migrator.py [opcje] --source ŹRÓDŁO --target CEL
    ./database_migrator.py [opcje] --config plik_konfiguracyjny.json
    ./database_migrator.py --interactive

OPCJE:
    -h, --help                      Wyświetla pomoc
    -c, --config PLIK               Użyj pliku konfiguracyjnego
    -i, --interactive               Tryb interaktywny
    -s, --source URL                Źródłowy URL połączenia z bazą danych
    -t, --target URL                Docelowy URL połączenia z bazą danych
    --tables TABELE                 Lista tabel do migracji (rozdzielone przecinkami)
    --exclude-tables TABELE         Lista tabel do wykluczenia (rozdzielone przecinkami)
    --batch-size ROZMIAR            Rozmiar paczki danych (domyślnie 1000)
    --truncate                      Wyczyść docelowe tabele przed migracją
    --create-tables                 Utwórz tabele w docelowej bazie, jeśli nie istnieją
    --drop-tables                   Usuń istniejące tabele w docelowej bazie przed migracją
    --map-types PLIK                Plik z mapowaniem typów danych
    --transform PLIK                Plik z funkcjami transformacji danych
    --only-schema                   Migruj tylko schemat, bez danych
    --dry-run                       Symulacja (bez faktycznych zmian)
    -v, --verbose                   Tryb gadatliwy - więcej informacji
    -q, --quiet                     Tryb cichy - tylko błędy
    --log PLIK                      Zapisz log operacji do pliku

FORMAT URL BAZY DANYCH:
    SQLite:     sqlite:///ścieżka/do/pliku.db
    MySQL:      mysql://użytkownik:hasło@host:port/nazwa_bazy
    PostgreSQL: postgresql://użytkownik:hasło@host:port/nazwa_bazy
    MS SQL:     mssql+pyodbc://użytkownik:hasło@host:port/nazwa_bazy?driver=ODBC+Driver+17+for+SQL+Server

PRZYKŁADY:
    # Migracja z MySQL do PostgreSQL
    ./database_migrator.py --source mysql://root:hasło@localhost/stara_baza \
                          --target postgresql://postgres:hasło@localhost/nowa_baza \
                          --tables klienci,zamówienia,produkty \
                          --create-tables

    # Migracja z SQLite do MySQL z czyszczeniem tabel docelowych
    ./database_migrator.py --source sqlite:///lokalna_baza.db \
                          --target mysql://root:hasło@localhost/nowa_baza \
                          --truncate --batch-size 500

    # Uruchomienie w trybie interaktywnym
    ./database_migrator.py --interactive

    # Użycie pliku konfiguracyjnego
    ./database_migrator.py --config migracja.json

FORMAT PLIKU KONFIGURACYJNEGO (JSON):
    {
        "source": "sqlite:///stara_baza.db",
        "target": "postgresql://postgres:hasło@localhost/nowa_baza",
        "tables": ["klienci", "zamówienia", "produkty"],
        "exclude_tables": ["logi", "tymczasowe"],
        "options": {
            "batch_size": 1000,
            "truncate": true,
            "create_tables": true,
            "dry_run": false,
            "verbose": true
        },
        "type_mappings": {
            "TEXT": "VARCHAR(255)",
            "INTEGER": "INT",
            "REAL": "FLOAT"
        },
        "transformations": {
            "klienci": {
                "email": "lower({value})",
                "telefon": "format_phone({value})"
            }
        }
    }

WYMAGANIA:
    - Python 3.6 lub nowszy
    - SQLAlchemy 1.4 lub nowszy
    - Sterowniki baz danych:
      - MySQL: mysqlclient lub pymysql
      - PostgreSQL: psycopg2
      - MS SQL: pyodbc
      - Oracle: cx_Oracle

INSTALACJA WYMAGANYCH BIBLIOTEK:
    pip install sqlalchemy mysqlclient psycopg2-binary pyodbc tqdm colorama
"""

import argparse
import datetime
import json
import logging
import os
import sys
import time
import traceback
from typing import Dict, List, Any, Tuple, Optional, Set, Callable

try:
    from sqlalchemy import create_engine, MetaData, Table, Column, inspect
    from sqlalchemy.ext.automap import automap_base
    from sqlalchemy.orm import Session
    from sqlalchemy.sql import text
    from sqlalchemy.schema import CreateTable
except ImportError:
    print("Nie znaleziono wymaganych bibliotek.")
    print("Zainstaluj wymagane pakiety: pip install sqlalchemy")
    sys.exit(1)

try:
    from tqdm import tqdm
    TQDM_AVAILABLE = True
except ImportError:
    TQDM_AVAILABLE = False

try:
    from colorama import init, Fore, Style
    init(autoreset=True)
    COLORAMA_AVAILABLE = True
except ImportError:
    COLORAMA_AVAILABLE = False


class DatabaseMigrator:
    def __init__(self, config: Dict[str, Any]):
        """
        Inicjalizacja migratora baz danych.
        
        Args:
            config: Słownik z konfiguracją migracji
        """
        # Konfiguracja źródła i celu
        self.source_url = config.get('source', '')
        self.target_url = config.get('target', '')
        
        # Tabele do przetworzenia
        self.tables = config.get('tables', [])
        self.exclude_tables = config.get('exclude_tables', [])
        
        # Opcje migracji
        options = config.get('options', {})
        self.batch_size = options.get('batch_size', 1000)
        self.truncate = options.get('truncate', False)
        self.create_tables = options.get('create_tables', False)
        self.drop_tables = options.get('drop_tables', False)
        self.only_schema = options.get('only_schema', False)
        self.dry_run = options.get('dry_run', False)
        self.verbose = options.get('verbose', False)
        self.quiet = options.get('quiet', False)
        
        # Mapowania typów i transformacje
        self.type_mappings = config.get('type_mappings', {})
        self.transformations = config.get('transformations', {})
        
        # Ustawienia logowania
        self.log_file = options.get('log_file', '')
        self._setup_logging()
        
        # Silniki i metadane baz danych
        self.source_engine = None
        self.target_engine = None
        self.source_metadata = None
        self.target_metadata = None
        self.source_inspector = None
        self.target_inspector = None
        
        # Statystyki migracji
        self.stats = {
            'start_time': None,
            'end_time': None,
            'tables_processed': 0,
            'tables_created': 0,
            'rows_processed': 0,
            'rows_migrated': 0,
            'errors': 0
        }
    
    def _setup_logging(self):
        """Konfiguracja systemu logowania."""
        log_level = logging.INFO
        if self.verbose:
            log_level = logging.DEBUG
        elif self.quiet:
            log_level = logging.ERROR
            
        # Formatowanie logów
        log_format = "%(asctime)s - %(levelname)s - %(message)s"
        formatter = logging.Formatter(log_format)
        
        # Logger
        self.logger = logging.getLogger("db_migrator")
        self.logger.setLevel(log_level)
        self.logger.handlers = []  # Usunięcie istniejących handlerów
        
        # Handler konsoli
        console_handler = logging.StreamHandler()
        console_handler.setFormatter(formatter)
        console_handler.setLevel(log_level)
        self.logger.addHandler(console_handler)
        
        # Handler pliku
        if self.log_file:
            try:
                file_handler = logging.FileHandler(self.log_file, mode='a', encoding='utf-8')
                file_handler.setFormatter(formatter)
                file_handler.setLevel(log_level)
                self.logger.addHandler(file_handler)
                self.logger.debug(f"Logi będą zapisywane do pliku: {self.log_file}")
            except Exception as e:
                self.logger.error(f"Nie można otworzyć pliku logów {self.log_file}: {str(e)}")
    
    def _colorize(self, text: str, color: str) -> str:
        """
        Koloruje tekst jeśli dostępna jest biblioteka colorama.
        
        Args:
            text: Tekst do pokolorowania
            color: Kolor (red, green, yellow, blue, magenta, cyan)
            
        Returns:
            Pokolorowany tekst lub oryginalny tekst
        """
        if not COLORAMA_AVAILABLE:
            return text
            
        colors = {
            'red': Fore.RED,
            'green': Fore.GREEN,
            'yellow': Fore.YELLOW,
            'blue': Fore.BLUE,
            'magenta': Fore.MAGENTA,
            'cyan': Fore.CYAN,
            'white': Fore.WHITE
        }
        
        return f"{colors.get(color, '')}{text}{Style.RESET_ALL}"
    
    def connect(self) -> bool:
        """
        Nawiązuje połączenia z bazami danych źródłową i docelową.
        
        Returns:
            True jeśli połączenia powiodły się, False w przeciwnym razie
        """
        self.logger.info(f"Łączenie z bazą źródłową: {self._mask_password(self.source_url)}")
        try:
            self.source_engine = create_engine(self.source_url)
            self.source_metadata = MetaData()
            self.source_metadata.reflect(bind=self.source_engine)
            self.source_inspector = inspect(self.source_engine)
            self.logger.info(self._colorize("Połączono z bazą źródłową", "green"))
        except Exception as e:
            self.logger.error(f"Błąd podczas łączenia z bazą źródłową: {str(e)}")
            return False
            
        self.logger.info(f"Łączenie z bazą docelową: {self._mask_password(self.target_url)}")
        try:
            self.target_engine = create_engine(self.target_url)
            self.target_metadata = MetaData()
            self.target_metadata.reflect(bind=self.target_engine)
            self.target_inspector = inspect(self.target_engine)
            self.logger.info(self._colorize("Połączono z bazą docelową", "green"))
        except Exception as e:
            self.logger.error(f"Błąd podczas łączenia z bazą docelową: {str(e)}")
            return False
            
        return True
    
    def _mask_password(self, url: str) -> str:
        """
        Maskuje hasło w URL bazy danych.
        
        Args:
            url: URL połączenia z bazą danych
            
        Returns:
            URL z zamaskowanym hasłem
        """
        if '//' not in url or '@' not in url:
            return url
            
        parts = url.split('@')
        auth_parts = parts[0].split('//')
        
        if ':' in auth_parts[1]:
            user, _ = auth_parts[1].split(':', 1)
            masked = f"{auth_parts[0]}//{user}:********@{parts[1]}"
        else:
            masked = url
            
        return masked
    
    def get_tables_to_process(self) -> List[str]:
        """
        Zwraca listę tabel do przetworzenia.
        
        Returns:
            Lista nazw tabel do migracji
        """
        available_tables = self.source_metadata.tables.keys()
        
        # Jeśli podano konkretne tabele
        if self.tables:
            # Sprawdź czy wszystkie podane tabele istnieją
            for table in self.tables:
                if table not in available_tables:
                    self.logger.warning(f"Tabela '{table}' nie istnieje w bazie źródłowej")
            
            return [t for t in self.tables if t in available_tables]
        
        # W przeciwnym razie użyj wszystkich tabel oprócz wykluczonych
        return [t for t in available_tables if t not in self.exclude_tables]
    
    def migrate_schema(self, table_name: str) -> bool:
        """
        Migruje schemat tabeli z bazy źródłowej do docelowej.
        
        Args:
            table_name: Nazwa tabeli
            
        Returns:
            True jeśli migracja schematu powiodła się, False w przeciwnym razie
        """
        self.logger.info(f"Migracja schematu tabeli '{table_name}'...")
        
        try:
            # Pobierz informacje o tabeli źródłowej
            source_table = self.source_metadata.tables[table_name]
            
            # Sprawdź czy tabela już istnieje w bazie docelowej
            if table_name in self.target_metadata.tables:
                if self.drop_tables:
                    if not self.dry_run:
                        self.target_metadata.tables[table_name].drop(self.target_engine)
                        self.logger.info(f"Usunięto istniejącą tabelę '{table_name}' w bazie docelowej")
                    else:
                        self.logger.info(f"[DRY RUN] Usunięto by istniejącą tabelę '{table_name}' w bazie docelowej")
                else:
                    self.logger.info(f"Tabela '{table_name}' już istnieje w bazie docelowej")
                    return True
            
            # Tworzenie tabeli w bazie docelowej
            if self.create_tables and not self.dry_run:
                # Pobierz definicję tabeli
                create_stmt = CreateTable(source_table)
                create_sql = str(create_stmt.compile(self.target_engine))
                
                # Zastosuj mapowania typów
                for source_type, target_type in self.type_mappings.items():
                    create_sql = create_sql.replace(source_type, target_type)
                
                # Utwórz tabelę
                with self.target_engine.connect() as conn:
                    conn.execute(text(create_sql))
                    conn.commit()
                
                self.logger.info(self._colorize(f"Utworzono tabelę '{table_name}' w bazie docelowej", "green"))
                self.stats['tables_created'] += 1
            elif self.dry_run:
                self.logger.info(f"[DRY RUN] Utworzono by tabelę '{table_name}' w bazie docelowej")
            
            return True
        except Exception as e:
            self.logger.error(f"Błąd podczas migracji schematu tabeli '{table_name}': {str(e)}")
            self.stats['errors'] += 1
            return False
    
    def migrate_data(self, table_name: str) -> bool:
        """
        Migruje dane z tabeli źródłowej do docelowej.
        
        Args:
            table_name: Nazwa tabeli
            
        Returns:
            True jeśli migracja danych powiodła się, False w przeciwnym razie
        """
        if self.only_schema:
            return True
            
        self.logger.info(f"Migracja danych tabeli '{table_name}'...")
        
        try:
            # Pobierz tabele
            source_table = self.source_metadata.tables[table_name]
            
            # Sprawdź czy tabela docelowa istnieje
            if table_name not in self.target_metadata.tables:
                if not self.create_tables:
                    self.logger.error(f"Tabela '{table_name}' nie istnieje w bazie docelowej")
                    return False
                else:
                    # Odśwież metadane docelowe
                    self.target_metadata = MetaData()
                    self.target_metadata.reflect(bind=self.target_engine)
            
            target_table = self.target_metadata.tables[table_name]
            
            # Wyczyść tabelę docelową jeśli potrzeba
            if self.truncate and not self.dry_run:
                with self.target_engine.connect() as conn:
                    conn.execute(target_table.delete())
                    conn.commit()
                self.logger.info(f"Wyczyszczono tabelę '{table_name}' w bazie docelowej")
            elif self.truncate and self.dry_run:
                self.logger.info(f"[DRY RUN] Wyczyszczono by tabelę '{table_name}' w bazie docelowej")
            
            # Policz liczbę wierszy
            row_count = 0
            with self.source_engine.connect() as conn:
                result = conn.execute(text(f"SELECT COUNT(*) FROM {table_name}"))
                row_count = result.scalar()
            
            self.logger.info(f"Liczba wierszy do migracji: {row_count}")
            
            # Pobierz transformacje dla tabeli
            transformations = self.transformations.get(table_name, {})
            
            # Migruj dane paczkami
            offset = 0
            migrated_rows = 0
            
            with self.source_engine.connect() as source_conn:
                with self.target_engine.connect() as target_conn:
                    # Utworzenie paska postępu jeśli dostępny
                    pbar = None
                    if TQDM_AVAILABLE and not self.quiet:
                        pbar = tqdm(total=row_count, desc=f"Migracja '{table_name}'", 
                                    unit="wiersze", ncols=100)
                    
                    while True:
                        # Pobierz dane z tabeli źródłowej
                        select_stmt = text(f"SELECT * FROM {table_name} LIMIT {self.batch_size} OFFSET {offset}")
                        result = source_conn.execute(select_stmt)
                        batch = result.fetchall()
                        
                        if not batch:
                            break
                            
                        # Przetwarzanie danych
                        rows_to_insert = []
                        for row in batch:
                            processed_row = {}
                            
                            # Zastosuj transformacje
                            for col_name, col_value in row._mapping.items():
                                if col_name in transformations:
                                    transform_expr = transformations[col_name]
                                    try:
                                        # Zastąp {value} wartością kolumny
                                        expr = transform_expr.replace("{value}", repr(col_value))
                                        processed_row[col_name] = eval(expr)
                                    except Exception as e:
                                        self.logger.warning(f"Błąd transformacji kolumny {col_name}: {str(e)}")
                                        processed_row[col_name] = col_value
                                else:
                                    processed_row[col_name] = col_value
                            
                            rows_to_insert.append(processed_row)
                        
                        # Wstaw dane do tabeli docelowej
                        if not self.dry_run and rows_to_insert:
                            target_conn.execute(target_table.insert(), rows_to_insert)
                            target_conn.commit()
                            
                        migrated_rows += len(batch)
                        offset += self.batch_size
                        
                        # Aktualizuj pasek postępu
                        if pbar:
                            pbar.update(len(batch))
                    
                    # Zamknij pasek postępu
                    if pbar:
                        pbar.close()
            
            self.stats['rows_processed'] += row_count
            self.stats['rows_migrated'] += migrated_rows
            
            self.logger.info(self._colorize(
                f"Migracja danych tabeli '{table_name}' zakończona: {migrated_rows}/{row_count} wierszy", 
                "green"
            ))
            
            return True
        except Exception as e:
            self.logger.error(f"Błąd podczas migracji danych tabeli '{table_name}': {str(e)}")
            traceback.print_exc()
            self.stats['errors'] += 1
            return False
    
    def migrate(self) -> bool:
        """
        Wykonuje migrację bazy danych.
        
        Returns:
            True jeśli migracja powiodła się, False w przeciwnym razie
        """
        self.stats['start_time'] = time.time()
        
        # Nawiąż połączenia
        if not self.connect():
            return False
        
        # Pobierz listę tabel do migracji
        tables = self.get_tables_to_process()
        
        if not tables:
            self.logger.error("Brak tabel do migracji")
            return False
        
        self.logger.info(f"Rozpoczynam migrację {len(tables)} tabel")
        
        # Migruj każdą tabelę
        for table_name in tables:
            self.logger.info(self._colorize(f"Przetwarzanie tabeli '{table_name}'...", "cyan"))
            
            # Migruj schemat
            if not self.migrate_schema(table_name):
                continue
            
            # Migruj dane
            if not self.migrate_data(table_name):
                continue
            
            self.stats['tables_processed'] += 1
        
        self.stats['end_time'] = time.time()
        
        return self.stats['errors'] == 0
    
    def print_summary(self) -> None:
        """Wyświetla podsumowanie migracji."""
        duration = self.stats['end_time'] - self.stats['start_time']
        
        self.logger.info("\n" + "=" * 60)
        self.logger.info(self._colorize("PODSUMOWANIE MIGRACJI", "cyan"))
        self.logger.info("=" * 60)
        self.logger.info(f"Czas trwania: {duration:.2f} sekund")
        self.logger.info(f"Przetworzone tabele: {self.stats['tables_processed']}")
        self.logger.info(f"Utworzone tabele: {self.stats['tables_created']}")
        self.logger.info(f"Przetworzone wiersze: {self.stats['rows_processed']}")
        self.logger.info(f"Zmigrowane wiersze: {self.stats['rows_migrated']}")
        self.logger.info(f"Liczba błędów: {self.stats['errors']}")
        
        if self.dry_run:
            self.logger.info("\nTryb symulacji - nie wprowadzono żadnych zmian.")
        
        self.logger.info("=" * 60)


def load_config_file(config_path: str) -> Dict[str, Any]:
    """
    Ładuje konfigurację z pliku JSON.
    
    Args:
        config_path: Ścieżka do pliku konfiguracyjnego
        
    Returns:
        Słownik z konfiguracją
    """
    try:
        with open(config_path, 'r', encoding='utf-8') as f:
            config = json.load(f)
        return config
    except Exception as e:
        print(f"Błąd podczas ładowania pliku konfiguracyjnego: {str(e)}")
        sys.exit(1)


def interactive_config() -> Dict[str, Any]:
    """
    Tworzy konfigurację w trybie interaktywnym.
    
    Returns:
        Słownik z konfiguracją
    """
    config = {
        'options': {}
    }
    
    print("\n" + "=" * 60)
    print("KONFIGURACJA MIGRACJI BAZY DANYCH")
    print("=" * 60)
    
    # Podstawowe informacje
    config['source'] = input("URL bazy źródłowej: ")
    config['target'] = input("URL bazy docelowej: ")
    
    # Tabele
    tables_input = input("Tabele do migracji (rozdzielone przecinkami, puste = wszystkie): ")
    if tables_input.strip():
        config['tables'] = [t.strip() for t in tables_input.split(',')]
    
    # Opcje
    config['options']['batch_size'] = int(input("Rozmiar paczki danych [1000]: ") or "1000")
    config['options']['create_tables'] = input("Tworzyć tabele w bazie docelowej? (t/n) [t]: ").lower() != 'n'
    config['options']['truncate'] = input("Wyczyścić tabele docelowe przed migracją? (t/n) [n]: ").lower() == 't'
    config['options']['dry_run'] = input("Tryb symulacji (bez zmian)? (t/n) [n]: ").lower() == 't'
    config['options']['verbose'] = input("Tryb gadatliwy? (t/n) [t]: ").lower() != 'n'
    
    # Zapisz konfigurację do pliku
    save_config = input("Zapisać konfigurację do pliku? (t/n) [n]: ").lower() == 't'
    if save_config:
        config_path = input("Ścieżka do pliku: ")
        try:
            with open(config_path, 'w', encoding='utf-8') as f:
                json.dump(config, f, indent=4)
            print(f"Konfiguracja zapisana do pliku: {config_path}")
        except Exception as e:
            print(f"Błąd podczas zapisywania konfiguracji: {str(e)}")
    
    return config


def main() -> None:
    """Główna funkcja programu."""
    parser = argparse.ArgumentParser(
        description="Narzędzie do migracji danych między różnymi bazami danych.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__.split("UŻYCIE:")[0]  # Używa części dokumentacji jako epilog
    )
    
    parser.add_argument("-c", "--config", help="Ścieżka do pliku konfiguracyjnego")
    parser.add_argument("-i", "--interactive", action="store_true", help="Tryb interaktywny")
    parser.add_argument("-s", "--source", help="Źródłowy URL połączenia z bazą danych")
    parser.add_argument("-t", "--target", help="Docelowy URL połączenia z bazą danych")
    parser.add_argument("--tables", help="Lista tabel do migracji (rozdzielone przecinkami)")
    parser.add_argument("--exclude-tables", help="Lista tabel do wykluczenia (rozdzielone przecinkami)")
    parser.add_argument("--batch-size", type=int, default=1000, help="Rozmiar paczki danych")
    parser.add_argument("--truncate", action="store_true", help="Wyczyść docelowe tabele przed migracją")
    parser.add_argument("--create-tables", action="store_true", 
                       help="Utwórz tabele w docelowej bazie, jeśli nie istnieją")
    parser.add_argument("--drop-tables", action="store_true", 
                       help="Usuń istniejące tabele w docelowej bazie przed migracją")
    parser.add_argument("--only-schema", action="store_true", help="Migruj tylko schemat, bez danych")
    parser.add_argument("--dry-run", action="store_true", help="Symulacja (bez faktycznych zmian)")
    parser.add_argument("-v", "--verbose", action="store_true", help="Tryb gadatliwy - więcej informacji")
    parser.add_argument("-q", "--quiet", action="store_true", help="Tryb cichy - tylko błędy")
    parser.add_argument("--log", help="Zapisz log operacji do pliku")
    
    args = parser.parse_args()
    
    # Sprawdź wymagane moduły
    try:
        import sqlalchemy
        version = sqlalchemy.__version__
        if version < '1.4.0':
            print(f"UWAGA: Wykryto SQLAlchemy {version}. Zalecana wersja to 1.4 lub nowsza.")
    except ImportError:
        print("UWAGA: Moduł 'sqlalchemy' nie jest zainstalowany.")
        print("Zainstaluj wymagane pakiety: pip install sqlalchemy")
        sys.exit(1)
    
    # Tryb interaktywny
    if args.interactive:
        config = interactive_config()
    # Plik konfiguracyjny
    elif args.config:
        config = load_config_file(args.config)
    # Parametry z linii poleceń
    elif args.source and args.target:
        tables = []
        if args.tables:
            tables = [t.strip() for t in args.tables.split(',')]
            
        exclude_tables = []
        if args.exclude_tables:
            exclude_tables = [t.strip() for t in args.exclude_tables.split(',')]
        
        config = {
            'source': args.source,
            'target': args.target,
            'tables': tables,
            'exclude_tables': exclude_tables,
            'options': {
                'batch_size': args.batch_size,
                'truncate': args.truncate,
                'create_tables': args.create_tables,
                'drop_tables': args.drop_tables,
                'only_schema': args.only_schema,
                'dry_run': args.dry_run,
                'verbose': args.verbose,
                'quiet': args.quiet,
                'log_file': args.log
            }
        }
    else:
        parser.print_help()
        print("\nBŁĄD: Musisz podać źródło i cel, plik konfiguracyjny lub użyć trybu interaktywnego.")
        sys.exit(1)
    
    # Rozpocznij migrację
    migrator = DatabaseMigrator(config)
    
    success = migrator.migrate()
    migrator.print_summary()
    
    if not success:
        print("Migracja zakończona z błędami.")
        sys.exit(1)
    
    print("Migracja zakończona pomyślnie.")
        

if __name__ == "__main__":
    main()