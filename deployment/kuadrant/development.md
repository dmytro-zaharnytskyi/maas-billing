# MaaS Development Log

This document consolidates all development activities, issues encountered, and resolutions from our recent work on the Models-as-a-Service (MaaS) project. It incorporates content from previous scattered .md files and scripts, focusing on key enhancements, bug fixes, and architectural decisions. Original scattered files have been removed to clean up the repository.

## Project Overview
- **Goal**: Enhance MaaS deployment with GPU support for Qwen model, implement token-based rate limiting, improve installation script robustness, and add testing utilities.
- **Base Setup**: Using Kuadrant for auth/rate-limiting, Istio for gateway, KServe for model serving.
- **Platforms**: Supports vanilla Kubernetes and OpenShift (with RHOAI).

## Key Enhancements Implemented

### 1. GPU-Optimized Qwen Model Deployment
- **File**: `../model_serving/qwen3-0.6b-vllm-gpu.yaml`
- **Changes**:
  - Added GPU resource requests/limits (1 NVIDIA GPU, 16Gi memory).
  - Optimized env vars for GPU utilization (85%), max sequence length (8192), batch size (64).
  - Enabled token counting in responses via `RETURN_TOKEN_COUNTS=true`.
  - Added liveness/readiness probes and volume mounts for caching.
  - Included HTTPRoute for domain-based routing.
- **Rationale**: Improves performance for GPU-based inference, enables token tracking for rate limiting.

### 2. Token-Based Rate Limiting
- **File**: `08-token-rate-limit-envoyfilter.yaml`
- **Changes**:
  - Implemented EnvoyFilter with Lua script for request/response processing.
  - Token limits: Free (200/min), Premium (1000/min), Enterprise (5000/min).
  - Counts tokens from response `usage` field (fallback to length estimation).
  - Adds response headers: `x-tokens-used`, `x-tokens-limit`, `x-tokens-remaining`.
  - ConfigMap for configurable limits and model multipliers.
- **Alternative**: WASM-based filter for better performance.
- **Rationale**: Provides granular control over LLM usage, better than request-based limiting.

### 3. Installation Script Improvements
- **File**: `install.sh` (modified)
- **Changes**:
  - New flags: `--token-rate-limit` (enables token-based instead of request-based), `--check-gpu` (verifies GPU nodes before deployment).
  - GPU check logic using `kubectl get nodes` and jq.
  - Conditional deployment of optimized Qwen YAML if available.
  - Enhanced waiting and error handling for model readiness.
  - Conditional application of rate limiting policies.
  - Updated usage examples and output messages.
- **Rationale**: Makes deployment more robust, especially for GPU models and custom rate limiting.

### 4. Testing Utilities
- **Files**:
  - `test-maas-auth.sh` (existing, kept): Tests API key auth and basic rate limiting.
  - `test-token-limits.sh` (new): Validates token-based rate limiting with tiered tests, header checks, and limit enforcement.
- **Changes to test-token-limits.sh**:
  - Platform detection (Kubernetes/OpenShift).
  - Request function with token header extraction and display.
  - Tests for short/long messages, rapid requests, and header validation.
- **Rationale**: Provides automated verification for new features.

### 5. Cleanup Script
- **File**: `cleanup.sh` (existing, enhanced if needed, kept)
- **Rationale**: Essential for resetting the environment; updated to clean new resources like EnvoyFilters.

## Issues Encountered and Resolutions

### Issue 1: Istio Installation Conflict with Existing CRDs
- **Description**: During `./install.sh --qwen3 --check-gpu --token-rate-limit`, encountered:
  ```
  Error: Unable to continue with install: CustomResourceDefinition "wasmplugins.extensions.istio.io" in namespace "" exists and cannot be imported into the current release: invalid ownership metadata; label validation error: missing key "app.kubernetes.io/managed-by": must be set to "Helm"; annotation validation error: missing key "meta.helm.sh/release-name": must be set to "istio-base"; annotation validation error: missing key "meta.helm.sh/release-namespace": must be set to "istio-system"
  ```
- **Cause**: Existing Istio CRDs from previous installations conflicting with Helm ownership.
- **Resolution**:
  - Uninstall previous Istio: `helm uninstall istio-base -n istio-system; helm uninstall istiod -n istio-system`
  - Delete conflicting CRDs: `kubectl delete crd wasmplugins.extensions.istio.io` (and others if needed).
  - Re-run install.sh to reinstall cleanly.
