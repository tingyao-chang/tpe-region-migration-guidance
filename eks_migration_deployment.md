# EKS 跨區域遷移部署指南

## 概述

本指南提供 EKS 叢集從 Tokyo Region → Taipei Region 遷移的具體執行命令和腳本。

## 前置準備

### 環境變數設定

```bash
# 1. 複製設定檔範本
cp config.sh.example config.sh

# 2. 編輯 config.sh 填入實際值
# 必要設定：
# - CLUSTER_NAME: EKS 叢集名稱
# - VPC_NAME: 目標區域的 VPC 名稱
# 選用設定：
# - DB_INSTANCE_ID: 如果有 RDS 資料庫需要遷移
# - DOMAIN_NAME, HOSTED_ZONE_ID: 如果需要 DNS 流量切換

# 3. 驗證設定
./config.sh
```

### VPC 基礎設施準備

```bash
# 載入共用函數
source common_functions.sh
load_config
validate_basic_config

# 方案 A：複製來源區域 VPC 設定（推薦）
./replicate_vpc_from_source.sh

# 方案 B：建立全新 VPC
./create_new_vpc.sh

# 驗證 VPC 資源
get_vpc_resources
```

## EKS 遷移步驟

### 1. 匯出 EKS 叢集設定

```bash
#!/bin/bash
# export_eks_config.sh
source common_functions.sh
load_config
validate_basic_config

echo "📤 匯出 EKS 叢集設定..."

# 驗證 EKS 特定設定
if [[ -z "$CLUSTER_NAME" ]]; then
    echo "❌ 錯誤：CLUSTER_NAME 未設定"
    exit 1
fi

# 1. 匯出叢集基本設定
aws eks describe-cluster \
  --name $CLUSTER_NAME \
  --region $SOURCE_REGION \
  --query 'cluster.{name:name,version:version,roleArn:roleArn,resourcesVpcConfig:resourcesVpcConfig,logging:logging,encryptionConfig:encryptionConfig,tags:tags}' \
  > eks-cluster-config.json

echo "叢集設定已匯出到 eks-cluster-config.json"

# 2. 匯出節點群組設定
aws eks list-nodegroups \
  --cluster-name $CLUSTER_NAME \
  --region $SOURCE_REGION \
  --query 'nodegroups' \
  --output text | while read nodegroup; do
    echo "匯出節點群組: $nodegroup"
    aws eks describe-nodegroup \
      --cluster-name $CLUSTER_NAME \
      --nodegroup-name $nodegroup \
      --region $SOURCE_REGION \
      --query 'nodegroup.{nodegroupName:nodegroupName,scalingConfig:scalingConfig,instanceTypes:instanceTypes,amiType:amiType,capacityType:capacityType,diskSize:diskSize,remoteAccess:remoteAccess,labels:labels,taints:taints,tags:tags}' \
      > "nodegroup-${nodegroup}-config.json"
done

# 3. 匯出 Fargate 設定檔（如果有）
aws eks list-fargate-profiles \
  --cluster-name $CLUSTER_NAME \
  --region $SOURCE_REGION \
  --query 'fargateProfileNames' \
  --output text | while read profile; do
    if [ "$profile" != "None" ]; then
        echo "匯出 Fargate 設定檔: $profile"
        aws eks describe-fargate-profile \
          --cluster-name $CLUSTER_NAME \
          --fargate-profile-name $profile \
          --region $SOURCE_REGION \
          --query 'fargateProfile.{fargateProfileName:fargateProfileName,podExecutionRoleArn:podExecutionRoleArn,subnets:subnets,selectors:selectors,tags:tags}' \
          > "fargate-${profile}-config.json"
    fi
done

# 4. 匯出附加元件設定
aws eks list-addons \
  --cluster-name $CLUSTER_NAME \
  --region $SOURCE_REGION \
  --query 'addons' \
  --output text | while read addon; do
    echo "匯出附加元件: $addon"
    aws eks describe-addon \
      --cluster-name $CLUSTER_NAME \
      --addon-name $addon \
      --region $SOURCE_REGION \
      --query 'addon.{addonName:addonName,addonVersion:addonVersion,configurationValues:configurationValues,tags:tags}' \
      > "addon-${addon}-config.json"
done

echo "✅ EKS 叢集設定匯出完成！"
```

