terraform {
  required_version = ">= 1.11.0"

  backend "s3" {
    bucket       = "bedrock-tf-state-alt-soe-tin-025-0080"
    key          = "project-bedrock/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      Project = "tinyuka-2025-capstone"
    }
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "project-bedrock-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["us-east-1a", "us-east-1b"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true

  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }

  tags = {
    Project = "tinyuka-2025-capstone"
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "project-bedrock-cluster"
  cluster_version = "1.33"

  cluster_endpoint_public_access = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  eks_managed_node_groups = {
    bedrock_nodes = {
      min_size     = 1
      max_size     = 3
      desired_size = 2

      instance_types = ["t3.medium"]
      capacity_type  = "ON_DEMAND"
    }
  }

  enable_cluster_creator_admin_permissions = true

  tags = {
    Project = "tinyuka-2025-capstone"
  }
}

resource "aws_security_group" "rds" {
  name        = "bedrock-rds-sg"
  description = "Allow DB traffic from EKS nodes only"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "MySQL from EKS nodes (Catalog service)"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }

  ingress {
    description     = "PostgreSQL from EKS nodes (Orders service)"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "bedrock-rds-sg"
    Project = "tinyuka-2025-capstone"
  }
}

resource "aws_db_subnet_group" "bedrock" {
  name       = "bedrock-db-subnet-group"
  subnet_ids = module.vpc.private_subnets

  tags = {
    Project = "tinyuka-2025-capstone"
  }
}

resource "random_password" "mysql" {
  length  = 20
  special = false
}

resource "random_password" "postgres" {
  length  = 20
  special = false
}

resource "aws_secretsmanager_secret" "mysql" {
  name = "bedrock/catalog-mysql-credentials"

  tags = {
    Project = "tinyuka-2025-capstone"
  }
}

resource "aws_secretsmanager_secret_version" "mysql" {
  secret_id = aws_secretsmanager_secret.mysql.id
  secret_string = jsonencode({
    username = "catalog_admin"
    password = random_password.mysql.result
    engine   = "mysql"
    host     = aws_db_instance.mysql.address
    port     = 3306
    dbname   = "catalog"
  })
}

resource "aws_secretsmanager_secret" "postgres" {
  name = "bedrock/orders-postgres-credentials"

  tags = {
    Project = "tinyuka-2025-capstone"
  }
}

resource "aws_secretsmanager_secret_version" "postgres" {
  secret_id = aws_secretsmanager_secret.postgres.id
  secret_string = jsonencode({
    username = "orders_admin"
    password = random_password.postgres.result
    engine   = "postgres"
    host     = aws_db_instance.postgres.address
    port     = 5432
    dbname   = "orders"
  })
}

resource "aws_db_instance" "mysql" {
  identifier     = "bedrock-catalog-mysql"
  engine         = "mysql"
  engine_version = "8.0"
  instance_class = "db.t3.micro"

  allocated_storage = 20
  storage_type       = "gp3"

  db_name  = "catalog"
  username = "catalog_admin"
  password = random_password.mysql.result

  db_subnet_group_name   = aws_db_subnet_group.bedrock.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  multi_az            = false
  publicly_accessible = false
  skip_final_snapshot = true

  backup_retention_period = 1

  tags = {
    Project = "tinyuka-2025-capstone"
  }
}

resource "aws_db_instance" "postgres" {
  identifier     = "bedrock-orders-postgres"
  engine         = "postgres"
  engine_version = "16"
  instance_class = "db.t3.micro"

  allocated_storage = 20
  storage_type       = "gp3"

  db_name  = "orders"
  username = "orders_admin"
  password = random_password.postgres.result

  db_subnet_group_name   = aws_db_subnet_group.bedrock.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  multi_az            = false
  publicly_accessible = false
  skip_final_snapshot = true

  backup_retention_period = 1

  tags = {
    Project = "tinyuka-2025-capstone"
  }
}

resource "aws_dynamodb_table" "carts" {
  name         = "bedrock-carts"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

  attribute {
    name = "customerId"
    type = "S"
  }

  global_secondary_index {
    name            = "idx_global_customerId"
    hash_key        = "customerId"
    projection_type = "ALL"
  }

  tags = {
    Project = "tinyuka-2025-capstone"
  }
}

# ============================================================
# 4.3 Developer IAM Access (bedrock-dev-view)
# ============================================================

resource "aws_iam_user" "bedrock_dev_view" {
  name = "bedrock-dev-view"

  tags = {
    Project = "tinyuka-2025-capstone"
  }
}

resource "aws_iam_user_policy_attachment" "bedrock_dev_view_readonly" {
  user       = aws_iam_user.bedrock_dev_view.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_eks_access_entry" "bedrock_dev_view" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_user.bedrock_dev_view.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "bedrock_dev_view_namespace_view" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_user.bedrock_dev_view.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"

  access_scope {
    type       = "namespace"
    namespaces = ["retail-app"]
  }
}