- **Prevention**: Added checks in install.sh to detect existing installations and prompt for cleanup.

### Issue 2: GPU Node Detection and Deployment Failures
- **Description**: Qwen model fails to schedule without GPU nodes, leading to pending pods.
- **Cause**: No nodes with `nvidia.com/gpu` resource.
- **Resolution**: Implemented `--check-gpu` flag with node query to fail early if no GPUs detected.
- **Additional Fix**: Added nodeSelector and tolerations in YAML for GPU affinity.

### Issue 3: Token Counting Not Working Initially
- **Description**: Response headers missing token info; limits not enforced.
- **Cause**: vLLM not configured to return usage stats; EnvoyFilter not processing responses.
- **Resolution**:
  - Added `RETURN_TOKEN_COUNTS=true` and `--return-tokens-as-token-ids` in vLLM args.
  - Enhanced Lua script to parse response body and update shared data.
  - Added fallback estimation for models without usage field.

### Issue 4: OpenShift-Specific Issues
- **Description**: Gateway API not fully functional in ServiceMesh 2.6; rate limiting not supported with native Istio.
- **Cause**: Compatibility issues between Kuadrant and RHOAI ServiceMesh.
- **Resolution**:
  - Fallback to native Istio for auth on OpenShift.
  - Conditional logic in install.sh to use EnvoyFilter for auth/rate-limiting.
  - Noted in docs: Rate limiting limited on OpenShift without Gateway API.

### Issue 5: Model Loading Timeouts
- **Description**: Initial model download takes >900s, causing wait timeouts.
- **Cause**: HuggingFace model download on first deploy.
- **Resolution**: Increased wait timeout to 900s with better logging; added progress messages in install.sh.

### Issue 6: Redundant Files and Documentation
- **Description**: Multiple scattered .md files and scripts cluttering repo.
- **Cause**: Iterative development creating temporary docs.
- **Resolution**: Consolidated into this `development.md`; deleted redundant files (see Cleanup section).

### Issue 7: OpenShift Route Conflicts and KServe Headless Service Routing
- **Description**: After deploying models on OpenShift with Gateway API, routes returned 503 errors even though all components were running:
  - Gateway was programmed and working internally
  - InferenceService pods were healthy
  - Authentication and rate limiting policies were applied
  - But external access via OpenShift routes failed with "Application is not available"
- **Root Causes**: 
  1. **Route conflicts**: The install script created routes in multiple namespaces (llm and istio-system) with the same hostname, causing OpenShift to reject the route with `HostAlreadyClaimed` error
  2. **Headless service issue**: KServe creates headless services (ClusterIP: None) for InferenceServices, which don't work well with Gateway API routing
  3. **Port targeting**: Routes needed to target the port by name ("http") rather than number for Gateway services
- **Symptoms**:
  - `oc get route` showed `HostAlreadyClaimed` status
  - Direct testing via port-forward or from within cluster worked fine
  - External routes returned 503 or "Application is not available" errors
- **Resolution**:
  1. **Fixed route conflicts**: 
     - Routes should only be created in istio-system namespace (where the Gateway lives)
     - Added cleanup of conflicting routes before creating new ones
     - Removed duplicate route creation from 02a-openshift-routes.yaml application
  2. **Fixed headless service issue**:
     - Created a new function `create_gateway_service()` that creates proper ClusterIP services for each InferenceService
     - These services map port 80 to the pod's port 8080
     - Updated HTTPRoutes to use these new services instead of the headless ones
  3. **Fixed port configuration**:
     - Routes now use `targetPort: http` (port name) instead of port numbers
     - Added proper weight and wildcardPolicy configuration
- **Testing**: After fixes, external routes work correctly:
  ```bash
  curl -k -X POST https://simulator-route-llm.apps.$BASE_DOMAIN/v1/chat/completions \
    -H 'Authorization: APIKEY freeuser1_key' \
    -H 'Content-Type: application/json' \
    -d '{"model":"simulator-model","messages":[{"role":"user","content":"test"}]}'
  ```
- **Prevention**: 
  - Script now automatically creates proper services for KServe models
  - Cleans up conflicting routes before creating new ones
  - Validates route admission status after creation

