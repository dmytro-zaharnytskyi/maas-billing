#!/usr/bin/env bash
set -euo pipefail

################################################################################
# Models-as-a-Service (MaaS) + Kuadrant one-shot installer
#
# Flags
#   --simulator           Deploy only the vLLM simulator (CPU/KIND clusters)
#   --qwen3               Deploy only the Qwen3-0.6 B model (GPU cluster)
#   --install-all-models  Deploy both simulator and Qwen3
#   --deploy-kind          Spin up a kind cluster named llm-maas and deploy the
#                         simulator model into it
#
# The script must be run from  deployment/kuadrant  (it relies on relative paths)
################################################################################

NAMESPACE="llm"
MODEL_TYPE=""
DEPLOY_KIND=false
SKIP_METRICS=false
OCP=false
TOKEN_RATE_LIMIT=false
GPU_CHECK=false

usage() {
  cat <<EOF
Usage: $0 [--simulator|--qwen3|--install-all-models|--deploy-kind] [--skip-metrics] [--token-rate-limit]

Options
  --simulator            Deploy vLLM simulator (no GPU required)
  --qwen3                Deploy Qwen3-0.6B model (GPU required)
  --install-all-models   Deploy both simulator and Qwen3
  --deploy-kind          Create a kind cluster named llm-maas and deploy the simulator model
  --skip-metrics         Skip Prometheus observability deployment
  --ocp                  Deploy to OpenShift cluster (disables auto-detection)
  --no-ocp               Force non-OpenShift mode (disables auto-detection)
  --token-rate-limit     Enable token-based rate limiting (instead of request-based)
  --check-gpu            Verify GPU availability before deploying GPU models
Examples
  $0 --simulator
  $0 --qwen3 --skip-metrics --check-gpu
  $0 --qwen3 --token-rate-limit
  $0 --install-all-models
  $0 --deploy-kind
  $0 --simulator --ocp
EOF
  exit 1
}

# ────────────────────────────── flag parsing ──────────────────────────────────
FORCE_NO_OCP=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --simulator)           MODEL_TYPE="simulator" ; shift ;;
    --qwen3)               MODEL_TYPE="qwen3"     ; shift ;;
    --install-all-models)  MODEL_TYPE="all"       ; shift ;;
    --deploy-kind)         DEPLOY_KIND=true; MODEL_TYPE="simulator" ; shift ;;
    --skip-metrics)        SKIP_METRICS=true ; shift ;;
    --token-rate-limit)    TOKEN_RATE_LIMIT=true ; shift ;;
    --check-gpu)           GPU_CHECK=true ; shift ;;
    -h|--help)             usage ;;
    --ocp)                 OCP=true ; shift ;;
    --no-ocp)              FORCE_NO_OCP=true ; OCP=false ; shift ;;
    *) echo "❌ Unknown option: $1"; usage ;;
  esac
done

[[ -z "$MODEL_TYPE" ]] && { echo "❌ Must specify a model flag"; usage; }

# ────────────────────────────── Auto-detect OpenShift ─────────────────────────
if [[ "$FORCE_NO_OCP" == false ]] && [[ "$OCP" == false ]]; then
  echo "🔍 Detecting platform..."
  
  # Method 1: Check if oc command exists and can get server info
  if command -v oc &>/dev/null; then
    if oc whoami --show-server &>/dev/null; then
      echo "  ✅ OpenShift detected via 'oc' command"
      OCP=true
    fi
  fi
  
  # Method 2: Check for OpenShift-specific resources if oc doesn't exist
  if [[ "$OCP" == false ]]; then
    if kubectl get clusterversion &>/dev/null || \
       kubectl get projects &>/dev/null || \
       kubectl get route -n openshift-console &>/dev/null || \
       kubectl get packagemanifests -n openshift-marketplace &>/dev/null; then
      echo "  ✅ OpenShift detected via API resources"
      OCP=true
    fi
  fi
  
  # Method 3: Check for Service Mesh operator specifically
  if [[ "$OCP" == false ]]; then
    if kubectl get csv -A 2>/dev/null | grep -i servicemeshoperator &>/dev/null; then
      echo "  ✅ OpenShift Service Mesh operator detected"
      OCP=true
    fi
  fi
  
  if [[ "$OCP" == true ]]; then
    echo "  ℹ️  Auto-detected OpenShift platform. Using Service Mesh instead of vanilla Istio."
    echo "  ℹ️  To force Kubernetes mode, use --no-ocp flag"
  else
    echo "  ℹ️  Detected vanilla Kubernetes. Will install Istio via Helm."
    echo "  ℹ️  To force OpenShift mode, use --ocp flag"
  fi
  echo ""
fi

# ────────────────────────────── sanity checks ─────────────────────────────────
if [[ ! -f "02-gateway-configuration.yaml" ]]; then
  echo "❌ Run this script from deployment/kuadrant"
  exit 1
fi

# ────────────────────────────── optional kind cluster ─────────────────────────
if [[ "$DEPLOY_KIND" == true ]]; then
  echo "🔧 Creating kind cluster 'llm-maas' (if absent)"
  if ! kind get clusters | grep -q '^llm-maas$'; then
    kind create cluster --name llm-maas
  else
    echo "ℹ️  kind cluster 'llm-maas' already exists; reusing"
  fi
fi

echo
echo "🚀 MaaS installation started"
echo "📦  Model selection: $MODEL_TYPE"
echo

