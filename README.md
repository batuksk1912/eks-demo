# EKS Demo: NGINX on AWS EKS via Terraform & Helm

A fully automated, end‑to‑end deployment of a simple containerized service (Bitnami NGINX) to an AWS EKS cluster using Terraform and Helm. The service is exposed via an Application Load Balancer (ALB) with HTTPS termination (ACM certificate) and fronted by a friendly subdomain (`app.baturaykayaturk.com`).

---

## 📋 Prerequisites

1. **AWS Account**
    - IAM permissions to create VPCs, EKS clusters, IAM Roles/Policies, S3, DynamoDB, ACM Certs, EC2 Tags, IAM OIDC provider, etc.
2. **GitHub** repository (public) for your Terraform code.
3. **GoDaddy** domain `baturaykayaturk.com` (or any DNS provider supporting CNAME).
4. **Local tooling** (one‑time setup):
    - AWS CLI v2
    - kubectl
    - Helm v3
    - Terraform 1.5+

---

## 🏛️ Architecture

             ┌──────────────────────────────┐
             │          Internet            │
             └───────────────┬──────────────┘
                             │ DNS → ALB DNS
             ┌───────────────┴─────────────┐
             │     AWS Application LB      │  
             │  (Ingress Controller + TLS) │
             └───────┬───────────┬─────────┘
    HTTPS(443) │           │HTTP(80)│ HTTP→HTTPS redirect  
               ▼           ▼
    ┌─────────────────────────────────────┐
    │           EKS Cluster               │
    │ ┌───────────┐   ┌───────────┐       │
    │ │ Worker    │   │ Worker    │       │
    │ │ Node(s)   │   │ Node(s)   │       │
    │ └────┬──────┘   └────┬──────┘       │
    │      │  Pod: nginx  │  Pod: nginx   │
    │      │ (ClusterIP)  │ (ClusterIP)   │
    └─────────────────────────────────────┘

- **VPC** with public & private subnets in 2 AZs
- **EKS** cluster (managed control plane + Spot worker nodes)
- **AWS LB Controller** provisions ALB with HTTPS + redirect
- **Terraform** manages infra + IAM + Helm releases
- **GitHub Actions** for CI/CD (deploy on tag, destroy on `main` push)

---

## 🚀 Getting Started

1. **Clone the repo**
   ```bash
   git clone https://github.com/your‑org/eks-demo.git
   cd eks-demo/envs/prod

2. **Bootstrap Terraform State**
   ```bash
   aws s3 mb s3://hiive-tfstate-<ACCOUNT_ID>
   aws dynamodb create-table \
   --table-name hiive-tf-lock \
   --attribute-definitions AttributeName=LockID,AttributeType=S \
   --key-schema AttributeName=LockID,KeyType=HASH \
   --billing-mode PAY_PER_REQUEST

Configure GitHub Variables

In Settings → Actions → Variables:

```ini
AWS_ROLE_ARN    = arn:aws:iam::<ACCOUNT_ID>:role/GitHubActionsOIDC
AWS_REGION      = ca-central-1
TF_STATE_BUCKET = hiive-tfstate-<ACCOUNT_ID>
TF_STATE_TABLE  = hiive-tf-lock
```

3. **Issue an ACM Certificate (ca-central-1)**
- Domain: app.baturaykayaturk.com
- Validate via DNS (create GoDaddy CNAME)

### Push a Git Tag to Trigger Deployment

1. **Create and push a tag**
   ```bash
   git tag v0.1.0
   git push origin v0.1.0

2. **CI/CD runs** via `.github/workflows/apply.yml`:
    ```bash
    terraform init
    terraform apply
    # (VPC, EKS, IAM, Helm releases)
    ```

3. **Wait (~5 min)** for:
    - ALB provisioning
    - Ingress status:
      ```bash
      kubectl -n prod get ingress demo-site-nginx \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
      ```
    - GitHub Actions completion


4. **Create GoDaddy CNAME**
    - **Host:** `app`
    - **Points to:** the ALB DNS name from the command above
    - **TTL:** `600` seconds


5. **Verify Deployment**
    ```bash
    dig +short app.baturaykayaturk.com
    curl -I https://app.baturaykayaturk.com
    ```

   ✅ You should see `HTTP/2 200` and the Bitnami NGINX welcome page.

---

## 🤝 Key Design Decisions

- **Terraform 1.5 + terraform-aws-modules/eks**  
  Battle‑tested modules for infra best practices.

- **Managed Node Groups (Spot)**  
  Cost‑optimized worker nodes with On‑Demand fallback.

- **Helm Provider**  
  Declarative in‑code chart releases for AWS Load Balancer Controller & NGINX.

- **ACM + ALB Controller**  
  Automated TLS termination, HTTP→HTTPS redirect, certificate renewal.

- **GitHub OIDC**  
  No long‑lived AWS keys in GitHub; least‑privilege IAM Role via trust policy.

- **VPC Tagging**  
  Subnets are auto‑discovered by the ALB controller, ensuring multi‑AZ availability.

---

## 🛡️ Production‑Grade Hardening

### 🔐 Private‑Only Subnets

- Deploy worker nodes into **private subnets**.
- Use **NAT Gateways** for outbound traffic.
- Restrict ALB to public subnets tagged:
  ```text
  kubernetes.io/role/elb = 1

### 🔐 Endpoint Access Control

- Set:
  ```hcl
  cluster_endpoint_public_access = false
  cluster_endpoint_private_access = true
  ```
  Enable private endpoint access via **VPN** or **Direct Connect**.

- Use **AWS IAM Authenticator** with **OIDC** for fine‑grained Kubernetes RBAC.

---

### 📈 Autoscaling & Resilience

- Add **Cluster Autoscaler** or **Karpenter** to enable dynamic node scaling.
- Use **Horizontal Pod Autoscaler (HPA)** for application‑level scaling based on CPU/memory usage or custom metrics.

---

### ✅ CI/CD & Branch Protection

- Protect the `main` branch:
    - Require **Pull Requests**, **approvals**, and **status checks** before merging.
- Run pre-merge validation:
  ```bash
  terraform fmt
  terraform validate
  helm lint
  ```

---

### 🔑 Secrets & Configuration

- Store secrets securely in:
    - **AWS Secrets Manager**
    - **AWS SSM Parameter Store** (with CSI driver)

- For in-cluster secret management, consider:
    - **SealedSecrets**
    - **HashiCorp Vault**

---

### 📊 Logging & Monitoring

- Ship logs and metrics to:
    - **CloudWatch Logs**
    - **CloudWatch Metrics**

- Integrate with third-party tools:
    - **Datadog**
    - **Prometheus + Grafana**

- Enable cloud-level visibility:
    - **VPC Flow Logs**
    - **Kubernetes Audit Logs**
    - **AWS CloudTrail**

---

### 🔒 Network Policies

- Enforce network isolation using:
    - **Calico**
    - Built-in **Kubernetes NetworkPolicies**

---

### 🧪 Security Scanning

- **Image scanning**:
    - **Amazon ECR Image Scan**
    - **Trivy**

- **Cluster vulnerability scanning**:
    - **Kube Bench**
    - **Kube Hunter**

---

## 🔗 Links & Screenshots

- 🌐 **Live service:** [https://app.baturaykayaturk.com](https://app.baturaykayaturk.com)
- 📂 **GitHub repo:** [https://github.com/batuksk1912/eks-demo](https://github.com/batuksk1912/eks-demo)