### Issue 8: Kuadrant Pods Stuck in Init State on OpenShift
- **Description**: Kuadrant operator pods were stuck in `Init:0/1` state with istio-validation init container never completing
- **Cause**: 
  - ServiceMeshMemberRoll initially didn't include required namespaces
  - Kuadrant pods were trying to inject Istio sidecars but `istio-cni` NetworkAttachmentDefinition was missing
  - Kuadrant operators don't actually need Istio sidecars
- **Resolution**:
  - Disabled sidecar injection for kuadrant-system namespace: `kubectl label namespace kuadrant-system istio-injection=disabled`
  - Removed kuadrant-system from ServiceMeshMemberRoll (only llm, llm-observability, and knative-serving needed)
  - Added automatic labeling in install script
- **Prevention**: Script now automatically disables sidecar injection for kuadrant-system namespace

### Issue 9: GPU Operator Fails on Managed OpenShift (ROSA)
- **Description**: GPU operator fails to initialize on ROSA clusters with monitoring label error
- **Symptoms**:
  - GPU operator logs show: `Unable to label namespace nvidia-gpu-operator for the GPU Operator monitoring`
  - No GPU daemonsets created despite having GPU nodes
  - ClusterPolicy validation error: `state: Unsupported value: ""`
- **Cause**: Managed OpenShift restricts namespace label modifications for monitoring
- **Resolution**:
  1. Disable monitoring in ClusterPolicy: Set `dcgmExporter.serviceMonitor.enabled: false`
  2. Add monitoring disable label: `kubectl label namespace nvidia-gpu-operator openshift.io/cluster-monitoring=false`
  3. Restart GPU operator pod
- **Result**: GPU operator successfully creates all daemonsets and GPU resources become available
- **Prevention**: Script now includes better GPU detection and error reporting

### Issue 10: KServe Doesn't Support HuggingFace StorageUri
- **Description**: InferenceService fails to deploy with `hf://` protocol for model storage
- **Error**: `StorageURI not supported: storageUri, must be one of: [gs://, s3://, pvc://, file://, https://, http://]`
- **Cause**: KServe doesn't support the `hf://` protocol for downloading models from HuggingFace
- **Resolution**:
  - Removed `storageUri` from InferenceService spec
  - Configured container directly with vLLM image and args
  - Pass model name directly to vLLM: `--model=Qwen/Qwen2.5-0.5B-Instruct`
  - vLLM downloads the model directly from HuggingFace at runtime
- **Updated YAML Structure**:
  ```yaml
  spec:
    predictor:
      containers:
      - name: kserve-container
        image: vllm/vllm-openai:latest
        args:
          - --model=Qwen/Qwen2.5-0.5B-Instruct
  ```
- **Prevention**: Updated qwen3-0.6b-vllm-gpu.yaml to use direct container specification

### Issue 11: GPU Detection Reports No GPUs When GPU Operator Is Initializing
- **Description**: Script reports "No GPU nodes found" even when GPU nodes exist but operator is still initializing
- **Cause**: Script only checked for `nvidia.com/gpu` resource capacity, which isn't available until driver installation completes
- **Resolution**:
  - Enhanced GPU detection to check both resources and labels
  - Added GPU operator status checking
  - Provide helpful diagnostics when GPUs are initializing
  - Better error messages explaining the initialization process
- **GPU Initialization Timeline**:
  1. Node labeled with `nvidia.com/gpu.present=true` (immediate)
  2. GPU operator creates daemonsets (1-2 minutes)
  3. Driver compilation and installation (5-10 minutes on first install)
  4. Device plugin advertises GPU resources (after driver ready)
- **Prevention**: Script now provides detailed status during GPU initialization

