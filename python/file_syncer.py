#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
file_syncer.py - Synchronizacja katalogów między różnymi lokalizacjami.

OPIS:
    Skrypt służy do synchronizacji plików i katalogów między różnymi lokalizacjami,
    lokalnymi lub zdalnymi (przez SFTP/SCP). Obsługuje synchronizację jednokierunkową 
    lub dwukierunkową, filtrowanie według wzorców, wykrywanie kolizji i tworzenie kopii 
    zapasowych.

UŻYCIE:
    ./file_syncer.py [opcje] źródło cel
    ./file_syncer.py [opcje] --config plik_konfiguracyjny.json

OPCJE:
    -h, --help                      Wyświetla pomoc
    -c, --config PLIK               Użyj pliku konfiguracyjnego
    -d, --dry-run                   Symulacja (bez faktycznych zmian)
    -v, --verbose                   Tryb gadatliwy - więcej informacji
    -q, --quiet                     Tryb cichy - tylko błędy
    -s, --sync-mode TRYB            Tryb synchronizacji:
                                      one-way: ze źródła do celu (domyślnie)
                                      two-way: w obie strony
                                      mirror: cel będzie dokładnym odbiciem źródła
    -e, --exclude WZORZEC           Wzorzec plików do pominięcia (można użyć wielokrotnie)
    -i, --include WZORZEC           Wzorzec plików do uwzględnienia (można użyć wielokrotnie)
    -t, --timestamp                 Użyj znaczników czasu do porównania
    -z, --checksum                  Użyj sum kontrolnych do porównania
    -b, --backup                    Twórz kopie zapasowe przed nadpisaniem
    -f, --force                     Wymuś synchronizację (ignoruj konflikty)
    -l, --log PLIK                  Zapisz log operacji do pliku
    -p, --port PORT                 Port dla połączeń zdalnych
    --ssh-key PLIK                  Klucz SSH dla połączeń zdalnych

FORMAT ŚCIEŻKI:
    Lokalna:  /ścieżka/do/katalogu
    Zdalna:   użytkownik@host:/ścieżka/do/katalogu

PRZYKŁADY:
    # Synchronizacja lokalnych katalogów
    ./file_syncer.py ~/dokumenty /media/backup/dokumenty

    # Synchronizacja ze zdalnym serwerem (wymaga klucza SSH lub hasła)
    ./file_syncer.py ~/projekty user@server:/home/user/projekty

    # Synchronizacja z użyciem pliku konfiguracyjnego
    ./file_syncer.py --config sync_config.json

    # Synchronizacja z wykluczeniem plików tymczasowych
    ./file_syncer.py --exclude "*.tmp" --exclude "*.bak" ~/projekty /backup/projekty

    # Dokładne lustrzane odbicie (usuwanie plików w celu, których nie ma w źródle)
    ./file_syncer.py --sync-mode mirror ~/wzorzec/ /cel/

FORMAT PLIKU KONFIGURACYJNEGO (JSON):
    {
        "sync_pairs": [
            {
                "source": "/ścieżka/do/źródła",
                "destination": "/ścieżka/do/celu",
                "sync_mode": "one-way",
                "exclude": ["*.tmp", "*.log"],
                "include": ["*.py", "*.txt"],
                "use_checksum": true,
                "backup": true
            },
            {
                "source": "user@host:/remote/path",
                "destination": "/local/path",
                "sync_mode": "two-way",
                "ssh_key": "~/.ssh/id_rsa"
            }
        ],
        "global_options": {
            "verbose": true,
            "log_file": "/path/to/sync.log"
        }
    }

WYMAGANIA:
    - Python 3.6 lub nowszy
    - Biblioteki: paramiko (dla SFTP), typer, rich (dla kolorowego interfejsu)

INSTALACJA WYMAGANYCH BIBLIOTEK:
    pip install paramiko typer rich
