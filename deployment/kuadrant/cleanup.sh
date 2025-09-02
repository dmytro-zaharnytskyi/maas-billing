#!/usr/bin/env bash
set -euo pipefail

################################################################################
# MaaS + Kuadrant Cleanup Script
# 
# This script removes all components installed by install.sh:
# - InferenceServices and model deployments
# - Kuadrant operator and policies
# - KServe
# - Istio
# - cert-manager
# - Gateway API CRDs
# - All created namespaces
#
# Run this from deployment/kuadrant directory
################################################################################

echo "================================================"
echo "MaaS + Kuadrant Cleanup Script"
echo "================================================"
echo ""
echo "This will remove:"
echo "  - All models and InferenceServices"
echo "  - Kuadrant operator and policies"
echo "  - KServe"
echo "  - Istio"
echo "  - cert-manager"
echo "  - Gateway API resources"
echo "  - Namespaces: llm, llm-observability, kuadrant-system"
echo ""
read -p "Do you want to proceed? (y/N): " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cleanup cancelled."
    exit 0
fi

echo ""
echo "Starting cleanup..."
echo ""

# Function to safely delete resources
safe_delete() {
    local resource=$1
    local namespace=${2:-}
    local name=${3:-}
    
    if [ -z "$namespace" ]; then
        echo "  - Deleting $resource..."
        kubectl delete $resource --ignore-not-found=true 2>/dev/null || true
    elif [ -z "$name" ]; then
        echo "  - Deleting all $resource in namespace $namespace..."
        kubectl delete $resource --all -n $namespace --ignore-not-found=true 2>/dev/null || true
    else
        echo "  - Deleting $resource $name in namespace $namespace..."
        kubectl delete $resource $name -n $namespace --ignore-not-found=true 2>/dev/null || true
    fi
}

# Function to delete namespace with wait
delete_namespace_wait() {
    local namespace=$1
    if kubectl get namespace "$namespace" &>/dev/null; then
        echo "Deleting namespace: $namespace"
        kubectl delete namespace "$namespace" --ignore-not-found=true --wait=false
        
        # Wait for namespace to be deleted (with timeout)
        echo "Waiting for namespace $namespace to be deleted..."
        local count=0
        while kubectl get namespace "$namespace" &>/dev/null && [ $count -lt 30 ]; do
            echo -n "."
            sleep 2
            count=$((count + 1))
        done
        echo " Done!"
    else
        echo "Namespace $namespace not found, skipping..."
    fi
}

# Step 1: Delete InferenceServices and ServingRuntimes
echo "Step 1: Cleaning up InferenceServices and model deployments..."
safe_delete "inferenceservice" "llm"
safe_delete "servingruntime" "llm"
safe_delete "clusterservingruntime"

# Step 2: Delete Kuadrant policies and resources
echo ""
echo "Step 2: Removing Kuadrant policies and resources..."
safe_delete "authpolicy" "llm"
safe_delete "ratelimitpolicy" "llm"
safe_delete "kuadrant" "kuadrant-system"

# Step 3: Remove Kuadrant resources and policies
echo ""
echo "Step 3: Removing Kuadrant resources and policies..."
echo "  - Deleting all AuthPolicies in namespace llm..."
kubectl delete authpolicy --all -n llm --ignore-not-found=true 2>/dev/null || true
echo "  - Deleting all AuthPolicies in namespace istio-system..."
kubectl delete authpolicy --all -n istio-system --ignore-not-found=true 2>/dev/null || true
echo "  - Deleting all AuthConfigs in namespace kuadrant-system..."
kubectl delete authconfig --all -n kuadrant-system --ignore-not-found=true 2>/dev/null || true
echo "  - Deleting all RateLimitPolicies in namespace llm..."
kubectl delete ratelimitpolicy --all -n llm --ignore-not-found=true 2>/dev/null || true
echo "  - Deleting all RateLimitPolicies in namespace istio-system..."
kubectl delete ratelimitpolicy --all -n istio-system --ignore-not-found=true 2>/dev/null || true
echo "  - Deleting all httproute in namespace llm..."
kubectl delete httproute --all -n llm --ignore-not-found=true 2>/dev/null || true
echo "  - Deleting all gateway in namespace llm..."
kubectl delete gateway --all -n llm --ignore-not-found=true 2>/dev/null || true
echo "  - Deleting Gateway in namespace istio-system..."
kubectl delete gateway inference-gateway -n istio-system --ignore-not-found=true 2>/dev/null || true