# ────────────────────────────── 1. Istio / Gateway API ────────────────────────
echo "🔧 1. Installing Istio & Gateway API"
chmod +x istio-install.sh
if [[ "$OCP" == true ]]; then
  echo "🔧 Checking for required OpenShift operators..."
  
  # Check for Service Mesh operator
  if oc get csv -A --no-headers 2>/dev/null | awk '{print $2}' | grep -i "servicemeshoperator" > /dev/null; then
    echo "  ✅ Service Mesh operator found"
  else
    echo ""
    echo "❌ ERROR: Red Hat OpenShift Service Mesh operator is not installed!"
    echo ""
    echo "Please install the following operators from the OpenShift Console:"
    echo "  1. Red Hat OpenShift Serverless operator"
    echo "  2. Red Hat OpenShift Service Mesh operator"
    echo "  3. Red Hat OpenShift AI (RHOAI) operator"
    echo ""
    echo "Installation steps:"
    echo "  1. Go to Operators → OperatorHub in the OpenShift Console"
    echo "  2. Search for and install each operator listed above"
    echo "  3. Wait for all operators to be ready"
    echo "  4. Re-run this script"
    echo ""
    exit 1
  fi
  
  # Check for Serverless operator
  if oc get csv -A --no-headers 2>/dev/null | awk '{print $2}' | grep -i "serverless-operator" > /dev/null; then
    echo "  ✅ Serverless operator found"
  else
    echo ""
    echo "❌ ERROR: Red Hat OpenShift Serverless operator is not installed!"
    echo ""
    echo "Please install the following operators from the OpenShift Console:"
    echo "  1. Red Hat OpenShift Serverless operator"
    echo "  2. Red Hat OpenShift Service Mesh operator (if not already installed)"
    echo "  3. Red Hat OpenShift AI (RHOAI) operator"
    echo ""
    echo "Installation steps:"
    echo "  1. Go to Operators → OperatorHub in the OpenShift Console"
    echo "  2. Search for and install each operator listed above"
    echo "  3. Wait for all operators to be ready"
    echo "  4. Re-run this script"
    echo ""
    exit 1
  fi
  
  # Check for RHOAI operator
  if oc get csv -A --no-headers 2>/dev/null | awk '{print $2}' | grep -i "rhods-operator" > /dev/null; then
    echo "  ✅ RHOAI operator found"
  else
    echo ""
    echo "❌ ERROR: Red Hat OpenShift AI (RHOAI) operator is not installed!"
    echo ""
    echo "Please install the following operators from the OpenShift Console:"
    echo "  1. Red Hat OpenShift Serverless operator (if not already installed)"
    echo "  2. Red Hat OpenShift Service Mesh operator (if not already installed)"
    echo "  3. Red Hat OpenShift AI (RHOAI) operator"
    echo ""
    echo "Installation steps:"
    echo "  1. Go to Operators → OperatorHub in the OpenShift Console"
    echo "  2. Search for and install each operator listed above"
    echo "  3. Wait for all operators to be ready"
    echo "  4. Re-run this script"
    echo ""
    exit 1
  fi
  
  echo "🔧 Skipping manual Istio installation (handled by Service Mesh operator)"
  
  # Install Gateway API CRDs (required even with ServiceMesh)
  echo "🔧 Installing Gateway API CRDs..."
  kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml || {
    echo "  ⚠️  Failed to install Gateway API CRDs"
    echo "  Trying alternative version..."
    kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.0.0/standard-install.yaml
  }
  echo "  ✅ Gateway API CRDs installed"
  
  # Create the istio GatewayClass
  echo "🔧 Creating istio GatewayClass..."
  cat << 'EOF' | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: istio
spec:
  controllerName: istio.io/gateway-controller
EOF
  echo "  ✅ GatewayClass created"
else
  # For vanilla Kubernetes, install Istio via the script
  echo "🔧 Installing Istio via Helm..."
  OCP=$OCP ./istio-install.sh apply
fi

# ────────────────────────────── 2. Namespaces ────────────────────────────────
echo "🔧 2. Creating namespaces"
kubectl apply -f 00-namespaces.yaml

# ────────────────────────────── 3. cert-manager & KServe ─────────────────────
echo "🔧 3. Installing cert-manager"
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.18.2/cert-manager.yaml

echo "⏳   Waiting for cert-manager to be ready"
kubectl wait --for=condition=Available deployment/cert-manager            -n cert-manager --timeout=300s
kubectl wait --for=condition=Available deployment/cert-manager-cainjector -n cert-manager --timeout=300s
kubectl wait --for=condition=Available deployment/cert-manager-webhook   -n cert-manager --timeout=300s

if [[ "$OCP" == true ]]; then
  echo "🔧 Checking for RHOAI installation..."
  
  # Check if DataScienceCluster exists
  if ! oc get datasciencecluster -n redhat-ods-operator &>/dev/null || [ $(oc get datasciencecluster -n redhat-ods-operator --no-headers 2>/dev/null | wc -l) -eq 0 ]; then
    echo "  ⚠️  DataScienceCluster not found. Creating RHOAI setup..."
    # Apply RHOAI setup if the file exists
    if [ -f "rhoai-setup.yaml" ]; then
      kubectl apply -f rhoai-setup.yaml
      echo "  ⏳ Waiting for DataScienceCluster to be ready (this may take several minutes)..."
      kubectl wait --for=condition=Ready datasciencecluster/default-dsc -n redhat-ods-operator --timeout=600s
    else
      echo "  ❌ rhoai-setup.yaml not found. Please ensure RHOAI is properly configured."
      exit 1
    fi
  else
    echo "  ✅ DataScienceCluster found, validating it's ready..."
    kubectl wait --for=condition=Ready datasciencecluster/default-dsc -n redhat-ods-operator --timeout=300s || true
  fi
  
  echo "🔧 Ensuring ServiceMesh is configured for authentication..."
  # Check if ServiceMeshControlPlane exists
  if ! oc get smcp data-science-smcp -n istio-system &>/dev/null; then
    echo "  ⚠️  ServiceMeshControlPlane not found. Creating it for Gateway API support..."
    if [ -f "fix-servicemesh.yaml" ]; then
      kubectl apply -f fix-servicemesh.yaml
      echo "  ⏳ Waiting for ServiceMesh to be ready..."
      kubectl wait --for=condition=Ready smcp/data-science-smcp -n istio-system --timeout=180s
    else
      echo "  ⚠️  Creating ServiceMesh inline..."
      cat << 'EOF' | kubectl apply -f -
---
apiVersion: v1
kind: Namespace
metadata:
  name: istio-system
---
apiVersion: maistra.io/v2
kind: ServiceMeshControlPlane
metadata:
  name: data-science-smcp
  namespace: istio-system
spec:
  version: v2.6
  mode: ClusterWide
  techPreview:
    gatewayAPI:
      enabled: true
  security:
    dataPlane:
      mtls: false
  gateways:
    ingress:
      enabled: true
      namespace: istio-system
      service:
        type: ClusterIP
---
apiVersion: maistra.io/v1
kind: ServiceMeshMemberRoll
metadata:
  name: default
  namespace: istio-system
spec:
  members:
  - llm
  - llm-observability
  - knative-serving
