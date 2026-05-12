#!/bin/bash
set -e  # Exit on error

# ==================== CONFIGURE HERE ====================
AWS_REGION="us-west-2"
CLUSTER_NAME="juice-shop"
ECR_REPO_NAME="juice-shop-repo"
DEPLOYMENT_YAML="k8s-src/juice-shop-deploy.yaml"
SERVICE_YAML="k8s-src/juice-shop-service.yaml"
NODEGROUP_NAME="juice-shop-bottlerocket-group"
INSTANCE_TYPE="t4g.medium"  # ARM64 instance type
IMAGE_TAG="juice-shop-app"
# ==================== CONFIGURATION END ====================

# ✅ Ensure AWS Credentials Are Set
echo "🔹 Checking AWS credentials..."
if ! aws sts get-caller-identity > /dev/null 2>&1; then
    echo "❌ AWS credentials are invalid or expired. Let's configure them."
    aws configure
fi
echo "✅ AWS credentials verified."

# ✅ Check if EKS Cluster exists
echo "🔹 Checking if EKS cluster $CLUSTER_NAME exists..."
if eksctl get cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" > /dev/null 2>&1; then
    echo "✅ EKS cluster $CLUSTER_NAME already exists. Skipping creation."
else
    echo "🚀 Creating EKS cluster control plane..."
    eksctl create cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --without-nodegroup
    echo "✅ EKS control plane created."
fi

# ✅ Add a Bottlerocket Node Group
echo "🚀 Adding Bottlerocket node group..."
eksctl create nodegroup --cluster "$CLUSTER_NAME" \
    --name "$NODEGROUP_NAME" \
    --region "$AWS_REGION" \
    --node-type "$INSTANCE_TYPE" \
    --nodes 2 \
    --node-ami-family Bottlerocket \
    || echo "✅ Bottlerocket node group already exists. Skipping creation."
echo "✅ Bottlerocket node group deployed."

# ✅ Update kubeconfig
echo "🔹 Updating kubeconfig for kubectl access..."
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME"
echo "✅ kubeconfig updated."

# ✅ Verify Nodes Are ARM64 & Running Bottlerocket
echo "🔹 Checking node status..."
kubectl get nodes -o custom-columns="NAME:.metadata.name,ARCH:.status.nodeInfo.architecture,OS:.status.nodeInfo.osImage"

# ✅ Get IAM Role for Worker Nodes
echo "🔹 Fetching IAM role for worker nodes..."
NODE_ROLE_ARN=$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP_NAME" --query "nodegroup.nodeRole" --output text --region "$AWS_REGION")
if [ -z "$NODE_ROLE_ARN" ]; then
    echo "❌ ERROR: Could not determine the IAM role for worker nodes. Exiting."
    exit 1
fi
echo "✅ IAM Role detected: $NODE_ROLE_ARN"
NODE_ROLE_NAME=$(echo "$NODE_ROLE_ARN" | awk -F'/' '{print $NF}')

# ✅ Ensure worker nodes have ECR access
echo "🔹 Checking IAM policies for worker nodes..."
if ! aws iam list-attached-role-policies --role-name "$NODE_ROLE_NAME" --query "AttachedPolicies[*].PolicyArn" --output text | grep -q "AmazonEC2ContainerRegistryReadOnly"; then
    echo "🚀 Attaching ECR ReadOnly policy to worker node IAM role..."
    aws iam attach-role-policy --role-name "$NODE_ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
    echo "✅ ECR ReadOnly policy attached."
else
    echo "✅ Worker nodes already have ECR ReadOnly policy."
fi

# ✅ Retrieve or Create ECR Repository
echo "🔹 Checking ECR repository..."
ECR_URI=$(aws ecr describe-repositories --repository-names "$ECR_REPO_NAME" --region "$AWS_REGION" --query 'repositories[0].repositoryUri' --output text 2>/dev/null || echo "")
if [ -z "$ECR_URI" ]; then
    echo "🚀 Creating ECR repository..."
    ECR_URI=$(aws ecr create-repository --repository-name "$ECR_REPO_NAME" --region "$AWS_REGION" --query 'repository.repositoryUri' --output text)
    echo "✅ ECR repository created: $ECR_URI"
else
    echo "✅ ECR repository exists: $ECR_URI"
fi

# ✅ Authenticate Docker with ECR
echo "🔹 Logging in to Amazon ECR..."
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_URI"
echo "✅ Docker authenticated with ECR."

# ✅ Build & Push Docker Image
echo "🚀 Building and pushing Juice Shop Docker image..."
docker build -t "$ECR_URI:$IMAGE_TAG" .
docker push "$ECR_URI:$IMAGE_TAG"
echo "✅ Docker image pushed to ECR."

# ✅ Ensure Kubernetes Deployment Uses Correct Image
echo "🔹 Updating Kubernetes manifests..."
if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "s|<ECR_IMAGE>|$ECR_URI:$IMAGE_TAG|g" "$DEPLOYMENT_YAML"
else
    sed -i "s|<ECR_IMAGE>|$ECR_URI:$IMAGE_TAG|g" "$DEPLOYMENT_YAML"
fi
echo "✅ Deployment YAML updated with correct image."

# ✅ Deploy Juice Shop to EKS
echo "🚀 Deploying Juice Shop to EKS..."
kubectl apply -f "$DEPLOYMENT_YAML"
kubectl apply -f "$SERVICE_YAML"
echo "✅ Juice Shop application deployed."

# ✅ Final Verification
echo "🚀 All done! Run the following command to check pod status:"
echo "kubectl get pods -o wide"
