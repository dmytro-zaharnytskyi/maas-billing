#!/bin/bash

# Fix Model Serving for MinIO Setup
# This script removes the problematic ObjectBucketClaim and creates MinIO connection

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Fixing Model Serving for MinIO Setup${NC}"
echo -e "${YELLOW}=====================================${NC}"

# Step 1: Remove the problematic ObjectBucketClaim file
echo -e "${YELLOW}Step 1: Removing ObjectBucketClaim file...${NC}"
if [ -f "../model_serving/obc-rgw.yaml" ]; then
    mv "../model_serving/obc-rgw.yaml" "../model_serving/obc-rgw.yaml.bak"
    echo -e "${GREEN}✓ Moved obc-rgw.yaml to obc-rgw.yaml.bak${NC}"
else
    echo -e "${YELLOW}⚠ obc-rgw.yaml not found (already removed?)${NC}"
fi

# Step 2: Create MinIO connection secret
echo -e "${YELLOW}Step 2: Creating MinIO connection secret...${NC}"

# Get MinIO service endpoint
MINIO_ENDPOINT="minio-service.minio-system.svc.cluster.local:9000"
MINIO_REGION="us-east-1"
MINIO_BUCKET="models"
MINIO_ACCESS_KEY="minioadmin"
MINIO_SECRET_KEY="minioadmin"

# Create the aws-connection-models secret
kubectl create secret generic aws-connection-models -n llm \
  --from-literal=AWS_ACCESS_KEY_ID="$MINIO_ACCESS_KEY" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$MINIO_SECRET_KEY" \
  --from-literal=AWS_S3_ENDPOINT="http://$MINIO_ENDPOINT" \
  --from-literal=AWS_DEFAULT_REGION="$MINIO_REGION" \
  --from-literal=AWS_S3_BUCKET="$MINIO_BUCKET" \
  --dry-run=client -o yaml | kubectl apply -f -

echo -e "${GREEN}✓ Created aws-connection-models secret for MinIO${NC}"

# Step 3: Create a simple bucket in MinIO (using kubectl port-forward)
echo -e "${YELLOW}Step 3: Creating models bucket in MinIO...${NC}"

# Start port-forward in background
kubectl port-forward svc/minio-service -n minio-system 9000:9000 &
PF_PID=$!
sleep 5

# Create bucket using mc (MinIO client)
if command -v mc &> /dev/null; then
    mc alias set localminio http://localhost:9000 minioadmin minioadmin
    mc mb localminio/models --ignore-existing
    echo -e "${GREEN}✓ Created models bucket in MinIO${NC}"
else
    echo -e "${YELLOW}⚠ mc (MinIO client) not found. You'll need to create the 'models' bucket manually${NC}"
    echo -e "   Use: kubectl port-forward svc/minio-service -n minio-system 9000:9000"
    echo -e "   Then visit: http://localhost:9000 (admin/minioadmin)"
fi

# Kill port-forward
kill $PF_PID 2>/dev/null || true

# Step 4: Show what was done
echo -e "\n${GREEN}✅ Model Serving Fix Complete!${NC}"
echo -e "\n${YELLOW}What was fixed:${NC}"
echo -e "• Removed ObjectBucketClaim (obc-rgw.yaml) - not needed for MinIO"
echo -e "• Created aws-connection-models secret pointing to MinIO"
echo -e "• Set up models bucket in MinIO"

echo -e "\n${YELLOW}You can now deploy model serving:${NC}"
echo -e "kubectl apply -f ../model_serving/ -n llm"

echo -e "\n${YELLOW}Or use mock models for testing:${NC}"
echo -e "kubectl apply -f local-model-serving.yaml"