EOF
      kubectl wait --for=condition=Ready smcp/data-science-smcp -n istio-system --timeout=180s
    fi
  else
    echo "  ✅ ServiceMeshControlPlane found"
    
    # Update ServiceMeshMemberRoll to include necessary namespaces
    echo "🔧 Updating ServiceMeshMemberRoll to include required namespaces..."
    # Get existing members (preserve knative-serving if it exists)
    EXISTING_MEMBERS=$(kubectl get servicemeshmemberroll default -n istio-system -o jsonpath='{.spec.members[*]}' 2>/dev/null || echo "")
    
    # Always ensure knative-serving, llm, and llm-observability are included
    # kuadrant-system should NOT be included as it doesn't need sidecars
    if [[ "$EXISTING_MEMBERS" == *"knative-serving"* ]]; then
      # knative-serving already exists, just add llm namespaces
      kubectl patch servicemeshmemberroll default -n istio-system --type=merge -p '{"spec":{"members":["knative-serving","llm","llm-observability"]}}' 2>/dev/null || true
    else
      # Add all required namespaces
      kubectl patch servicemeshmemberroll default -n istio-system --type=merge -p '{"spec":{"members":["llm","llm-observability","knative-serving"]}}' 2>/dev/null || true
    fi
    echo "  ✅ ServiceMeshMemberRoll updated"
  fi
  
  echo "🔧 Skipping KServe setup, Openshift Serverless operator handles this (Installed by the RHOAI operator)"

  echo "🔧 Updating ServiceMeshControlPlane for RHOAI to enable Gateway API"
  kubectl patch smcp/data-science-smcp -n istio-system --type=merge -p '{"spec":{"mode":"ClusterWide"}}' 2>/dev/null || true

  echo "🔧 Updating ServiceMeshControlPlane to set mtls to PERMISSIVE (workaround)"
  kubectl patch smcp/data-science-smcp -n istio-system --type=merge -p '{"spec":{"security":{"dataPlane":{"mtls":false}}}}' 2>/dev/null || true
else
  echo "🔧 Installing KServe"
  kubectl apply --server-side --force-conflicts -f https://github.com/kserve/kserve/releases/download/v0.15.2/kserve.yaml

  echo "⏳   Waiting for KServe controller"
  kubectl wait --for=condition=Available deployment/kserve-controller-manager -n kserve --timeout=300s
fi

echo "🔧 Configuring KServe for Gateway API"
if [[ "$OCP" == true ]]; then
  # Removing this for now, not sure if we need to make this these updates in order to get the gateway api to work later
  # kubectl apply -f 01-kserve-config.yaml
  echo "🔧 Skipping KServe config, Openshift Serverless operator handles this (Installed by the RHOAI operator)"
  echo "🔧 Applying OpenShift Security Context Constraints"
  kubectl apply -f 02b-openshift-scc.yaml

  # Don't create routes here - they will be created later in the proper namespace
  # echo "🔧 Creating Routes"
  # kubectl apply -f 02a-openshift-routes.yaml
else
  kubectl apply -f 01-kserve-config.yaml
  
  # Fix logger configuration issue in KServe
  echo "  - Adding logger configuration to fix pod creation..."
  kubectl patch configmap inferenceservice-config -n kserve --type='json' -p='[{"op": "add", "path": "/data/logger", "value": "{\n  \"image\": \"kserve/agent:v0.15.2\",\n  \"memoryRequest\": \"100Mi\",\n  \"memoryLimit\": \"1Gi\",\n  \"cpuRequest\": \"100m\",\n  \"cpuLimit\": \"1\"\n}\n"}]' 2>/dev/null || true
  
  kubectl rollout restart deployment/kserve-controller-manager -n kserve
  kubectl wait --for=condition=Available deployment/kserve-controller-manager -n kserve --timeout=120s

  echo "📄  Current inferenceservice-config ConfigMap:"
  kubectl get configmap inferenceservice-config -n kserve -o yaml
fi



# ────────────────────────────── 4. Gateway + Routes ──────────────────────────
echo "🔧 4. Setting up Gateway and domain-based routes"

if [[ "$OCP" == true ]]; then
  # Get base domain for OpenShift
  BASE_DOMAIN=$(oc whoami --show-server | sed 's/https:\/\/api\.//' | sed 's/:.*//')
  
  echo "🔧 Testing Gateway API support..."
  
  # Try to create a test Gateway API Gateway
  TEST_GATEWAY_CREATED=false
  cat << EOF | kubectl apply -f - 2>/dev/null && TEST_GATEWAY_CREATED=true || true
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: test-gateway-api
  namespace: llm
spec:
  gatewayClassName: istio
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    hostname: "test.local"
EOF

  # Wait and check if Gateway pod is created
  if [[ "$TEST_GATEWAY_CREATED" == true ]]; then
    sleep 5
    if kubectl get pods -n llm 2>/dev/null | grep -q "test-gateway-api"; then
      echo "✅ Gateway API is working! Using Gateway API for both auth and rate limiting"
      USE_GATEWAY_API=true
      kubectl delete gateway test-gateway-api -n llm --ignore-not-found=true 2>/dev/null
    else
      echo "⚠️  Gateway API not fully functional, falling back to native Istio"
      USE_GATEWAY_API=false
      kubectl delete gateway test-gateway-api -n llm --ignore-not-found=true 2>/dev/null
    fi
  else
    echo "⚠️  Gateway API not available, using native Istio"
    USE_GATEWAY_API=false
  fi
  
  if [[ "$USE_GATEWAY_API" == true ]]; then
    # Use Gateway API (supports both auth and rate limiting)
    echo "🔧 Creating Gateway API resources..."
    
    # IMPORTANT: Gateway must be in istio-system namespace for ServiceMesh to trust it
    cat << EOF | kubectl apply -f -
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: inference-gateway
  namespace: istio-system
spec:
  gatewayClassName: istio
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    hostname: "*.apps.${BASE_DOMAIN}"
    allowedRoutes:
      namespaces:
        from: All
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: simulator-route
  namespace: llm
spec:
  parentRefs:
  - name: inference-gateway
    namespace: istio-system
  hostnames:
  - "simulator-route-llm.apps.${BASE_DOMAIN}"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: vllm-simulator-predictor
      port: 80
EOF
    
    echo "🔧 Waiting for Gateway to be ready..."
    sleep 10
    
    # Create NetworkPolicy to allow OpenShift Router traffic
    echo "🔧 Creating NetworkPolicy to allow OpenShift Router..."
    cat << EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-openshift-router
  namespace: istio-system
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: openshift-ingress
    - namespaceSelector:
        matchLabels:
          network.openshift.io/policy-group: ingress
    - namespaceSelector: {}
