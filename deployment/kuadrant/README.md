# Models as a Service with Kuadrant

This repository demonstrates how to deploy a Models-as-a-Service platform using Kuadrant instead of 3scale for API management. Kuadrant provides cloud-native API gateway capabilities using Istio and the Gateway API.

## Architecture Overview

**Gateway:** API Gateway + Istio/Envoy with Kuadrant policies integrated
**Models:** KServe InferenceServices (Granite, Mistral, Nomic, Qwen, Simulator)
**Authentication:** API Keys (simple) or Keycloak (Red Hat SSO)
**Rate Limiting:** Token-based (via EnvoyFilter) or Request-based (via Kuadrant RateLimitPolicy)
**Observability:** Prometheus + Kuadrant Scrapes (for Kuadrant chargeback WIP see [Question on mapping authorized_calls metrics to a user](https://github.com/Kuadrant/limitador/issues/434))

### Key Components

- **Istio Service Mesh**: Provides the data plane for traffic management
- **Kuadrant Operator**: Manages API policies and traffic control
- **Limitador**: Rate limiting service with Redis backend (for request-based limits)
- **Authorino**: Authentication and authorization service
- **Gateway API**: Standard Kubernetes API for ingress traffic
- **KServe**: Model serving platform that creates model pods
- **EnvoyFilter**: Custom Lua script for token-based rate limiting

## How Model Pods Get Created

**The flow that creates actual running model pods:**

```bash
1. Apply an InferenceService YAML
   ↓
2. KServe Controller sees the InferenceService
   ↓
3. KServe creates a Deployment for your model
   ↓
4. Deployment creates Pod(s) with:
   - GPU allocation
   - Model download from HuggingFace
   - vLLM or other serving runtime
   ↓
5. Pod starts serving model on port 8080
   ↓
6. Kube Service exposes the pod
   ↓
7. HTTPRoute creates domain-based routing (e.g., qwen3.maas.local, simulator.maas.local)
   ↓
8. Kuadrant policies protect each domain route
```

## Prerequisites

- Kubernetes cluster with admin access
- kubectl configured
- For KIND clusters: `kind create cluster --name llm-maas`
- For minikube with GPU: `minikube start --driver docker --container-runtime docker --gpus all --memory no-limit --cpus no-limit`
- Kustomize

## 🚀 Quick Start (Automated Installer)

### Installation Options

The `install.sh` script provides comprehensive deployment with these key flags:

```bash
# Core Model Deployment Flags
--simulator           # Deploy vLLM simulator (no GPU required)
--qwen3              # Deploy Qwen3-0.6B model (GPU required)
--install-all-models # Deploy both simulator and Qwen3
--deploy-kind        # Create a KIND cluster and deploy simulator

# Feature Flags
--token-rate-limit   # Enable token-based rate limiting (recommended)
--check-gpu          # Verify GPU availability before deployment
--skip-metrics       # Skip Prometheus observability deployment

# Platform Flags
--ocp                # Force OpenShift mode
--no-ocp             # Force vanilla Kubernetes mode
```

### Quick Examples

**For KIND clusters (no GPU):**
```bash
cd deployment/kuadrant
./install.sh --simulator --token-rate-limit
```

**For GPU clusters with token-based rate limiting:**
```bash
cd deployment/kuadrant  
./install.sh --qwen3 --check-gpu --token-rate-limit
```

**Deploy everything with enterprise features:**
```bash
./install.sh --install-all-models --token-rate-limit
```

The installer will:
- ✅ Auto-detect platform (OpenShift vs Kubernetes)
- ✅ Deploy Istio + Gateway API + KServe + Kuadrant
- ✅ Configure gateway-level authentication
- ✅ Set up token-based or request-based rate limiting
- ✅ Deploy your chosen model(s)
- ✅ Create API keys for all tiers (Free/Premium/Enterprise)
- ✅ Show test commands and verify installation

## 🔐 How Authentication Works

### Architecture

The authentication system uses **Kuadrant's Authorino** service to validate API keys at the gateway level before requests reach the models.

```
Client Request
     ↓
[Authorization: APIKEY freeuser1_key]
     ↓
Istio Gateway (ingress)
     ↓
Authorino (validates API key)
     ↓
[If valid] → Forward to Model
[If invalid] → Return 401
```

### Components Involved

1. **API Key Secrets** (`05-api-key-secrets.yaml`):
   - Kubernetes secrets in the `llm` namespace
   - Contains API keys for each tier (free/premium/enterprise)
   - Labeled with `kuadrant.io/auth-secret: "true"`

2. **Authorino Deployment** (in `kuadrant-system` namespace):
   - Validates incoming API keys
   - Checks against stored secrets
   - Extracts user metadata (tier, user ID)

3. **AuthPolicy** (`06-auth-policies-apikey.yaml`):
   - Defines authentication rules for the gateway
   - Maps API keys to user identities
   - Configures response headers with user info

### API Key Tiers

| Tier | API Keys | Purpose |
|------|----------|---------|
| **Free** | `freeuser1_key`, `freeuser2_key` | Basic access, lowest limits |
| **Premium** | `premiumuser1_key`, `premiumuser2_key` | Enhanced access, higher limits |
| **Enterprise** | `enterpriseuser1_key` | Highest access, maximum limits |

## 📊 How Token-Based Rate Limiting Works

### Overview

Token-based rate limiting is more sophisticated than request counting—it tracks actual model usage based on input/output tokens, providing fair usage control for LLM services.

### Architecture

```
Request with API Key
     ↓
EnvoyFilter (Lua Script)
     ↓
1. Extract API key
2. Map to tier (free/premium/enterprise)
3. Check current usage in shared memory
4. [If under limit] → Forward request
   [If over limit] → Return 429
     ↓
Model processes request
     ↓
Response with token usage
     ↓
EnvoyFilter (Lua Script)
     ↓
1. Extract token count from response
2. Update usage in shared memory
3. Add rate limit headers
     ↓
Response to client
```

### Components and Services

1. **EnvoyFilter** (`08-token-rate-limit-envoyfilter.yaml`):
   - Deployed in `istio-system` namespace
   - Injects Lua script into gateway pods
   - Intercepts all `/v1/chat/completions` requests

2. **Lua Script Processing**:
   ```lua
   -- Request phase: Check if user has tokens available
   local token_limits = {
     free = 200,        -- 200 tokens/minute
     premium = 1000,    -- 1000 tokens/minute
     enterprise = 5000  -- 5000 tokens/minute
   }
   
   -- Response phase: Count and track token usage
   -- Parse: "usage":{"total_tokens":30}
   -- Store: tokens:API_KEY:YYYYMMDDHHMM → current_usage
   ```

3. **Envoy Shared Data Store**:
   - In-memory storage within each gateway pod
   - Tracks usage with keys like `tokens:freeuser1_key:202409021545`
   - 60-second TTL for automatic reset

4. **Model Token Reporting**:
   - **Simulator**: Fixed 30 tokens per request
   - **Qwen**: Actual token counts via `RETURN_TOKEN_COUNTS=true`
   - **Fallback**: Estimates ~4 characters per token

### Rate Limit Tiers

| Tier | Tokens/Minute | Tokens/Hour* | Tokens/Day* | Typical Requests |
|------|--------------|-------------|-------------|-----------------|
| **Free** | 200 | 5,000 | 50,000 | ~6-7 requests |
| **Premium** | 1,000 | 30,000 | 500,000 | ~30-35 requests |
| **Enterprise** | 5,000 | 150,000 | 2,000,000 | ~150-170 requests |

*Hour/day limits defined but not currently enforced

### Response Headers

Every response includes rate limit information:
```
x-ratelimit-limit-tokens: 1000       # User's tier limit
x-ratelimit-consumed-tokens: 45      # Tokens used in this request
x-ratelimit-remaining-tokens: 955    # Tokens left in current minute
```

### How Token Counting Works

1. **Request Interception**: EnvoyFilter intercepts all model requests
2. **API Key Extraction**: Lua extracts key from `Authorization: APIKEY xxx`
3. **Tier Mapping**: Maps API key to user tier
4. **Usage Check**: Verifies tokens available in current minute window
5. **Model Processing**: Request forwarded to model if under limit
6. **Token Extraction**: Parses `usage.total_tokens` from response
7. **Usage Update**: Updates shared memory with new total
8. **Header Injection**: Adds rate limit info to response

### Deployment

When you run `./install.sh --token-rate-limit`:
1. Applies EnvoyFilter to `istio-system` namespace
2. **Restarts gateway deployments** to inject Lua filter
3. ConfigMap with limits created for future customization
4. Filter becomes active immediately

### Token-Based vs Request-Based Comparison

| Aspect | Token-Based | Request-Based |
|--------|------------|---------------|
| **Fairness** | ✅ Accounts for actual usage | ❌ All requests treated equally |
| **Granularity** | ✅ Precise token counting | ❌ Simple request counting |
| **Complexity** | Higher (Lua scripting) | Lower (native Kuadrant) |
| **Performance** | Fast (in-memory) | Fast (Redis-backed) |
| **Distribution** | Per-pod tracking | Centralized in Limitador |
| **Use Case** | LLM services | Traditional APIs |

### Current Limitations

- **Not Distributed**: Each gateway pod tracks usage independently (multiple pods = multiple rate limit buckets)
- **Memory-Based**: Usage data lost on pod restart
- **Fixed Tiers**: Adding new tiers requires updating the EnvoyFilter
- **No Persistence**: No historical usage tracking for billing/analytics

## 🧪 Testing the Installation

### Quick Verification

After installation, verify the system:

```bash
# Quick installation check
./verify-install.sh

# Comprehensive testing (all models, auth, rate limits)
./test-models-comprehensive.sh
```

### Manual Testing

**Test Authentication (should fail without API key):**
```bash
curl -X POST https://simulator-route-llm.apps.$DOMAIN/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"simulator-model","messages":[{"role":"user","content":"Test"}]}'
# Expected: 401 Unauthorized
```

**Test with API Key (Free Tier):**
```bash
curl -X POST https://simulator-route-llm.apps.$DOMAIN/v1/chat/completions \
  -H 'Authorization: APIKEY freeuser1_key' \
  -H 'Content-Type: application/json' \
  -d '{"model":"simulator-model","messages":[{"role":"user","content":"Hello"}]}'
# Expected: 200 OK with response
```

**Test Token Rate Limiting:**
```bash
# Free tier: 200 tokens/minute (~6-7 requests)
for i in {1..10}; do
  echo "Request $i:"
  curl -s -o /dev/null -w "Status: %{http_code}\n" \
    -X POST https://simulator-route-llm.apps.$DOMAIN/v1/chat/completions \
    -H 'Authorization: APIKEY freeuser1_key' \
    -H 'Content-Type: application/json' \
    -d '{"model":"simulator-model","messages":[{"role":"user","content":"Test"}]}'
done
# Expected: First ~6 requests succeed (200), then 429 (rate limited)
```

**Check Rate Limit Headers:**
```bash
curl -i -X POST https://simulator-route-llm.apps.$DOMAIN/v1/chat/completions \
  -H 'Authorization: APIKEY premiumuser1_key' \
  -H 'Content-Type: application/json' \
  -d '{"model":"simulator-model","messages":[{"role":"user","content":"Test"}]}' \
  2>/dev/null | grep x-ratelimit

# Expected headers:
# x-ratelimit-limit-tokens: 1000
# x-ratelimit-consumed-tokens: 30
# x-ratelimit-remaining-tokens: 970
```

## 📈 Monitoring and Observability

Token usage and rate limiting can be monitored through:

1. **Response Headers**: Real-time token consumption per request
2. **Gateway Logs**: Lua script logs token usage details
3. **Prometheus Metrics**: Limitador metrics for request-based limits
4. **Custom Dashboards**: Track token usage patterns over time

```bash
# View gateway logs with token counting
kubectl logs -n istio-system deployment/inference-gateway-istio -c istio-proxy | grep "Token"

# View Authorino logs for auth events  
kubectl logs -n kuadrant-system deployment/authorino | grep "auth"
```

## 🔧 Customization

### Adjusting Token Limits

Edit the EnvoyFilter to modify token limits:

```bash
# Edit the Lua script in 08-token-rate-limit-envoyfilter.yaml
local token_limits = {
  free = 500,        -- Increase free tier
  premium = 2000,    -- Increase premium tier
  enterprise = 10000 -- Increase enterprise tier
}

# Apply changes
kubectl apply -f 08-token-rate-limit-envoyfilter.yaml

# Restart gateway to apply
kubectl rollout restart deployment/inference-gateway-istio -n istio-system
```

### Adding New API Keys

```bash
# Add new user to 05-api-key-secrets.yaml
# Update user_tiers mapping in 08-token-rate-limit-envoyfilter.yaml
# Apply both files and restart gateway
```

## Manual Deployment (Advanced)

Follow the manual deployment steps below for full understanding and control over your MaaS deployment.

## Manual Deployment Instructions

```shell
git clone xxx
cd deployment/kuadrant
```

### 1. Install Istio and Gateway API

Install Istio and Gateway API CRDs using the provided script:

- Install Gateway API CRDs
- Install Istio base components and Istiod

```bash
chmod +x istio-install.sh
./istio-install.sh apply
```

This manifest will create the required namespaces (`llm` and `llm-observability`)

Create additional namespaces:

```bash
kubectl apply -f 00-namespaces.yaml
```

### 2. Install KServe (for Model Serving)

**Note:** KServe requires cert-manager for webhook certificates.

```bash
# Install cert-manager first
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.18.2/cert-manager.yaml

# Wait for cert-manager to be ready
kubectl wait --for=condition=Available deployment/cert-manager -n cert-manager --timeout=300s
kubectl wait --for=condition=Available deployment/cert-manager-cainjector -n cert-manager --timeout=300s
kubectl wait --for=condition=Available deployment/cert-manager-webhook -n cert-manager --timeout=300s

# Install KServe CRDs and controller
kubectl apply --server-side -f https://github.com/kserve/kserve/releases/download/v0.15.2/kserve.yaml

# Wait for KServe controller to be ready
kubectl wait --for=condition=Available deployment/kserve-controller-manager -n kserve --timeout=300s

# Configure KServe for Gateway API integration
# For OpenShift clusters:
kubectl apply -f 01-kserve-config-openshift.yaml

# For local development:
# kubectl apply -f 01-kserve-config.yaml

# Restart KServe controller to pick up new configuration
kubectl rollout restart deployment/kserve-controller-manager -n kserve
kubectl wait --for=condition=Available deployment/kserve-controller-manager -n kserve --timeout=120s

# View inferenceervice configmap
kubectl get configmap inferenceservice-config -n kserve -o yaml

kubectl get configmap inferenceservice-config -n kserve \
  -o jsonpath='{.data.deploy}{"\n"}{.data.ingress}{"\n"}'

# Output
# {"defaultDeploymentMode": "RawDeployment"}
# {"enableGatewayApi": true, "kserveIngressGateway": "inference-gateway.llm"}

```

### 3. Configure Gateway and Routing

The configuration supports both local development and OpenShift cluster deployments.

#### For OpenShift Clusters:

Deploy the Gateway and routing configuration with OpenShift Routes:

```bash
kubectl apply -f 02-gateway-configuration.yaml
kubectl apply -f 03-model-routing-domains.yaml
kubectl apply -f 02a-openshift-routes.yaml
```

The manifests are pre-configured for the domain: `apps.summit-gpu.octo-emerging.redhataicoe.com`

**For different OpenShift clusters:** Update the hostnames in `02-gateway-configuration.yaml`, `03-model-routing-domains.yaml`, and `02a-openshift-routes.yaml` to match your cluster's ingress domain.

#### For Local Development (KIND/minikube):

For local clusters, use the original `.maas.local` configuration:

```bash
# Reset to local development configuration
sed -i 's/apps\.summit-gpu\.octo-emerging\.redhataicoe\.com/maas.local/g' 02-gateway-configuration.yaml
sed -i 's/-llm\.apps\.summit-gpu\.octo-emerging\.redhataicoe\.com/.maas.local/g' 03-model-routing-domains.yaml

kubectl apply -f 02-gateway-configuration.yaml  
kubectl apply -f 03-model-routing-domains.yaml

# Add to /etc/hosts for local testing
echo "127.0.0.1 simulator.maas.local qwen3.maas.local granite.maas.local mistral.maas.local nomic.maas.local" >> /etc/hosts
```

### 4. Install Kuadrant Operator

```bash
# Option 1: Using Helm (recommended)

helm repo add kuadrant https://kuadrant.io/helm-charts
helm repo update

helm install kuadrant-operator kuadrant/kuadrant-operator \
  --create-namespace \
  --namespace kuadrant-system

kubectl apply -f 04-kuadrant-operator.yaml

# Wait for the operator to be ready
kubectl wait --for=condition=Available deployment/kuadrant-operator-controller-manager -n kuadrant-system --timeout=300s

# If the status does not become ready try kicking the operator:
kubectl rollout restart deployment kuadrant-operator-controller-manager -n kuadrant-system

# Deploy Kuadrant instance HA Limitador (Not tested)
#kubectl apply -f 03-kuadrant-instance.yaml
#
## Wait for Kuadrant components to be ready
#kubectl wait --for=condition=Available deployment/limitador -n kuadrant-system --timeout=300s
#kubectl wait --for=condition=Available deployment/authorino -n kuadrant-system --timeout=300s
```

### 5. (Optional) Deploy Local Storage (for minikube/local development)

```bash
# Deploy MinIO for S3-compatible local storage
kubectl apply -f minio-local-storage.yaml

# Wait for MinIO to be ready
kubectl wait --for=condition=Available deployment/minio -n minio-system --timeout=300s
```

### 7. Deploy AI Models with KServe

> Option 1 Deploy models using KServe InferenceServices on a GPU accelerator:
> There is an added example of how to set the runtime with kserve via `vllm-latest-runtime.yaml`

#### 🚨 OpenDataHub/ROSA Cluster Troubleshooting

**If you encounter this error on ROSA/OpenShift clusters with OpenDataHub:**

```
Error from server (InternalError): error when creating "vllm-simulator-kserve.yaml": 
Internal error occurred: failed calling webhook "minferenceservice-v1beta1.odh-model-controller.opendatahub.io": 
failed to call webhook: Post "https://odh-model-controller-webhook-service.redhat-ods-applications.svc:443/mutate-serving-kserve-io-v1beta1-inferenceservice?timeout=10s": 
service "odh-model-controller-webhook-service" not found
```

**Root Cause:** OpenDataHub webhook is configured but the service is missing (usually due to missing Service Mesh operator dependency).

**Solution:** Remove the broken webhook and retry:

```bash
# Remove the problematic OpenDataHub webhook
kubectl delete mutatingwebhookconfiguration mutating.odh-model-controller.opendatahub.io

# Retry deploying your model
kubectl apply -f ../model_serving/vllm-simulator-kserve.yaml
```

This won't affect your KServe deployment since you're using the standard KServe controller, not OpenDataHub's model controller.

#### OpenShift Security Context Constraints

**For OpenShift clusters, deploy Security Context Constraints before deploying models:**

```bash
# Deploy ServiceAccount and SecurityContextConstraints for OpenShift
kubectl apply -f 02b-openshift-scc.yaml
```

This creates:
- A `kserve-service-account` ServiceAccount in the `llm` namespace
- A `kserve-scc` SecurityContextConstraints that allows the necessary permissions for model containers

#### Deploy Models

**For OpenShift clusters:**

```bash
# Deploy the OpenShift-compatible simulator model (without Istio sidecar)
kubectl apply -f ../model_serving/vllm-simulator-kserve-openshift.yaml

# Deploy the OpenShift-compatible vLLM ServingRuntime with GPU support
kubectl apply -f ../model_serving/vllm-latest-runtime-openshift.yaml

# Deploy the Qwen3-0.6B model on GPU nodes (requires nvidia.com/gpu.present=true node)
kubectl apply -f ../model_serving/qwen3-0.6b-vllm-raw-openshift.yaml
```

> **Note**: The OpenShift manifests disable Istio sidecar injection (`sidecar.istio.io/inject: "false"`) to avoid iptables/networking issues in restrictive OpenShift environments. The GPU model includes proper node selection and tolerations for NVIDIA GPU nodes.

**For local development (KIND/minikube):**

```bash
# Deploy the standard simulator model  
kubectl apply -f ../model_serving/vllm-simulator-kserve.yaml

# Deploy other models as needed
kubectl apply -f ../model_serving/vllm-latest-runtime.yaml
kubectl apply -f ../model_serving/qwen3-0.6b-vllm-raw.yaml
```

#### Monitor Model Deployment

```bash
# Monitor InferenceService deployment status
kubectl get inferenceservice -n llm

# Watch model deployment (GPU models take 5-10 minutes for model download)
kubectl describe inferenceservice qwen3-0-6b-instruct -n llm

# Check if pods are running (may take 5-15 minutes for model downloads)
kubectl get pods -n llm -l serving.kserve.io/inferenceservice

# Follow logs to see model loading progress (GPU models)
kubectl logs -n llm -l serving.kserve.io/inferenceservice=qwen3-0-6b-instruct -c kserve-container -f

# Wait for GPU model to be ready
kubectl wait --for=condition=Ready inferenceservice qwen3-0-6b-instruct -n llm --timeout=900s

# Check GPU allocation
kubectl describe node ip-10-0-71-72.ec2.internal | grep -A5 "Allocated resources"
```

# Watch model deployment (takes 5-10 minutes for model download)
kubectl describe inferenceservice qwen3-0-6b-instruct -n llm

# Check if pods are running (may take 5-15 minutes for model downloads)
kubectl get pods -n llm -l serving.kserve.io/inferenceservice

# Follow logs to see model loading progress
kubectl logs -n llm -l serving.kserve.io/inferenceservice -c kserve-container -f

# Wait for model to be ready
kubectl wait --for=condition=Ready inferenceservice qwen3-0-6b-instruct -n llm --timeout=900s
```

> Option 2 - If in a KIND environment or non-GPU use:

```shell
kubectl apply -f ../model_serving/vllm-simulator-kserve.yaml
```

### 6. Configure Authentication and Rate Limiting

Deploy API key secrets, auth policies, and rate limiting:

```bash
# Create API key secrets (includes enterprise tier)
kubectl apply -f 05-api-key-secrets.yaml

# Apply API key-based auth policies
kubectl apply -f 06-auth-policies-apikey.yaml

# Choose your rate limiting approach:

# Option A: Token-based rate limiting (recommended for LLMs)
kubectl apply -f 08-token-rate-limit-envoyfilter.yaml
kubectl rollout restart deployment/inference-gateway-istio -n istio-system

# Option B: Request-based rate limiting (traditional)
kubectl apply -f 07-rate-limit-policies.yaml

# Restart Kuadrant controller to ensure policies are applied
kubectl rollout restart deployment kuadrant-operator-controller-manager -n kuadrant-system
```

### 7. Access Your Models

#### For OpenShift Clusters:

Your models are directly accessible via the OpenShift Routes (no port-forwarding needed):

- **Simulator**: `http://simulator-llm.apps.summit-gpu.octo-emerging.redhataicoe.com`
- **Qwen3**: `http://qwen3-llm.apps.summit-gpu.octo-emerging.redhataicoe.com`  
- **Granite**: `http://granite-llm.apps.summit-gpu.octo-emerging.redhataicoe.com`
- **Mistral**: `http://mistral-llm.apps.summit-gpu.octo-emerging.redhataicoe.com`
- **Nomic**: `http://nomic-llm.apps.summit-gpu.octo-emerging.redhataicoe.com`

#### For Local Development (KIND/minikube):

If running on kind/minikube, you need port forwarding to access the models:

```bash
# Port-forward to Kuadrant gateway (REQUIRED for authentication)
kubectl port-forward -n llm svc/inference-gateway-istio 8000:80 &
```

### 8. Test the MaaS API

#### For OpenShift Clusters:

Test all user tiers and rate limits with the automated script:

```bash
# Test simulator model (default - uses OpenShift route)
./scripts/test-request-limits.sh

# Test qwen3 model when ready
./scripts/test-request-limits.sh --host qwen3-llm.apps.summit-gpu.octo-emerging.redhataicoe.com --model qwen3-0-6b-instruct
```

#### For Local Development:

```bash
# Test simulator model (default - uses port-forward)
./scripts/test-request-limits.sh --host simulator.maas.local

# Test qwen3 model when ready  
./scripts/test-request-limits.sh --host qwen3.maas.local --model qwen3-0-6b-instruct
```

Example output showing rate limiting in action:

```bash
📡  Host    : simulator.maas.local
🤖  Model ID: simulator-model

=== Free User (5 requests per 2min) ===
Free req #1  -> 200
Free req #2  -> 200
Free req #3  -> 200
Free req #4  -> 200
Free req #5  -> 200
Free req #6  -> 429
Free req #7  -> 429

=== Premium User 1 (20 requests per 2min) ===
Premium1 req #1  -> 200
Premium1 req #2  -> 200
...
Premium1 req #20 -> 200
Premium1 req #21 -> 429
Premium1 req #22 -> 429

=== Premium User 2 (20 requests per 2min) ===
Premium2 req #1  -> 200
...
Premium2 req #20 -> 200
Premium2 req #21 -> 429
Premium2 req #22 -> 429

=== Second Free User (5 requests per 2min) ===
Free2 req #1  -> 200
...
Free2 req #5  -> 200
Free2 req #6  -> 429
Free2 req #7  -> 429
```

Test individual models with manual curl commands:

**Simulator Model (OpenShift):**

```bash
# Single request test
curl -s -H 'Authorization: APIKEY freeuser1_key' \
     -H 'Content-Type: application/json' \
     -d '{"model":"simulator-model","messages":[{"role":"user","content":"Hello!"}]}' \
     http://simulator-llm.apps.summit-gpu.octo-emerging.redhataicoe.com/v1/chat/completions

# Test rate limiting (Free tier: 5 requests per 2min)
for i in {1..7}; do
  printf "Free tier request #%-2s -> " "$i"
  curl -s -o /dev/null -w "%{http_code}\n" \
       -X POST http://simulator-llm.apps.summit-gpu.octo-emerging.redhataicoe.com/v1/chat/completions \
       -H 'Authorization: APIKEY freeuser1_key' \
       -H 'Content-Type: application/json' \
       -d '{"model":"simulator-model","messages":[{"role":"user","content":"Test request"}],"max_tokens":10}'
done
```

**Qwen3 Model (OpenShift):**

```bash
# Single request test
curl -s -H 'Authorization: APIKEY premiumuser1_key' \
     -H 'Content-Type: application/json' \
     -d '{"model":"qwen3-0-6b-instruct","messages":[{"role":"user","content":"Hello!"}]}' \
     http://qwen3-llm.apps.summit-gpu.octo-emerging.redhataicoe.com/v1/chat/completions

# Test rate limiting (Premium tier: 20 requests per 2min)
for i in {1..22}; do
  printf "Premium tier request #%-2s -> " "$i"
  curl -s -o /dev/null -w "%{http_code}\n" \
       -X POST http://qwen3-llm.apps.summit-gpu.octo-emerging.redhataicoe.com/v1/chat/completions \
       -H 'Authorization: APIKEY premiumuser1_key' \
       -H 'Content-Type: application/json' \
       -d '{"model":"qwen3-0-6b-instruct","messages":[{"role":"user","content":"Test request"}],"max_tokens":10}'
done
```

**Available API Keys and Rate Limits:**

| Tier | API Keys | Token Limits/min | Request Limits/2min |
|------|----------|-----------------|-------------------|
| **Free** | `freeuser1_key`, `freeuser2_key` | 200 tokens | 5 requests |
| **Premium** | `premiumuser1_key`, `premiumuser2_key` | 1,000 tokens | 20 requests |
| **Enterprise** | `enterpriseuser1_key` | 5,000 tokens | 100 requests |

- Expected Responses

- ✅ **200**: Request successful
- ❌ **429**: Rate limit exceeded (too many requests)
- ❌ **401**: Invalid/missing API key

### 9. Deploy Observability

Deploy Prometheus and monitoring components:

```bash
# Install Prometheus Operator
kubectl apply --server-side --field-manager=quickstart-installer -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/master/bundle.yaml

# Wait for Prometheus Operator to be ready
kubectl wait --for=condition=Available deployment/prometheus-operator -n default --timeout=300s

# From models-aas/deployment/kuadrant Kuadrant prometheus observability
kubectl apply -k kustomize/prometheus/

# Wait for Prometheus to be ready
kubectl wait --for=condition=Running prometheus/models-aas-observability -n llm-observability --timeout=300s

# Port-forward to access Prometheus UI
kubectl port-forward -n llm-observability svc/models-aas-observability 9090:9090 &

# Forward Limitador admin metric scrape target
kubectl -n kuadrant-system port-forward svc/limitador-limitador 8080:8080

# Access Prometheus at http://localhost:9090
```

### Query the Limitador Scrape Endpoint

> 🚨 See this issue for status on getting per user scrape data for authorization and limits with Kudrant [Question on mapping authorized_calls metrics to a user](https://github.com/Kuadrant/limitador/issues/434)

For now, you can scrape namespace wide limits:

```shell
$ curl -s http://localhost:8080/metrics | grep calls
# HELP authorized_calls Authorized calls
# TYPE authorized_calls counter
authorized_calls{limitador_namespace="llm/simulator-domain-route"} 100
# HELP limited_calls Limited calls
# TYPE limited_calls counter
limited_calls{limitador_namespace="llm/simulator-domain-route"} 16
```

### Query Metrics via Prom API

```bash
# Get limited_calls via Prometheus
curl -sG --data-urlencode 'query=limited_calls'     http://localhost:9090/api/v1/query | jq '.data.result'
[
  {
    "metric": {
      "__name__": "limited_calls",
      "container": "limitador",
      "endpoint": "http",
      "instance": "10.244.0.19:8080",
      "job": "limitador-limitador",
      "limitador_namespace": "llm/simulator-domain-route",
      "namespace": "kuadrant-system",
      "pod": "limitador-limitador-84bdfb4747-n8h44",
      "service": "limitador-limitador"
    },
    "value": [
      1754366303.129,
      "16"
    ]
  }
]

curl -sG --data-urlencode 'query=authorized_calls'     http://localhost:9090/api/v1/query | jq '.data.result'
[
  {
    "metric": {
      "__name__": "authorized_calls",
      "container": "limitador",
      "endpoint": "http",
      "instance": "10.244.0.19:8080",
      "job": "limitador-limitador",
      "limitador_namespace": "llm/simulator-domain-route",
      "namespace": "kuadrant-system",
      "pod": "limitador-limitador-84bdfb4747-n8h44",
      "service": "limitador-limitador"
    },
    "value": [
      1754366383.534,
      "100"
    ]
  }
]
```

## Troubleshooting

### View Logs

```bash
# Kuadrant operator logs
kubectl logs -n kuadrant-system deployment/kuadrant-operator-controller-manager

# Istio gateway logs
kubectl logs -n istio-system deployment/istio-ingressgateway

# Limitador logs
kubectl logs -n kuadrant-system deployment/limitador

# Authorino logs
kubectl logs -n kuadrant-system deployment/authorino
```

### Common Issues

- **502 Bad Gateway**: Check if model services are running and healthy
- **No Rate Limiting or Auth**: Kick the kuadrant-operator-controller-manager
- **Token headers not visible**: Ensure gateway was restarted after applying EnvoyFilter
- **Rate limits not enforcing**: Check if `--token-rate-limit` flag was used during installation
- **429 errors immediately**: Token limits reset every 60 seconds, wait for window to reset

### Openshift Troubleshooting

- **KServe provisioning failed error**: If istio was installed with upstream helm chart it needs to be full purged. See [Istio Troubleshooting](docs/istio_troubleshooting.md)
- **Inference service not found**: If `inference-gateway-istio` pod is showing `cannot fetch Wasm module llm.kuadrant-inference-gateway: missing image pulling secret` then create a secret with the image pull secret for the `llm` namespace. More info [here](https://developers.redhat.com/products/red-hat-connectivity-link/quick-setup#installtheopenshiftservicemesh30operator5990)


## Customization

### Adjusting Rate Limits

**For Token-Based Limits:**

Edit the EnvoyFilter in `08-token-rate-limit-envoyfilter.yaml`:
```lua
local token_limits = {
  free = 500,        -- Increase from 200
  premium = 2000,    -- Increase from 1000
  enterprise = 10000 -- Increase from 5000
}
```
Then restart the gateway:
```bash
kubectl apply -f 08-token-rate-limit-envoyfilter.yaml
kubectl rollout restart deployment/inference-gateway-istio -n istio-system
```

**For Request-Based Limits:**

Edit the RateLimitPolicy resources in `07-rate-limit-policies.yaml`:
```yaml
limits:
  "requests-per-2min":
    rates:
      - limit: 150  # Increase from 100
        duration: 2m
        unit: request
```

## Performance Tuning

### Gateway Scaling

```bash
# Scale Istio gateway
kubectl scale deployment/istio-ingressgateway -n istio-system --replicas=3

# Scale Kuadrant components
kubectl scale deployment/limitador -n kuadrant-system --replicas=3
kubectl scale deployment/authorino -n kuadrant-system --replicas=2
```

---

## Kustomize-Based Deployment (Not Fully Tested)

For production deployments and GitOps workflows, use the modular kustomize structure for better organization and maintainability.

### Kustomize Directory Structure

```
deployment/kuadrant/kustomize/
├── base/                    # Core infrastructure (operators, namespaces, storage)
├── gateway/                 # Gateway API and routing configuration
├── auth/                    # Authentication and rate limiting policies  
├── observability/           # Monitoring stack (Prometheus, Grafana)
└── prometheus/              # Enhanced Prometheus with ServiceMonitors
```

### Deploy Individual Components

```bash
cd models-aas/deployment/kuadrant

# Deploy only base infrastructure
kubectl apply -k kustomize/base/

# Deploy only gateway configuration
kubectl apply -k kustomize/gateway/

# Deploy only authentication and rate limiting
kubectl apply -k kustomize/auth/

# Deploy only observability stack
kubectl apply -k kustomize/observability/

# Deploy enhanced Prometheus separately
kubectl apply -k kustomize/prometheus/
```

### Deploy Everything with Kustomize

```bash
# Deploy complete MaaS platform using modular kustomize
kubectl apply -k .

# Wait for all components to be ready
kubectl wait --for=condition=Available deployment/kuadrant-operator-controller-manager -n kuadrant-system --timeout=300s
kubectl wait --for=condition=Available deployment/limitador-limitador -n kuadrant-system --timeout=300s
kubectl wait --for=condition=Available deployment/authorino -n kuadrant-system --timeout=300s
kubectl wait --for=condition=Available deployment/models-aas-observability -n llm-observability --timeout=300s

# Verify deployment
kubectl get pods -A | grep -E 'kuadrant|llm'
```

---

## Keycloak OIDC Authentication (Alternative to API Keys)

For production deployments, you can use Keycloak with OIDC JWT tokens instead of static API keys for dev. This provides user management, token expiration, and group-based access control.

This allows for provisioning users into groups dynamically without reconfiguring the MaaS service deployments.

### Deploy Keycloak with OIDC Authentication

```bash
# Deploy Keycloak and configure OIDC authentication
kubectl apply -k keycloak/

# Wait for Keycloak to be ready
kubectl wait --for=condition=Available deployment/keycloak -n keycloak-system --timeout=300s

# Wait for realm import job to complete
kubectl wait --for=condition=Complete job/keycloak-realm-import -n keycloak-system --timeout=300s

# Port-forward Keycloak for token management
kubectl port-forward -n keycloak-system svc/keycloak 8080:8080 &
```

### User Accounts and Tiers

The Keycloak realm has a few pre-configured users across the three tiers/groups for demoing:

| Tier | Users | Rate Limit | Password |
|------|-------|------------|----------|
| **Free** | `freeuser1`, `freeuser2` | 5 req/2min | `password123` |
| **Premium** | `premiumuser1`, `premiumuser2` | 20 req/2min | `password123` |
| **Enterprise** | `enterpriseuser1` | 100 req/2min | `password123` |

### Get JWT Tokens

Use the provided script to get JWT tokens for testing:

```bash
# Get token for a free user
cd keycloak/
./get-token.sh freeuser1

# Get token for a premium user  
./get-token.sh premiumuser1

# Get token for an enterprise user
./get-token.sh enterpriseuser1
```

### Test OIDC Authentication

```bash
# Run the rate-limiting tests with OIDC auth and rate limiting tests
cd keycloak/
./test-oidc-auth.sh
```

Example output:
```bash
  Testing OIDC Authentication and Rate Limiting
  API Host: simulator.maas.local:8000
  Keycloak: localhost:8080

=== Testing Free User: freeuser1 (5 requests per 2min) ===
✅ Token acquired for freeuser1
freeuser1 req #1 -> 200 ✅
freeuser1 req #2 -> 200 ✅
freeuser1 req #3 -> 200 ✅
freeuser1 req #4 -> 200 ✅
freeuser1 req #5 -> 200 ✅
freeuser1 req #6 -> 429 ⚠️ (rate limited)
freeuser1 req #7 -> 429 ⚠️ (rate limited)
```

### Manual API Testing with JWT

```bash
# Get a token
TOKEN=$(./get-token.sh freeuser1 | grep -A1 "Access Token:" | tail -1)

# Test API call with JWT
curl -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/json" \
     -d '{"model":"simulator-model","messages":[{"role":"user","content":"Infer call with OIDC Auth!"}]}' \
     http://simulator.maas.local:8000/v1/chat/completions
```

### Keycloak Admin Access

Access the Keycloak admin console for user management:

```bash
# Port-forward Keycloak (if not already done)
kubectl port-forward -n keycloak-system svc/keycloak 8080:8080

# Access admin console at http://localhost:8080
# Username: admin
# Password: admin123
# Realm: maas
```

### Architecture Changes with OIDC

When using OIDC authentication:

1. **AuthPolicy** validates JWT tokens from Keycloak
2. **User identification** based on JWT `sub` claim
3. **Rate limiting** per user ID (not API key)
4. **User attributes** extracted from JWT claims (tier, groups, email)

### Switch Between Authentication Methods in the Demo ENV

```bash
# Use API keys (default)
kubectl apply -f 06-auth-policies-apikey.yaml
kubectl apply -f 07-rate-limit-policies.yaml

# Switch to OIDC
kubectl apply -f keycloak/05-auth-policy-oidc.yaml  
kubectl apply -f keycloak/06-rate-limit-policy-oidc.yaml

# Remove the API key policies
kubectl delete -f 06-auth-policies-apikey.yaml
kubectl delete -f 07-rate-limit-policies.yaml
```
