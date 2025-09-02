# Prerequisites for MaaS Deployment

## Overview
This document outlines the prerequisites and known issues for deploying the Models-as-a-Service (MaaS) stack on OpenShift/Kubernetes clusters.

## Platform Requirements

### OpenShift (Recommended)
- **Version**: OpenShift 4.14+ (tested on 4.17)
- **Platform**: ROSA, ARO, or self-managed OpenShift
- **Why OpenShift**: Provides integrated Service Mesh, simplified operator management, and better GPU support

### Kubernetes (Alternative)
- **Version**: 1.28+
- **Additional Requirements**: Manual Istio installation via Helm

## Required Operators/Components

### 1. OpenShift Service Mesh (OpenShift Only)
- **Purpose**: Provides Istio functionality
- **Installation**: Via OperatorHub
- **Components**:
  - ServiceMeshControlPlane
  - ServiceMeshMemberRoll
  - Istio sidecars for service mesh functionality

### 2. OpenShift Serverless (OpenShift Only)
- **Purpose**: Provides Knative for KServe
- **Installation**: Via OperatorHub
- **Components**:
  - Knative Serving
  - Knative Eventing (optional)

### 3. Red Hat OpenShift AI (RHOAI)
- **Purpose**: Provides KServe and model serving capabilities
- **Installation**: Via OperatorHub
- **Components**:
  - DataScienceCluster
  - KServe controllers
  - Model serving runtimes

### 4. NVIDIA GPU Operator (For GPU Workloads)
- **Purpose**: Manages GPU drivers and device plugins
- **Version**: 23.9+ recommended
- **Installation**: Via OperatorHub or Helm
- **Components**:
  - GPU driver daemonset
  - Device plugin
  - DCGM exporter
  - GPU feature discovery

### 5. Gateway API
- **Purpose**: Modern ingress management
- **Version**: v1.0+
- **Installation**: Automatically installed by the script

### 6. Cert-Manager
- **Purpose**: Certificate management for TLS
- **Version**: v1.13+
- **Installation**: Automatically installed by the script

### 7. Kuadrant
- **Purpose**: API management, authentication, and rate limiting
- **Version**: Latest
- **Installation**: Via Helm (handled by script)
- **Components**:
  - Authorino (authentication)
  - Limitador (rate limiting)
  - Kuadrant operator

## Node Requirements

### CPU Nodes
- **Minimum**: 4 vCPUs, 16GB RAM
- **Recommended**: 8 vCPUs, 32GB RAM
- **Purpose**: Running operators, control plane, and CPU-based models

### GPU Nodes (Optional but Recommended)
- **Supported GPUs**:
  - NVIDIA Tesla T4 (tested, requires workarounds)
  - NVIDIA V100
  - NVIDIA A10
  - NVIDIA A100
- **Instance Types (AWS)**:
  - g4dn.xlarge (T4 GPU) - most cost-effective
  - p3.2xlarge (V100)
  - g5.xlarge (A10G)
- **Requirements**:
  - NVIDIA driver 525+ (automatically installed by GPU operator)
  - CUDA 12.0+ compatibility

## Storage Requirements
- **Persistent Volumes**: 100GB+ for model storage
- **EmptyDir**: Used for temporary caches (shm, tmp)
- **Storage Classes**: Default storage class must be configured

## Network Requirements
- **Ingress**: OpenShift Routes or Kubernetes Ingress
- **Service Mesh**: Istio-based networking
- **DNS**: Wildcard DNS for application routes
- **Ports**:
  - 80/443: HTTP/HTTPS traffic
  - 8080: Model serving endpoints
  - 15090: Istio metrics

## Known Issues and Resolutions

### Issue 1: GPU Operator on Managed OpenShift (ROSA/ARO)
- **Problem**: GPU operator fails to label namespace for monitoring
- **Solution**: 
  ```bash
  # Disable monitoring in ClusterPolicy
  kubectl patch clusterpolicy gpu-cluster-policy --type=merge -p '{"spec":{"dcgmExporter":{"serviceMonitor":{"enabled":false}}}}'
  
  # Label namespace to disable monitoring
  kubectl label namespace nvidia-gpu-operator openshift.io/cluster-monitoring=false
  ```

