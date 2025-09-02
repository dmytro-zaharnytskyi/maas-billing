# ArgoCD Setup Guide for MaaS Platform

This guide provides comprehensive instructions for setting up ArgoCD to manage your MaaS (Models-as-a-Service) platform deployment, making it easy to deploy, test, and reset your environment.

## 🎯 Benefits of ArgoCD for MaaS

- **🔄 Easy Reset**: Quickly return to "empty" cluster state for testing
- **📝 Declarative**: All configuration in Git
- **🔍 Visibility**: Visual representation of all components
- **🔒 Consistency**: Same deployment across environments
- **⚡ Fast Recovery**: Restore entire platform from Git in minutes

## 🚀 Quick Setup (Automated)

### Option 1: Fully Automated Setup

```bash
cd deployment/argocd

# 1. Update the repository URL in the script
sed -i 's|https://github.com/your-org/maas-billing|https://github.com/YOUR_USERNAME/maas-billing|g' setup-argocd.sh

# 2. Install everything
./setup-argocd.sh install

# 3. Reset cluster anytime for testing
./setup-argocd.sh reset

# 4. Completely remove everything
./setup-argocd.sh uninstall
```

## 📋 Manual Setup (Step-by-Step)

### Step 1: Install ArgoCD

```bash
# Create ArgoCD namespace
kubectl create namespace argocd

# Install ArgoCD
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for ArgoCD to be ready
kubectl wait --for=condition=Available deployment/argocd-server -n argocd --timeout=300s
```

### Step 2: Access ArgoCD UI

#### For OpenShift:
```bash
# Create route
oc create route passthrough argocd-server --service=argocd-server --port=https -n argocd

# Get URL
echo "ArgoCD URL: https://$(oc get route argocd-server -n argocd -o jsonpath='{.spec.host}')"
```

#### For Kubernetes:
```bash
# Port-forward to access UI
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Access at: https://localhost:8080
```

### Step 3: Get ArgoCD Password

```bash
# Get admin password
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d
```

**Login credentials:**
- Username: `admin`
- Password: (from command above)

### Step 4: Create MaaS Applications

Apply the ArgoCD applications:

```bash
# Update repository URL first
export YOUR_REPO_URL="https://github.com/YOUR_USERNAME/maas-billing"

# Create applications
cat <<EOF | kubectl apply -f -
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: maas-prerequisites
  namespace: argocd
spec:
  project: default
  source:
    repoURL: $YOUR_REPO_URL
    targetRevision: main
    path: deployment/prerequisites
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    manual: {}
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: maas-platform
  namespace: argocd
spec:
  project: default
  source:
    repoURL: $YOUR_REPO_URL
    targetRevision: main
    path: deployment/kuadrant
    directory:
      include: |
        00-namespaces.yaml
        04-kuadrant-operator.yaml
        05-api-key-secrets.yaml
        06-auth-policies-apikey.yaml
        07-rate-limit-policies.yaml
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: maas-models
  namespace: argocd
spec:
  project: default
  source:
    repoURL: $YOUR_REPO_URL
    targetRevision: main
    path: deployment/model_serving
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    manual: {}
EOF
```

## 🔧 ArgoCD UI Instructions

### 1. Login to ArgoCD
1. Open ArgoCD URL in browser
2. Click "Log In Via OIDC" or use admin credentials
3. Username: `admin`, Password: (from Step 3 above)

### 2. Deploy Prerequisites (Manual)
1. In ArgoCD UI, find the **`maas-prerequisites`** application
2. Click **SYNC** → **SYNCHRONIZE**
3. Wait for all operators to be installed and ready
4. **Important**: This installs RHOAI, Service Mesh, Serverless, GPU operators

### 3. Deploy Platform (Automatic)
1. The **`maas-platform`** application will auto-sync
2. Monitor the deployment in the ArgoCD UI
3. Check that all resources are green/healthy

### 4. Deploy Models (Manual)
1. Click on **`maas-models`** application
2. Click **SYNC** → **SYNCHRONIZE**
3. Select which models to deploy (simulator, qwen3, or both)

## 🔄 Easy Reset Workflow

### Using the Script:
```bash
cd deployment/argocd
./setup-argocd.sh reset
```

### Using ArgoCD UI:
1. **Delete Applications**: Select all MaaS apps → **DELETE** → **CASCADE**
2. **Wait for Cleanup**: Monitor until all resources are removed
3. **Redeploy**: Click **SYNC** on applications to redeploy