"""

import argparse
import paramiko
import datetime
import fnmatch
import hashlib
import json
import logging
import os
import shutil
import sys
import time
from enum import Enum
from pathlib import Path
from typing import List, Dict, Any, Tuple, Optional, Set

try:
    import paramiko
    SFTP_AVAILABLE = True
except ImportError:
    SFTP_AVAILABLE = False

try:
    from rich.console import Console
    from rich.progress import Progress, BarColumn, TextColumn, TimeRemainingColumn
    from rich.logging import RichHandler
    RICH_AVAILABLE = True
except ImportError:
    RICH_AVAILABLE = False


# Definicje klas i stałych
class SyncMode(str, Enum):
    ONE_WAY = "one-way"
    TWO_WAY = "two-way"
    MIRROR = "mirror"


class FileAction(str, Enum):
    COPY = "copy"
    UPDATE = "update"
    DELETE = "delete"
    CONFLICT = "conflict"
    SKIP = "skip"


class PathType(str, Enum):
    LOCAL = "local"
    REMOTE = "remote"


VERSION = "1.0.0"
BUFFER_SIZE = 8192  # 8KB
MAX_WORKERS = 4  # Maksymalna liczba równoległych wątków


class FileSyncer:
    def __init__(self, options: Dict[str, Any]):
        """
        Inicjalizacja synchronizera plików z podanymi opcjami.

        Args:
            options: Słownik opcji konfiguracyjnych
        """
        # Podstawowe opcje
        self.source = options.get("source", "")
        self.destination = options.get("destination", "")
        self.dry_run = options.get("dry_run", False)
        self.verbose = options.get("verbose", False)
        self.quiet = options.get("quiet", False)
        self.sync_mode = options.get("sync_mode", SyncMode.ONE_WAY)
        self.exclude_patterns = options.get("exclude", [])
        self.include_patterns = options.get("include", [])
        self.use_timestamp = options.get("timestamp", True)
        self.use_checksum = options.get("checksum", False)
        self.backup = options.get("backup", False)
        self.force = options.get("force", False)
        self.log_file = options.get("log", "")
        self.ssh_port = options.get("port", 22)
        self.ssh_key = options.get("ssh_key", "")

        # Ustawienia logowania
        self._setup_logging()

        # Inicjalizacja klientów SFTP (jeśli potrzebne)
        self.source_sftp = None
        self.dest_sftp = None
        self.source_type = self._get_path_type(self.source)
        self.dest_type = self._get_path_type(self.destination)

        # Statystyki
        self.stats = {
            "copied": 0,
            "updated": 0,
            "deleted": 0,
            "skipped": 0,
            "conflicts": 0,
            "errors": 0,
            "bytes_transferred": 0,
            "start_time": time.time(),
            "end_time": 0
        }

        # Inicjalizacja rich console jeśli dostępne
        if RICH_AVAILABLE and not self.quiet:
            self.console = Console()
        else:
            self.console = None

    def _setup_logging(self) -> None:
        """Konfiguracja systemu logowania."""
        log_level = logging.WARNING
        if self.verbose:
            log_level = logging.DEBUG
        elif self.quiet:
            log_level = logging.ERROR

        # Konfiguracja handlera dla konsoli
        if RICH_AVAILABLE:
            console_handler = RichHandler(level=log_level, show_time=False)
            log_format = "%(message)s"
        else:
            console_handler = logging.StreamHandler()
            log_format = "%(asctime)s - %(levelname)s - %(message)s"
            console_handler.setFormatter(logging.Formatter(log_format))
            console_handler.setLevel(log_level)

        # Podstawowa konfiguracja logging
        self.logger = logging.getLogger("file_syncer")
        self.logger.setLevel(log_level)
        self.logger.addHandler(console_handler)
        self.logger.propagate = False

        # Dodaj handler pliku jeśli określono
        if self.log_file:
            file_handler = logging.FileHandler(self.log_file, mode='a', encoding='utf-8')
            file_handler.setFormatter(logging.Formatter(
                "%(asctime)s - %(levelname)s - %(message)s"
            ))
            file_handler.setLevel(log_level)
            self.logger.addHandler(file_handler)

    def _get_path_type(self, path: str) -> PathType:
        """
        Określa typ ścieżki (lokalna lub zdalna).

        Args:
            path: Ścieżka do sprawdzenia

        Returns:
            PathType.REMOTE jeśli ścieżka jest zdalna, PathType.LOCAL w przeciwnym razie
        """
        return PathType.REMOTE if "@" in path and ":" in path else PathType.LOCAL

    def _parse_remote_path(self, path: str) -> Tuple[str, str, str]:
        """
        Parsuje zdalną ścieżkę na komponenty: użytkownik, host, ścieżka.

        Args:
            path: Zdalna ścieżka w formacie user@host:/path

        Returns:
            Tuple zawierające (użytkownik, host, ścieżkę)
        """
        user_host, remote_path = path.split(":", 1)
        if "@" in user_host:
            username, hostname = user_host.split("@", 1)
        else:
            username = os.environ.get("USER", "")
            hostname = user_host

        return username, hostname, remote_path

    def _connect_sftp(self, path: str) -> Tuple[paramiko.SFTPClient, str]:
        """
        Łączy się z serwerem SFTP.

        Args:
            path: Ścieżka w formacie user@host:/path

        Returns:
            Tuple zawierające (klienta SFTP, ścieżkę na serwerze)
        """
        if not SFTP_AVAILABLE:
            self.logger.error("Moduł paramiko jest wymagany dla operacji SFTP. Zainstaluj: pip install paramiko")
            sys.exit(1)

        username, hostname, remote_path = self._parse_remote_path(path)
        try:
            client = paramiko.SSHClient()
            client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
            
            # Opcje połączenia
            connect_kwargs = {
                "username": username,
                "port": self.ssh_port,
                "timeout": 10,
            }
            
            # Użyj klucza SSH jeśli podany
            if self.ssh_key:
                key_path = os.path.expanduser(self.ssh_key)
                if os.path.isfile(key_path):
                    connect_kwargs["key_filename"] = key_path
                else:
                    self.logger.warning(f"Plik klucza SSH nie istnieje: {key_path}")
            
            self.logger.info(f"Łączenie z {username}@{hostname}...")
            client.connect(hostname, **connect_kwargs)
            sftp = client.open_sftp()
            return sftp, remote_path
        except Exception as e:
            self.logger.error(f"Błąd połączenia SFTP: {str(e)}")
            sys.exit(1)

    def setup_connections(self) -> None:
        """Ustanawia połączenia SFTP jeśli to konieczne."""
        if self.source_type == PathType.REMOTE:
            self.source_sftp, self.source = self._connect_sftp(self.source)
            self.logger.info(f"Połączono ze źródłowym serwerem SFTP: {self.source}")

        if self.dest_type == PathType.REMOTE:
            self.dest_sftp, self.destination = self._connect_sftp(self.destination)
            self.logger.info(f"Połączono z docelowym serwerem SFTP: {self.destination}")

    def close_connections(self) -> None:
        """Zamyka otwarte połączenia SFTP."""
        if self.source_sftp:
            try:
                self.source_sftp.close()
                self.source_sftp.get_channel().get_transport().close()
            except Exception:
                pass

        if self.dest_sftp:
            try:
                self.dest_sftp.close()
                self.dest_sftp.get_channel().get_transport().close()
            except Exception:
                pass

    def _path_exists(self, path: str, path_type: PathType) -> bool:
        """
        Sprawdza czy ścieżka istnieje lokalnie lub zdalnie.

        Args:
            path: Ścieżka do sprawdzenia
            path_type: Typ ścieżki (lokalna lub zdalna)

        Returns:
            True jeśli ścieżka istnieje, False w przeciwnym razie
        """
        try:
            if path_type == PathType.LOCAL:
                return os.path.exists(path)
            else:
                if path_type == PathType.REMOTE and self.source_type == PathType.REMOTE:
                    sftp = self.source_sftp
                else:
                    sftp = self.dest_sftp
                sftp.stat(path)
                return True
        except (FileNotFoundError, IOError):
            return False
        except Exception as e:
            self.logger.error(f"Błąd podczas sprawdzania ścieżki {path}: {str(e)}")
            return False

    def _list_files(self, directory: str, path_type: PathType) -> List[Dict[str, Any]]:
        """
        Zwraca listę plików i katalogów w podanym katalogu.

        Args:
            directory: Ścieżka do katalogu
            path_type: Typ ścieżki (lokalna lub zdalna)

        Returns:
            Lista słowników z informacjami o plikach
        """
        files = []
        try:
            if path_type == PathType.LOCAL:
                for root, dirs, filenames in os.walk(directory):
                    for filename in filenames:
                        full_path = os.path.join(root, filename)
                        rel_path = os.path.relpath(full_path, directory)
                        stat = os.stat(full_path)
                        files.append({
                            "path": rel_path,
                            "full_path": full_path,
                            "size": stat.st_size,
                            "mtime": stat.st_mtime,
                            "is_dir": False
                        })
                    for dirname in dirs:
                        full_path = os.path.join(root, dirname)
                        rel_path = os.path.relpath(full_path, directory)
                        files.append({
                            "path": rel_path,
                            "full_path": full_path,
                            "size": 0,
                            "mtime": os.stat(full_path).st_mtime,
                            "is_dir": True
                        })
            else:
                # Użyj odpowiedniego klienta SFTP
                sftp = self.source_sftp if path_type == PathType.REMOTE and self.source_type == PathType.REMOTE else self.dest_sftp
                
                # Rekurencyjna funkcja do listowania plików przez SFTP
                def list_remote_dir(remote_dir, base_dir):
                    result = []
                    try:
                        items = sftp.listdir_attr(remote_dir)
                        for item in items:
                            full_path = os.path.join(remote_dir, item.filename)
                            rel_path = os.path.relpath(full_path, base_dir)
                            
                            if stat.S_ISDIR(item.st_mode):
                                result.append({
                                    "path": rel_path,
                                    "full_path": full_path,
                                    "size": 0,
                                    "mtime": item.st_mtime,
                                    "is_dir": True
                                })
                                result.extend(list_remote_dir(full_path, base_dir))
                            else:
                                result.append({
                                    "path": rel_path,
                                    "full_path": full_path,
                                    "size": item.st_size,
                                    "mtime": item.st_mtime,
                                    "is_dir": False
                                })
                        return result
                    except Exception as e:
                        self.logger.error(f"Błąd podczas listowania zdalnego katalogu {remote_dir}: {str(e)}")
                        return []
                
                files = list_remote_dir(directory, directory)
        except Exception as e:
            self.logger.error(f"Błąd podczas listowania plików w {directory}: {str(e)}")
        
        return files

    def _should_include_file(self, filepath: str) -> bool:
        """
        Sprawdza czy plik powinien być uwzględniony w synchronizacji.

        Args:
            filepath: Ścieżka do pliku (względna)

        Returns:
            True jeśli plik powinien być uwzględniony, False w przeciwnym razie
        """
        filename = os.path.basename(filepath)
        
        # Najpierw sprawdź wzorce do wykluczenia
        for pattern in self.exclude_patterns:
            if fnmatch.fnmatch(filepath, pattern) or fnmatch.fnmatch(filename, pattern):
                return False
        
        # Jeśli są wzorce do uwzględnienia, plik musi pasować do co najmniej jednego
        if self.include_patterns:
            for pattern in self.include_patterns:
                if fnmatch.fnmatch(filepath, pattern) or fnmatch.fnmatch(filename, pattern):
                    return True
            return False
        
        # Domyślnie uwzględnij plik (jeśli nie było wzorców include)
        return True

    def _calculate_checksum(self, filepath: str, path_type: PathType) -> str:
        """
        Oblicza sumę kontrolną pliku.

        Args:
            filepath: Ścieżka do pliku
            path_type: Typ ścieżki (lokalna lub zdalna)

        Returns:
            Suma kontrolna jako string
        """
        hasher = hashlib.md5()
        
        try:
            if path_type == PathType.LOCAL:
                with open(filepath, 'rb') as f:
                    while chunk := f.read(BUFFER_SIZE):
                        hasher.update(chunk)
            else:
                sftp = self.source_sftp if path_type == PathType.REMOTE and self.source_type == PathType.REMOTE else self.dest_sftp
                with sftp.open(filepath, 'rb') as f:
                    while chunk := f.read(BUFFER_SIZE):
                        hasher.update(chunk)
                        
            return hasher.hexdigest()
        except Exception as e:
            self.logger.warning(f"Nie można obliczyć sumy kontrolnej dla {filepath}: {str(e)}")
            return ""

    def _create_directory(self, dirpath: str, path_type: PathType) -> bool:
        """
        Tworzy katalog (i katalogi nadrzędne jeśli potrzeba).

        Args:
            dirpath: Ścieżka do katalogu
            path_type: Typ ścieżki (lokalna lub zdalna)

        Returns:
            True jeśli operacja się powiodła, False w przeciwnym razie
        """
        if self.dry_run:
            self.logger.info(f"[DRY RUN] Tworzenie katalogu: {dirpath}")
            return True
            
        try:
            if path_type == PathType.LOCAL:
                os.makedirs(dirpath, exist_ok=True)
            else:
                sftp = self.dest_sftp
                # Rekurencyjne tworzenie katalogów
                path_parts = dirpath.split('/')
                current_path = ""
                
                for part in path_parts:
                    if not part:
                        continue
                        
                    current_path = current_path + '/' + part if current_path else part
                    
                    try:
                        sftp.stat(current_path)
                    except IOError:
                        sftp.mkdir(current_path)
                        
            return True
        except Exception as e:
            self.logger.error(f"Błąd podczas tworzenia katalogu {dirpath}: {str(e)}")
            self.stats["errors"] += 1
            return False

    def _copy_file(self, src_path: str, dest_path: str, 
                  src_type: PathType, dest_type: PathType) -> bool:
        """
        Kopiuje plik z lokalizacji źródłowej do docelowej.

        Args:
            src_path: Ścieżka źródłowa
            dest_path: Ścieżka docelowa
            src_type: Typ ścieżki źródłowej
            dest_type: Typ ścieżki docelowej

        Returns:
            True jeśli operacja się powiodła, False w przeciwnym razie
        """
        if self.dry_run:
            self.logger.info(f"[DRY RUN] Kopiowanie: {src_path} -> {dest_path}")
            return True
            
        # Tworzenie katalogu docelowego jeśli nie istnieje
        dest_dir = os.path.dirname(dest_path)
        if dest_dir and not self._path_exists(dest_dir, dest_type):
            if not self._create_directory(dest_dir, dest_type):
                return False
        
        # Tworzenie kopii zapasowej jeśli włączone
        if self.backup and self._path_exists(dest_path, dest_type):
            backup_path = f"{dest_path}.bak.{int(time.time())}"
            try:
                if dest_type == PathType.LOCAL:
                    shutil.copy2(dest_path, backup_path)
                else:
                    self.dest_sftp.get(dest_path, backup_path + ".tmp")
                    self.dest_sftp.put(backup_path + ".tmp", backup_path)
                    os.unlink(backup_path + ".tmp")
                self.logger.info(f"Utworzono kopię zapasową: {backup_path}")
            except Exception as e:
                self.logger.warning(f"Nie można utworzyć kopii zapasowej {dest_path}: {str(e)}")
        
        try:
            # Inicjalizacja progress bar jeśli dostępny
            if RICH_AVAILABLE and self.console and not self.quiet:
                file_size = 0
                if src_type == PathType.LOCAL:
                    file_size = os.path.getsize(src_path)
                else:
                    file_stats = self.source_sftp.stat(src_path)
                    file_size = file_stats.st_size
                
                self.console.print(f"Kopiowanie: {os.path.basename(src_path)}")
                with Progress(
                    TextColumn("[progress.description]{task.description}"),
                    BarColumn(),
                    TextColumn("[progress.percentage]{task.percentage:>3.0f}%"),
                    TimeRemainingColumn(),
                    console=self.console
                ) as progress:
                    task = progress.add_task(f"[cyan]{os.path.basename(src_path)}", total=file_size)
                    
                    # Lokalne do lokalnego
                    if src_type == PathType.LOCAL and dest_type == PathType.LOCAL:
                        with open(src_path, 'rb') as src, open(dest_path, 'wb') as dest:
                            copied = 0
                            while chunk := src.read(BUFFER_SIZE):
                                dest.write(chunk)
                                copied += len(chunk)
                                progress.update(task, completed=copied)
                                self.stats["bytes_transferred"] += len(chunk)
                    
                    # Lokalne do zdalnego
                    elif src_type == PathType.LOCAL and dest_type == PathType.REMOTE:
                        with open(src_path, 'rb') as src:
                            with self.dest_sftp.open(dest_path, 'wb') as dest:
                                copied = 0
                                while chunk := src.read(BUFFER_SIZE):
                                    dest.write(chunk)
                                    copied += len(chunk)
                                    progress.update(task, completed=copied)
                                    self.stats["bytes_transferred"] += len(chunk)
                    
                    # Zdalne do lokalnego
                    elif src_type == PathType.REMOTE and dest_type == PathType.LOCAL:
                        with self.source_sftp.open(src_path, 'rb') as src:
                            with open(dest_path, 'wb') as dest:
                                copied = 0
                                while chunk := src.read(BUFFER_SIZE):
                                    dest.write(chunk)
                                    copied += len(chunk)
                                    progress.update(task, completed=copied)
                                    self.stats["bytes_transferred"] += len(chunk)
                    
                    # Zdalne do zdalnego
                    elif src_type == PathType.REMOTE and dest_type == PathType.REMOTE:
                        # Pobierz do tymczasowego pliku, potem wyślij
                        temp_path = f"/tmp/file_syncer_temp_{os.getpid()}_{int(time.time())}"
                        try:
                            with self.source_sftp.open(src_path, 'rb') as src:
                                with open(temp_path, 'wb') as temp:
                                    copied = 0
                                    while chunk := src.read(BUFFER_SIZE):
                                        temp.write(chunk)
                                        copied += len(chunk)
                                        progress.update(task, completed=copied//2)
                                        self.stats["bytes_transferred"] += len(chunk)
                            
                            with open(temp_path, 'rb') as temp:
                                with self.dest_sftp.open(dest_path, 'wb') as dest:
                                    copied = 0
                                    total = os.path.getsize(temp_path)
                                    while chunk := temp.read(BUFFER_SIZE):
                                        dest.write(chunk)
                                        copied += len(chunk)
                                        progress.update(task, completed=(file_size//2) + (copied//2))
                                        self.stats["bytes_transferred"] += len(chunk)
                        finally:
                            if os.path.exists(temp_path):
                                os.unlink(temp_path)
            else:
                # Kopiowanie bez progress bar
                if src_type == PathType.LOCAL and dest_type == PathType.LOCAL:
                    shutil.copy2(src_path, dest_path)
                    self.stats["bytes_transferred"] += os.path.getsize(src_path)
                elif src_type == PathType.LOCAL and dest_type == PathType.REMOTE:
                    self.dest_sftp.put(src_path, dest_path)
                    self.stats["bytes_transferred"] += os.path.getsize(src_path)
                elif src_type == PathType.REMOTE and dest_type == PathType.LOCAL:
                    self.source_sftp.get(src_path, dest_path)
                    self.stats["bytes_transferred"] += os.path.getsize(dest_path)
                elif src_type == PathType.REMOTE and dest_type == PathType.REMOTE:
                    temp_path = f"/tmp/file_syncer_temp_{os.getpid()}_{int(time.time())}"
                    try:
                        self.source_sftp.get(src_path, temp_path)
                        self.dest_sftp.put(temp_path, dest_path)
                        self.stats["bytes_transferred"] += os.path.getsize(temp_path)
                    finally:
                        if os.path.exists(temp_path):
                            os.unlink(temp_path)
            
            return True
        except Exception as e:
            self.logger.error(f"Błąd podczas kopiowania {src_path} -> {dest_path}: {str(e)}")
            self.stats["errors"] += 1
            return False

    def _delete_path(self, path: str, path_type: PathType, is_dir: bool = False) -> bool:
        """
        Usuwa plik lub katalog.

        Args:
            path: Ścieżka do usunięcia
            path_type: Typ ścieżki (lokalna lub zdalna)
            is_dir: Czy ścieżka jest katalogiem

        Returns:
            True jeśli operacja się powiodła, False w przeciwnym razie
        """
        if self.dry_run:
            self.logger.info(f"[DRY RUN] Usuwanie: {path}")
            return True
            
        # Tworzenie kopii zapasowej jeśli włączone
        if self.backup and not is_dir:
            backup_path = f"{path}.bak.{int(time.time())}"
            try:
                if path_type == PathType.LOCAL:
                    shutil.copy2(path, backup_path)
                else:
                    temp_file = f"/tmp/file_syncer_backup_{os.getpid()}_{int(time.time())}"
                    sftp = self.dest_sftp
                    sftp.get(path, temp_file)
                    if path_type == PathType.LOCAL:
                        shutil.move(temp_file, backup_path)
                    else:
                        sftp.put(temp_file, backup_path)
                        os.unlink(temp_file)
                self.logger.info(f"Utworzono kopię zapasową przed usunięciem: {backup_path}")
            except Exception as e:
                self.logger.warning(f"Nie można utworzyć kopii zapasowej {path}: {str(e)}")
            
        try:
            if path_type == PathType.LOCAL:
                if is_dir:
                    shutil.rmtree(path)
                else:
                    os.unlink(path)
            else:
                sftp = self.dest_sftp
                if is_dir:
                    # Rekurencyjne usuwanie katalogów
                    def rmdir_recursive(sftp, path):
                        try:
                            files = sftp.listdir(path)
                            for f in files:
                                filepath = os.path.join(path, f)
                                try:
                                    sftp.remove(filepath)
                                except IOError:
                                    rmdir_recursive(sftp, filepath)
                            sftp.rmdir(path)
                        except IOError as e:
                            self.logger.error(f"Błąd podczas usuwania zdalnego katalogu {path}: {str(e)}")
                    
                    rmdir_recursive(sftp, path)
                else:
                    sftp.remove(path)
                    
            self.logger.info(f"Usunięto: {path}")
            return True
        except Exception as e:
            self.logger.error(f"Błąd podczas usuwania {path}: {str(e)}")
            self.stats["errors"] += 1
            return False
            
    def _compare_files(self, source_file: Dict[str, Any], dest_file: Dict[str, Any],
                      source_path: str, dest_path: str) -> FileAction:
        """
        Porównuje dwa pliki i określa wymaganą akcję.
        
        Args:
            source_file: Informacje o pliku źródłowym
            dest_file: Informacje o pliku docelowym
            source_path: Pełna ścieżka do pliku źródłowego
            dest_path: Pełna ścieżka do pliku docelowego
            
        Returns:
            Akcja do wykonania (COPY, UPDATE, SKIP)
        """
        # Jeśli plik w miejscu docelowym nie istnieje, kopiuj
        if not dest_file:
            return FileAction.COPY
            
        # Jeśli rozmiary są różne, aktualizuj
        if source_file["size"] != dest_file["size"]:
            return FileAction.UPDATE
            
        # Porównanie na podstawie czasu modyfikacji
        if self.use_timestamp and not self.use_checksum:
            # Dodaj 2 sekundy marginesu ze względu na różnice w systemach plików
            if source_file["mtime"] > dest_file["mtime"] + 2:
                return FileAction.UPDATE
                
        # Porównanie na podstawie sumy kontrolnej
        if self.use_checksum:
            source_checksum = self._calculate_checksum(
                source_path, 
                PathType.REMOTE if self.source_type == PathType.REMOTE else PathType.LOCAL
            )
            dest_checksum = self._calculate_checksum(
                dest_path,
                PathType.REMOTE if self.dest_type == PathType.REMOTE else PathType.LOCAL
            )
            
            if source_checksum and dest_checksum and source_checksum != dest_checksum:
                return FileAction.UPDATE
                
        # Pliki są identyczne lub nie można określić różnicy
        return FileAction.SKIP
        
    def _detect_conflicts(self, source_files: Dict[str, Dict[str, Any]], 
                         dest_files: Dict[str, Dict[str, Any]]) -> List[str]:
        """
        Wykrywa konflikty między plikami (zmienione z obu stron).
        
        Args:
            source_files: Pliki źródłowe
            dest_files: Pliki docelowe
            
        Returns:
            Lista ścieżek plików z konfliktami
        """
        if self.sync_mode != SyncMode.TWO_WAY:
            return []
            
        conflicts = []
        
        for rel_path, source_file in source_files.items():
            if rel_path in dest_files:
                dest_file = dest_files[rel_path]
                
                # Pomiń katalogi
                if source_file["is_dir"] or dest_file["is_dir"]:
                    continue
                    
                # Sprawdź czy plik zmieniony z obu stron
                source_path = source_file["full_path"]
                dest_path = dest_file["full_path"]
                
                if self.use_checksum:
                    source_checksum = self._calculate_checksum(
                        source_path, 
                        PathType.REMOTE if self.source_type == PathType.REMOTE else PathType.LOCAL
                    )
                    dest_checksum = self._calculate_checksum(
                        dest_path,
                        PathType.REMOTE if self.dest_type == PathType.REMOTE else PathType.LOCAL
                    )
                    
                    # Jeśli pliki mają różne sumy kontrolne i oba zostały zmienione od ostatniej synchronizacji
                    if source_checksum != dest_checksum:
                        # To jest uproszczone - w prawdziwej implementacji potrzebny byłby
                        # mechanizm śledzenia ostatniej synchronizacji
                        conflicts.append(rel_path)
                elif abs(source_file["mtime"] - dest_file["mtime"]) > 2:
                    # Używamy różnicy czasów jako prostej heurystyki
                    conflicts.append(rel_path)
                    
        return conflicts
        
    def _resolve_conflict(self, rel_path: str, source_file: Dict[str, Any], 
                         dest_file: Dict[str, Any]) -> FileAction:
        """
        Rozwiązuje konflikt między plikami.
        
        Args:
            rel_path: Względna ścieżka pliku
            source_file: Informacje o pliku źródłowym
            dest_file: Informacje o pliku docelowym
            
        Returns:
            Akcja do wykonania
        """
        if self.force:
            # W trybie wymuszonym używamy pliku źródłowego
            self.logger.warning(f"Konflikt rozwiązany na korzyść źródła (wymuszony tryb): {rel_path}")
            return FileAction.UPDATE
            
        # Sprawdź który plik jest nowszy
        if source_file["mtime"] > dest_file["mtime"]:
            self.logger.info(f"Konflikt rozwiązany na korzyść źródła (nowszy): {rel_path}")
            return FileAction.UPDATE
        else:
            self.logger.info(f"Konflikt rozwiązany na korzyść celu (nowszy): {rel_path}")
            return FileAction.SKIP
            
    def synchronize(self) -> bool:
        """
        Wykonuje synchronizację między źródłem a celem.
        
        Returns:
            True jeśli synchronizacja przebiegła pomyślnie
        """
        self.logger.info(f"Rozpoczynam synchronizację: {self.source} -> {self.destination}")
        self.logger.info(f"Tryb synchronizacji: {self.sync_mode}")
        
        # Sprawdź czy ścieżki istnieją
        if not self._path_exists(self.source, self.source_type):
            self.logger.error(f"Ścieżka źródłowa nie istnieje: {self.source}")
            return False
            
        if not self._path_exists(self.destination, self.dest_type) and self.sync_mode != SyncMode.MIRROR:
            if not self._create_directory(self.destination, self.dest_type):
                self.logger.error(f"Nie można utworzyć katalogu docelowego: {self.destination}")
                return False
        
        # Pobierz listy plików
        self.logger.info("Skanowanie katalogów...")
        source_files_list = self._list_files(self.source, self.source_type)
        
        # Filtruj pliki według wzorców
        source_files_list = [f for f in source_files_list if self._should_include_file(f["path"])]
        
        # Konwertuj na słownik dla szybszego dostępu
        source_files = {f["path"]: f for f in source_files_list}
        
        # Pobierz pliki docelowe jeśli katalog istnieje
        dest_files = {}
        if self._path_exists(self.destination, self.dest_type):
            dest_files_list = self._list_files(self.destination, self.dest_type)
            dest_files = {f["path"]: f for f in dest_files_list}
            
        self.logger.info(f"Znaleziono {len(source_files)} plików źródłowych i {len(dest_files)} plików docelowych")
        
        # Wykryj konflikty w trybie dwukierunkowym
        conflicts = self._detect_conflicts(source_files, dest_files)
        if conflicts:
            self.logger.warning(f"Wykryto {len(conflicts)} konfliktów")
            for conflict in conflicts:
                self.logger.warning(f"  Konflikt: {conflict}")
        
        # Przygotuj listy operacji
        to_copy = []
        to_update = []
        to_delete = []
        skipped = []
        
        # Pliki i katalogi do skopiowania lub aktualizacji (z źródła do celu)
        for rel_path, source_file in source_files.items():
            dest_file = dest_files.get(rel_path)
            source_path = source_file["full_path"]
            dest_path = os.path.join(self.destination, rel_path) if self.dest_type == PathType.LOCAL else \
                        os.path.join(self.destination, rel_path).replace('\\', '/')
            
            if source_file["is_dir"]:
                # Dla katalogów sprawdzamy tylko czy istnieją
                if not dest_file:
                    to_copy.append((source_path, dest_path, source_file["is_dir"]))
                continue
                
            # Sprawdź czy plik jest w konflikcie
            if rel_path in conflicts:
                action = self._resolve_conflict(rel_path, source_file, dest_file)
                if action == FileAction.SKIP:
                    skipped.append(rel_path)
                    self.stats["conflicts"] += 1
                    continue
            else:
                # Normalne porównanie plików
                action = self._compare_files(source_file, dest_file, source_path, dest_path)
                
            if action == FileAction.COPY:
                to_copy.append((source_path, dest_path, source_file["is_dir"]))
            elif action == FileAction.UPDATE:
                to_update.append((source_path, dest_path, source_file["is_dir"]))
            else:  # SKIP
                skipped.append(rel_path)
                
        # Pliki do usunięcia w trybie mirror
        if self.sync_mode == SyncMode.MIRROR:
            for rel_path, dest_file in dest_files.items():
                if rel_path not in source_files and self._should_include_file(rel_path):
                    dest_path = dest_file["full_path"]
                    to_delete.append((dest_path, dest_file["is_dir"]))
        
        # Wykonaj operacje
        self.logger.info(f"Pliki do skopiowania: {len(to_copy)}")
        self.logger.info(f"Pliki do aktualizacji: {len(to_update)}")
        self.logger.info(f"Pliki do usunięcia: {len(to_delete)}")
        self.logger.info(f"Pliki pominięte: {len(skipped)}")
        
        # Najpierw utwórz katalogi
        for source_path, dest_path, is_dir in to_copy:
            if is_dir:
                if self._create_directory(dest_path, self.dest_type):
                    self.stats["copied"] += 1
                    
        # Kopiuj nowe pliki
        for source_path, dest_path, is_dir in to_copy:
            if not is_dir:
                if self._copy_file(source_path, dest_path, 
                                 self.source_type, self.dest_type):
                    self.stats["copied"] += 1
                    
        # Aktualizuj istniejące pliki
        for source_path, dest_path, is_dir in to_update:
            if not is_dir:
                if self._copy_file(source_path, dest_path, 
                                 self.source_type, self.dest_type):
                    self.stats["updated"] += 1
                    
        # Usuń pliki (tylko w trybie mirror)
        for dest_path, is_dir in to_delete:
            if self._delete_path(dest_path, self.dest_type, is_dir):
                self.stats["deleted"] += 1
                
        self.stats["skipped"] = len(skipped)
        self.stats["end_time"] = time.time()
        
        return self.stats["errors"] == 0
        
    def print_summary(self) -> None:
        """Wyświetla podsumowanie operacji synchronizacji."""
        duration = self.stats["end_time"] - self.stats["start_time"]
        bytes_transferred_mb = self.stats["bytes_transferred"] / (1024 * 1024)
        
        self.logger.info("\n" + "=" * 60)
        self.logger.info("PODSUMOWANIE SYNCHRONIZACJI")
        self.logger.info("=" * 60)
        self.logger.info(f"Czas trwania: {duration:.2f} sekund")
        self.logger.info(f"Skopiowane pliki: {self.stats['copied']}")
        self.logger.info(f"Zaktualizowane pliki: {self.stats['updated']}")
        self.logger.info(f"Usunięte pliki: {self.stats['deleted']}")
        self.logger.info(f"Pominięte pliki: {self.stats['skipped']}")
        self.logger.info(f"Konflikty: {self.stats['conflicts']}")
        self.logger.info(f"Błędy: {self.stats['errors']}")
        self.logger.info(f"Przesłane dane: {bytes_transferred_mb:.2f} MB")
        
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
        
        
def main() -> None:
    """Główna funkcja programu."""
    parser = argparse.ArgumentParser(
        description="Narzędzie do synchronizacji katalogów między różnymi lokalizacjami.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__.split("UŻYCIE:")[0]  # Używa części dokumentacji jako epilog
    )
    
    parser.add_argument("source", nargs="?", help="Katalog źródłowy")
    parser.add_argument("destination", nargs="?", help="Katalog docelowy")
    parser.add_argument("-c", "--config", help="Ścieżka do pliku konfiguracyjnego")
    parser.add_argument("-d", "--dry-run", action="store_true", help="Symulacja (bez faktycznych zmian)")
    parser.add_argument("-v", "--verbose", action="store_true", help="Tryb gadatliwy - więcej informacji")
    parser.add_argument("-q", "--quiet", action="store_true", help="Tryb cichy - tylko błędy")
    parser.add_argument("-s", "--sync-mode", choices=["one-way", "two-way", "mirror"], 
                       default="one-way", help="Tryb synchronizacji")
    parser.add_argument("-e", "--exclude", action="append", default=[], help="Wzorzec plików do pominięcia")
    parser.add_argument("-i", "--include", action="append", default=[], help="Wzorzec plików do uwzględnienia")
    parser.add_argument("-t", "--timestamp", action="store_true", help="Użyj znaczników czasu do porównania")
    parser.add_argument("-z", "--checksum", action="store_true", help="Użyj sum kontrolnych do porównania")
    parser.add_argument("-b", "--backup", action="store_true", help="Twórz kopie zapasowe przed nadpisaniem")
    parser.add_argument("-f", "--force", action="store_true", help="Wymuś synchronizację (ignoruj konflikty)")
    parser.add_argument("-l", "--log", help="Zapisz log operacji do pliku")
    parser.add_argument("-p", "--port", type=int, default=22, help="Port dla połączeń zdalnych")
    parser.add_argument("--ssh-key", help="Klucz SSH dla połączeń zdalnych")
    parser.add_argument("--version", action="version", version=f"file_syncer.py {VERSION}")
    
    args = parser.parse_args()
    
    # Sprawdź wymagane moduły
    if not SFTP_AVAILABLE:
        print("UWAGA: Moduł 'paramiko' nie jest zainstalowany. Operacje SFTP nie będą dostępne.")
        
    if not RICH_AVAILABLE:
        print("UWAGA: Moduł 'rich' nie jest zainstalowany. Interfejs będzie ograniczony.")
    
    # Sprawdź czy podano źródło i cel lub plik konfiguracyjny
    if not args.config and (not args.source or not args.destination):
        parser.print_help()
        print("\nBłąD: Musisz podać źródło i cel lub plik konfiguracyjny.")
        sys.exit(1)
        
    # Jeśli podano plik konfiguracyjny
    if args.config:
        config = load_config_file(args.config)
        
        # Obsługa wielu par synchronizacji
        if "sync_pairs" in config:
            for i, pair_config in enumerate(config["sync_pairs"]):
                print(f"\nSynchronizacja pary {i+1}/{len(config['sync_pairs'])}")
                
                # Połącz globalne opcje z opcjami pary
                pair_options = {}
                if "global_options" in config:
                    pair_options.update(config["global_options"])
                pair_options.update(pair_config)
                
                # Nadpisz opcjami z wiersza poleceń
                if args.verbose:
                    pair_options["verbose"] = True
                if args.quiet:
                    pair_options["quiet"] = True
                if args.dry_run:
                    pair_options["dry_run"] = True
                
                syncer = FileSyncer(pair_options)
                
                try:
                    syncer.setup_connections()
                    success = syncer.synchronize()
                    syncer.print_summary()
                finally:
                    syncer.close_connections()
                    
                if not success and not args.dry_run:
                    print(f"Synchronizacja pary {i+1} zakończona z błędami.")
        else:
            # Pojedyncza para synchronizacji
            options = config
            
            # Nadpisz opcjami z wiersza poleceń
            if args.verbose:
                options["verbose"] = True
            if args.quiet:
                options["quiet"] = True
            if args.dry_run:
                options["dry_run"] = True
                
            syncer = FileSyncer(options)
            
            try:
                syncer.setup_connections()
                success = syncer.synchronize()
                syncer.print_summary()
            finally:
                syncer.close_connections()
                
            if not success and not args.dry_run:
                print("Synchronizacja zakończona z błędami.")
    else:
        # Użyj opcji z wiersza poleceń
        options = {
            "source": args.source,
            "destination": args.destination,
            "dry_run": args.dry_run,
            "verbose": args.verbose,
            "quiet": args.quiet,
            "sync_mode": args.sync_mode,
            "exclude": args.exclude,
            "include": args.include,
            "timestamp": args.timestamp,
            "checksum": args.checksum,
            "backup": args.backup,
            "force": args.force,
            "log": args.log,
            "port": args.port,
            "ssh_key": args.ssh_key
        }
        
        syncer = FileSyncer(options)
        
        try:
            syncer.setup_connections()
            success = syncer.synchronize()
            syncer.print_summary()
        finally:
            syncer.close_connections()
            
        if not success and not args.dry_run:
            print("Synchronizacja zakończona z błędami.")
            sys.exit(1)
            
            
if __name__ == "__main__":
    main()