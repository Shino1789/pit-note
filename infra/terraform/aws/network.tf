# ==================================================
# VPC
# ==================================================
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "pitvia-vpc"
  }
}

# ==================================================
# Subnet
# ==================================================
resource "aws_subnet" "public_1a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.0.0/20"
  availability_zone       = "ap-northeast-1a"
  map_public_ip_on_launch = false

  tags = {
    Name = "pitvia-vpc-subnet-public1-ap-northeast-1a"
  }
}

resource "aws_subnet" "public_1c" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.16.0/20"
  availability_zone       = "ap-northeast-1c"
  map_public_ip_on_launch = false

  tags = {
    Name = "pitvia-vpc-subnet-public2-ap-northeast-1c"
  }
}

resource "aws_subnet" "private_1a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.128.0/20"
  availability_zone = "ap-northeast-1a"

  tags = {
    Name = "pitvia-vpc-subnet-private1-ap-northeast-1a"
  }
}

resource "aws_subnet" "private_1c" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.144.0/20"
  availability_zone = "ap-northeast-1c"

  tags = {
    Name = "pitvia-vpc-subnet-private2-ap-northeast-1c"
  }
}

# ==================================================
# Internet Gateway
# ==================================================
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "pitvia-vpc-igw"
  }
}

# ==================================================
# Public Route Table（Public Subnet ×2）
# ==================================================
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "pitvia-vpc-rtb-public"
  }
}

resource "aws_route" "public_igw" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public_1a" {
  subnet_id      = aws_subnet.public_1a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_1c" {
  subnet_id      = aws_subnet.public_1c.id
  route_table_id = aws_route_table.public.id
}

# ==================================================
# Private Route Table（AZごとに1つ、NAT Gateway経由）
# ・NAT Gateway専用の特殊Route Table / Gateway Associationは
#   ここには含めない（AWSが自動生成するため。実機検証済み）
# ==================================================
resource "aws_route_table" "private_1a" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "pitvia-vpc-rtb-private1-ap-northeast-1a"
  }
}

resource "aws_route" "private_1a_nat" {
  route_table_id         = aws_route_table.private_1a.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main.id
}

resource "aws_route_table_association" "private_1a" {
  subnet_id      = aws_subnet.private_1a.id
  route_table_id = aws_route_table.private_1a.id
}

resource "aws_route_table" "private_1c" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "pitvia-vpc-rtb-private2-ap-northeast-1c"
  }
}

resource "aws_route" "private_1c_nat" {
  route_table_id         = aws_route_table.private_1c.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main.id
}

resource "aws_route_table_association" "private_1c" {
  subnet_id      = aws_subnet.private_1c.id
  route_table_id = aws_route_table.private_1c.id
}

# ==================================================
# NAT Gateway（Regional / Auto Mode）
# ・availability_mode = "regional" のみ指定し、subnet_idは指定しない
# ・実機検証（別VPCでのdestroy→apply×2サイクル）により、
#   この構成でAWSが専用Route Table + Gateway Associationを
#   自動生成し、Private Subnetからの通信が正常に成立することを確認済み
# ・allocation_idもあえて指定しない（Auto Mode）。実機のNAT Gateway
#   （nat-144eb2792674ecc3b）を確認した結果、EIPは2つとも
#   ServiceManaged=rnat（AWSがRegional NAT Gateway用に完全自動管理する
#   EIP）であり、ユーザー/Terraformが所有するEIPは存在しなかった。
#   allocation_idを指定してTerraformでEIPを作成・管理する構成にすると、
#   実機構成と一致せずimport/plan時に不要な差分が生じるため、
#   AWSにEIPの確保・複数AZへの展開を完全に委ねる
# ==================================================
resource "aws_nat_gateway" "main" {
  connectivity_type = "public"
  availability_mode = "regional"
  vpc_id            = aws_vpc.main.id

  tags = {
    Name = "pitvia-nat-gateway"
  }

  depends_on = [aws_internet_gateway.main]
}
