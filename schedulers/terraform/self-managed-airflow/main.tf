#---------------------------------------------------------------
# EKS Blueprints
#---------------------------------------------------------------
module "eks_blueprints" {
  source = "github.com/aws-ia/terraform-aws-eks-blueprints?ref=v4.28.0"

  cluster_name    = local.name
  cluster_version = var.eks_cluster_version

  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnets

  #---------------------------------------
  # Note: This can further restricted to specific required for each Add-on and your application
  #---------------------------------------
  node_security_group_additional_rules = {
    # Extend node-to-node security group rules. Recommended and required for the Add-ons
    ingress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
    # Recommended outbound traffic for Node groups
    egress_all = {
      description      = "Node all egress"
      protocol         = "-1"
      from_port        = 0
      to_port          = 0
      type             = "egress"
      cidr_blocks      = ["0.0.0.0/0"]
      ipv6_cidr_blocks = ["::/0"]
    }
    # Allows Control Plane Nodes to talk to Worker nodes on all ports. Added this to simplify the example and further avoid issues with Add-ons communication with Control plane.
    # This can be restricted further to specific port based on the requirement for each Add-on e.g., metrics-server 4443, spark-operator 8080, karpenter 8443 etc.
    # Change this according to your security requirements if needed
    ingress_cluster_to_node_all_traffic = {
      description                   = "Cluster API to Nodegroup all traffic"
      protocol                      = "-1"
      from_port                     = 0
      to_port                       = 0
      type                          = "ingress"
      source_cluster_security_group = true
    }
  }

  managed_node_groups = {
    # Core node group for deploying all the critical add-ons
    mng1 = {
      node_group_name = "core-node-grp"
      subnet_ids      = module.vpc.private_subnets

      instance_types = ["m5.xlarge"]
      ami_type       = "AL2_x86_64"
      capacity_type  = "ON_DEMAND"

      disk_size = 100
      disk_type = "gp3"

      max_size               = 9
      min_size               = 3
      desired_size           = 3
      create_launch_template = true
      launch_template_os     = "amazonlinux2eks"

      update_config = [{
        max_unavailable_percentage = 50
      }]

      k8s_labels = {
        Environment   = "preprod"
        Zone          = "test"
        WorkerType    = "ON_DEMAND"
        NodeGroupType = "core"
      }

      # See this doc node-template tags https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/FAQ.md#how-can-i-scale-a-node-group-to-0
      additional_tags = {
        Name                                                             = "core-node-grp"
        subnet_type                                                      = "private"
        "k8s.io/cluster-autoscaler/node-template/label/arch"             = "x86"
        "k8s.io/cluster-autoscaler/node-template/label/kubernetes.io/os" = "linux"
        "k8s.io/cluster-autoscaler/node-template/label/noderole"         = "core"
        "k8s.io/cluster-autoscaler/node-template/label/node-lifecycle"   = "on-demand"
        "k8s.io/cluster-autoscaler/${local.name}"                        = "owned"
        "k8s.io/cluster-autoscaler/enabled"                              = "true"
      }
    }
  }

  tags = local.tags
}

#---------------------------------------------------------------
# RDS Postgres Database for Apache Airflow Metadata
#---------------------------------------------------------------
module "db" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 5.0"

  identifier = local.airflow_name

  engine               = "postgres"
  engine_version       = "14.3"
  family               = "postgres14"
  major_engine_version = "14"
  instance_class       = "db.m6i.xlarge"

  storage_type      = "io1"
  allocated_storage = 100
  iops              = 3000

  db_name                = local.airflow_name
  username               = local.airflow_name
  create_random_password = false
  password               = sensitive(aws_secretsmanager_secret_version.postgres.secret_string)
  port                   = 5432

  multi_az               = true
  db_subnet_group_name   = module.vpc.database_subnet_group
  vpc_security_group_ids = [module.security_group.security_group_id]

  maintenance_window              = "Mon:00:00-Mon:03:00"
  backup_window                   = "03:00-06:00"
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]
  create_cloudwatch_log_group     = true

  backup_retention_period = 5
  skip_final_snapshot     = true
  deletion_protection     = false

  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  create_monitoring_role                = true
  monitoring_interval                   = 60
  monitoring_role_name                  = "airflow-metastore"
  monitoring_role_use_name_prefix       = true
  monitoring_role_description           = "Airflow Postgres Metastore for monitoring role"

  parameters = [
    {
      name  = "autovacuum"
      value = 1
    },
    {
      name  = "client_encoding"
      value = "utf8"
    }
  ]

  tags = local.tags
}

#tfsec:ignore:*
module "airflow_s3_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 3.0"

  bucket = "airflow-logs-${data.aws_caller_identity.current.account_id}"
  acl    = "private"

  # For example only - please evaluate for your environment
  force_destroy = true

  attach_deny_insecure_transport_policy = true
  attach_require_latest_tls_policy      = true

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
    }
  }

  tags = local.tags
}

