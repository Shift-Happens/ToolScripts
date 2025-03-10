# ToolScripts

A collection of useful scripts that I use regularly for various automation tasks and productivity enhancements.

## Overview

This repository serves as a centralized location for all my commonly used scripts. By storing them in one place, I can easily access, update, and share these tools across different systems.

## Repository Structure

```
ToolScripts/
├── bash/                           # Shell scripts for Linux/Unix systems
│   ├── DockerCleanup.sh            # Clean up unused Docker resources
│   ├── FindDuplicateFiles.sh       # Find and manage duplicate files
│   ├── NetworkAnalyzer.sh          # Analyze network connections and performance
│   ├── server_deep_inventory.sh    # Collect detailed server information
│   ├── SystemCleanup.sh            # Clean temporary files and optimize system
│   └── SystemUpdate.sh             # Update system packages
│
├── Docker/                         # Docker-related resources
│   ├── database-migration-container # Container for database migrations
│   ├── fullstack-app-template      # Complete stack template (frontend/backend/db)
│   ├── logging-pipeline            # Centralized logging setup
│   ├── microservice-starter-dockerfile # Template for microservices
│   ├── monitoring-stack            # Monitoring solution setup
│   └── multi-stage-dockerfile      # Optimized multi-stage build examples
│
├── powershell/                     # PowerShell scripts for Windows
│   ├── ExportEventLogs.ps1         # Export and analyze Windows event logs
│   ├── GetSystemInventory.ps1      # Collect system information
│   └── RestartServicesSequentially.ps1 # Safely restart dependent services
│
├── python/                         # Python utility scripts
│   ├── api_tester.py               # Test and validate API endpoints
│   ├── api_tester_przyklad_konfiguracji.json # Example config for API tester
│   ├── certificate_lifecycle_manager.py # Manage SSL/TLS certificates
│   ├── database_migrator.py        # Database migration tool
│   ├── database_migrator_przyklad_konfiguracji.json # Example config for DB migrator
│   ├── file_syncer.py              # Sync files between locations
│   └── file_syncer_przyklad_konfiguracji.json # Example config for file syncer
│
└── terraform/                      # Infrastructure as Code templates
    ├── centralized-logging-module.tf # Centralized logging infrastructure
    ├── multi-region-dr-module.tf   # Multi-region disaster recovery setup
    ├── security-baseline-module.tf # Security baseline configuration
    └── vpc-network-module.tf       # VPC network configuration
```

## Usage

Most scripts include usage instructions at the top of the file or within example configuration JSON files.

## Categories

- **System Maintenance** - Scripts for cleaning, updating, and maintaining systems
- **Docker Resources** - Templates and configurations for containerized applications
- **Networking Tools** - Scripts for monitoring and managing network resources
- **Infrastructure as Code** - Terraform modules for cloud infrastructure
- **Automation** - Scripts that automate repetitive tasks
- **Security Tools** - Scripts for security monitoring and certificate management