EOF
    
    # Create OpenShift route to Gateway service IN ISTIO-SYSTEM namespace
    echo "🔧 Creating OpenShift route to Gateway..."
    
    # First, clean up any conflicting routes
    echo "  - Cleaning up any conflicting routes..."
    oc delete route simulator-route -n llm --ignore-not-found=true 2>/dev/null || true
    oc delete route simulator-route -n istio-system --ignore-not-found=true 2>/dev/null || true
    oc delete route qwen3-route -n llm --ignore-not-found=true 2>/dev/null || true
    oc delete route qwen3-route -n istio-system --ignore-not-found=true 2>/dev/null || true
    sleep 2
    
    # Find the Gateway service name (it might have a generated suffix)
    GATEWAY_SVC=$(kubectl get svc -n istio-system | grep "inference-gateway" | awk '{print $1}')
    if [[ -z "$GATEWAY_SVC" ]]; then
      # If no Gateway-specific service, use istio-ingressgateway
      GATEWAY_SVC="istio-ingressgateway"
      GATEWAY_PORT="8080"
    else
      GATEWAY_PORT="http"  # Use the port name instead of number for Gateway API services
    fi
    
    cat << EOF | kubectl apply -f -
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: simulator-route
  namespace: istio-system
spec:
  host: simulator-route-llm.apps.${BASE_DOMAIN}
  to:
    kind: Service
    name: ${GATEWAY_SVC}
    weight: 100
  port:
    targetPort: ${GATEWAY_PORT}
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
  wildcardPolicy: None
EOF
    
    # Create route for Qwen model if it will be deployed
    if [[ "$MODEL_TYPE" == "qwen3" || "$MODEL_TYPE" == "all" ]]; then
      cat << EOF | kubectl apply -f -
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: qwen3-route
  namespace: istio-system
spec:
  host: qwen3-route-llm.apps.${BASE_DOMAIN}
  to:
    kind: Service
    name: ${GATEWAY_SVC}
    weight: 100
  port:
    targetPort: ${GATEWAY_PORT}
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
  wildcardPolicy: None
EOF
    fi
    
    # Wait for routes to be admitted
    echo "  - Waiting for routes to be admitted..."
    sleep 3
    if oc get route simulator-route -n istio-system -o jsonpath='{.status.ingress[0].conditions[0].status}' 2>/dev/null | grep -q "True"; then
      echo "  ✅ Route successfully created and admitted"
    else
      echo "  ⚠️  Route may not be fully admitted yet, please check: oc get route -n istio-system"
    fi
    
  else
    # Fall back to native Istio (auth only, no rate limiting)
    echo "🔧 Using native Istio resources (ServiceMesh 2.6 Gateway API is broken)..."
    
    # Get base domain for OpenShift
    BASE_DOMAIN=$(oc whoami --show-server | sed 's/https:\/\/api\.//' | sed 's/:.*//')
    
    # Create native Istio Gateway and VirtualService
    cat << EOF | kubectl apply -f -
---
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: inference-gateway
  namespace: llm
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 8080
      name: http
      protocol: HTTP
    hosts:
    - "*.${BASE_DOMAIN}"
    - "*.apps.${BASE_DOMAIN}"
---
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: simulator-virtualservice
  namespace: llm
spec:
  hosts:
  - "simulator-route-llm.apps.${BASE_DOMAIN}"
  gateways:
  - inference-gateway
  http:
  - match:
    - uri:
        prefix: "/"
    route:
    - destination:
        host: vllm-simulator-predictor.llm.svc.cluster.local
        port:
          number: 80
EOF
    
    echo "🔧 Creating OpenShift route to istio-ingressgateway..."
    
    # Clean up any conflicting routes first
    echo "  - Removing any conflicting routes..."
    oc delete route simulator-route -n llm --ignore-not-found=true 2>/dev/null || true
    oc delete route simulator-route -n istio-system --ignore-not-found=true 2>/dev/null || true
    sleep 2
    
    # Create the route in istio-system namespace
    cat << EOF | kubectl apply -f -
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: simulator-route
  namespace: istio-system
spec:
  host: simulator-route-llm.apps.${BASE_DOMAIN}
  to:
    kind: Service
    name: istio-ingressgateway
  port:
    targetPort: 8080
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF
    
    # Wait for route to be admitted
    echo "  - Waiting for route to be admitted..."
    sleep 3
    if oc get route simulator-route -n istio-system -o jsonpath='{.status.ingress[0].conditions[0].status}' 2>/dev/null | grep -q "True"; then
      echo "  ✅ Route successfully created and admitted"
    else
      echo "  ⚠️  Route may not be fully admitted yet, please check: oc get route -n istio-system"
    fi
  fi
  
else
  # For vanilla Kubernetes, use Gateway API
  kubectl apply -f 02-gateway-configuration.yaml
  kubectl apply -f 03-model-routing-domains.yaml
  ./setup-local-domains.sh setup
fi

# ────────────────────────────── 5. Kuadrant Operator ─────────────────────────
echo "🔧 5. Installing Kuadrant operator"

# For OpenShift with Service Mesh, disable sidecar injection for kuadrant-system
if [[ "$OCP" == true ]]; then
  echo "  - Disabling Istio sidecar injection for kuadrant-system namespace..."
  kubectl label namespace kuadrant-system istio-injection=disabled --overwrite 2>/dev/null || true
  kubectl label namespace kuadrant-system maistra.io/member-of- --overwrite 2>/dev/null || true
fi

helm repo add kuadrant https://kuadrant.io/helm-charts 2>/dev/null || true
helm repo update

# Check if already installed and upgrade or install
if helm list -n kuadrant-system 2>/dev/null | grep -q kuadrant-operator; then
  echo "  - Kuadrant operator already installed, upgrading..."
  helm upgrade kuadrant-operator kuadrant/kuadrant-operator \
    --namespace kuadrant-system
else
  echo "  - Installing Kuadrant operator..."
  helm install kuadrant-operator kuadrant/kuadrant-operator \
    --create-namespace \
    --namespace kuadrant-system
fi

kubectl apply -f 04-kuadrant-operator.yaml

echo "⏳   Waiting for Kuadrant operator (this may take a few minutes)..."
# Increase timeout and add retry logic for Kuadrant
MAX_RETRIES=3
RETRY_COUNT=0
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
  if kubectl wait --for=condition=Available deployment/kuadrant-operator-controller-manager -n kuadrant-system --timeout=120s 2>/dev/null; then
    echo "  ✅ Kuadrant operator is ready"
    break
  else
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
      echo "  ⚠️  Kuadrant not ready yet, checking status..."
      kubectl get pods -n kuadrant-system
      echo "  Retrying... (attempt $((RETRY_COUNT + 1))/$MAX_RETRIES)"
      sleep 10
    else
      echo "  ⚠️  Kuadrant operator is taking longer than expected to start"
      echo "  Check the status with: kubectl get pods -n kuadrant-system"
      echo "  Continuing with installation..."
    fi
  fi