### 2. 修改區域特定設定

```bash
#!/bin/bash
# modify_eks_config.sh
source common_functions.sh
load_config
validate_basic_config

echo "🔧 修改區域特定設定..."

# 獲取 VPC 資源
get_vpc_resources

# 建立 EKS 安全群組
EKS_SECURITY_GROUP_ID=$(create_or_get_security_group "EKS-Cluster" "eks-cluster-sg" "Security group for EKS cluster migration")
add_security_group_rules $EKS_SECURITY_GROUP_ID "app"

# 設定變數供後續使用
TARGET_SUBNET_IDS="$PRIVATE_SUBNET_IDS $PUBLIC_SUBNET_IDS"
TARGET_SECURITY_GROUP_ID="$EKS_SECURITY_GROUP_ID"

# 更新叢集設定檔
jq --arg subnets "$(echo $TARGET_SUBNET_IDS | tr ' ' ',')" \
   --arg sg "$TARGET_SECURITY_GROUP_ID" \
   '.resourcesVpcConfig.subnetIds = ($subnets | split(",")) | 
    .resourcesVpcConfig.securityGroupIds = [$sg]' \
   eks-cluster-config.json > eks-cluster-config-modified.json

# 更新節點群組設定檔
for nodegroup_file in nodegroup-*-config.json; do
    if [ -f "$nodegroup_file" ]; then
        echo "更新節點群組設定: $nodegroup_file"
        jq --arg subnets "$(echo $PRIVATE_SUBNET_IDS | tr ' ' ',')" \
           '.subnets = ($subnets | split(","))' \
           "$nodegroup_file" > "${nodegroup_file%.json}-modified.json"
    fi
done

# 更新 Fargate 設定檔
for fargate_file in fargate-*-config.json; do
    if [ -f "$fargate_file" ]; then
        echo "更新 Fargate 設定: $fargate_file"
        jq --arg subnets "$(echo $PRIVATE_SUBNET_IDS | tr ' ' ',')" \
           '.subnets = ($subnets | split(","))' \
           "$fargate_file" > "${fargate_file%.json}-modified.json"
    fi
done

echo "✅ 區域特定設定修改完成！"
```

### 3. 部署到 Taipei Region

