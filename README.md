# Project Bedrock — InnovateMart EKS Deployment

Production-grade AWS EKS deployment for InnovateMart's retail-store-sample-app, built for the Tinyuka Third Semester capstone exam.

## Architecture Summary

- **VPC**: `project-bedrock-vpc` — 2 AZs (us-east-1a/b), public + private subnets, single NAT Gateway
- **EKS**: `project-bedrock-cluster` — Kubernetes 1.33, managed node group (t3.medium, 1-3 nodes)
- **Data layer**: RDS MySQL (Catalog), RDS PostgreSQL (Orders), DynamoDB (Carts) — all in private subnets, credentials in Secrets Manager
- **Ingress**: AWS Load Balancer Controller + ALB
- **Developer access**: IAM user `bedrock-dev-view` (Console ReadOnly + S3 PutObject) with namespace-scoped EKS Access Entry (view-only on `retail-app`)
- **Observability**: EKS control plane logging (all 5 log types) + CloudWatch Observability EKS add-on (Container Insights)
- **Serverless**: S3 bucket → Lambda (`bedrock-asset-processor`) triggered on upload, logs filename to CloudWatch
- **CI/CD**: GitHub Actions with OIDC (no static AWS keys) — `plan` on PR (posted as comment), `apply` on merge to `main`
- **Cost guardrails**: single NAT Gateway, AWS Budget ($20/month, 80% email alert)

## Deployment Guide

### Prerequisites
- Terraform >= 1.11
- AWS CLI configured with sufficient permissions
- kubectl, Helm

### Steps
1. Clone this repo
2. `cd terraform && terraform init`
3. `terraform plan` — review changes
4. `terraform apply`
5. Configure kubectl: `aws eks update-kubeconfig --name project-bedrock-cluster --region us-east-1`
6. Verify: `kubectl get pods -n retail-app`

### CI/CD
- Open a PR against `main` with Terraform changes → `plan` runs automatically, output posted as a PR comment
- Merge to `main` → `apply` runs automatically via GitHub Actions using OIDC (role: `bedrock-github-actions-role`)

### Accessing the Store
Retrieve the ALB URL:
```bash
kubectl get ingress -n retail-app
```
Open the `ADDRESS` shown in a browser.

## Teardown

**⚠ This destroys real AWS infrastructure — confirm before running.**

```bash
cd terraform
terraform destroy
```

Manual cleanup NOT handled by `terraform destroy`:
- **S3 bucket objects**: `aws s3 rm s3://bedrock-assets-alt-soe-tin-025-0080 --recursive` (bucket itself won't delete if non-empty)
- **CloudWatch Log Groups**: Created by the CloudWatch Observability add-on are not managed by Terraform and persist after destroy — delete manually via console or:
```bash
  aws logs delete-log-group --log-group-name "/aws/containerinsights/project-bedrock-cluster/application" --region us-east-1
  aws logs delete-log-group --log-group-name "/aws/containerinsights/project-bedrock-cluster/dataplane" --region us-east-1
  aws logs delete-log-group --log-group-name "/aws/containerinsights/project-bedrock-cluster/host" --region us-east-1
  aws logs delete-log-group --log-group-name "/aws/containerinsights/project-bedrock-cluster/performance" --region us-east-1
  aws logs delete-log-group --log-group-name "/aws/lambda/bedrock-asset-processor" --region us-east-1
```
- **RDS final snapshots**: `skip_final_snapshot = true` was set for cost/simplicity — no snapshot is retained after destroy.

## Grading Credentials

See submitted Google Doc for `bedrock-dev-view` Access Key ID, Secret Access Key, and console password.

## Tagging

All resources tagged `Project: tinyuka-2025-capstone`.

## Bonus: 5.5 Resilience — Pod Self-Healing Demo

**Before:** `retail-store-ui-79f76d545d-4j77f` — Running, age 18h, node `ip-10-0-1-29.ec2.internal`

**Action:**
```bash
kubectl delete pod -n retail-app -l app.kubernetes.io/name=ui
```

**After:** Kubernetes' ReplicaSet controller detected the deletion and scheduled a replacement automatically — `retail-store-ui-79f76d545d-5hnxg` reached `1/1 Running` within **~21 seconds**, no manual intervention.

## Bonus: 5.5 Resilience — Database Backup Posture

Both RDS instances (MySQL for Catalog, PostgreSQL for Orders) have automated backups enabled via `backup_retention_period = 1` (1-day retention window). Chosen to satisfy the `BackupRetentionPeriod > 0` requirement while keeping storage cost minimal for an exam environment; the retention window can be raised in `terraform/main.tf` for production use.