### Using CLI:
```bash
# Quick reset
kubectl delete application maas-platform maas-models -n argocd --wait=true
kubectl delete namespace llm llm-observability kuadrant-system --ignore-not-found=true

# Redeploy (applications will auto-recreate resources)
kubectl patch application maas-platform -n argocd --type='merge' -p='{"operation":{"initiatedBy":{"username":"admin"}}}'
```

## 📊 Monitoring Your Deployment

### ArgoCD UI Features:
- **🌳 Resource Tree**: Visual representation of all Kubernetes resources
- **📊 Health Status**: Real-time health of all components
- **📝 Logs**: Access logs from any pod directly in UI
- **🔄 Sync Status**: See what's in sync vs. what needs updates
- **📈 Metrics**: Resource usage and performance metrics

### Key Applications to Monitor:
1. **`maas-prerequisites`**: Operators (RHOAI, Service Mesh, GPU)
2. **`maas-platform`**: Core platform (Kuadrant, auth, rate limiting)
3. **`maas-models`**: Model serving (simulator, Qwen3)
4. **`maas-token-limiting`**: Token-based rate limiting (optional)

## 🛠️ Troubleshooting

### ArgoCD Not Accessible
```bash
# Check ArgoCD pods
kubectl get pods -n argocd

# Restart ArgoCD server if needed
kubectl rollout restart deployment/argocd-server -n argocd
```

### Applications Stuck in Sync
```bash
# Force refresh
kubectl patch application maas-platform -n argocd --type='json' -p='[{"op": "replace", "path": "/operation", "value": null}]'

# Or delete and recreate
kubectl delete application maas-platform -n argocd
# Then recreate via UI or CLI
```

### Resources Not Deploying
1. Check **Events** tab in ArgoCD UI
2. Look at **Resource Details** for error messages
3. Verify Git repository is accessible
4. Check RBAC permissions

## 🔐 Security Best Practices

### 1. Repository Access
```bash
# Use SSH keys for private repositories
kubectl create secret generic repo-secret \
  --from-file=sshPrivateKey=/path/to/ssh/private/key \
  -n argocd

# Then reference in Application spec:
# source:
#   repoURL: git@github.com:your-org/maas-billing.git
#   repoSecretRef:
#     name: repo-secret
```

### 2. RBAC Configuration
```bash
# Create service account for ArgoCD
kubectl create serviceaccount argocd-application-controller -n argocd

# Grant necessary permissions
kubectl create clusterrolebinding argocd-application-controller \
  --clusterrole=cluster-admin \
  --serviceaccount=argocd:argocd-application-controller
```

## 🚀 Advanced Configurations

### 1. Multi-Environment Setup
Create different applications for dev/staging/prod:

```yaml
# maas-dev.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: maas-platform-dev
spec:
  source:
    targetRevision: develop
    path: deployment/kuadrant
  destination:
    namespace: maas-dev
```

### 2. Sync Waves for Ordered Deployment
Add annotations to control deployment order:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "1"  # Deploy first
```

### 3. Health Checks
Add custom health checks for KServe:

```yaml
spec:
  ignoreDifferences:
  - group: "serving.kserve.io"
    kind: "InferenceService"
    jsonPointers:
    - /status
```

## 📚 Additional Resources

- [ArgoCD Documentation](https://argo-cd.readthedocs.io/)
- [GitOps Best Practices](https://www.gitops.tech/)
- [Kubernetes GitOps Guide](https://kubernetes.io/docs/concepts/overview/working-with-objects/declarative-config/)

## 🎯 Testing Workflow

### Daily Development Cycle:
1. **Morning**: `./setup-argocd.sh reset` (clean slate)
2. **Develop**: Make changes, push to Git
3. **Test**: ArgoCD auto-syncs changes
4. **Evening**: `./setup-argocd.sh reset` (clean up)

### Feature Testing:
1. **Branch**: Create feature branch
2. **Deploy**: Update ArgoCD app to use feature branch
3. **Test**: Validate functionality
4. **Cleanup**: Reset to main branch

### Production Deployment:
1. **Tag**: Create Git tag for release
2. **Deploy**: Update ArgoCD app to use tag
3. **Monitor**: Watch deployment in ArgoCD UI
4. **Rollback**: Change tag if issues occur

This setup gives you a **production-grade GitOps workflow** with easy testing and reset capabilities! 