```bash
#!/bin/bash
# deploy_eks_cluster.sh
source common_functions.sh
load_config
validate_basic_config

echo "🚀 在 Taipei Region 部署 EKS 叢集..."

# 1. 建立 EKS 叢集
CLUSTER_CONFIG=$(cat eks-cluster-config-modified.json)

aws eks create-cluster \
  --region $TARGET_REGION \
  --name $(echo $CLUSTER_CONFIG | jq -r '.name') \
  --version $(echo $CLUSTER_CONFIG | jq -r '.version') \
  --role-arn $(echo $CLUSTER_CONFIG | jq -r '.roleArn') \
  --resources-vpc-config "$(echo $CLUSTER_CONFIG | jq -c '.resourcesVpcConfig')" \
  --logging "$(echo $CLUSTER_CONFIG | jq -c '.logging // {}')" \
  --tags "$(echo $CLUSTER_CONFIG | jq -c '.tags // {}')"

# 2. 等待叢集建立完成
echo "⏳ 等待 EKS 叢集建立完成..."
aws eks wait cluster-active \
  --name $CLUSTER_NAME \
  --region $TARGET_REGION

echo "✅ EKS 叢集建立完成！"

# 3. 建立節點群組
for nodegroup_file in nodegroup-*-modified.json; do
    if [ -f "$nodegroup_file" ]; then
        echo "建立節點群組: $nodegroup_file"
        
        NODEGROUP_CONFIG=$(cat "$nodegroup_file")
        NODEGROUP_NAME=$(echo $NODEGROUP_CONFIG | jq -r '.nodegroupName')
        
        aws eks create-nodegroup \
          --region $TARGET_REGION \
          --cluster-name $CLUSTER_NAME \
          --nodegroup-name $NODEGROUP_NAME \
          --scaling-config "$(echo $NODEGROUP_CONFIG | jq -c '.scalingConfig')" \
          --instance-types "$(echo $NODEGROUP_CONFIG | jq -c '.instanceTypes')" \
          --ami-type "$(echo $NODEGROUP_CONFIG | jq -r '.amiType')" \
          --capacity-type "$(echo $NODEGROUP_CONFIG | jq -r '.capacityType')" \
          --disk-size "$(echo $NODEGROUP_CONFIG | jq -r '.diskSize')" \
          --subnets "$(echo $NODEGROUP_CONFIG | jq -c '.subnets')" \
          --node-role "$(echo $NODEGROUP_CONFIG | jq -r '.nodeRole')" \
          --labels "$(echo $NODEGROUP_CONFIG | jq -c '.labels // {}')" \
          --tags "$(echo $NODEGROUP_CONFIG | jq -c '.tags // {}')"
        
        # 等待節點群組建立完成
        echo "⏳ 等待節點群組 $NODEGROUP_NAME 建立完成..."
        aws eks wait nodegroup-active \
          --cluster-name $CLUSTER_NAME \
          --nodegroup-name $NODEGROUP_NAME \
          --region $TARGET_REGION
    fi
done

# 4. 建立 Fargate 設定檔
for fargate_file in fargate-*-modified.json; do
    if [ -f "$fargate_file" ]; then
        echo "建立 Fargate 設定檔: $fargate_file"
        
        FARGATE_CONFIG=$(cat "$fargate_file")
        FARGATE_NAME=$(echo $FARGATE_CONFIG | jq -r '.fargateProfileName')
        
        aws eks create-fargate-profile \
          --region $TARGET_REGION \
          --cluster-name $CLUSTER_NAME \
          --fargate-profile-name $FARGATE_NAME \
          --pod-execution-role-arn "$(echo $FARGATE_CONFIG | jq -r '.podExecutionRoleArn')" \
          --subnets "$(echo $FARGATE_CONFIG | jq -c '.subnets')" \
          --selectors "$(echo $FARGATE_CONFIG | jq -c '.selectors')" \
          --tags "$(echo $FARGATE_CONFIG | jq -c '.tags // {}')"
        
        # 等待 Fargate 設定檔建立完成
        echo "⏳ 等待 Fargate 設定檔 $FARGATE_NAME 建立完成..."
        aws eks wait fargate-profile-active \
          --cluster-name $CLUSTER_NAME \
          --fargate-profile-name $FARGATE_NAME \
          --region $TARGET_REGION
    fi
done

# 5. 安裝附加元件
for addon_file in addon-*-config.json; do
    if [ -f "$addon_file" ]; then
        echo "安裝附加元件: $addon_file"
        
        ADDON_CONFIG=$(cat "$addon_file")
        ADDON_NAME=$(echo $ADDON_CONFIG | jq -r '.addonName')
        
        aws eks create-addon \
          --region $TARGET_REGION \
          --cluster-name $CLUSTER_NAME \
          --addon-name $ADDON_NAME \
          --addon-version "$(echo $ADDON_CONFIG | jq -r '.addonVersion')" \
          --configuration-values "$(echo $ADDON_CONFIG | jq -r '.configurationValues // ""')" \
          --tags "$(echo $ADDON_CONFIG | jq -c '.tags // {}')"
    fi
done

echo "✅ EKS 叢集部署完成！"

# 6. 更新 kubeconfig
aws eks update-kubeconfig \
  --region $TARGET_REGION \
  --name $CLUSTER_NAME

echo "✅ kubeconfig 已更新，可以使用 kubectl 連接到新叢集"
```

### 4. Kubernetes 應用程式遷移