done

# Wait for Authorino and Limitador to be ready as well
echo "⏳   Waiting for Authorino and Limitador..."
kubectl wait --for=condition=Available deployment/authorino -n kuadrant-system --timeout=120s 2>/dev/null || true
kubectl wait --for=condition=Available deployment/limitador-limitador -n kuadrant-system --timeout=120s 2>/dev/null || true

if [[ "$OCP" == true ]]; then
  echo "🔧 Ensuring Kuadrant detects ServiceMesh..."
  # Restart Kuadrant to detect newly installed ServiceMesh/Istio
  kubectl rollout restart deployment/kuadrant-operator-controller-manager -n kuadrant-system 2>/dev/null || true
  kubectl wait --for=condition=Available deployment/kuadrant-operator-controller-manager -n kuadrant-system --timeout=60s 2>/dev/null || true
fi
# ────────────────────────────── 6. Model deployment ──────────────────────────
echo "🔧 6. Deploying model(s)"

# Function to create a ClusterIP service for KServe InferenceService
# KServe creates headless services which don't work well with Gateway API
create_gateway_service() {
  local inference_service=$1
  local namespace=$2
  
  echo "  Creating ClusterIP service for $inference_service..."
  cat << EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: ${inference_service}-gateway-svc
  namespace: ${namespace}
  labels:
    serving.kserve.io/inferenceservice: ${inference_service}
spec:
  type: ClusterIP
  ports:
  - name: http
    port: 80
    targetPort: 8080
    protocol: TCP
  selector:
    serving.kserve.io/inferenceservice: ${inference_service}
EOF
}

# GPU availability check for GPU models
if [[ "$MODEL_TYPE" == "qwen3" || "$MODEL_TYPE" == "all" ]] && [[ "$GPU_CHECK" == true ]]; then
  echo "🔍 Checking for GPU availability..."
  
  # Check for GPU nodes with actual GPU resources (not just labels)
  GPU_NODES=$(kubectl get nodes -o json | jq -r '.items[] | select(.status.capacity."nvidia.com/gpu" != null) | .metadata.name' 2>/dev/null | wc -l)
  
  if [[ "$GPU_NODES" -eq 0 ]]; then
    echo "❌ No GPU resources found in cluster!"
    echo "   Checking for GPU-labeled nodes..."
    
    # Check if there are nodes labeled for GPU but without resources
    GPU_LABELED_NODES=$(kubectl get nodes -l nvidia.com/gpu.present=true --no-headers 2>/dev/null | wc -l)
    if [[ "$GPU_LABELED_NODES" -gt 0 ]]; then
      echo "   ⚠️  Found $GPU_LABELED_NODES node(s) labeled for GPU but no GPU resources available"
      echo "   This might mean:"
      echo "   1. GPU operator is still initializing"
      echo "   2. GPU drivers are being installed"
      echo "   3. There's an issue with the GPU operator"
      echo ""
      echo "   Checking GPU operator status..."
      GPU_OPERATOR_POD=$(kubectl get pods -n nvidia-gpu-operator -l app=gpu-operator --no-headers 2>/dev/null | awk '{print $1}')
      if [[ -n "$GPU_OPERATOR_POD" ]]; then
        echo "   GPU operator pod: $GPU_OPERATOR_POD"
        kubectl logs -n nvidia-gpu-operator "$GPU_OPERATOR_POD" --tail=5 2>/dev/null | grep -E "error|Error|ERROR" || echo "   No recent errors in GPU operator logs"
        
        # Check for GPU driver pods
        DRIVER_PODS=$(kubectl get pods -n nvidia-gpu-operator | grep nvidia-driver-daemonset | grep -v Running | wc -l)
        if [[ "$DRIVER_PODS" -gt 0 ]]; then
          echo "   ⚠️  GPU driver pods are still initializing. This can take 5-10 minutes."
          echo "   Run this command to check status:"
          echo "   kubectl get pods -n nvidia-gpu-operator -o wide"
        fi
      fi
    fi
    
    echo ""
    echo "   Options:"
    echo "   1. Wait for GPU initialization and run again"
    echo "   2. Use --simulator flag instead (CPU-based)"
    echo "   3. Skip GPU check with --qwen3 (without --check-gpu)"
    exit 1
  else
    echo "✅ Found $GPU_NODES node(s) with GPU resources"
    kubectl get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.capacity.nvidia\\.com/gpu,TYPE:.metadata.labels.node\\.kubernetes\\.io/instance-type | grep -v "<none>"
  fi
fi