### Issue 12: Triton Compilation Failure on Tesla T4 GPUs
- **Description**: vLLM crashes with `RuntimeError: PassManager::run failed` during Triton kernel compilation
- **Error**: Occurs in `context_attention_fwd` function when processing the first request
- **GPU Affected**: Tesla T4 (Turing architecture, compute capability 7.5)
- **Root Cause**: Incompatibility between latest vLLM/Triton and T4 GPU architecture
- **Resolution**:
  1. Use stable vLLM version: `vllm/vllm-openai:v0.6.2` instead of `latest`
  2. Disable Triton attention kernels: Set `VLLM_USE_TRITON_ATTENTION=0`
  3. Use xFormers backend: Set `VLLM_ATTENTION_BACKEND=XFORMERS`
  4. Disable Triton Flash Attention: Set `VLLM_USE_TRITON_FLASH_ATTN=0`
  5. Enable eager mode: Add `--enforce-eager` to disable CUDA graphs
  6. Remove prefix caching: Don't use `--enable-prefix-caching`
  7. Reduce limits for stability:
     - `--max-model-len=4096` (from 8192)
     - `--max-num-seqs=32` (from 64)
  8. Use explicit dtype: `--dtype=float16`
- **Additional Optimizations**:
  - Set `NCCL_P2P_DISABLE=1` for stability
  - Increase probe delays for model loading time
- **Result**: Model runs successfully without Triton compilation errors
- **Prevention**: Updated qwen3-0.6b-vllm-gpu.yaml with all T4-specific workarounds

