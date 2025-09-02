#!/usr/bin/env bash
set -euo pipefail

################################################################################
# ArgoCD Setup Script for MaaS Platform
# 
# This script:
# 1. Installs ArgoCD
# 2. Sets up the MaaS GitOps applications
# 3. Provides easy reset/redeploy functionality
#
# Usage:
#   ./setup-argocd.sh install     # Install ArgoCD and MaaS apps
#   ./setup-argocd.sh reset       # Reset cluster and redeploy
#   ./setup-argocd.sh uninstall   # Remove everything
################################################################################

NAMESPACE="argocd"
REPO_URL="https://github.com/your-org/maas-billing"  # Update this with your repo
BRANCH="main"
OCP=false

# Detect if running on OpenShift
if command -v oc &> /dev/null; then
    KUBECTL="oc"
    OCP=true
    echo "🔧 Detected OpenShift platform"
else
    KUBECTL="kubectl"
    echo "🔧 Detected Kubernetes platform"
fi

usage() {
    cat <<EOF
Usage: $0 [install|reset|uninstall] [--repo-url URL] [--branch BRANCH]

Commands:
  install     Install ArgoCD and deploy MaaS platform
  reset       Reset cluster and redeploy everything
  uninstall   Remove ArgoCD and all MaaS components

Options:
  --repo-url URL    Git repository URL (default: $REPO_URL)
  --branch BRANCH   Git branch to use (default: $BRANCH)

Examples:
  $0 install
  $0 reset
  $0 install --repo-url https://github.com/myorg/maas-billing --branch dev
  $0 uninstall

Note: Update REPO_URL in this script to point to your forked repository
EOF
    exit 1
}

# Parse arguments
COMMAND=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        install|reset|uninstall) COMMAND="$1"; shift ;;
        --repo-url) REPO_URL="$2"; shift 2 ;;
        --branch) BRANCH="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "❌ Unknown option: $1"; usage ;;
    esac
done

[[ -z "$COMMAND" ]] && { echo "❌ Must specify a command"; usage; }

install_argocd() {
    echo "🔧 Installing ArgoCD..."
    
    # Create namespace
    $KUBECTL create namespace $NAMESPACE --dry-run=client -o yaml | $KUBECTL apply -f -
    
    # Install ArgoCD
    echo "📦 Installing ArgoCD components..."
    $KUBECTL apply -n $NAMESPACE -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
    
    # Wait for ArgoCD to be ready
    echo "⏳ Waiting for ArgoCD to be ready..."
    $KUBECTL wait --for=condition=Available deployment/argocd-server -n $NAMESPACE --timeout=300s
    $KUBECTL wait --for=condition=Available deployment/argocd-application-controller -n $NAMESPACE --timeout=300s
    
    if [[ "$OCP" == true ]]; then
        # Create OpenShift route for ArgoCD
        echo "🔧 Creating OpenShift route for ArgoCD..."
        cat <<EOF | $KUBECTL apply -f -
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: argocd-server
  namespace: $NAMESPACE
spec:
  to:
    kind: Service
    name: argocd-server
  port:
    targetPort: https
  tls:
    termination: passthrough
    insecureEdgeTerminationPolicy: Redirect
EOF
        ARGOCD_URL="https://$($KUBECTL get route argocd-server -n $NAMESPACE -o jsonpath='{.spec.host}')"
    else
        echo "🔧 ArgoCD will be available via port-forward"
        ARGOCD_URL="https://localhost:8080"
    fi
    
    echo "✅ ArgoCD installed successfully!"
    echo "🌐 ArgoCD URL: $ARGOCD_URL"
}

get_argocd_password() {
    echo "🔑 Getting ArgoCD admin password..."
    if [[ "$OCP" == true ]]; then
        # On OpenShift, get password from secret
        ARGOCD_PASSWORD=$($KUBECTL get secret argocd-initial-admin-secret -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d)
    else
        # On Kubernetes, get password from secret
        ARGOCD_PASSWORD=$($KUBECTL get secret argocd-initial-admin-secret -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d)
    fi
    echo "👤 Username: admin"
    echo "🔐 Password: $ARGOCD_PASSWORD"
}