case "$MODEL_TYPE" in
  simulator)
    if [[ "$OCP" == true ]]; then
      kubectl apply -f ../model_serving/vllm-simulator-kserve-openshift.yaml
    else
      kubectl apply -f ../model_serving/vllm-simulator-kserve.yaml
    fi
    kubectl wait --for=condition=Ready inferenceservice/vllm-simulator -n "$NAMESPACE" --timeout=120s
    # Create proper ClusterIP service for Gateway routing
    create_gateway_service "vllm-simulator" "$NAMESPACE"
    
    # Update HTTPRoute to use the new service if on OpenShift with Gateway API
    if [[ "$OCP" == true ]] && [[ "$USE_GATEWAY_API" == true ]]; then
      kubectl patch httproute simulator-route -n llm --type=json -p='[{"op": "replace", "path": "/spec/rules/0/backendRefs/0/name", "value": "vllm-simulator-gateway-svc"}]' 2>/dev/null || true
    fi
    ;;
  qwen3)
    echo "🚀 Deploying GPU-optimized Qwen3 model..."
    
    # Clean up any existing failed deployment
    kubectl delete inferenceservice qwen3-0-6b-instruct -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null
    
    # Check if optimized GPU version exists
    if [[ -f "../model_serving/qwen3-0.6b-vllm-gpu.yaml" ]]; then
      echo "  Using GPU-optimized deployment configuration"
      kubectl apply -f ../model_serving/qwen3-0.6b-vllm-gpu.yaml
    elif [[ "$OCP" == true ]]; then
      kubectl apply -f ../model_serving/qwen3-0.6b-vllm-raw-openshift.yaml
    else
      kubectl apply -f ../model_serving/qwen3-0.6b-vllm-raw.yaml
    fi
    
    echo "  ⏳ Waiting for InferenceService to be ready..."
    
    # Wait for InferenceService with better error handling
    MAX_WAIT=600  # 10 minutes
    WAIT_TIME=0
    INTERVAL=15
    
    while [[ $WAIT_TIME -lt $MAX_WAIT ]]; do
      # Check if Ready
      if kubectl get inferenceservice qwen3-0-6b-instruct -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q "True"; then
        echo "  ✅ InferenceService is ready!"
        break
      fi
      
      # Check for errors
      ERROR_MSG=$(kubectl get inferenceservice qwen3-0-6b-instruct -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null)
      if [[ -n "$ERROR_MSG" ]]; then
        echo "  ⚠️  Status: $ERROR_MSG"
      fi
      
      # Check events for errors
      EVENTS=$(kubectl get events -n "$NAMESPACE" --field-selector involvedObject.name=qwen3-0-6b-instruct --sort-by='.lastTimestamp' | tail -3)
      if echo "$EVENTS" | grep -q "Error\|Failed\|Invalid"; then
        echo "  ⚠️  Recent events:"
        echo "$EVENTS" | tail -3 | sed 's/^/    /'
      fi
      
      # Check if pod exists
      POD_COUNT=$(kubectl get pods -n "$NAMESPACE" -l serving.kserve.io/inferenceservice=qwen3-0-6b-instruct --no-headers 2>/dev/null | wc -l)
      if [[ $POD_COUNT -eq 0 ]]; then
        echo "  ⏳ No pods created yet. Checking InferenceService status..."
        kubectl describe inferenceservice qwen3-0-6b-instruct -n "$NAMESPACE" | grep -A5 "Events:" | tail -5
      else
        POD_STATUS=$(kubectl get pods -n "$NAMESPACE" -l serving.kserve.io/inferenceservice=qwen3-0-6b-instruct --no-headers 2>/dev/null | awk '{print $3}')
        echo "  ⏳ Pod status: $POD_STATUS"
        
        # If pod is in error state, show logs
        if echo "$POD_STATUS" | grep -q "Error\|CrashLoopBackOff\|ImagePullBackOff"; then
          echo "  ❌ Pod is in error state. Recent logs:"
          POD_NAME=$(kubectl get pods -n "$NAMESPACE" -l serving.kserve.io/inferenceservice=qwen3-0-6b-instruct --no-headers 2>/dev/null | awk '{print $1}' | head -1)
          kubectl logs -n "$NAMESPACE" "$POD_NAME" --tail=10 2>/dev/null | sed 's/^/    /'
          echo "  ❌ Model deployment failed. Check the logs above for details."
          exit 1
        fi
      fi
      
      sleep $INTERVAL
      WAIT_TIME=$((WAIT_TIME + INTERVAL))
      
      # Show progress
      if [[ $((WAIT_TIME % 60)) -eq 0 ]]; then
        echo "  ⏳ Still waiting... ($((WAIT_TIME / 60)) minutes elapsed)"
        
        # For long waits, check if model is downloading
        if [[ $POD_COUNT -gt 0 ]]; then
          POD_NAME=$(kubectl get pods -n "$NAMESPACE" -l serving.kserve.io/inferenceservice=qwen3-0-6b-instruct --no-headers 2>/dev/null | awk '{print $1}' | head -1)
          if kubectl logs -n "$NAMESPACE" "$POD_NAME" 2>/dev/null | grep -q "Downloading.*Qwen"; then
            echo "  📥 Model is being downloaded from HuggingFace. This may take several minutes..."
          fi
        fi
      fi
    done
    
    if [[ $WAIT_TIME -ge $MAX_WAIT ]]; then
      echo "  ⚠️  Model deployment is taking longer than expected"
      echo "  Check pod status with: kubectl get pods -n $NAMESPACE"
      echo "  Check logs with: kubectl logs -n $NAMESPACE -l serving.kserve.io/inferenceservice=qwen3-0-6b-instruct"
      echo "  Continuing with service creation anyway..."
    fi
    
    # Create proper ClusterIP service for Gateway routing
    create_gateway_service "qwen3-0-6b-instruct" "$NAMESPACE"
    
    # Update HTTPRoute if it exists
    if [[ "$OCP" == true ]] && [[ "$USE_GATEWAY_API" == true ]]; then
      kubectl patch httproute qwen3-route -n llm --type=json -p='[{"op": "replace", "path": "/spec/rules/0/backendRefs/0/name", "value": "qwen3-0-6b-instruct-gateway-svc"}]' 2>/dev/null || true
    fi
    ;;
  all)
    if [[ "$OCP" == true ]]; then
      kubectl apply -f ../model_serving/vllm-simulator-kserve-openshift.yaml
    else
      kubectl apply -f ../model_serving/vllm-latest-runtime.yaml
      kubectl apply -f ../model_serving/vllm-simulator-kserve.yaml
    fi
    
    if [[ -f "../model_serving/qwen3-0.6b-vllm-gpu.yaml" ]]; then
      kubectl apply -f ../model_serving/qwen3-0.6b-vllm-gpu.yaml
    else
      kubectl apply -f ../model_serving/qwen3-0.6b-vllm-raw.yaml
    fi
    
    kubectl wait --for=condition=Ready inferenceservice/vllm-simulator       -n "$NAMESPACE" --timeout=120s
    create_gateway_service "vllm-simulator" "$NAMESPACE"
    
    echo "  ⏳ Waiting for GPU model..."
    kubectl wait --for=condition=Ready inferenceservice/qwen3-0-6b-instruct  -n "$NAMESPACE" --timeout=900s
    create_gateway_service "qwen3-0-6b-instruct" "$NAMESPACE"
    
    # Update HTTPRoutes if on OpenShift with Gateway API
    if [[ "$OCP" == true ]] && [[ "$USE_GATEWAY_API" == true ]]; then
      kubectl patch httproute simulator-route -n llm --type=json -p='[{"op": "replace", "path": "/spec/rules/0/backendRefs/0/name", "value": "vllm-simulator-gateway-svc"}]' 2>/dev/null || true
      kubectl patch httproute qwen3-route -n llm --type=json -p='[{"op": "replace", "path": "/spec/rules/0/backendRefs/0/name", "value": "qwen3-0-6b-instruct-gateway-svc"}]' 2>/dev/null || true
    fi
    ;;
esac

# ────────────────────────────── 7. Gateway policies ──────────────────────────
echo "🔧 7. Applying API-key auth & rate-limit policies"
kubectl apply -f 05-api-key-secrets.yaml