# ============================================================
# Phase 6: Observability — CloudWatch Container Insights
# ============================================================

resource "aws_iam_role_policy_attachment" "node_cloudwatch" {
  role       = module.eks.eks_managed_node_groups["bedrock_nodes"].iam_role_name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_eks_addon" "cloudwatch_observability" {
  cluster_name = module.eks.cluster_name
  addon_name   = "amazon-cloudwatch-observability"

  tags = {
    Project = "tinyuka-2025-capstone"
  }

  depends_on = [aws_iam_role_policy_attachment.node_cloudwatch]
}

# ============================================================
# Phase 7: Serverless — S3 → Lambda (bedrock-asset-processor)
# ============================================================

resource "aws_s3_bucket" "assets" {
  bucket = "bedrock-assets-alt-soe-tin-025-0080"

  tags = {
    Project = "tinyuka-2025-capstone"
  }
}

resource "aws_s3_bucket_public_access_block" "assets" {
  bucket = aws_s3_bucket.assets.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ------------------------------------------------------------
# Lambda execution role — minimal: read this bucket, write logs only
# ------------------------------------------------------------

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "asset_processor" {
  name               = "bedrock-asset-processor-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json

  tags = {
    Project = "tinyuka-2025-capstone"
  }
}

data "aws_iam_policy_document" "asset_processor_policy" {
  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.assets.arn}/*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["arn:aws:logs:us-east-1:461905260869:log-group:/aws/lambda/bedrock-asset-processor:*"]
  }
}

resource "aws_iam_role_policy" "asset_processor" {
  name   = "bedrock-asset-processor-policy"
  role   = aws_iam_role.asset_processor.id
  policy = data.aws_iam_policy_document.asset_processor_policy.json
}

# ------------------------------------------------------------
# Lambda function
# ------------------------------------------------------------

resource "aws_lambda_function" "asset_processor" {
  function_name = "bedrock-asset-processor"
  role          = aws_iam_role.asset_processor.arn
  handler       = "asset_processor.handler"
  runtime       = "python3.12"

  filename         = "${path.module}/../lambda/asset_processor.zip"
  source_code_hash = filebase64sha256("${path.module}/../lambda/asset_processor.zip")

  tags = {
    Project = "tinyuka-2025-capstone"
  }
}

resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.asset_processor.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.assets.arn
}

resource "aws_s3_bucket_notification" "assets" {
  bucket = aws_s3_bucket.assets.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.asset_processor.arn
    events               = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_lambda_permission.allow_s3]
}

# ------------------------------------------------------------
# bedrock-dev-view: grant s3:PutObject on this bucket only (Section 4.3/4.5)
# ------------------------------------------------------------

data "aws_iam_policy_document" "dev_view_put_object" {
  statement {
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.assets.arn}/*"]
  }
}

resource "aws_iam_user_policy" "bedrock_dev_view_put_object" {
  name   = "bedrock-dev-view-s3-putobject"
  user   = aws_iam_user.bedrock_dev_view.name
  policy = data.aws_iam_policy_document.dev_view_put_object.json
}

# ============================================================
# Cost Guardrail: AWS Budget with email alert
# ============================================================

resource "aws_budgets_budget" "bedrock" {
  name         = "bedrock-capstone-budget"
  budget_type  = "COST"
  limit_amount = "20"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:Project$tinyuka-2025-capstone"]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type              = "PERCENTAGE"
    notification_type           = "ACTUAL"
    subscriber_email_addresses  = ["abuchi40@gmail.com"]
  }
}

# ============================================================
# Phase 8: CI/CD — GitHub Actions OIDC
# ============================================================

data "tls_certificate" "github_actions" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github_actions" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github_actions.certificates[0].sha1_fingerprint]

  tags = {
    Project = "tinyuka-2025-capstone"
  }
}

data "aws_iam_policy_document" "github_actions_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:Ekwueme-sixtus*/project-bedrock*:*"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "bedrock-github-actions-role"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume.json

  tags = {
    Project = "tinyuka-2025-capstone"
  }
}

resource "aws_iam_role_policy_attachment" "github_actions_admin" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# ============================================================
# Required root outputs (Section 4.1 / Deliverables)
# ============================================================

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "region" {
  value = "us-east-1"
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "assets_bucket_name" {
  value = aws_s3_bucket.assets.bucket
}


# ============================================================
# Bonus 5.4: VPC CNI managed add-on with NetworkPolicy enforcement enabled
# ============================================================

resource "aws_eks_addon" "vpc_cni" {
  cluster_name = module.eks.cluster_name
  addon_name   = "vpc-cni"

  configuration_values = jsonencode({
    enableNetworkPolicy = "true"
  })

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = {
    Project = "tinyuka-2025-capstone"
  }
}
