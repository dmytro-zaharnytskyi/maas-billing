#!/bin/bash

# KServe Troubleshooting Script
# This script helps diagnose KServe installation issues

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}KServe Troubleshooting Script${NC}"
echo -e "${YELLOW}================================${NC}"

# Function to check component status
check_component() {
    local namespace=$1
    local component=$2
    local deployment=$3
    
    echo -e "\n${YELLOW}Checking $component in $namespace...${NC}"
    
    if kubectl get namespace $namespace &>/dev/null; then
        echo -e "${GREEN}✓ Namespace $namespace exists${NC}"
    else
        echo -e "${RED}✗ Namespace $namespace does not exist${NC}"
        return 1
    fi
    
    if kubectl get deployment $deployment -n $namespace &>/dev/null; then
        local ready=$(kubectl get deployment $deployment -n $namespace -o jsonpath='{.status.readyReplicas}')
        local desired=$(kubectl get deployment $deployment -n $namespace -o jsonpath='{.spec.replicas}')
        
        if [ "$ready" = "$desired" ] && [ "$ready" != "0" ]; then
            echo -e "${GREEN}✓ $deployment is ready ($ready/$desired)${NC}"
        else
            echo -e "${RED}✗ $deployment is not ready ($ready/$desired)${NC}"
            kubectl get pods -n $namespace -l app=$deployment
            return 1
        fi
    else
        echo -e "${RED}✗ Deployment $deployment not found in $namespace${NC}"
        return 1
    fi
}

# Function to check certificates
check_certificates() {
    echo -e "\n${YELLOW}Checking certificates...${NC}"
    
    if kubectl get certificates -n kserve &>/dev/null; then
        local certs=$(kubectl get certificates -n kserve --no-headers | wc -l)
        if [ "$certs" -gt 0 ]; then
            echo -e "${GREEN}✓ Found $certs certificate(s) in kserve namespace${NC}"
            kubectl get certificates -n kserve
        else
            echo -e "${YELLOW}⚠ No certificates found in kserve namespace${NC}"
        fi
    else
        echo -e "${YELLOW}⚠ No certificate CRDs found${NC}"
    fi
}

# Function to check webhook configuration
check_webhooks() {
    echo -e "\n${YELLOW}Checking webhook configurations...${NC}"
    
    if kubectl get validatingwebhookconfigurations | grep kserve &>/dev/null; then
        echo -e "${GREEN}✓ KServe validating webhooks found${NC}"
    else
        echo -e "${RED}✗ KServe validating webhooks not found${NC}"
    fi
    
    if kubectl get mutatingwebhookconfigurations | grep kserve &>/dev/null; then
        echo -e "${GREEN}✓ KServe mutating webhooks found${NC}"
    else
        echo -e "${RED}✗ KServe mutating webhooks not found${NC}"
    fi
}

# Function to check KServe configuration
check_kserve_config() {
    echo -e "\n${YELLOW}Checking KServe configuration...${NC}"
    
    if kubectl get configmap inferenceservice-config -n kserve &>/dev/null; then
        echo -e "${GREEN}✓ KServe configuration found${NC}"
        
        local deploy_mode=$(kubectl get configmap inferenceservice-config -n kserve -o jsonpath='{.data.deploy}' | jq -r '.defaultDeploymentMode' 2>/dev/null || echo "unknown")
        echo -e "  Deployment mode: $deploy_mode"
        
        local gateway_enabled=$(kubectl get configmap inferenceservice-config -n kserve -o jsonpath='{.data.ingress}' | jq -r '.enableGatewayApi' 2>/dev/null || echo "unknown")
        echo -e "  Gateway API enabled: $gateway_enabled"
    else
        echo -e "${RED}✗ KServe configuration not found${NC}"
    fi
}

# Main checks
echo -e "\n${YELLOW}1. Checking cert-manager...${NC}"
check_component "cert-manager" "cert-manager" "cert-manager"
check_component "cert-manager" "cert-manager-cainjector" "cert-manager-cainjector"
check_component "cert-manager" "cert-manager-webhook" "cert-manager-webhook"

echo -e "\n${YELLOW}2. Checking KServe...${NC}"
check_component "kserve" "kserve-controller" "kserve-controller-manager"

echo -e "\n${YELLOW}3. Checking certificates...${NC}"
check_certificates

echo -e "\n${YELLOW}4. Checking webhooks...${NC}"
check_webhooks

echo -e "\n${YELLOW}5. Checking KServe configuration...${NC}"
check_kserve_config

# Test InferenceService CRD
echo -e "\n${YELLOW}6. Checking InferenceService CRD...${NC}"
if kubectl get crd inferenceservices.serving.kserve.io &>/dev/null; then
    echo -e "${GREEN}✓ InferenceService CRD exists${NC}"
else
    echo -e "${RED}✗ InferenceService CRD not found${NC}"
fi

# Summary
echo -e "\n${YELLOW}================================${NC}"
echo -e "${GREEN}Troubleshooting complete!${NC}"

# Quick fix suggestions
echo -e "\n${YELLOW}Quick fix commands:${NC}"
echo -e "• Reinstall cert-manager: kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.17.0/cert-manager.yaml"
echo -e "• Reinstall KServe: kubectl apply --server-side -f https://github.com/kserve/kserve/releases/download/v0.15.0/kserve.yaml"
echo -e "• Restart KServe controller: kubectl rollout restart deployment/kserve-controller-manager -n kserve"
echo -e "• Check logs: kubectl logs -n kserve deployment/kserve-controller-manager"

echo -e "\n${YELLOW}Test with mock model:${NC}"
echo -e "kubectl apply -f local-model-serving.yaml"
echo -e "./test-api.sh"