# Check if token-based rate limiting is requested
if [[ "$TOKEN_RATE_LIMIT" == true ]]; then
  echo "🔧 Configuring token-based rate limiting..."
  
  # Apply the token rate limiting EnvoyFilter
  if [[ -f "08-token-rate-limit-envoyfilter.yaml" ]]; then
    kubectl apply -f 08-token-rate-limit-envoyfilter.yaml
    echo "  ✅ Token-based rate limiting configured"
    echo "  Token limits per minute:"
    echo "    - Free tier: 200 tokens"
    echo "    - Premium tier: 1,000 tokens"
    echo "    - Enterprise tier: 5,000 tokens"
  else
    echo "  ⚠️  Token rate limit configuration not found"
    echo "  Using default request-based rate limiting"
    TOKEN_RATE_LIMIT=false
  fi
fi

if [[ "$OCP" == true ]]; then
  if [[ "$USE_GATEWAY_API" == true ]]; then
    echo "🔧 Configuring authentication and rate limiting with Gateway API..."
    
    # CRITICAL: Copy API key secrets to istio-system namespace where the Gateway is
    echo "📋 Copying API key secrets to istio-system namespace..."
    for secret in freeuser1-apikey freeuser2-apikey premiumuser1-apikey premiumuser2-apikey; do
      echo "  - Copying $secret"
      kubectl get secret $secret -n llm -o yaml 2>/dev/null | \
        sed 's/namespace: llm/namespace: istio-system/' | \
        kubectl apply -f - 2>/dev/null || echo "    ⚠️  Secret $secret not found or already exists"
    done
    
    # Apply policies in istio-system namespace (same as Gateway)
    echo "🔧 Applying AuthPolicy and RateLimitPolicy in istio-system..."
    # Apply AuthPolicy in istio-system namespace
    sed 's/namespace: llm/namespace: istio-system/' 06-auth-policies-apikey.yaml | kubectl apply -f -
    
    # Apply RateLimitPolicy in istio-system namespace
    sed 's/namespace: llm/namespace: istio-system/' 07-rate-limit-policies.yaml | kubectl apply -f -
    
    # Restart Kuadrant components to ensure policies are applied
    kubectl rollout restart deployment/authorino -n kuadrant-system
    kubectl rollout restart deployment/limitador-limitador -n kuadrant-system
    kubectl rollout restart deployment/kuadrant-operator-controller-manager -n kuadrant-system
    kubectl rollout status deployment/authorino -n kuadrant-system --timeout=60s
    kubectl rollout status deployment/limitador-limitador -n kuadrant-system --timeout=60s
    
    echo ""
    echo "✅ Gateway API configuration complete"
    echo "   - Authentication: ✅ ENABLED"
    echo "   - Rate Limiting: ✅ ENABLED (5 req/2min for free, 20 req/2min for premium)"
    echo "   - Policies and secrets in istio-system namespace"
    
  else
    echo "🔧 Configuring authentication for native Istio (ServiceMesh 2.6)..."
    
    # CRITICAL: Copy API key secrets to kuadrant-system namespace for Authorino to access them
    echo "📋 Copying API key secrets to kuadrant-system namespace..."
    for secret in freeuser1-apikey freeuser2-apikey premiumuser1-apikey premiumuser2-apikey; do
      echo "  - Copying $secret"
      kubectl get secret $secret -n llm -o yaml 2>/dev/null | \
        sed 's/namespace: llm/namespace: kuadrant-system/' | \
        kubectl apply -f - 2>/dev/null || echo "    ⚠️  Secret $secret not found or already exists"
    done
    
    # Apply EnvoyFilter for external authorization
    echo "🔧 Applying EnvoyFilter for authentication..."
    kubectl apply -f 06-istio-auth-envoyfilter.yaml
    
    # Apply AuthConfig for Authorino
    echo "🔧 Applying AuthConfig..."
    kubectl apply -f 06-authconfig-istio.yaml
    
    # Restart Istio ingress gateway to apply EnvoyFilter
    echo "🔄 Restarting Istio ingress gateway..."
    kubectl rollout restart deployment/istio-ingressgateway -n istio-system
    kubectl rollout status deployment/istio-ingressgateway -n istio-system --timeout=60s
    
    # Restart Authorino to ensure it picks up the new configuration
    echo "🔄 Restarting Authorino..."
    kubectl rollout restart deployment/authorino -n kuadrant-system
    kubectl rollout status deployment/authorino -n kuadrant-system --timeout=60s
    
    echo ""
    echo "⚠️  IMPORTANT: Native Istio authentication configured"
    echo "   - Secrets must be in kuadrant-system namespace"
    echo "   - Use format: Authorization: APIKEY <key> (note: no space after APIKEY)"
    echo "   - Authentication: ✅ WORKING"
    echo "   - Rate Limiting: ❌ NOT AVAILABLE (RateLimitPolicy doesn't support native Istio)"
  fi
else
  # For vanilla Kubernetes with Gateway API
  kubectl apply -f 06-auth-policies-apikey.yaml
  
  # Apply appropriate rate limiting
  if [[ "$TOKEN_RATE_LIMIT" == false ]]; then
    kubectl apply -f 07-rate-limit-policies.yaml
    echo ""
    echo "✅ Gateway API authentication and request-based rate limiting configured"
  else
    echo ""
    echo "✅ Gateway API authentication and token-based rate limiting configured"
  fi
fi

kubectl rollout restart deployment kuadrant-operator-controller-manager -n kuadrant-system
kubectl wait --for=condition=Available deployment/kuadrant-operator-controller-manager -n kuadrant-system --timeout=300s

# ────────────────────────────── 8. Observability ─────────────────────────────
if [[ "$SKIP_METRICS" == false && "$OCP" == false ]]; then
  echo "🔧 8. Installing Prometheus observability"
  
  # Install Prometheus Operator
  kubectl apply --server-side --field-manager=quickstart-installer -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/master/bundle.yaml
  
  # Wait for Prometheus Operator to be ready
  kubectl wait --for=condition=Available deployment/prometheus-operator -n default --timeout=300s
  
  # From models-aas/deployment/kuadrant Kuadrant prometheus observability
  kubectl apply -k kustomize/prometheus/
else
  if [[ "$SKIP_METRICS" == true ]]; then
    echo "⏭️  8. Skipping Prometheus observability (--skip-metrics flag)"
  else
    echo "⏭️  8. Skipping Prometheus observability (OCP should already have this installed)"
  fi
fi

# ────────────────────────────── 9. Verification ──────────────────────────────
echo "🔧 9. Verifying objects"
kubectl get gateway,httproute,authpolicy,ratelimitpolicy -n "$NAMESPACE"
kubectl get inferenceservice,pods -n "$NAMESPACE"

