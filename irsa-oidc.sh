#!/bin/bash

set -e

# ======= USER CONFIGURATION =======
CLUSTER_NAME="dtmcluster"
REGION="us-east-1"  
NAMESPACE="luit"
SERVICE_ACCOUNT_NAME="luitsa"
POLICY_NAME="EFSAccessPolicy"
ROLE_NAME="EKSIRSAEFSRole"
# ===================================

echo "🔍 Getting AWS account ID..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "🔍 Checking if OIDC provider is already associated with the EKS cluster..."
OIDC_URL=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" --query "cluster.identity.oidc.issuer" --output text)

if [[ "$OIDC_URL" == "null" ]]; then
  echo "⚙️ OIDC not found. Associating provider..."
  eksctl utils associate-iam-oidc-provider \
    --cluster "$CLUSTER_NAME" \
    --region "$REGION" \
    --approve
else
  echo "✅ OIDC is already associated: $OIDC_URL"
fi

# Strip "https://" for trust relationship
OIDC_HOSTPATH=$(echo "$OIDC_URL" | sed -e "s/^https:\/\///")

echo "📝 Creating IAM policy for EFS access..."
cat <<EOF > efs-access-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "elasticfilesystem:ClientMount",
        "elasticfilesystem:ClientWrite",
        "elasticfilesystem:ClientRootAccess"
      ],
      "Resource": "*"
    }
  ]
}
EOF

aws iam create-policy \
  --policy-name "$POLICY_NAME" \
  --policy-document file://efs-access-policy.json || echo "⚠️ Policy may already exist."

POLICY_ARN="arn:aws:iam::$ACCOUNT_ID:policy/$POLICY_NAME"

echo "🔐 Creating IAM role and trust relationship for IRSA..."
cat <<EOF > trust-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::$ACCOUNT_ID:oidc-provider/$OIDC_HOSTPATH"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "$OIDC_HOSTPATH:sub": "system:serviceaccount:$NAMESPACE:$SERVICE_ACCOUNT_NAME"
        }
      }
    }
  ]
}
EOF

aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document file://trust-policy.json || echo "⚠️ Role may already exist."

echo "📎 Attaching IAM policy to the role..."
aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn "$POLICY_ARN"

echo "🔗 Getting IAM role ARN..."
ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)

echo "🔧 Annotating Kubernetes service account for IRSA..."
kubectl annotate serviceaccount "$SERVICE_ACCOUNT_NAME" \
  -n "$NAMESPACE" \
  eks.amazonaws.com/role-arn="$ROLE_ARN" \
  --overwrite

echo "✅ DONE: OIDC configured, IAM role with EFS access created, and service account annotated."
