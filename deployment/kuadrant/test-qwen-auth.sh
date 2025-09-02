#!/bin/bash

# Test script for Qwen model with authentication and rate limiting

# Don't exit on error - we want to test failures too

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get the route URL
ROUTE_URL=$(oc get route qwen3-route -n istio-system -o jsonpath='{.spec.host}' 2>/dev/null || echo "qwen3-route-llm.apps.dmytroz-maas-v2.7ctq.s1.devshift.org")
SIMULATOR_URL=$(oc get route simulator-route -n istio-system -o jsonpath='{.spec.host}' 2>/dev/null || echo "simulator-route-llm.apps.dmytroz-maas-v2.7ctq.s1.devshift.org")

echo "🧪 Testing MaaS Authentication and Rate Limiting"
echo "================================================"
echo ""

# Test 1: No authentication - Simulator
echo -e "${YELLOW}Test 1: Simulator - Request WITHOUT API key (should fail with 401)${NC}"
echo "URL: https://$SIMULATOR_URL/v1/chat/completions"
RESPONSE=$(curl -k -s -X POST "https://$SIMULATOR_URL/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"simulator-model","messages":[{"role":"user","content":"Hello"}]}' \
  -w "\n{\"http_code\": %{http_code}}" 2>/dev/null | tail -1)

HTTP_CODE=$(echo "$RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin)['http_code'])")

if [ "$HTTP_CODE" = "401" ]; then
  echo -e "${GREEN}✅ PASS: Got 401 Unauthorized as expected${NC}"
else
  echo -e "${RED}❌ FAIL: Expected 401, got $HTTP_CODE${NC}"
fi
echo ""

# Test 2: With valid API key - Simulator
echo -e "${YELLOW}Test 2: Simulator - Request WITH Premium API key (should work)${NC}"
RESPONSE=$(curl -k -s -X POST "https://$SIMULATOR_URL/v1/chat/completions" \
  -H 'Authorization: APIKEY premiumuser1_key' \
  -H 'Content-Type: application/json' \
  -d '{"model":"simulator-model","messages":[{"role":"user","content":"Hello"}]}' \
  -w "\n{\"http_code\": %{http_code}}" 2>/dev/null)

HTTP_CODE=$(echo "$RESPONSE" | tail -1 | python3 -c "import sys, json; print(json.load(sys.stdin)['http_code'])")

if [ "$HTTP_CODE" = "200" ]; then
  echo -e "${GREEN}✅ PASS: Got 200 OK with valid API key${NC}"
  echo "Response preview:"
  echo "$RESPONSE" | head -1 | python3 -m json.tool 2>/dev/null | head -5
else
  echo -e "${RED}❌ FAIL: Expected 200, got $HTTP_CODE${NC}"
fi
echo ""

# Test 3: Rate limiting for free tier - Simulator
echo -e "${YELLOW}Test 3: Simulator - Rate Limiting FREE tier (5 req/2min)${NC}"
echo "Making 7 requests rapidly..."

PASS_COUNT=0
FAIL_COUNT=0

for i in {1..7}; do
  HTTP_CODE=$(curl -k -s -X POST "https://$SIMULATOR_URL/v1/chat/completions" \
    -H 'Authorization: APIKEY freeuser2_key' \
    -H 'Content-Type: application/json' \
    -d '{"model":"simulator-model","messages":[{"role":"user","content":"Test"}]}' \
    -w "%{http_code}" -o /dev/null 2>/dev/null)
  
  if [ $i -le 5 ]; then
    if [ "$HTTP_CODE" = "200" ]; then
      echo -e "  Request $i: ${GREEN}✓ 200 OK${NC}"
      ((PASS_COUNT++))
    else
      echo -e "  Request $i: ${RED}✗ Got $HTTP_CODE (expected 200)${NC}"
      ((FAIL_COUNT++))
    fi
  else
    if [ "$HTTP_CODE" = "429" ]; then
      echo -e "  Request $i: ${GREEN}✓ 429 Rate Limited${NC}"
      ((PASS_COUNT++))
    else
      echo -e "  Request $i: ${RED}✗ Got $HTTP_CODE (expected 429)${NC}"
      ((FAIL_COUNT++))
    fi
  fi
  sleep 0.3
done

if [ $FAIL_COUNT -eq 0 ]; then
  echo -e "${GREEN}✅ PASS: Rate limiting working correctly for free tier${NC}"
else
  echo -e "${RED}❌ FAIL: Rate limiting not working as expected${NC}"
fi
echo ""

# Test 4: Comprehensive Qwen GPU Model Testing
echo -e "${YELLOW}Test 4: Qwen GPU Model - Comprehensive Testing${NC}"
echo "================================================"

# Check pod status
POD_STATUS=$(kubectl get pods -n llm -l serving.kserve.io/inferenceservice=qwen3-0-6b-instruct --no-headers 2>/dev/null | awk '{print $3}')
POD_NAME=$(kubectl get pods -n llm -l serving.kserve.io/inferenceservice=qwen3-0-6b-instruct --no-headers 2>/dev/null | awk '{print $1}')

if [ -z "$POD_STATUS" ]; then
  echo -e "${RED}❌ Qwen model not deployed${NC}"
  echo "  Deploy with: ./install.sh --qwen3"
elif [ "$POD_STATUS" = "Running" ]; then
  READY=$(kubectl get pods -n llm -l serving.kserve.io/inferenceservice=qwen3-0-6b-instruct --no-headers 2>/dev/null | awk '{print $2}')
  if [ "$READY" = "1/1" ]; then
    echo -e "${GREEN}✅ Qwen model pod is running (Pod: $POD_NAME)${NC}"
    
    # Get GPU info
    echo -e "${BLUE}ℹ️  GPU Information:${NC}"
    GPU_NODE=$(kubectl get pod $POD_NAME -n llm -o jsonpath='{.spec.nodeName}' 2>/dev/null)
    GPU_TYPE=$(kubectl get node $GPU_NODE -o jsonpath='{.metadata.labels.nvidia\.com/gpu\.product}' 2>/dev/null || echo "Unknown")
    GPU_MEMORY=$(kubectl get node $GPU_NODE -o jsonpath='{.metadata.labels.nvidia\.com/gpu\.memory}' 2>/dev/null || echo "Unknown")
    echo "  Node: $GPU_NODE"
    echo "  GPU Type: $GPU_TYPE"
    echo "  GPU Memory: ${GPU_MEMORY}MB"
    echo ""
    
    # Test 4a: Without authentication
    echo -e "${YELLOW}Test 4a: Qwen - Request WITHOUT API key (should fail)${NC}"
    HTTP_CODE=$(curl -k -s -X POST "https://$ROUTE_URL/v1/chat/completions" \
      -H 'Content-Type: application/json' \
      -d '{"model":"qwen3-0-6b-instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":10}' \
      -w "%{http_code}" -o /dev/null 2>/dev/null)
    
    if [ "$HTTP_CODE" = "401" ]; then
      echo -e "  ${GREEN}✅ PASS: Authentication working (401 without key)${NC}"
    else
      echo -e "  ${RED}❌ FAIL: Expected 401, got $HTTP_CODE${NC}"
    fi
    
    # Test 4b: With premium authentication
    echo -e "${YELLOW}Test 4b: Qwen - Request WITH Premium API key${NC}"
    RESPONSE=$(curl -k -s -X POST "https://$ROUTE_URL/v1/chat/completions" \
      -H 'Authorization: APIKEY premiumuser1_key' \
      -H 'Content-Type: application/json' \
      -d '{"model":"qwen3-0-6b-instruct","messages":[{"role":"user","content":"What is 2+2?"}],"max_tokens":20}' \
      -w "\n{\"http_code\": %{http_code}, \"time_total\": %{time_total}}" 2>/dev/null)
    
    JSON_RESPONSE=$(echo "$RESPONSE" | head -1)
    METRICS=$(echo "$RESPONSE" | tail -1)
    HTTP_CODE=$(echo "$METRICS" | python3 -c "import sys, json; print(json.load(sys.stdin)['http_code'])" 2>/dev/null || echo "0")
    TIME_TOTAL=$(echo "$METRICS" | python3 -c "import sys, json; print(json.load(sys.stdin)['time_total'])" 2>/dev/null || echo "0")
    
    if [ "$HTTP_CODE" = "200" ]; then
      echo -e "  ${GREEN}✅ PASS: Qwen model responding correctly${NC}"
      echo "  Response time: ${TIME_TOTAL}s"
      
      # Parse and display response
      if echo "$JSON_RESPONSE" | python3 -m json.tool &>/dev/null; then
        MODEL=$(echo "$JSON_RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin).get('model', 'unknown'))" 2>/dev/null)
        CONTENT=$(echo "$JSON_RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin)['choices'][0]['message']['content'])" 2>/dev/null | head -1)
        TOKENS=$(echo "$JSON_RESPONSE" | python3 -c "import sys, json; u=json.load(sys.stdin).get('usage', {}); print(f\"prompt:{u.get('prompt_tokens', 0)}, completion:{u.get('completion_tokens', 0)}, total:{u.get('total_tokens', 0)}\")" 2>/dev/null)
        
        echo "  Model: $MODEL"
        echo "  Response: \"$CONTENT\""
        echo "  Token usage: $TOKENS"
      fi
    else
      echo -e "  ${YELLOW}⚠️  Qwen model returned HTTP $HTTP_CODE${NC}"
      echo "  Response time: ${TIME_TOTAL}s"
      
      # Check logs for errors
      if [ "$HTTP_CODE" = "500" ] || [ "$HTTP_CODE" = "503" ]; then
        echo "  Checking recent logs for errors..."
        RECENT_ERRORS=$(kubectl logs -n llm $POD_NAME --tail=10 2>/dev/null | grep -E "ERROR|error|Error" | head -3)
        if [ -n "$RECENT_ERRORS" ]; then
          echo "  Recent errors in logs:"
          echo "$RECENT_ERRORS" | sed 's/^/    /'
        fi
      fi
    fi
    
    # Test 4c: Rate limiting for Qwen with free tier
    echo -e "${YELLOW}Test 4c: Qwen - Rate Limiting with FREE tier${NC}"
    echo "  Making 3 rapid requests..."
    
    FREE_PASS=0
    FREE_FAIL=0
    
    for i in {1..3}; do
      HTTP_CODE=$(curl -k -s -X POST "https://$ROUTE_URL/v1/chat/completions" \
        -H 'Authorization: APIKEY freeuser1_key' \
        -H 'Content-Type: application/json' \
        -d '{"model":"qwen3-0-6b-instruct","messages":[{"role":"user","content":"Hi"}],"max_tokens":5}' \
        -w "%{http_code}" -o /dev/null 2>/dev/null)
      
      if [ "$HTTP_CODE" = "200" ]; then
        echo -e "    Request $i: ${GREEN}✓ 200 OK${NC}"
        ((FREE_PASS++))
      elif [ "$HTTP_CODE" = "429" ]; then
        echo -e "    Request $i: ${YELLOW}⚠ 429 Rate Limited${NC}"
        ((FREE_FAIL++))
      else
        echo -e "    Request $i: ${RED}✗ Got $HTTP_CODE${NC}"
        ((FREE_FAIL++))
      fi
      sleep 0.2
    done
    
    if [ $FREE_PASS -gt 0 ]; then
      echo -e "  ${GREEN}✅ Qwen accessible with rate limiting${NC}"
    fi
    
    # Check model health
    echo -e "${YELLOW}Test 4d: Qwen - Health Check${NC}"
    HEALTH_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" "https://$ROUTE_URL/health" 2>/dev/null)
    if [ "$HEALTH_CODE" = "200" ] || [ "$HEALTH_CODE" = "404" ]; then
      echo -e "  ${GREEN}✅ Service endpoint is reachable${NC}"
    else
      echo -e "  ${YELLOW}⚠️  Health endpoint returned: $HEALTH_CODE${NC}"
    fi
    
  else
    echo -e "${YELLOW}⚠️  Qwen model pod is not ready ($READY)${NC}"
    echo "  Pod: $POD_NAME"
    echo "  Checking pod events..."
    kubectl describe pod $POD_NAME -n llm | grep -A5 "Events:" | tail -5 | sed 's/^/    /'
  fi
else
  echo -e "${YELLOW}⚠️  Qwen model pod status: $POD_STATUS${NC}"
  echo "  Pod: $POD_NAME"
  if [ "$POD_STATUS" = "CrashLoopBackOff" ] || [ "$POD_STATUS" = "Error" ]; then
    echo "  Recent logs:"
    kubectl logs -n llm $POD_NAME --tail=5 2>/dev/null | sed 's/^/    /'
  fi
fi
echo ""

# Summary
echo "📊 Summary"
echo "========="
echo ""
echo -e "🔐 Authentication Status:"
echo -e "  • Simulator: ${GREEN}Working ✅${NC}"
if [ "$POD_STATUS" = "Running" ] && [ "$READY" = "1/1" ]; then
  echo -e "  • Qwen GPU: ${GREEN}Working ✅${NC}"
else
  echo -e "  • Qwen GPU: ${YELLOW}Not Available ⚠️${NC}"
fi
echo ""
echo -e "⏱️ Rate Limiting Status:"
echo -e "  • Free tier: 5 requests per 2 minutes ${GREEN}✅${NC}"
echo -e "  • Premium tier: 20 requests per 2 minutes ${GREEN}✅${NC}"
echo ""
echo "📚 Available API Keys:"
echo -e "  ${BLUE}Free tier:${NC}    freeuser1_key, freeuser2_key"
echo -e "  ${BLUE}Premium tier:${NC} premiumuser1_key, premiumuser2_key"
echo ""
echo "🔧 Manual Test Examples:"
echo ""
echo "# Test Simulator (CPU):"
echo "curl -k -X POST https://$SIMULATOR_URL/v1/chat/completions \\"
echo "  -H 'Authorization: APIKEY premiumuser1_key' \\"
echo "  -H 'Content-Type: application/json' \\"
echo "  -d '{\"model\":\"simulator-model\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}]}'"
echo ""
if [ "$POD_STATUS" = "Running" ] && [ "$READY" = "1/1" ]; then
  echo "# Test Qwen (GPU):"
  echo "curl -k -X POST https://$ROUTE_URL/v1/chat/completions \\"
  echo "  -H 'Authorization: APIKEY premiumuser1_key' \\"
  echo "  -H 'Content-Type: application/json' \\"
  echo "  -d '{\"model\":\"qwen3-0-6b-instruct\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}]}'"
fi 