### Issue 2: Triton Compilation on Tesla T4 GPUs
- **Problem**: vLLM crashes with Triton kernel compilation errors
- **Solution**: Use vLLM v0.6.2 with specific environment variables:
  ```yaml
  env:
    - name: VLLM_USE_TRITON_ATTENTION
      value: "0"
    - name: VLLM_ATTENTION_BACKEND
      value: "XFORMERS"
    - name: VLLM_USE_TRITON_FLASH_ATTN
      value: "0"
  ```

### Issue 3: KServe Headless Service Issues
- **Problem**: Gateway API cannot route to headless services
- **Solution**: Create ClusterIP services for InferenceServices
  ```bash
  # Script creates gateway services automatically
  # Manual creation if needed:
  kubectl create service clusterip model-gateway-svc \
    --tcp=80:8080 \
    --selector=serving.kserve.io/inferenceservice=model-name
  ```

### Issue 4: Istio Sidecar Injection Conflicts
- **Problem**: Kuadrant pods stuck in init state
- **Solution**: Disable sidecar injection for kuadrant-system:
  ```bash
  kubectl label namespace kuadrant-system istio-injection=disabled
  ```

### Issue 5: HuggingFace StorageUri Not Supported
- **Problem**: KServe doesn't support hf:// protocol
- **Solution**: Use direct container specification with model name as argument

## Pre-Installation Checklist

- [ ] OpenShift cluster 4.14+ or Kubernetes 1.28+
- [ ] Cluster admin access
- [ ] Service Mesh operator installed (OpenShift)
- [ ] Serverless operator installed (OpenShift)
- [ ] RHOAI operator installed
- [ ] GPU operator installed (if using GPUs)
- [ ] Default storage class configured
- [ ] DNS wildcard domain available
- [ ] Sufficient node resources (CPU/Memory)
- [ ] GPU nodes available (optional)

## Quick Validation Commands

```bash
# Check OpenShift version
oc version

# Check operators (OpenShift)
oc get csv -n openshift-operators

# Check GPU resources
kubectl get nodes -L nvidia.com/gpu.present
kubectl get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.capacity.nvidia\\.com/gpu

# Check storage classes
kubectl get storageclass

# Check Service Mesh
kubectl get smcp -A
kubectl get smmr -A

# Check RHOAI
kubectl get datasciencecluster -A

# Validate Gateway API
kubectl get gatewayclasses
```

## Installation Order

1. Install required operators via OperatorHub (OpenShift) or Helm (Kubernetes)
2. Wait for operators to be ready
3. Run the installation script:
   ```bash
   ./install.sh --simulator  # For CPU-only deployment
   ./install.sh --qwen3 --check-gpu  # For GPU deployment
   ```

## Troubleshooting

### GPU Not Detected
```bash
# Check GPU operator logs
kubectl logs -n nvidia-gpu-operator deployment/gpu-operator

# Check driver installation
kubectl get pods -n nvidia-gpu-operator | grep driver

# Force GPU operator reconciliation
kubectl delete pod -n nvidia-gpu-operator -l app=gpu-operator
```

### Model Deployment Failures
```bash
# Check InferenceService status
kubectl describe inferenceservice model-name -n llm

# Check pod logs
kubectl logs -n llm -l serving.kserve.io/inferenceservice=model-name

# Check events
kubectl get events -n llm --sort-by='.lastTimestamp'
```

### Authentication/Rate Limiting Issues
```bash
# Check Kuadrant components
kubectl get pods -n kuadrant-system

# Check AuthPolicy
kubectl get authpolicy -A

# Check RateLimitPolicy
kubectl get ratelimitpolicy -A

# Test authentication
curl -k https://your-route/v1/models -H "Authorization: APIKEY your_key"
```

## Performance Tuning

### GPU Models
- Adjust `--gpu-memory-utilization` based on GPU memory
- Tune `--max-model-len` for context window
- Set `--max-num-seqs` based on concurrent requests
- Use `--dtype=float16` for T4 GPUs

### CPU Models
- Increase replica count for high availability
- Adjust memory limits based on model size
- Configure appropriate CPU requests/limits

## Security Considerations

- All models require API key authentication
- Rate limiting prevents abuse
- TLS termination at edge (OpenShift Routes)
- Network policies restrict inter-namespace communication
- Pod security contexts enforce non-root users

## Additional Resources

- [OpenShift Documentation](https://docs.openshift.com/)
- [KServe Documentation](https://kserve.github.io/)
- [Kuadrant Documentation](https://kuadrant.io/)
- [vLLM Documentation](https://docs.vllm.ai/)
- [NVIDIA GPU Operator](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/) 