#---------------------------------------------------------------
# Apache Airflow Postgres Metastore DB Master password
#---------------------------------------------------------------
resource "random_password" "postgres" {
  length  = 16
  special = false
}
#tfsec:ignore:aws-ssm-secret-use-customer-key
resource "aws_secretsmanager_secret" "postgres" {
  name                    = "postgres"
  recovery_window_in_days = 0 # Set to zero for this example to force delete during Terraform destroy
}

resource "aws_secretsmanager_secret_version" "postgres" {
  secret_id     = aws_secretsmanager_secret.postgres.id
  secret_string = random_password.postgres.result
}

##---------------------------------------------------------------
## Apache Airflow Webserver Secret
##---------------------------------------------------------------
resource "random_id" "airflow_webserver" {
  byte_length = 16
}

#tfsec:ignore:aws-ssm-secret-use-customer-key
resource "aws_secretsmanager_secret" "airflow_webserver" {
  name                    = "airflow_webserver_secret_key"
  recovery_window_in_days = 0 # Set to zero for this example to force delete during Terraform destroy
}

resource "aws_secretsmanager_secret_version" "airflow_webserver" {
  secret_id     = aws_secretsmanager_secret.airflow_webserver.id
  secret_string = random_id.airflow_webserver.hex
}

#---------------------------------------------------------------
# Webserver Secret Key
#---------------------------------------------------------------
resource "kubectl_manifest" "airflow_webserver" {
  sensitive_fields = [
    "data.webserver-secret-key"
  ]

  yaml_body = <<-YAML
apiVersion: v1
kind: Secret
metadata:
   name: ${local.airflow_webserver_secret_name}
   namespace: ${module.airflow_irsa.namespace}
type: Opaque
data:
  webserver-secret-key: ${base64encode(aws_secretsmanager_secret_version.airflow_webserver.secret_string)}
YAML
}

#---------------------------------------------------------------
# Managing DAG files with GitSync - EFS Storage Class
#---------------------------------------------------------------
resource "kubectl_manifest" "efs_sc" {
  yaml_body = <<-YAML
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${local.efs_storage_class}
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap
  fileSystemId: ${aws_efs_file_system.efs.id}
  directoryPerms: "700"
  gidRangeStart: "1000"
  gidRangeEnd: "2000"
YAML

  depends_on = [module.eks_blueprints.eks_cluster_id]
}

#---------------------------------------------------------------
# Persistent Volume Claim for EFS
#---------------------------------------------------------------
resource "kubectl_manifest" "efs_pvc" {
  yaml_body = <<-YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${local.efs_pvc}
  namespace: ${module.airflow_irsa.namespace}
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: ${local.efs_storage_class}
  resources:
    requests:
      storage: 10Gi
YAML

  depends_on = [kubectl_manifest.efs_sc]
}
#---------------------------------------------------------------
# EFS Filesystem for Airflow DAGs
#---------------------------------------------------------------
resource "aws_efs_file_system" "efs" {
  creation_token = "efs"
  encrypted      = true

  tags = local.tags
}

resource "aws_efs_mount_target" "efs_mt" {
  count = length(module.vpc.private_subnets)

  file_system_id  = aws_efs_file_system.efs.id
  subnet_id       = module.vpc.private_subnets[count.index]
  security_groups = [aws_security_group.efs.id]
}

resource "aws_security_group" "efs" {
  name        = "${local.name}-efs"
  description = "Allow inbound NFS traffic from private subnets of the VPC"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "Allow NFS 2049/tcp"
    cidr_blocks = module.vpc.private_subnets_cidr_blocks
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
  }

  tags = local.tags
}

#---------------------------------------------------------------
# IRSA for Airflow S3 logging
#---------------------------------------------------------------
module "airflow_irsa" {
  source                     = "github.com/aws-ia/terraform-aws-eks-blueprints//modules/irsa?ref=v4.28.0"
  eks_cluster_id             = module.eks_blueprints.eks_cluster_id
  eks_oidc_provider_arn      = module.eks_blueprints.eks_oidc_provider_arn
  irsa_iam_policies          = [aws_iam_policy.airflow.arn]
  kubernetes_namespace       = "airflow"
  kubernetes_service_account = local.airflow_service_account
}

#---------------------------------------------------------------
# Creates IAM policy for accessing s3 bucket
#---------------------------------------------------------------
resource "aws_iam_policy" "airflow" {
  description = "IAM role policy for Airflow S3 Logs"
  name        = "${local.name}-airflow-irsa"
  policy      = data.aws_iam_policy_document.airflow_s3_logs.json
}

#---------------------------------------------------------------
# PostgreSQL RDS security group
#---------------------------------------------------------------
module "security_group" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 4.0"

  name        = local.name
  description = "Complete PostgreSQL example security group"
  vpc_id      = module.vpc.vpc_id

  # ingress
  ingress_with_cidr_blocks = [
    {
      from_port   = 5432
      to_port     = 5432
      protocol    = "tcp"
      description = "PostgreSQL access from within VPC"
      cidr_blocks = module.vpc.vpc_cidr_block
    },
  ]

  tags = local.tags
}
