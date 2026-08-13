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

## Bonus: 5.4 Network Policies

Kubernetes `NetworkPolicy` resources restrict pod-to-pod traffic within `retail-app` to only the paths each service actually needs (manifests in `k8s/network-policies/`). A default-deny-ingress baseline blocks all traffic unless explicitly allowed.

**Important:** the AWS VPC CNI does not enforce NetworkPolicy by default — it must be explicitly enabled via the `vpc-cni` EKS add-on's `enableNetworkPolicy` configuration value (`terraform/main.tf`), which was added as part of this work.

Verified with direct pod-to-pod `curl` tests:
- `catalog → orders` (not an allowed path): **times out** ✅
- `ui → catalog` (allowed): **200/404** (reaches app) ✅
- `checkout → orders` (allowed): **200** ✅

## Accessing the Store

The retail store is exposed via an AWS Load Balancer Controller-managed ALB at:

http://k8s-retailap-retailst-1ada82715c-2030306503.us-east-1.elb.amazonaws.com

Note: The AWS Load Balancer Controller IAM policy (AWSLoadBalancerControllerIAMPolicy) required updating to a newer version to include the elasticloadbalancing:DescribeListenerAttributes action - without it, ALB provisioning fails with an AccessDenied error. Updated via a new policy version (v2.14.1 of the official policy JSON from the aws-load-balancer-controller GitHub repo).

## Bonus: 5.3 Cluster Autoscaling (Partial)

The Cluster Autoscaler was installed via Helm with a dedicated IRSA role (`bedrock-cluster-autoscaler-role`, Terraform-managed in `terraform/main.tf`) scoped to the node group's specific ASG (least-privilege: Describe* actions account-wide, mutating actions restricted to one ASG ARN).

Status: IAM/IRSA configuration is correctly deployed and verifiable via `aws iam get-role`/`get-role-policy`. However, a live scale-up demonstration was not achieved in this environment — the autoscaler's reconcile loop did not complete a scan cycle after IRSA was fixed, despite the ASG having available headroom (MaxSize=3, DesiredCapacity=2) and 12+ pods in Pending state during a forced load test. Root cause not fully isolated within the time available; worth revisiting with a longer diagnostic window or by trying Karpenter as an alternative.

## Bonus: 5.2 TLS/ACM (Partial)

A self-signed TLS certificate was generated and imported into ACM (arn:aws:acm:us-east-1:461905260869:certificate/7689197d-3ec5-434f-b8be-982130cb313e), and an HTTPS listener (port 443) was successfully attached to the ALB via Ingress annotations, alongside the existing HTTP listener.

Status: ACM certificate import and ALB HTTPS listener creation both succeeded and are verifiable via `aws elbv2 describe-listeners`. Security groups correctly allow inbound 443 from 0.0.0.0/0 on both attached SGs. However, TLS handshakes to the HTTPS listener consistently fail with a "TLS alert: access denied" at the protocol level (reproduced at both TLS 1.2 and TLS 1.3), a known but under-documented ALB/self-signed-cert interaction. Root cause not isolated within the time available. The Ingress was reverted to HTTP-only to keep the live store stable and accessible; the HTTPS configuration files and troubleshooting are preserved for reference in tls/ and this note.

## Bonus: 5.1 Helm-Based Deployment

The upstream `retail-store-sample-chart` (v0.8.5, `oci://public.ecr.aws/aws-containers/retail-store-sample-chart`) is used with a custom `helm/values-bedrock.yaml` overriding the data layer to point at this project's managed AWS services instead of in-cluster database pods:

- catalog.mysql -> RDS MySQL (bedrock-catalog-mysql), credentials from Secrets Manager
- orders.postgresql -> RDS PostgreSQL (bedrock-orders-postgres), credentials from Secrets Manager
- carts.dynamodb -> DynamoDB table bedrock-carts

Deploy with:

helm install retail-store-bedrock oci://public.ecr.aws/aws-containers/retail-store-sample-chart --version 0.8.5 -n retail-app -f helm/values-bedrock.yaml

Validated via `helm template` dry-run (renders successfully, exit code 0, all RDS endpoints/DynamoDB table/Secrets Manager references correctly present in generated manifests). Not applied to the live cluster in this submission — the application is currently running via the raw manifests documented earlier in this README, which are proven stable and were kept in place to avoid disrupting the working deployment during grading.