## Architectural Decisions
- **Rate Limiting**: Chose EnvoyFilter over Kuadrant RateLimitPolicy for token-based flexibility (Kuadrant doesn't support dynamic token counting natively).
- **Token Storage**: Used Envoy's in-memory shared data for simplicity; noted Redis for future scalability.
- **GPU Optimization**: Balanced memory utilization and batch size for common NVIDIA GPUs (e.g., A100/T4).
- **Testing**: Separate scripts for auth and token limits to isolate concerns.

## Cleanup Performed
- **Deleted Redundant .md Files**:
  - AUTHENTICATION-WITH-NATIVE-ISTIO.md
  - GATEWAY-API-SOLUTION.md
  - INSTALLATION-SUMMARY.md
  - ISTIO-GATEWAY-SOLUTION.md
  - MAAS-ARCHITECTURE-V2.md
  - MAAS-AUTHENTICATION-SOLUTION.md
  - TOKEN-BASED-RATE-LIMITING.md (content merged here)
- **Deleted Redundant Scripts/YAMLs**:
  - update-install-gateway-api.sh (unused)
  - rhoai-setup.yaml (specific to one setup)
  - Any temporary files in temp/
- **Kept Essentials**:
  - install.sh
  - cleanup.sh
  - test-maas-auth.sh (as verification script)
  - test-token-limits.sh (new verification for tokens)
  - New feature YAMLs: qwen3-0.6b-vllm-gpu.yaml, 08-token-rate-limit-envoyfilter.yaml

## Next Steps
- Test full deployment after cluster reinstall.
- Implement Redis for distributed token counting.
- Add billing integration based on token usage.
- Monitor performance and adjust limits.

## Installation Script Comprehensive Guide

### Overview
The `install.sh` script is the central deployment tool for the MaaS system, providing comprehensive support for both vanilla Kubernetes and OpenShift environments with automatic detection and platform-specific configurations.

### Key Features
- **Platform Auto-Detection**: Automatically detects OpenShift vs vanilla Kubernetes
- **GPU Support**: `--check-gpu` flag for GPU node verification
- **Token-Based Rate Limiting**: `--token-rate-limit` flag for advanced rate limiting
- **Model Deployment**: Flags for deploying vLLM simulator (`--simulator`) and Qwen3 (`--qwen3`)
- **Gateway API Support**: Automatic detection and configuration
- **Comprehensive Error Handling**: Detailed logging and rollback capabilities

### Command-Line Options
```bash
./install.sh [OPTIONS]

Options:
  --simulator          Deploy vLLM simulator model
  --qwen3              Deploy Qwen3 GPU model
  --check-gpu          Check for GPU nodes before deployment
  --token-rate-limit   Enable token-based rate limiting (instead of request-based)
  --openshift-routes   Create OpenShift routes (for OpenShift only)
  --skip-rhoai         Skip RHOAI setup (for OpenShift)
  --help               Show help message
```

### Token-Based Rate Limiting Configuration

#### Implementation Details
- **EnvoyFilter**: Uses Lua script to count tokens from model responses
- **Tier Limits**: 
  - Free: 200 tokens/minute
  - Premium: 1,000 tokens/minute
  - Enterprise: 5,000 tokens/minute
- **Gateway Restart**: Automatically restarts gateway deployments after applying EnvoyFilter
- **Platform Support**: Works on both Kubernetes and OpenShift

#### How Token Counting Works
1. **Request Interception**: EnvoyFilter intercepts all requests to `/v1/chat/completions`
2. **API Key Extraction**: Lua script extracts API key from `Authorization: APIKEY <key>` header
3. **Tier Mapping**: Maps API key to user tier (free/premium/enterprise)
4. **Response Processing**: Counts tokens from response `usage.total_tokens` field
5. **Rate Limit Enforcement**: Blocks requests if user exceeds tier limit
6. **Header Injection**: Adds rate limit info to response headers

#### Response Headers
- `x-ratelimit-limit-tokens`: Total token limit per minute
- `x-ratelimit-consumed-tokens`: Tokens consumed in current request
- `x-ratelimit-remaining-tokens`: Tokens remaining in current window

## Comprehensive Testing Guide

### Test Scripts Overview

We've consolidated all testing into two focused scripts for simplicity and maintainability:

#### 1. test-models-comprehensive.sh - Complete Test Suite ⭐
This is the main test script that covers everything: infrastructure verification, authentication, rate limiting, and model testing.

**Features**:
- Infrastructure verification (namespaces, deployments, API keys)
- Token rate limiting component checks (EnvoyFilter, ConfigMap, Lua filter)
- Authentication testing (with/without API keys)
- Token-based rate limiting validation for all tiers
- Model functionality tests for both Simulator and Qwen
- Cross-tier isolation verification

**The 10 Core Tests**:
| Test # | Model     | Scenario                              | Expected Result          |
|--------|-----------|---------------------------------------|--------------------------|
| 1      | Simulator | WITH Authentication                   | ✅ Success (200)        |
| 2      | Simulator | WITHOUT Authentication                | ❌ Fail (401)           |
| 3      | Qwen      | WITH Authentication                   | ✅ Success (200)        |
| 4      | Qwen      | WITHOUT Authentication                | ❌ Fail (401)           |
| 5      | Simulator | FREE Tier Rate Limiting (200 tokens) | 🛑 Limited at ~180      |
| 6      | Simulator | PREMIUM Tier (1000 tokens)           | ✅ Pass 10 requests     |
| 7      | Simulator | ENTERPRISE Tier (5000 tokens)        | ✅ Pass 20 requests     |
| 8      | Qwen      | FREE Tier Rate Limiting (200 tokens) | 🛑 Limited at ~180      |
| 9      | Qwen      | PREMIUM Tier (1000 tokens)           | ✅ Pass 10 requests     |
| 10     | Qwen      | ENTERPRISE Tier (5000 tokens)        | ✅ Pass 15 requests     |

**Usage**:
```bash
# Full test with infrastructure verification
./test-models-comprehensive.sh

# Skip infrastructure checks for faster testing
./test-models-comprehensive.sh --skip-infra

# Skip 60-second wait between tests
./test-models-comprehensive.sh --no-wait

# Verbose output for debugging
./test-models-comprehensive.sh --verbose
```

#### 2. verify-install.sh - Quick Installation Check
A lightweight script for rapid installation verification.

**Checks**:
- Core namespaces (llm, istio-system, kuadrant-system)
- Essential deployments (Authorino, Gateway)
- Model deployments (Simulator, Qwen)
- API key secrets (free, premium, enterprise)
- Token rate limiting configuration

**Usage**:
```bash
# Quick verification (takes seconds)
./verify-install.sh
```

### Removed Scripts
The following scripts were removed as their functionality is now fully covered by the comprehensive test:
- `test-maas-complete.sh` - Merged into test-models-comprehensive.sh
- `test-token-limits.sh` - Token testing integrated into main suite
- `verify-token-install.sh` - Replaced by simpler verify-install.sh
- `test-qwen-auth.sh` - Qwen tests integrated into main suite

### API Keys Configuration

| Tier       | API Keys                              | Token Limit/min | Request Limit/2min |
|------------|---------------------------------------|-----------------|-------------------|
| Free       | freeuser1_key, freeuser2_key         | 200            | 5                 |
| Premium    | premiumuser1_key, premiumuser2_key   | 1,000          | 20                |
| Enterprise | enterpriseuser1_key                   | 5,000          | 100               |

### Test Script Improvements

#### Fixed Issues
1. **Test Counting Bug**: Infrastructure checks were incorrectly incrementing test counters
2. **Debug Output Interference**: Fixed by redirecting debug messages to stderr
3. **Arithmetic Operations**: Fixed bash operations for `set -e` compatibility
4. **Token Counting Regex**: Updated to handle JSON with spaces
5. **Rate Limit Exhaustion**: Added automatic detection and wait for reset
6. **Qwen Pod Detection**: Fixed to handle multiple pods correctly

## Model Configuration Details

### Simulator Model
- **Fixed Token Count**: Always returns 30 tokens per request
- **Purpose**: Testing and validation
- **No GPU Required**: Runs on CPU nodes

### Qwen3 Model (GPU-Optimized)
- **Actual Token Counting**: Returns real token usage based on input/output
- **GPU Required**: Needs NVIDIA GPU with 16Gi+ memory
- **Optimizations**:
  - Token counting enabled (`RETURN_TOKEN_COUNTS=true`)
  - GPU utilization set to 85%
  - Max sequence length: 4096 (reduced for T4 stability)
  - Batch size: 32 (optimized for T4)
  - Uses xFormers attention backend for T4 compatibility

### T4 GPU Specific Configuration
Due to Triton compilation issues on Tesla T4 GPUs, the following workarounds are applied:
- Use stable vLLM version (v0.6.2)
- Disable Triton kernels
- Use xFormers backend
- Enable eager mode
- Reduce memory limits

## Troubleshooting Guide

### Common Issues and Solutions

#### Rate Limits Exhausted
**Problem**: Tests fail immediately with 429 status
**Solution**: Wait 60 seconds or use `--skip-wait` flag
```bash
# Check current status
curl -k -X POST https://simulator-route-llm.apps.$DOMAIN/v1/chat/completions \
  -H "Authorization: APIKEY premiumuser1_key" \
  -H "Content-Type: application/json" \
  -d '{"model":"simulator-model","messages":[{"role":"user","content":"Test"}]}' \
  -w "\nHTTP: %{http_code}\n"
```

#### Enterprise Tier Not Working
**Problem**: Enterprise API key returns 401
**Solution**: Ensure secret exists and restart Authorino
```bash
kubectl get secret enterpriseuser1-apikey -n llm
kubectl rollout restart deployment/authorino -n kuadrant-system
```

#### Token Headers Not Visible
**Problem**: Response doesn't include token rate limit headers
**Solution**: Restart gateway to load EnvoyFilter
```bash
kubectl rollout restart deployment/inference-gateway-istio -n istio-system
```

#### Qwen Pod Status Unknown
**Problem**: Multiple Qwen pods with different statuses
**Solution**: Script now correctly identifies Running pods with 1/1 ready status

## Quick Reference Commands

### Check System Status
```bash
# View all API keys
kubectl get secrets -n llm | grep apikey

# Check token rate limits
kubectl get configmap token-rate-limits -n istio-system -o yaml

# View EnvoyFilter
kubectl get envoyfilter token-rate-limit-filter -n istio-system -o yaml

# Check model pods
kubectl get pods -n llm
```

### Test Specific Tiers
```bash
# Test Free Tier
curl -k -X POST https://simulator-route-llm.apps.$DOMAIN/v1/chat/completions \
  -H "Authorization: APIKEY freeuser1_key" \
  -H "Content-Type: application/json" \
  -d '{"model":"simulator-model","messages":[{"role":"user","content":"Test"}]}'

# Test Premium Tier
curl -k -X POST https://simulator-route-llm.apps.$DOMAIN/v1/chat/completions \
  -H "Authorization: APIKEY premiumuser1_key" \
  -H "Content-Type: application/json" \
  -d '{"model":"simulator-model","messages":[{"role":"user","content":"Test"}]}'

# Test Enterprise Tier
curl -k -X POST https://simulator-route-llm.apps.$DOMAIN/v1/chat/completions \
  -H "Authorization: APIKEY enterpriseuser1_key" \
  -H "Content-Type: application/json" \
  -d '{"model":"simulator-model","messages":[{"role":"user","content":"Test"}]}'
```

## Future Enhancements
- Redis integration for distributed token counting
- Dynamic tier configuration via ConfigMap
- Prometheus metrics for token usage monitoring
- Billing system integration based on token consumption
- Support for multiple models with different token multipliers
- WebSocket support for streaming responses with token counting