echo
echo "✅ MaaS installation complete!"
echo
echo "🔌 Port-forward the gateway in a separate terminal:"
echo "   kubectl port-forward -n $NAMESPACE svc/inference-gateway-istio 8000:80"
echo

if [[ "$SKIP_METRICS" == false && "$OCP" == false ]]; then
echo "📊 Access Prometheus metrics (in separate terminals):"
echo "   kubectl port-forward -n llm-observability svc/models-aas-observability 9090:9090"
echo "   kubectl port-forward -n kuadrant-system svc/limitador-limitador 8080:8080"
echo "   Then visit: http://localhost:9090 (Prometheus) and http://localhost:8080/metrics (Limitador)"
echo
fi
echo "🎯 Test examples:"

if [[ "$OCP" == true ]]; then
  # OpenShift with native Istio
  BASE_DOMAIN=$(oc whoami --show-server 2>/dev/null | sed 's/https:\/\/api\.//' | sed 's/:.*//') || BASE_DOMAIN="your-domain"
  echo ""
  echo "For OpenShift (native Istio):"
  if [[ "$MODEL_TYPE" == "simulator" || "$MODEL_TYPE" == "all" ]]; then
cat <<EOF
# Free tier – Simulator
curl -k -X POST https://simulator-route-llm.apps.$BASE_DOMAIN/v1/chat/completions \\
  -H 'Authorization: APIKEY freeuser1_key' \\
  -H 'Content-Type: application/json' \\
  -d '{"model":"simulator-model","messages":[{"role":"user","content":"Hello from free tier!"}]}'
EOF
  echo
  fi
  
  if [[ "$MODEL_TYPE" == "qwen3" || "$MODEL_TYPE" == "all" ]]; then
cat <<EOF
# Premium tier – Qwen3-0.6B
curl -k -X POST https://qwen3-route-llm.apps.$BASE_DOMAIN/v1/chat/completions \\
  -H 'Authorization: APIKEY premiumuser1_key' \\
  -H 'Content-Type: application/json' \\
  -d '{"model":"qwen3-0-6b-instruct","messages":[{"role":"user","content":"Hello! Write a Python function."}]}'
EOF
  echo
  fi
  
cat <<EOF
# Test authentication (should fail without API key)
curl -k -X POST https://simulator-route-llm.apps.$BASE_DOMAIN/v1/chat/completions \\
  -H 'Content-Type: application/json' \\
  -d '{"model":"simulator-model","messages":[{"role":"user","content":"No auth test"}]}'
EOF

else
  # Vanilla Kubernetes with Gateway API
  echo ""
  echo "For Kubernetes (Gateway API):"
  echo "First, port-forward the gateway:"
  echo "   kubectl port-forward -n $NAMESPACE svc/inference-gateway-istio 8000:80"
  echo ""
  
  if [[ "$MODEL_TYPE" == "simulator" || "$MODEL_TYPE" == "all" ]]; then
cat <<'EOF'
# Free tier (5 req/2 min) – Simulator
curl -H 'Authorization: APIKEY freeuser1_key' \
     -H 'Content-Type: application/json' \
     -d '{"model":"simulator-model","messages":[{"role":"user","content":"Hello from free tier!"}]}' \
     http://simulator.maas.local:8000/v1/chat/completions
EOF
  echo
  fi
  
  if [[ "$MODEL_TYPE" == "qwen3" || "$MODEL_TYPE" == "all" ]]; then
cat <<'EOF'
# Premium tier – Qwen3-0.6B
curl -H 'Authorization: APIKEY premiumuser1_key' \
     -H 'Content-Type: application/json' \
     -d '{"model":"qwen3-0-6b-instruct","messages":[{"role":"user","content":"Hello! Write a Python function."}]}' \
     http://qwen3.maas.local:8000/v1/chat/completions
EOF
  echo
  fi
  
cat <<'EOF'
# Un-authenticated request (should be blocked)
timeout 5 curl -H 'Content-Type: application/json' \
        -d '{"model":"simulator-model","messages":[{"role":"user","content":"Hello"}]}' \
        http://simulator.maas.local:8000/v1/chat/completions
EOF
fi

echo ""
echo "📊  Available API keys"
if [[ "$TOKEN_RATE_LIMIT" == true ]]; then
  echo "    Free:      freeuser1_key, freeuser2_key (200 tokens/min)"
  echo "    Premium:   premiumuser1_key, premiumuser2_key (1,000 tokens/min)"
  echo "    Enterprise: (future) (5,000 tokens/min)"
  echo ""
  echo "📈 Token counting:"
  echo "    - Response headers will include: x-tokens-used, x-tokens-limit, x-tokens-remaining"
  echo "    - Tokens are counted from model's 'usage' field in response"
else
  echo "    Free:      freeuser1_key, freeuser2_key (5 req/2 min)"
  echo "    Premium:   premiumuser1_key, premiumuser2_key (20 req/2 min)"
fi

if [[ "$OCP" == true ]]; then
  echo ""
  if [[ "$USE_GATEWAY_API" == true ]]; then
    echo "✅ Configuration: Gateway API with full authentication and rate limiting"
    echo "   - Gateway in istio-system namespace"
    echo "   - Policies in istio-system namespace"
    echo "   - Route in istio-system namespace"
    echo "   - Format: Authorization: APIKEY <key>"
    echo "   - Authentication: ✅ WORKING"
    echo "   - Rate Limiting: ✅ WORKING"
  else
    echo "⚠️  Configuration: Native Istio (authentication only)"
    echo "   - Using EnvoyFilter + AuthConfig"
    echo "   - Secrets in kuadrant-system namespace"
    echo "   - Format: Authorization: APIKEY <key> (no space after APIKEY)"
    echo "   - Authentication: ✅ WORKING"
    echo "   - Rate Limiting: ❌ NOT AVAILABLE (RateLimitPolicy doesn't support native Istio)"
  fi
  echo ""
  echo "   Test script available: ./test-maas-auth.sh"
else
  echo "    Forward the inference gateway with → kubectl port-forward -n llm svc/inference-gateway-istio 8000:80"
fi

echo "    🤖 Run an automated quota stress with → scripts/test-request-limits.sh"
echo
echo "🔥 Deploy complete"

if [[ "$OCP" == true ]]; then
  echo ""
  echo "⚠️ Please validate that you created your 'wasm-plugin-pull-secret' pull secret inside of $NAMESPACE"
  echo "More info here: https://developers.redhat.com/products/red-hat-connectivity-link/quick-setup"
fi

