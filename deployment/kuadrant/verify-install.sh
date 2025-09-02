#!/bin/bash

# Quick installation verification script
# Performs basic checks to ensure the MaaS system is properly installed

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "╔══════════════════════════════════════════════════════════════════════════════╗"
echo "║                     MaaS Installation Verification                           ║"
echo "╚══════════════════════════════════════════════════════════════════════════════╝"
echo ""

ERRORS=0
WARNINGS=0

# Check namespaces
echo -e "${BLUE}🔍 Checking namespaces...${NC}"
for ns in llm istio-system kuadrant-system; do
  if kubectl get namespace $ns &>/dev/null; then
    echo -e "  ${GREEN}✅ $ns${NC}"
  else
    echo -e "  ${RED}❌ $ns missing${NC}"
    ((ERRORS++))
  fi
done

# Check deployments
echo -e "\n${BLUE}🔍 Checking core deployments...${NC}"
if kubectl get deployment authorino -n kuadrant-system &>/dev/null; then
  echo -e "  ${GREEN}✅ Authorino (authentication)${NC}"
else
  echo -e "  ${RED}❌ Authorino missing${NC}"
  ((ERRORS++))
fi

if kubectl get deployment inference-gateway-istio -n istio-system &>/dev/null 2>&1; then
  echo -e "  ${GREEN}✅ Gateway${NC}"
else
  echo -e "  ${YELLOW}⚠️  Gateway not found (might be using different gateway)${NC}"
  ((WARNINGS++))
fi

# Check models
echo -e "\n${BLUE}🔍 Checking models...${NC}"
if kubectl get inferenceservice vllm-simulator -n llm &>/dev/null; then
  echo -e "  ${GREEN}✅ Simulator model${NC}"
else
  echo -e "  ${YELLOW}⚠️  Simulator not deployed${NC}"
  ((WARNINGS++))
fi

if kubectl get inferenceservice qwen3-0-6b-instruct -n llm &>/dev/null; then
  RUNNING=$(kubectl get pods -n llm -l serving.kserve.io/inferenceservice=qwen3-0-6b-instruct --no-headers 2>/dev/null | grep "Running" | grep "1/1" | wc -l)
  if [[ $RUNNING -gt 0 ]]; then
    echo -e "  ${GREEN}✅ Qwen3 model (running)${NC}"
  else
    echo -e "  ${YELLOW}⚠️  Qwen3 deployed but not running${NC}"
    ((WARNINGS++))
  fi
else
  echo -e "  ${YELLOW}⚠️  Qwen3 not deployed${NC}"
  ((WARNINGS++))
fi

# Check API keys
echo -e "\n${BLUE}🔍 Checking API keys...${NC}"
for key in freeuser1-apikey premiumuser1-apikey enterpriseuser1-apikey; do
  if kubectl get secret $key -n llm &>/dev/null; then
    echo -e "  ${GREEN}✅ $key${NC}"
  else
    echo -e "  ${YELLOW}⚠️  $key missing${NC}"
    ((WARNINGS++))
  fi
done

# Check token rate limiting
echo -e "\n${BLUE}🔍 Checking token rate limiting...${NC}"
if kubectl get envoyfilter token-rate-limit-filter -n istio-system &>/dev/null; then
  echo -e "  ${GREEN}✅ EnvoyFilter configured${NC}"
else
  echo -e "  ${YELLOW}⚠️  Token rate limiting not configured${NC}"
  ((WARNINGS++))
fi

# Summary
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [[ $ERRORS -eq 0 ]]; then
  if [[ $WARNINGS -eq 0 ]]; then
    echo -e "${GREEN}✅ All checks passed! System is properly installed.${NC}"
  else
    echo -e "${YELLOW}⚠️  Installation complete with $WARNINGS warnings.${NC}"
    echo "   Run './test-models-comprehensive.sh' for detailed testing."
  fi
  exit 0
else
  echo -e "${RED}❌ Installation has $ERRORS errors and $WARNINGS warnings.${NC}"
  echo "   Please run './install.sh --simulator --token-rate-limit' to fix."
  exit 1
fi 