# main.tf - Główny plik modułu VPC Network

variable "vpc_name" {
  description = "Nazwa VPC"
  type        = string
}

variable "vpc_cidr" {
  description = "Blok CIDR dla VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "azs" {
  description = "Lista stref dostępności do użycia"
  type        = list(string)
}

variable "private_subnets" {
  description = "Lista bloków CIDR dla podsieci prywatnych"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "public_subnets" {
  description = "Lista bloków CIDR dla podsieci publicznych"
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
}

variable "enable_nat_gateway" {
  description = "Czy tworzyć bramy NAT"
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "Czy używać pojedynczej bramy NAT zamiast jednej na strefę"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tagi do przypisania wszystkim zasobom"
  type        = map(string)
  default     = {}
}

# Tworzenie VPC
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  
  tags = merge(
    {
      "Name" = var.vpc_name
    },
    var.tags
  )
}

# Tworzenie podsieci publicznych
resource "aws_subnet" "public" {
  count = length(var.public_subnets)
  
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnets[count.index]
  availability_zone       = var.azs[count.index % length(var.azs)]
  map_public_ip_on_launch = true
  
  tags = merge(
    {
      "Name" = "${var.vpc_name}-public-${var.azs[count.index % length(var.azs)]}"
      "Tier" = "Public"
    },
    var.tags
  )
}

# Tworzenie podsieci prywatnych
resource "aws_subnet" "private" {
  count = length(var.private_subnets)
  
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.private_subnets[count.index]
  availability_zone       = var.azs[count.index % length(var.azs)]
  
  tags = merge(
    {
      "Name" = "${var.vpc_name}-private-${var.azs[count.index % length(var.azs)]}"
      "Tier" = "Private"
    },
    var.tags
  )
}

# Internet Gateway
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  
  tags = merge(
    {
      "Name" = "${var.vpc_name}-igw"
    },
    var.tags
  )
}

# Elastic IP dla NAT Gateway
resource "aws_eip" "nat" {
  count = var.enable_nat_gateway ? (var.single_nat_gateway ? 1 : length(var.azs)) : 0
  
  domain = "vpc"
  
  tags = merge(
    {
      "Name" = "${var.vpc_name}-nat-eip-${count.index + 1}"
    },
    var.tags
  )
}

# NAT Gateway
resource "aws_nat_gateway" "this" {
  count = var.enable_nat_gateway ? (var.single_nat_gateway ? 1 : length(var.azs)) : 0
  
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  
  tags = merge(
    {
      "Name" = "${var.vpc_name}-nat-gw-${count.index + 1}"
    },
    var.tags
  )
  
  depends_on = [aws_internet_gateway.this]
}

# Tabela routingu dla podsieci publicznych
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  
  tags = merge(
    {
      "Name" = "${var.vpc_name}-public-rt"
    },
    var.tags
  )
}

# Reguła routingu do Internet Gateway dla podsieci publicznych
resource "aws_route" "public_internet_gateway" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

# Tabele routingu dla podsieci prywatnych
resource "aws_route_table" "private" {
  count = var.enable_nat_gateway ? (var.single_nat_gateway ? 1 : length(var.azs)) : 0
  
  vpc_id = aws_vpc.this.id
  
  tags = merge(
    {
      "Name" = var.single_nat_gateway ? "${var.vpc_name}-private-rt" : "${var.vpc_name}-private-rt-${var.azs[count.index]}"
    },
    var.tags
  )
}

# Reguły routingu do NAT Gateway dla podsieci prywatnych
resource "aws_route" "private_nat_gateway" {
  count = var.enable_nat_gateway ? (var.single_nat_gateway ? 1 : length(var.azs)) : 0
  
  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[count.index % (var.single_nat_gateway ? 1 : length(var.azs))].id
}

# Powiązanie tabeli routingu z podsieciami publicznymi
resource "aws_route_table_association" "public" {
  count = length(var.public_subnets)
  
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Powiązanie tabeli routingu z podsieciami prywatnymi
resource "aws_route_table_association" "private" {
  count = var.enable_nat_gateway ? length(var.private_subnets) : 0
  
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[var.single_nat_gateway ? 0 : count.index % length(var.azs)].id
}

# Outputs
output "vpc_id" {
  description = "ID utworzonego VPC"
  value       = aws_vpc.this.id
}

output "vpc_cidr_block" {
  description = "Blok CIDR VPC"
  value       = aws_vpc.this.cidr_block
}

output "public_subnets" {
  description = "Lista ID podsieci publicznych"
  value       = aws_subnet.public[*].id
}

output "private_subnets" {
  description = "Lista ID podsieci prywatnych"
  value       = aws_subnet.private[*].id
}

output "nat_gateway_ids" {
  description = "Lista ID bram NAT"
  value       = aws_nat_gateway.this[*].id
}

output "public_route_table_id" {
  description = "ID tabeli routingu dla podsieci publicznych"
  value       = aws_route_table.public.id
}

output "private_route_table_ids" {
  description = "Lista ID tabeli routingu dla podsieci prywatnych"
  value       = aws_route_table.private[*].id
}