# Also remove native Istio resources if they exist
echo "  - Deleting native Istio resources..."
kubectl delete gateway.networking.istio.io --all -n llm --ignore-not-found=true 2>/dev/null || true
kubectl delete virtualservice --all -n llm --ignore-not-found=true 2>/dev/null || true
kubectl delete envoyfilter maas-auth-filter -n istio-system --ignore-not-found=true 2>/dev/null || true

# Remove OpenShift routes created for native Istio
if command -v oc &> /dev/null; then
    echo "  - Deleting OpenShift routes for native Istio..."
    oc delete route simulator-route -n istio-system --ignore-not-found=true 2>/dev/null || true
    oc delete route qwen3-route -n istio-system --ignore-not-found=true 2>/dev/null || true
fi

# Remove NetworkPolicy for OpenShift Router
echo "  - Deleting NetworkPolicy allow-openshift-router..."
kubectl delete networkpolicy allow-openshift-router -n istio-system --ignore-not-found=true 2>/dev/null || true

# Remove API key secrets from kuadrant-system (copied for OpenShift native Istio)
echo "  - Deleting copied API key secrets from kuadrant-system..."
for secret in freeuser1-apikey freeuser2-apikey premiumuser1-apikey premiumuser2-apikey; do
    kubectl delete secret $secret -n kuadrant-system --ignore-not-found=true 2>/dev/null || true
done

# Remove API key secrets from istio-system (copied for Gateway API)
echo "  - Deleting copied API key secrets from istio-system..."
for secret in freeuser1-apikey freeuser2-apikey premiumuser1-apikey premiumuser2-apikey; do
    kubectl delete secret $secret -n istio-system --ignore-not-found=true 2>/dev/null || true
done

# Step 4: Uninstall Kuadrant operator (Helm)
echo ""
echo "Step 4: Uninstalling Kuadrant operator..."
if helm list -n kuadrant-system 2>/dev/null | grep -q kuadrant-operator; then
    echo "  - Uninstalling Kuadrant Helm release..."
    helm uninstall kuadrant-operator -n kuadrant-system 2>/dev/null || true
else
    echo "  - Kuadrant Helm release not found"
fi

# Step 5: Delete Prometheus resources (if installed)
echo ""
echo "Step 5: Removing Prometheus resources..."
safe_delete "prometheus" "llm-observability"
safe_delete "servicemonitor" "llm-observability"
safe_delete "prometheusrule" "llm-observability"

# Remove Prometheus Operator if it exists
if kubectl get deployment prometheus-operator -n default &>/dev/null; then
    echo "  - Removing Prometheus Operator..."
    kubectl delete -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/master/bundle.yaml --ignore-not-found=true 2>/dev/null || true
fi

# Step 6: Delete namespaces (this will clean up remaining resources)
echo ""
echo "Step 6: Deleting namespaces..."
delete_namespace_wait "llm"
delete_namespace_wait "llm-observability"
delete_namespace_wait "kuadrant-system"

# Step 7: Uninstall Istio (Helm) - Skip if RHOAI ServiceMesh is present
echo ""
echo "Step 7: Uninstalling Istio..."

# Check if this is RHOAI's ServiceMesh
if kubectl get smcp -n istio-system 2>/dev/null | grep -q "data-science-smcp"; then
    echo "  ⚠️  RHOAI ServiceMesh detected, skipping Istio removal"
    echo "  ℹ️  To remove RHOAI components, delete the DataScienceCluster from OpenShift Console"
else
    if helm list -n istio-system 2>/dev/null | grep -q istiod; then
        echo "  - Uninstalling Istiod Helm release..."
        helm uninstall istiod -n istio-system 2>/dev/null || true
    fi

    if helm list -n istio-system 2>/dev/null | grep -q istio-base; then
        echo "  - Uninstalling Istio Base Helm release..."
        helm uninstall istio-base -n istio-system 2>/dev/null || true
    fi

    # Delete Istio namespace only if not managed by RHOAI
    delete_namespace_wait "istio-system"
fi

# Step 8: Uninstall KServe - Skip if managed by RHOAI
echo ""
echo "Step 8: Removing KServe..."

# Check if KServe is managed by RHOAI
if kubectl get datasciencecluster -n redhat-ods-operator 2>/dev/null | grep -q "default-dsc"; then
    echo "  ⚠️  RHOAI-managed KServe detected, skipping KServe removal"
    echo "  ℹ️  KServe is managed by RHOAI DataScienceCluster"