```bash
#!/bin/bash
# migrate_k8s_apps.sh
source config.sh

SOURCE_CLUSTER_CONTEXT="arn:aws:eks:$SOURCE_REGION:$AWS_ACCOUNT_ID:cluster/$CLUSTER_NAME"
TARGET_CLUSTER_CONTEXT="arn:aws:eks:$TARGET_REGION:$AWS_ACCOUNT_ID:cluster/$CLUSTER_NAME"

echo "🔄 遷移 Kubernetes 應用程式..."

# 1. 設定 kubectl context
kubectl config use-context $SOURCE_CLUSTER_CONTEXT

# 2. 匯出所有 Kubernetes 資源（排除系統命名空間）
echo "📤 匯出 Kubernetes 資源..."
kubectl get all,configmap,secret,pvc,ingress \
  --all-namespaces \
  --export -o yaml \
  --ignore-not-found=true \
  --field-selector metadata.namespace!=kube-system,metadata.namespace!=kube-public,metadata.namespace!=kube-node-lease \
  > k8s-resources-export.yaml

# 3. 自動修改映像路徑和資料庫設定
echo "🔧 修改容器映像路徑和資料庫設定..."
sed "s/ap-northeast-1/ap-east-2/g" k8s-resources-export.yaml | \
sed "s/${DB_INSTANCE_ID}/${DB_INSTANCE_ID}-tpe/g" > k8s-resources-modified.yaml

# 4. 部署到目標叢集
echo "🚀 部署到目標叢集..."
kubectl config use-context $TARGET_CLUSTER_CONTEXT

# 先建立命名空間
kubectl get namespaces -o yaml --export | kubectl apply -f -

# 部署所有資源
kubectl apply -f k8s-resources-modified.yaml

# 5. 驗證部署狀態
echo "🔍 驗證部署狀態..."
kubectl get pods --all-namespaces
kubectl get services --all-namespaces

echo "✅ Kubernetes 應用程式遷移完成！"
```

## 驗證和測試

### 驗證 EKS 遷移

```bash
#!/bin/bash
# verify_eks_migration.sh
source config.sh

echo "🔍 驗證 EKS 遷移狀態..."

# 1. 檢查叢集狀態
echo "檢查叢集狀態："
aws eks describe-cluster \
  --name $CLUSTER_NAME \
  --region $TARGET_REGION \
  --query 'cluster.{Name:name,Status:status,Version:version,Endpoint:endpoint}'

# 2. 檢查節點群組狀態
echo "檢查節點群組狀態："
aws eks list-nodegroups \
  --cluster-name $CLUSTER_NAME \
  --region $TARGET_REGION \
  --query 'nodegroups' \
  --output text | while read nodegroup; do
    aws eks describe-nodegroup \
      --cluster-name $CLUSTER_NAME \
      --nodegroup-name $nodegroup \
      --region $TARGET_REGION \
      --query 'nodegroup.{Name:nodegroupName,Status:status,DesiredSize:scalingConfig.desiredSize,CurrentSize:scalingConfig.currentSize}'
done

# 3. 檢查 Pod 狀態
echo "檢查 Pod 狀態："
kubectl get pods --all-namespaces --field-selector=status.phase!=Running

# 4. 檢查服務端點
echo "檢查服務端點："
kubectl get services --all-namespaces -o wide

# 5. 執行健康檢查
echo "執行健康檢查："
kubectl get nodes
kubectl top nodes 2>/dev/null || echo "Metrics server 未安裝"

echo "✅ EKS 遷移驗證完成！"
```

## 流量切換

### DNS 流量切換

```bash
#!/bin/bash
# switch_dns_traffic.sh
source config.sh

SERVICE_TYPE="eks"
DOMAIN_NAME="your-domain.com"  # 替換為實際域名

echo "🔄 開始 DNS 流量切換..."

# 獲取目標端點
TARGET_ENDPOINT=$(kubectl get service -n default your-service -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

if [[ -z "$TARGET_ENDPOINT" ]]; then
    echo "錯誤：無法獲取目標服務端點"
    exit 1
fi

echo "目標端點: $TARGET_ENDPOINT"

# 漸進式流量切換（從 10% 開始）
for weight in 10 25 50 75 100; do
    echo "切換 $weight% 流量到 Taipei Region..."
    
    aws route53 change-resource-record-sets \
      --hosted-zone-id $HOSTED_ZONE_ID \
      --change-batch "{
        \"Changes\": [{
          \"Action\": \"UPSERT\",
          \"ResourceRecordSet\": {
            \"Name\": \"$DOMAIN_NAME\",
            \"Type\": \"CNAME\",
            \"SetIdentifier\": \"Taipei-$SERVICE_TYPE\",
            \"Weight\": $weight,
            \"TTL\": 60,
            \"ResourceRecords\": [{\"Value\": \"$TARGET_ENDPOINT\"}]
          }
        }]
      }"
    
    echo "等待 2 分鐘觀察流量..."
    sleep 120
    
    # 檢查健康狀態
    curl -f "http://$TARGET_ENDPOINT/health" || echo "健康檢查失敗"
done

echo "✅ DNS 流量切換完成！"
```