create_maas_applications() {
    echo "🔧 Creating MaaS ArgoCD applications..."
    
    # Create the main MaaS application
    cat <<EOF | $KUBECTL apply -f -
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: maas-platform
  namespace: $NAMESPACE
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: $REPO_URL
    targetRevision: $BRANCH
    path: deployment/kuadrant
    directory:
      recurse: false
      include: |
        00-namespaces.yaml
        01-kserve-config.yaml
        02-gateway-configuration.yaml
        03-model-routing-domains.yaml
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
    syncOptions:
    - CreateNamespace=true
    - ApplyOutOfSyncOnly=true
  ignoreDifferences:
  - group: "*"
    kind: "Secret"
    jsonPointers:
    - /data
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: maas-models
  namespace: $NAMESPACE
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: $REPO_URL
    targetRevision: $BRANCH
    path: deployment/model_serving
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: maas-token-limiting
  namespace: $NAMESPACE
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: $REPO_URL
    targetRevision: $BRANCH
    path: deployment/kuadrant
    directory:
      include: "08-token-rate-limit-envoyfilter.yaml"
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    manual: {}
  ignoreDifferences:
  - group: "networking.istio.io"
    kind: "EnvoyFilter"
    jsonPointers:
    - /spec/configPatches/0/patch/value/typed_config/inline_code
EOF

    echo "✅ MaaS ArgoCD applications created!"
}

install_prerequisites_app() {
    echo "🔧 Creating prerequisites application..."
    
    cat <<EOF | $KUBECTL apply -f -
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: maas-prerequisites
  namespace: $NAMESPACE
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: $REPO_URL
    targetRevision: $BRANCH
    path: deployment/prerequisites
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    manual: {}
    syncOptions:
    - CreateNamespace=true
  info:
  - name: 'Prerequisites'
    value: 'Install operators manually from OpenShift Console first'
EOF

    echo "✅ Prerequisites application created (manual sync required)"
}

reset_cluster() {
    echo "🔄 Resetting cluster..."
    
    # Delete all MaaS applications (this will cascade delete all resources)
    echo "🗑️  Deleting MaaS applications..."
    $KUBECTL delete application maas-platform maas-models maas-token-limiting -n $NAMESPACE --ignore-not-found=true --wait=true
    
    # Wait for cleanup
    echo "⏳ Waiting for resources to be cleaned up..."
    sleep 30
    
    # Force cleanup any remaining resources
    echo "🧹 Force cleaning remaining resources..."
    $KUBECTL delete namespace llm llm-observability kuadrant-system --ignore-not-found=true --wait=false
    
    # Wait a bit more
    sleep 10
    
    # Recreate applications
    echo "🚀 Redeploying MaaS applications..."
    create_maas_applications
    
    echo "✅ Cluster reset complete!"
}

uninstall_everything() {
    echo "🗑️  Uninstalling everything..."
    
    # Run the cleanup script first
    if [[ -f "../kuadrant/cleanup.sh" ]]; then
        echo "🧹 Running MaaS cleanup script..."
        cd ../kuadrant && ./cleanup.sh && cd ../argocd
    fi
    
    # Delete ArgoCD applications
    $KUBECTL delete application --all -n $NAMESPACE --ignore-not-found=true --wait=true
    
    # Delete ArgoCD itself
    echo "🗑️  Removing ArgoCD..."
    $KUBECTL delete -n $NAMESPACE -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml --ignore-not-found=true
    
    # Delete namespace
    $KUBECTL delete namespace $NAMESPACE --ignore-not-found=true
    
    echo "✅ Uninstall complete!"
}

show_access_info() {
    if [[ "$OCP" == true ]]; then
        ARGOCD_URL="https://$($KUBECTL get route argocd-server -n $NAMESPACE -o jsonpath='{.spec.host}' 2>/dev/null || echo 'route-not-found')"
        echo "🌐 ArgoCD URL: $ARGOCD_URL"
    else
        echo "🔌 Access ArgoCD via port-forward:"
        echo "   $KUBECTL port-forward svc/argocd-server -n $NAMESPACE 8080:443"
        echo "   Then visit: https://localhost:8080"
    fi
    
    if $KUBECTL get secret argocd-initial-admin-secret -n $NAMESPACE &>/dev/null; then
        get_argocd_password
    else
        echo "⚠️  ArgoCD password secret not found"
    fi
}

case "$COMMAND" in
    install)
        echo "🚀 Installing ArgoCD and MaaS platform..."
        install_argocd
        sleep 10
        install_prerequisites_app
        create_maas_applications
        echo ""
        echo "✅ Installation complete!"
        echo ""
        show_access_info
        echo ""
        echo "📋 Next steps:"
        echo "1. Install prerequisites (operators) manually from OpenShift Console"
        echo "2. Sync 'maas-prerequisites' app in ArgoCD (if using GitOps for operators)"
        echo "3. Sync 'maas-platform' app to deploy the platform"
        echo "4. Optionally sync 'maas-token-limiting' for token-based rate limiting"
        ;;
    reset)
        echo "🔄 Resetting cluster for clean deployment..."
        reset_cluster
        echo ""
        echo "✅ Reset complete!"
        echo "🎯 Check ArgoCD UI to monitor redeployment progress"
        ;;
    uninstall)
        echo "🗑️  Uninstalling everything..."
        uninstall_everything
        echo "✅ Uninstall complete!"
        ;;
    *)
        echo "❌ Unknown command: $COMMAND"
        usage
        ;;
esac 