else
    # Delete KServe webhook configurations first
    safe_delete "mutatingwebhookconfiguration inferenceservice.serving.kserve.io"
    safe_delete "validatingwebhookconfiguration clusterservingruntime.serving.kserve.io"
    safe_delete "validatingwebhookconfiguration inferencegraph.serving.kserve.io"
    safe_delete "validatingwebhookconfiguration inferenceservice.serving.kserve.io"
    safe_delete "validatingwebhookconfiguration localmodelcache.serving.kserve.io"
    safe_delete "validatingwebhookconfiguration servingruntime.serving.kserve.io"
    safe_delete "validatingwebhookconfiguration trainedmodel.serving.kserve.io"

    # Delete KServe namespace
    delete_namespace_wait "kserve"

    # Delete KServe CRDs
    echo "  - Removing KServe CRDs..."
    kubectl delete crd inferenceservices.serving.kserve.io --ignore-not-found=true
    kubectl delete crd servingruntimes.serving.kserve.io --ignore-not-found=true
    kubectl delete crd clusterservingruntimes.serving.kserve.io --ignore-not-found=true
    kubectl delete crd clusterstoragecontainers.serving.kserve.io --ignore-not-found=true
    kubectl delete crd trainedmodels.serving.kserve.io --ignore-not-found=true
    kubectl delete crd inferencegraphs.serving.kserve.io --ignore-not-found=true
    kubectl delete crd localmodelnodegroups.serving.kserve.io --ignore-not-found=true
    kubectl delete crd localmodelnodes.serving.kserve.io --ignore-not-found=true
    kubectl delete crd localmodelcaches.serving.kserve.io --ignore-not-found=true
fi

# Step 9: Uninstall cert-manager
echo ""
echo "Step 9: Removing cert-manager..."
kubectl delete -f https://github.com/cert-manager/cert-manager/releases/download/v1.12.0/cert-manager.yaml --ignore-not-found=true 2>/dev/null || true

# Wait for cert-manager namespace deletion
delete_namespace_wait "cert-manager"

# Step 10: Remove Gateway API CRDs
echo ""
echo "Step 10: Removing Gateway API CRDs..."
kubectl delete crd gatewayclasses.gateway.networking.k8s.io --ignore-not-found=true
kubectl delete crd gateways.gateway.networking.k8s.io --ignore-not-found=true
kubectl delete crd httproutes.gateway.networking.k8s.io --ignore-not-found=true
kubectl delete crd grpcroutes.gateway.networking.k8s.io --ignore-not-found=true
kubectl delete crd referencegrants.gateway.networking.k8s.io --ignore-not-found=true
kubectl delete crd tcproutes.gateway.networking.k8s.io --ignore-not-found=true
kubectl delete crd tlsroutes.gateway.networking.k8s.io --ignore-not-found=true
kubectl delete crd udproutes.gateway.networking.k8s.io --ignore-not-found=true

# Step 11: Clean up any remaining Kuadrant CRDs
echo ""
echo "Step 11: Removing Kuadrant CRDs..."
kubectl delete crd kuadrants.kuadrant.io --ignore-not-found=true
kubectl delete crd authpolicies.kuadrant.io --ignore-not-found=true
kubectl delete crd ratelimitpolicies.kuadrant.io --ignore-not-found=true
kubectl delete crd dnspolicies.kuadrant.io --ignore-not-found=true
kubectl delete crd tlspolicies.kuadrant.io --ignore-not-found=true
kubectl delete crd authconfigs.authorino.kuadrant.io --ignore-not-found=true
kubectl delete crd authorizationpolicies.authorino.kuadrant.io --ignore-not-found=true

# Step 12: Final verification
echo ""
echo "================================================"
echo "Cleanup completed!"
echo "================================================"
echo ""
echo "Verification - Remaining resources:"
echo ""

# Check for remaining namespaces
echo "Namespaces check:"
for ns in llm llm-observability kuadrant-system istio-system kserve cert-manager; do
    if kubectl get namespace $ns &>/dev/null; then
        echo "  ⚠️  Namespace $ns still exists"
    else
        echo "  ✅ Namespace $ns removed"
    fi
done

# Check for Helm releases
echo ""
echo "Helm releases check:"
helm list -A 2>/dev/null | grep -E "(kuadrant|istio)" || echo "  ✅ No Kuadrant or Istio Helm releases found"

echo ""
echo "You can now run a fresh installation with:"
echo "  ./install.sh --simulator"
echo ""
echo "Note: Some resources may take a few moments to fully delete in the background." 