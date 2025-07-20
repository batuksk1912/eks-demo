# eks-demo

eks-demo/
├ envs/prod/
│   ├ backend.tf
│   ├ main.tf
│   └ variables.tf
└ .github/workflows/
    ├ plan.yml
    └ apply.yml


            ┌──────────────────────┐
            │  GitHub Actions CI   │
            │  • plan.yml          │
            │  • apply.yml         │
            └──────┬─────▲─────────┘
                   │OIDC │
                   │     │ sts:AssumeRoleWithWebIdentity
┌──────────────────┴─────┴──────────────────────────────────┐
│                      AWS Account                          │
│  VPC (10.0.0.0/16)                                        │
│   ├─ Public subnets (ALB + nat-gw)                        │
│   └─ Private subnets (EKS nodes)                          │
│                                                           │
│  AWS WAFv2  ─► ALB  ─► AWS LB Controller ─► Ingress, svc  │
│                         │                                 │
│                  EKS managed node group (ASG)             │
│                    └─ sample-app Deployment + HPA         │
└───────────────────────────────────────────────────────────┘
