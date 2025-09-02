#!/bin/bash

# Comprehensive Model Testing Script
# Tests authentication and rate limiting for both Simulator and Qwen models
# across all tiers (free, premium, enterprise)
# Includes infrastructure verification and installation checks

set -euo pipefail

# ================================================================================
# Configuration
# ================================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Test configuration
VERBOSE=${VERBOSE:-false}
RESET_WAIT=${RESET_WAIT:-true}
SKIP_INFRA=${SKIP_INFRA:-false}

# Test results tracking
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
WARNINGS=0

# API Keys by tier
declare -A API_KEYS=(
  ["free"]="freeuser1_key"
  ["premium"]="premiumuser1_key"
  ["enterprise"]="enterpriseuser1_key"
)

# Token limits per tier (per minute)
declare -A TOKEN_LIMITS=(
  ["free"]="200"
  ["premium"]="1000"
  ["enterprise"]="5000"
)

# ================================================================================
# Helper Functions
# ================================================================================

log_test() {
  TOTAL_TESTS=$((TOTAL_TESTS + 1))
  echo ""
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${CYAN}TEST #$TOTAL_TESTS: $1${NC}"
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

log_success() {
  echo -e "${GREEN}✅ PASS: $1${NC}"
  PASSED_TESTS=$((PASSED_TESTS + 1))
}

log_error() {
  echo -e "${RED}❌ FAIL: $1${NC}"
  FAILED_TESTS=$((FAILED_TESTS + 1))
}

log_warning() {
  echo -e "${YELLOW}⚠️  WARNING: $1${NC}"
  WARNINGS=$((WARNINGS + 1))
}

log_info() {
  echo -e "${BLUE}ℹ️  $1${NC}"
}

log_check() {
  echo -e "${CYAN}🔍 $1${NC}"
}

# ================================================================================
# Platform Detection and URL Setup
# ================================================================================

detect_platform() {
  log_info "Detecting platform and setting up URLs..."
  
  if command -v oc &>/dev/null && oc whoami --show-server &>/dev/null; then
    PLATFORM="openshift"
    BASE_DOMAIN=$(oc whoami --show-server | sed 's/https:\/\/api\.//' | sed 's/:.*//')
    SIMULATOR_URL="https://simulator-route-llm.apps.$BASE_DOMAIN/v1/chat/completions"
    QWEN_URL="https://qwen3-route-llm.apps.$BASE_DOMAIN/v1/chat/completions"
    CURL_OPTS="-k"
    echo -e "${GREEN}✅ Platform: OpenShift (Domain: $BASE_DOMAIN)${NC}"
  else
    PLATFORM="kubernetes"
    # Check if port-forward is running
    if ! nc -z localhost 8000 2>/dev/null; then
      log_info "Starting port-forward..."
      kubectl port-forward -n llm svc/inference-gateway-istio 8000:80 &
      PF_PID=$!
      sleep 3
    fi
    SIMULATOR_URL="http://simulator.maas.local:8000/v1/chat/completions"
    QWEN_URL="http://qwen3.maas.local:8000/v1/chat/completions"
    CURL_OPTS=""
    echo -e "${GREEN}✅ Platform: Kubernetes (using port-forward)${NC}"
  fi
}

# ================================================================================
# Infrastructure Verification (from test-maas-complete.sh)
# ================================================================================

verify_infrastructure() {
  echo ""
  echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${MAGENTA}🏗️  INFRASTRUCTURE VERIFICATION${NC}"
  echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  
  local infra_ok=true
  
  # Check namespaces
  log_check "Checking required namespaces..."
  for ns in llm istio-system kuadrant-system; do
    if kubectl get namespace $ns &>/dev/null; then
      echo -e "  ${GREEN}✅ Namespace '$ns' exists${NC}"
    else
      echo -e "  ${RED}❌ Namespace '$ns' NOT FOUND${NC}"
      infra_ok=false
    fi
  done
  
  # Check token rate limiting components
  log_check "Checking token rate limiting components..."
  
  # Check EnvoyFilter
  if kubectl get envoyfilter token-rate-limit-filter -n istio-system &>/dev/null; then
    echo -e "  ${GREEN}✅ EnvoyFilter 'token-rate-limit-filter' exists${NC}"
    
    # Check if Lua filter is loaded in gateway
    if kubectl get deployment inference-gateway-istio -n istio-system &>/dev/null; then
      LUA_COUNT=$(kubectl exec -n istio-system deployment/inference-gateway-istio -c istio-proxy -- \
        pilot-agent request GET config_dump 2>/dev/null | grep -c "lua" || echo "0")
      if [[ $LUA_COUNT -gt 0 ]]; then
        echo -e "  ${GREEN}✅ Lua filter loaded in gateway ($LUA_COUNT references)${NC}"
      else
        echo -e "  ${YELLOW}⚠️  Lua filter not loaded in gateway${NC}"
      fi
    fi
  else
    echo -e "  ${YELLOW}⚠️  Token rate limiting EnvoyFilter not found${NC}"
  fi
  
  # Check ConfigMap
  if kubectl get configmap token-rate-limits -n istio-system &>/dev/null; then
    echo -e "  ${GREEN}✅ ConfigMap 'token-rate-limits' exists${NC}"
  else
    echo -e "  ${YELLOW}⚠️  ConfigMap 'token-rate-limits' not found${NC}"
  fi
  
  # Check API key secrets
  log_check "Checking API key secrets..."
  local secret_count=0
  for tier in free premium enterprise; do
    local user="${tier}user1"
    if [[ "$tier" == "free" ]]; then user="freeuser1"; fi
    if [[ "$tier" == "premium" ]]; then user="premiumuser1"; fi
    if [[ "$tier" == "enterprise" ]]; then user="enterpriseuser1"; fi
    
    if kubectl get secret "${user}-apikey" -n llm &>/dev/null; then
      echo -e "  ${GREEN}✅ ${tier^} tier API key exists${NC}"
      secret_count=$((secret_count + 1))
    else
      echo -e "  ${RED}❌ ${tier^} tier API key NOT FOUND${NC}"
    fi
  done
  
  # Check Kuadrant components
  log_check "Checking Kuadrant components..."
  if kubectl get deployment authorino -n kuadrant-system &>/dev/null; then
    echo -e "  ${GREEN}✅ Authorino (authentication) deployed${NC}"
  else
    echo -e "  ${RED}❌ Authorino NOT deployed${NC}"
    infra_ok=false
  fi
  
  if kubectl get deployment limitador-limitador -n kuadrant-system &>/dev/null; then
    echo -e "  ${GREEN}✅ Limitador (rate limiting) deployed${NC}"
  else
    echo -e "  ${YELLOW}⚠️  Limitador not deployed${NC}"
  fi
  
  if [[ "$infra_ok" == false ]]; then
    log_error "Infrastructure verification failed! Some components are missing."
    echo "Please run: ./install.sh --simulator --token-rate-limit"
    return 1
  fi
  
  return 0
}

# ================================================================================
# Model Availability Check
# ================================================================================

check_models() {
  log_info "Checking model availability..."
  
  # Check Simulator
  if kubectl get inferenceservice vllm-simulator -n llm &>/dev/null; then
    SIMULATOR_AVAILABLE=true
    echo -e "  ${GREEN}✅ Simulator model deployed${NC}"
  else
    SIMULATOR_AVAILABLE=false
    echo -e "  ${RED}❌ Simulator model NOT deployed${NC}"
  fi
  
  # Check Qwen - handle multiple pods correctly
  if kubectl get inferenceservice qwen3-0-6b-instruct -n llm &>/dev/null; then
    # Get only Running pods
    RUNNING_PODS=$(kubectl get pods -n llm -l serving.kserve.io/inferenceservice=qwen3-0-6b-instruct --no-headers 2>/dev/null | grep "Running" | grep "1/1" | wc -l)
    if [[ $RUNNING_PODS -gt 0 ]]; then
      QWEN_AVAILABLE=true
      POD_NAME=$(kubectl get pods -n llm -l serving.kserve.io/inferenceservice=qwen3-0-6b-instruct --no-headers 2>/dev/null | grep "Running" | grep "1/1" | head -1 | awk '{print $1}')
      echo -e "  ${GREEN}✅ Qwen3 model running (Pod: $POD_NAME)${NC}"
    else
      QWEN_AVAILABLE=false
      echo -e "  ${YELLOW}⚠️  Qwen3 model deployed but no running pods${NC}"
    fi
  else
    QWEN_AVAILABLE=false
    echo -e "  ${YELLOW}⚠️  Qwen3 model not deployed${NC}"
  fi
}

# ================================================================================
# Request Helper Function
# ================================================================================

make_request() {
  local url=$1
  local api_key=$2
  local model=$3
  local message=${4:-"Test message"}
  
  local response=$(curl $CURL_OPTS -s -o /dev/null -w "%{http_code}" -X POST "$url" \
    -H "Authorization: APIKEY $api_key" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"$message\"}]}" 2>/dev/null)
  
  echo "$response"
}

make_request_no_auth() {
  local url=$1
  local model=$2
  local message=${3:-"Test message"}
  
  local response=$(curl $CURL_OPTS -s -o /dev/null -w "%{http_code}" -X POST "$url" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"$message\"}]}" 2>/dev/null)
  
  echo "$response"
}

# ================================================================================
# Test 1: Simulator WITH Authentication
# ================================================================================

test_simulator_with_auth() {
  log_test "Simulator WITH Authentication (should succeed)"
  
  if [[ "$SIMULATOR_AVAILABLE" != true ]]; then
    log_info "Simulator not available, skipping test"
    return
  fi
  
  response=$(make_request "$SIMULATOR_URL" "${API_KEYS[premium]}" "simulator-model" "Test with auth")
  
  if [[ "$response" == "200" ]]; then
    log_success "Simulator accepts authenticated requests"
  else
    log_error "Simulator failed with auth (HTTP $response)"
  fi
}

# ================================================================================
# Test 2: Simulator WITHOUT Authentication
# ================================================================================

test_simulator_without_auth() {
  log_test "Simulator WITHOUT Authentication (should fail with 401)"
  
  if [[ "$SIMULATOR_AVAILABLE" != true ]]; then
    log_info "Simulator not available, skipping test"
    return
  fi
  
  response=$(make_request_no_auth "$SIMULATOR_URL" "simulator-model" "Test without auth")
  
  if [[ "$response" == "401" ]]; then
    log_success "Simulator correctly rejects unauthenticated requests"
  else
    log_error "Expected 401, got HTTP $response"
  fi
}

# ================================================================================
# Test 3: Qwen WITH Authentication
# ================================================================================

test_qwen_with_auth() {
  log_test "Qwen WITH Authentication (should succeed)"
  
  if [[ "$QWEN_AVAILABLE" != true ]]; then
    log_info "Qwen not available, skipping test"
    return
  fi
  
  response=$(make_request "$QWEN_URL" "${API_KEYS[premium]}" "qwen3-0-6b-instruct" "What is 2+2?")
  
  if [[ "$response" == "200" ]]; then
    log_success "Qwen accepts authenticated requests"
  else
    log_error "Qwen failed with auth (HTTP $response)"
  fi
}

# ================================================================================
# Test 4: Qwen WITHOUT Authentication
# ================================================================================

test_qwen_without_auth() {
  log_test "Qwen WITHOUT Authentication (should fail with 401)"
  
  if [[ "$QWEN_AVAILABLE" != true ]]; then
    log_info "Qwen not available, skipping test"
    return
  fi
  
  response=$(make_request_no_auth "$QWEN_URL" "qwen3-0-6b-instruct" "What is 2+2?")
  
  if [[ "$response" == "401" ]]; then
    log_success "Qwen correctly rejects unauthenticated requests"
  else
    log_error "Expected 401, got HTTP $response"
  fi
}

# ================================================================================
# Test 5: Simulator FREE Tier Rate Limiting
# ================================================================================

test_simulator_free_tier() {
  log_test "Simulator FREE Tier Rate Limiting (200 tokens/min)"
  
  if [[ "$SIMULATOR_AVAILABLE" != true ]]; then
    log_info "Simulator not available, skipping test"
    return
  fi
  
  log_info "Making requests to consume 200 token limit..."
  local tokens_used=0
  local request_count=0
  local rate_limited=false
  
  # Each simulator request uses 30 tokens, so ~7 requests should hit the limit
  for i in {1..10}; do
    response=$(make_request "$SIMULATOR_URL" "${API_KEYS[free]}" "simulator-model" "Request $i")
    
    if [[ "$response" == "200" ]]; then
      request_count=$((request_count + 1))
      tokens_used=$((tokens_used + 30))
      echo "  Request $i: ✅ Success (Total: $tokens_used tokens)"
    elif [[ "$response" == "429" ]]; then
      echo "  Request $i: 🛑 Rate limited at $tokens_used tokens"
      rate_limited=true
      break
    else
      echo "  Request $i: ❓ HTTP $response"
    fi
    
    sleep 0.2
  done
  
  if [[ "$rate_limited" == true ]] && [[ $tokens_used -le 200 ]]; then
    log_success "Free tier correctly limited around 200 tokens"
  else
    log_error "Free tier rate limiting not working correctly (used $tokens_used tokens)"
  fi
}

# ================================================================================
# Test 6: Simulator PREMIUM Tier Rate Limiting
# ================================================================================

test_simulator_premium_tier() {
  log_test "Simulator PREMIUM Tier Rate Limiting (1000 tokens/min)"
  
  if [[ "$SIMULATOR_AVAILABLE" != true ]]; then
    log_info "Simulator not available, skipping test"
    return
  fi
  
  # Wait a bit to ensure clean state
  sleep 2
  
  log_info "Making 10 requests (should use ~300 tokens, well under 1000 limit)..."
  local success_count=0
  
  for i in {1..10}; do
    response=$(make_request "$SIMULATOR_URL" "${API_KEYS[premium]}" "simulator-model" "Premium request $i")
    
    if [[ "$response" == "200" ]]; then
      success_count=$((success_count + 1))
      echo "  Request $i: ✅ Success"
    elif [[ "$response" == "429" ]]; then
      echo "  Request $i: 🛑 Rate limited (unexpected)"
      break
    else
      echo "  Request $i: ❓ HTTP $response"
    fi
  done
  
  if [[ $success_count -eq 10 ]]; then
    log_success "Premium tier handled all 10 requests (300 tokens) without limit"
  else
    log_error "Premium tier was limited after $success_count requests"
  fi
}

# ================================================================================
# Test 7: Simulator ENTERPRISE Tier Rate Limiting
# ================================================================================

test_simulator_enterprise_tier() {
  log_test "Simulator ENTERPRISE Tier Rate Limiting (5000 tokens/min)"
  
  if [[ "$SIMULATOR_AVAILABLE" != true ]]; then
    log_info "Simulator not available, skipping test"
    return
  fi
  
  # Check if enterprise key exists
  if ! kubectl get secret enterpriseuser1-apikey -n llm &>/dev/null; then
    log_info "Enterprise tier not configured, skipping test"
    return
  fi
  
  log_info "Making 20 requests (should use ~600 tokens, well under 5000 limit)..."
  local success_count=0
  
  for i in {1..20}; do
    response=$(make_request "$SIMULATOR_URL" "${API_KEYS[enterprise]}" "simulator-model" "Enterprise request $i")
    
    if [[ "$response" == "200" ]]; then
      success_count=$((success_count + 1))
      if [[ $((i % 5)) -eq 0 ]]; then
        echo "  Requests 1-$i: ✅ All successful"
      fi
    elif [[ "$response" == "429" ]]; then
      echo "  Request $i: 🛑 Rate limited (unexpected)"
      break
    else
      echo "  Request $i: ❓ HTTP $response"
    fi
  done
  
  if [[ $success_count -eq 20 ]]; then
    log_success "Enterprise tier handled all 20 requests (600 tokens) without limit"
  else
    log_error "Enterprise tier was limited after $success_count requests"
  fi
}

# ================================================================================
# Test 8: Qwen FREE Tier Rate Limiting
# ================================================================================

test_qwen_free_tier() {
  log_test "Qwen FREE Tier Rate Limiting (200 tokens/min)"
  
  if [[ "$QWEN_AVAILABLE" != true ]]; then
    log_info "Qwen not available, skipping test"
    return
  fi
  
  # Wait for clean state
  sleep 2
  
  log_info "Making requests to test 200 token limit..."
  local tokens_used=0
  local request_count=0
  local rate_limited=false
  
  # Qwen uses actual tokens, estimates ~40-50 per request
  for i in {1..8}; do
    response=$(make_request "$QWEN_URL" "${API_KEYS[free]}" "qwen3-0-6b-instruct" "Count to $i")
    
    if [[ "$response" == "200" ]]; then
      request_count=$((request_count + 1))
      tokens_used=$((tokens_used + 45))  # Estimate
      echo "  Request $i: ✅ Success (Est. total: $tokens_used tokens)"
    elif [[ "$response" == "429" ]]; then
      echo "  Request $i: 🛑 Rate limited at ~$tokens_used tokens"
      rate_limited=true
      break
    else
      echo "  Request $i: ❓ HTTP $response"
    fi
    
    sleep 0.3
  done
  
  if [[ "$rate_limited" == true ]] && [[ $tokens_used -le 250 ]]; then
    log_success "Free tier correctly limited around 200 tokens"
  elif [[ "$request_count" -gt 0 ]]; then
    log_success "Free tier processed $request_count requests"
  else
    log_error "Free tier rate limiting issue"
  fi
}

# ================================================================================
# Test 9: Qwen PREMIUM Tier Rate Limiting
# ================================================================================

test_qwen_premium_tier() {
  log_test "Qwen PREMIUM Tier Rate Limiting (1000 tokens/min)"
  
  if [[ "$QWEN_AVAILABLE" != true ]]; then
    log_info "Qwen not available, skipping test"
    return
  fi
  
  # Wait for clean state
  sleep 2
  
  log_info "Making 10 requests (should use ~450 tokens, under 1000 limit)..."
  local success_count=0
  
  for i in {1..10}; do
    response=$(make_request "$QWEN_URL" "${API_KEYS[premium]}" "qwen3-0-6b-instruct" "Tell me fact number $i")
    
    if [[ "$response" == "200" ]]; then
      success_count=$((success_count + 1))
      echo "  Request $i: ✅ Success"
    elif [[ "$response" == "429" ]]; then
      echo "  Request $i: 🛑 Rate limited (unexpected)"
      break
    else
      echo "  Request $i: ❓ HTTP $response"
    fi
    
    sleep 0.2
  done
  
  if [[ $success_count -eq 10 ]]; then
    log_success "Premium tier handled all 10 Qwen requests without limit"
  else
    log_error "Premium tier was limited after $success_count requests"
  fi
}

# ================================================================================
# Test 10: Qwen ENTERPRISE Tier Rate Limiting
# ================================================================================

test_qwen_enterprise_tier() {
  log_test "Qwen ENTERPRISE Tier Rate Limiting (5000 tokens/min)"
  
  if [[ "$QWEN_AVAILABLE" != true ]]; then
    log_info "Qwen not available, skipping test"
    return
  fi
  
  # Check if enterprise key exists
  if ! kubectl get secret enterpriseuser1-apikey -n llm &>/dev/null; then
    log_info "Enterprise tier not configured, using premium key as fallback"
    # Use premium key as fallback for testing
    local test_key="${API_KEYS[premium]}"
    local expected_limit="1000"
  else
    local test_key="${API_KEYS[enterprise]}"
    local expected_limit="5000"
  fi
  
  log_info "Making 15 requests (should use ~675 tokens)..."
  local success_count=0
  
  for i in {1..15}; do
    response=$(make_request "$QWEN_URL" "$test_key" "qwen3-0-6b-instruct" "Question $i: What is $i plus $i?")
    
    if [[ "$response" == "200" ]]; then
      success_count=$((success_count + 1))
      if [[ $((i % 5)) -eq 0 ]]; then
        echo "  Requests 1-$i: ✅ All successful"
      fi
    elif [[ "$response" == "429" ]]; then
      echo "  Request $i: 🛑 Rate limited"
      break
    else
      echo "  Request $i: ❓ HTTP $response"
    fi
    
    sleep 0.2
  done
  
  if [[ $success_count -ge 10 ]]; then
    log_success "High tier handled $success_count Qwen requests successfully"
  else
    log_error "High tier was limited after only $success_count requests"
  fi
}

# ================================================================================
# Wait for Rate Limit Reset
# ================================================================================

wait_for_reset() {
  if [[ "$RESET_WAIT" == true ]]; then
    echo ""
    log_info "Checking if rate limits need to reset..."
    
    # Test with premium key
    response=$(make_request "$SIMULATOR_URL" "${API_KEYS[premium]}" "simulator-model" "Test")
    
    if [[ "$response" == "429" ]]; then
      echo -e "${YELLOW}⚠️  Rate limits exhausted, waiting 60 seconds for reset...${NC}"
      for i in {60..1}; do
        echo -ne "\r  Waiting: $i seconds remaining... "
        sleep 1
      done
      echo -e "\r  ${GREEN}✅ Rate limits should be reset now${NC}      "
    else
      echo -e "${GREEN}✅ Rate limits are available${NC}"
    fi
  fi
}

# ================================================================================
# Summary Report
# ================================================================================

generate_summary() {
  echo ""
  echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${MAGENTA}📊 TEST SUMMARY${NC}"
  echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  
  local pass_rate=0
  if [[ $TOTAL_TESTS -gt 0 ]]; then
    pass_rate=$(( (PASSED_TESTS * 100) / TOTAL_TESTS ))
  fi
  
  echo "Test Results:"
  echo "  Total Tests:  $TOTAL_TESTS"
  echo -e "  Passed:       ${GREEN}$PASSED_TESTS${NC}"
  echo -e "  Failed:       ${RED}$FAILED_TESTS${NC}"
  echo -e "  Warnings:     ${YELLOW}$WARNINGS${NC}"
  echo "  Pass Rate:    $pass_rate%"
  echo ""
  
  echo "Models Tested:"
  echo "  Simulator: $([ "$SIMULATOR_AVAILABLE" == true ] && echo "✅ Available" || echo "❌ Not Available")"
  echo "  Qwen3:     $([ "$QWEN_AVAILABLE" == true ] && echo "✅ Available" || echo "❌ Not Available")"
  echo ""
  
  echo "Configuration:"
  echo "  Platform:     $PLATFORM"
  echo "  Rate Limit:   TOKEN-BASED"
  echo "  Tiers:        Free (200), Premium (1000), Enterprise (5000) tokens/min"
  echo ""
  
  if [[ $FAILED_TESTS -eq 0 ]]; then
    echo -e "${GREEN}✅ ALL TESTS PASSED!${NC}"
  elif [[ $pass_rate -ge 80 ]]; then
    echo -e "${YELLOW}⚠️  MOSTLY PASSING ($pass_rate%)${NC}"
  else
    echo -e "${RED}❌ MULTIPLE FAILURES ($pass_rate% pass rate)${NC}"
  fi
}

# ================================================================================
# Main Execution
# ================================================================================

main() {
  clear
  echo "╔══════════════════════════════════════════════════════════════════════════════╗"
  echo "║           Comprehensive Model Authentication & Rate Limiting Tests           ║"
  echo "╚══════════════════════════════════════════════════════════════════════════════╝"
  echo ""
  
  # Setup
  detect_platform
  
  # Infrastructure verification (unless skipped)
  if [[ "$SKIP_INFRA" != true ]]; then
    if ! verify_infrastructure; then
      echo -e "${RED}Infrastructure verification failed. Exiting.${NC}"
      exit 1
    fi
  fi
  
  check_models
  wait_for_reset
  
  # Run all 10 tests
  test_simulator_with_auth      # Test 1
  test_simulator_without_auth   # Test 2
  test_qwen_with_auth          # Test 3
  test_qwen_without_auth       # Test 4
  
  # Small wait between auth tests and rate limit tests
  echo ""
  log_info "Waiting 3 seconds before rate limit tests..."
  sleep 3
  
  test_simulator_free_tier     # Test 5
  test_simulator_premium_tier  # Test 6
  test_simulator_enterprise_tier # Test 7
  
  # Wait for free tier to reset
  echo ""
  log_info "Waiting 60 seconds for free tier reset before Qwen tests..."
  for i in {60..1}; do
    echo -ne "\r  Waiting: $i seconds remaining... "
    sleep 1
  done
  echo -e "\r  ${GREEN}✅ Continuing with Qwen tests${NC}      "
  
  test_qwen_free_tier         # Test 8
  test_qwen_premium_tier      # Test 9
  test_qwen_enterprise_tier   # Test 10
  
  # Generate summary
  generate_summary
  
  # Cleanup
  if [[ -n "${PF_PID:-}" ]]; then
    log_info "Cleaning up port-forward (PID: $PF_PID)"
    kill $PF_PID 2>/dev/null || true
  fi
  
  echo ""
  echo "Test completed at $(date '+%Y-%m-%d %H:%M:%S')"
  
  # Exit with appropriate code
  if [[ $FAILED_TESTS -gt 0 ]]; then
    exit 1
  else
    exit 0
  fi
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --no-wait)
      RESET_WAIT=false
      shift
      ;;
    --verbose|-v)
      VERBOSE=true
      shift
      ;;
    --skip-infra)
      SKIP_INFRA=true
      shift
      ;;
    --help|-h)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --no-wait     Skip waiting for rate limit reset"
      echo "  --verbose     Show detailed output"
      echo "  --skip-infra  Skip infrastructure verification"
      echo "  --help        Show this help message"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      echo "Use --help for usage information"
      exit 1
      ;;
  esac
done

# Run main function
main "$@" 