## 回滾程序

### 緊急回滾

```bash
#!/bin/bash
# emergency_rollback.sh
source config.sh

SERVICE_TYPE="eks"
DOMAIN_NAME="your-domain.com"

echo "🚨 執行緊急回滾..."

# 立即將所有流量切回來源區域
aws route53 change-resource-record-sets \
  --hosted-zone-id $HOSTED_ZONE_ID \
  --change-batch "{
    \"Changes\": [{
      \"Action\": \"UPSERT\",
      \"ResourceRecordSet\": {
        \"Name\": \"$DOMAIN_NAME\",
        \"Type\": \"CNAME\",
        \"SetIdentifier\": \"Tokyo-$SERVICE_TYPE\",
        \"Weight\": 100,
        \"TTL\": 60,
        \"ResourceRecords\": [{\"Value\": \"$SOURCE_ENDPOINT\"}]
      }
    }]
  }"

echo "✅ 緊急回滾完成！流量已切回 Tokyo Region"
```

## 完整遷移腳本

```bash
#!/bin/bash
# complete_eks_migration.sh
source common_functions.sh
load_config
validate_basic_config

echo "🚀 開始完整 EKS 遷移流程..."

# 1. 設定 ECR 複製（背景執行）
if [[ "$ECR_REPLICATION_ENABLED" == "true" ]]; then
    setup_ecr_replication &
    ECR_PID=$!
fi

# 2. 遷移 RDS 資料庫（如果需要）
if [[ "$RDS_MIGRATION_ENABLED" == "true" && -n "$DB_INSTANCE_ID" ]]; then
    migrate_rds_database &
    RDS_PID=$!
fi

# 3. 匯出設定
./export_eks_config.sh

# 4. 修改設定
./modify_eks_config.sh

# 5. 部署叢集
./deploy_eks_cluster.sh

# 6. 遷移應用程式
./migrate_k8s_apps.sh

# 7. 等待背景任務完成
if [[ -n "$ECR_PID" ]]; then
    wait $ECR_PID
    echo "✅ ECR 複製完成"
fi

if [[ -n "$RDS_PID" ]]; then
    wait $RDS_PID
    echo "✅ RDS 遷移完成"
fi

# 8. 驗證遷移
verify_migration_status "eks"

echo "✅ EKS 遷移完成！"
echo "下一步：執行流量切換"
echo "  ./switch_dns_traffic.sh"
```

## 使用說明

### 快速開始

```bash
# 1. 設定環境變數
cp config.sh.example config.sh
# 編輯 config.sh 填入實際值

# 2. 驗證設定
./config.sh

# 3. 準備 VPC 基礎設施
source common_functions.sh
load_config
get_vpc_resources

# 4. 執行完整遷移
./complete_eks_migration.sh

# 5. 執行流量切換（如果設定了 DNS）
if [[ -n "$HOSTED_ZONE_ID" ]]; then
    # 獲取 EKS 服務端點
    TARGET_ENDPOINT=$(kubectl get service -n default your-service -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    source common_functions.sh
    switch_dns_traffic "eks" "$TARGET_ENDPOINT"
fi

# 6. 如需回滾
# emergency_rollback "eks" "$SOURCE_ENDPOINT"
```

### 注意事項

1. **權限要求**：確保 AWS CLI 具備 EKS、EC2、IAM 的完整權限
2. **kubectl 版本**：確保 kubectl 版本與 EKS 叢集版本相容
3. **網路連通性**：確保目標區域的網路配置正確
4. **資料庫連線**：確認應用程式能正確連接到遷移後的資料庫
5. **監控設定**：遷移後重新配置 CloudWatch 和其他監控工具

### 故障排除

- **叢集建立失敗**：檢查 IAM 角色權限和 VPC 配置
- **節點群組無法啟動**：確認子網路有足夠的 IP 地址
- **Pod 無法啟動**：檢查映像路徑和環境變數設定
- **服務無法訪問**：驗證安全群組和網路 ACL 設定

### 清理

```bash
# 清理暫存檔案
source common_functions.sh
cleanup_temp_files
```
