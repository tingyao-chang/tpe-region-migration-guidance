# ECS 跨區域遷移部署指南

## 概述

本指南提供 ECS 服務從 Tokyo Region → Taipei Region 遷移的具體執行命令和腳本。

## 前置準備

### 環境變數設定

```bash
#!/bin/bash
# config.sh - 設定環境變數
export SOURCE_REGION="ap-northeast-1"
export TARGET_REGION="ap-east-2"
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export CLUSTER_NAME="your-cluster"
export DB_INSTANCE_ID="your-db-instance"

# VPC 相關設定
export VPC_NAME="migration-vpc"
export VPC_CIDR="10.0.0.0/16"

# 驗證必要參數
validate_config() {
    local errors=()
    
    if [[ -z "$SOURCE_REGION" ]]; then
        errors+=("SOURCE_REGION 未設定")
    fi
    
    if [[ -z "$TARGET_REGION" ]]; then
        errors+=("TARGET_REGION 未設定")
    fi
    
    if [[ -z "$AWS_ACCOUNT_ID" ]]; then
        errors+=("無法獲取 AWS_ACCOUNT_ID，請檢查 AWS CLI 設定")
    fi
    
    if [[ -z "$CLUSTER_NAME" ]]; then
        errors+=("CLUSTER_NAME 未設定")
    fi
    
    if [[ -z "$DB_INSTANCE_ID" ]]; then
        errors+=("DB_INSTANCE_ID 未設定")
    fi
    
    if [[ ${#errors[@]} -gt 0 ]]; then
        echo "❌ 設定錯誤："
        printf '  - %s\n' "${errors[@]}"
        exit 1
    fi
    
    echo "✅ 設定驗證通過"
}

# 執行驗證
validate_config

# 載入設定
source config.sh
```

### VPC 基礎設施準備

請參考主要部署指南中的 VPC 準備步驟，或使用以下快速腳本：

```bash
# 複製來源區域 VPC 設定
./replicate_vpc_from_source.sh

# 或建立全新 VPC
./create_new_vpc.sh
```

## ECS 遷移步驟

### 1. 匯出 ECS 叢集設定

```bash
#!/bin/bash
# export_ecs_config.sh
source config.sh

echo "📤 匯出 ECS 叢集設定..."

# 1. 匯出叢集設定
aws ecs describe-clusters \
  --clusters $CLUSTER_NAME \
  --region $SOURCE_REGION \
  --query 'clusters[0].{clusterName:clusterName,tags:tags,settings:settings,configuration:configuration}' \
  > ecs-cluster-config.json

echo "叢集設定已匯出到 ecs-cluster-config.json"

# 2. 匯出所有服務設定
aws ecs list-services \
  --cluster $CLUSTER_NAME \
  --region $SOURCE_REGION \
  --query 'serviceArns' \
  --output text | while read service_arn; do
    service_name=$(basename $service_arn)
    echo "匯出服務: $service_name"
    
    aws ecs describe-services \
      --cluster $CLUSTER_NAME \
      --services $service_arn \
      --region $SOURCE_REGION \
      --query 'services[0].{serviceName:serviceName,taskDefinition:taskDefinition,desiredCount:desiredCount,launchType:launchType,capacityProviderStrategy:capacityProviderStrategy,networkConfiguration:networkConfiguration,loadBalancers:loadBalancers,serviceRegistries:serviceRegistries,tags:tags,enableExecuteCommand:enableExecuteCommand}' \
      > "service-${service_name}-config.json"
done

# 3. 匯出所有任務定義
aws ecs list-task-definitions \
  --region $SOURCE_REGION \
  --query 'taskDefinitionArns' \
  --output text | while read taskdef_arn; do
    taskdef_name=$(echo $taskdef_arn | cut -d'/' -f2 | cut -d':' -f1)
    echo "匯出任務定義: $taskdef_name"
    
    aws ecs describe-task-definition \
      --task-definition $taskdef_arn \
      --region $SOURCE_REGION \
      --query 'taskDefinition.{family:family,taskRoleArn:taskRoleArn,executionRoleArn:executionRoleArn,networkMode:networkMode,requiresCompatibilities:requiresCompatibilities,cpu:cpu,memory:memory,containerDefinitions:containerDefinitions,volumes:volumes,placementConstraints:placementConstraints,tags:tags}' \
      > "taskdef-${taskdef_name}-config.json"
done

# 4. 匯出容量提供者設定
aws ecs describe-capacity-providers \
  --region $SOURCE_REGION \
  --query 'capacityProviders[].{name:name,autoScalingGroupProvider:autoScalingGroupProvider,tags:tags}' \
  > capacity-providers-config.json

echo "✅ ECS 叢集設定匯出完成！"
```

### 2. 部署 ECS 叢集

```bash
#!/bin/bash
# deploy_ecs_cluster.sh
source config.sh

echo "🚀 在 Taipei Region 部署 ECS 叢集..."

# 1. 建立 ECS 叢集
CLUSTER_CONFIG=$(cat ecs-cluster-config.json)

aws ecs create-cluster \
  --cluster-name $CLUSTER_NAME \
  --tags "$(echo $CLUSTER_CONFIG | jq -c '.tags // []')" \
  --settings "$(echo $CLUSTER_CONFIG | jq -c '.settings // []')" \
  --configuration "$(echo $CLUSTER_CONFIG | jq -c '.configuration // {}')" \
  --region $TARGET_REGION

echo "✅ ECS 叢集建立完成！"

# 2. 註冊任務定義
for taskdef_file in taskdef-*-config.json; do
    if [ -f "$taskdef_file" ]; then
        echo "註冊任務定義: $taskdef_file"
        
        # 修改容器映像 URI 和環境變數
        jq '.containerDefinitions[].image |= sub("ap-northeast-1"; "ap-east-2") |
            .containerDefinitions[].environment[]? |= if .name == "DB_HOST" then .value |= sub("'$DB_INSTANCE_ID'"; "'$DB_INSTANCE_ID'-tpe") else . end' \
           "$taskdef_file" > "${taskdef_file%.json}-modified.json"
        
        TASKDEF_CONFIG=$(cat "${taskdef_file%.json}-modified.json")
        
        aws ecs register-task-definition \
          --region $TARGET_REGION \
          --family "$(echo $TASKDEF_CONFIG | jq -r '.family')" \
          --task-role-arn "$(echo $TASKDEF_CONFIG | jq -r '.taskRoleArn // ""')" \
          --execution-role-arn "$(echo $TASKDEF_CONFIG | jq -r '.executionRoleArn')" \
          --network-mode "$(echo $TASKDEF_CONFIG | jq -r '.networkMode')" \
          --requires-compatibilities "$(echo $TASKDEF_CONFIG | jq -c '.requiresCompatibilities')" \
          --cpu "$(echo $TASKDEF_CONFIG | jq -r '.cpu // ""')" \
          --memory "$(echo $TASKDEF_CONFIG | jq -r '.memory // ""')" \
          --container-definitions "$(echo $TASKDEF_CONFIG | jq -c '.containerDefinitions')" \
          --volumes "$(echo $TASKDEF_CONFIG | jq -c '.volumes // []')" \
          --placement-constraints "$(echo $TASKDEF_CONFIG | jq -c '.placementConstraints // []')" \
          --tags "$(echo $TASKDEF_CONFIG | jq -c '.tags // []')"
    fi
done

# 3. 建立服務（自動修改網路設定）
get_ecs_vpc_resources() {
    local vpc_name=${VPC_NAME:-"migration-vpc"}
    
    # 查找 VPC
    TARGET_VPC_ID=$(aws ec2 describe-vpcs \
        --filters "Name=tag:Name,Values=$vpc_name" "Name=state,Values=available" \
        --query 'Vpcs[0].VpcId' --output text --region $TARGET_REGION)
    
    if [[ "$TARGET_VPC_ID" == "None" || -z "$TARGET_VPC_ID" ]]; then
        echo "錯誤：找不到 VPC '$vpc_name'"
        exit 1
    fi
    
    # 獲取私有子網路（用於 ECS 任務）
    TARGET_SUBNET_IDS=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$TARGET_VPC_ID" \
                  "Name=tag:Type,Values=Private" \
                  "Name=state,Values=available" \
        --query 'Subnets[].SubnetId' --output text --region $TARGET_REGION)
    
    # 查找或建立 ECS 安全群組
    TARGET_SECURITY_GROUP_ID=$(aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=$TARGET_VPC_ID" \
                  "Name=tag:Purpose,Values=ECS-Service" \
        --query 'SecurityGroups[0].GroupId' --output text --region $TARGET_REGION)
    
    if [[ "$TARGET_SECURITY_GROUP_ID" == "None" || -z "$TARGET_SECURITY_GROUP_ID" ]]; then
        echo "建立 ECS 服務安全群組..."
        TARGET_SECURITY_GROUP_ID=$(aws ec2 create-security-group \
            --group-name "ecs-service-sg-$(date +%s)" \
            --description "Security group for ECS service migration" \
            --vpc-id $TARGET_VPC_ID \
            --tag-specifications "ResourceType=security-group,Tags=[{Key=Purpose,Value=ECS-Service},{Key=Name,Value=ecs-service-sg}]" \
            --query 'GroupId' --output text --region $TARGET_REGION)
        
        # 加入必要的安全群組規則
        aws ec2 authorize-security-group-ingress \
            --group-id $TARGET_SECURITY_GROUP_ID \
            --protocol tcp --port 80 --cidr 10.0.0.0/8 \
            --region $TARGET_REGION
        
        aws ec2 authorize-security-group-ingress \
            --group-id $TARGET_SECURITY_GROUP_ID \
            --protocol tcp --port 443 --cidr 10.0.0.0/8 \
            --region $TARGET_REGION
    fi
}

get_ecs_vpc_resources

for service_file in service-*-config.json; do
    if [ -f "$service_file" ]; then
        echo "建立服務: $service_file"
        
        # 修改網路設定
        jq --arg subnets "$(echo $TARGET_SUBNET_IDS | tr ' ' ',')" \
           --arg sg "$TARGET_SECURITY_GROUP_ID" \
           '.networkConfiguration.awsvpcConfiguration.subnets = ($subnets | split(",")) | 
            .networkConfiguration.awsvpcConfiguration.securityGroups = [$sg]' \
           "$service_file" > "${service_file%.json}-modified.json"
        
        SERVICE_CONFIG=$(cat "${service_file%.json}-modified.json")
        SERVICE_NAME=$(echo $SERVICE_CONFIG | jq -r '.serviceName')
        
        aws ecs create-service \
          --region $TARGET_REGION \
          --cluster $CLUSTER_NAME \
          --service-name $SERVICE_NAME \
          --task-definition "$(echo $SERVICE_CONFIG | jq -r '.taskDefinition')" \
          --desired-count "$(echo $SERVICE_CONFIG | jq -r '.desiredCount')" \
          --launch-type "$(echo $SERVICE_CONFIG | jq -r '.launchType // "FARGATE"')" \
          --network-configuration "$(echo $SERVICE_CONFIG | jq -c '.networkConfiguration')" \
          --load-balancers "$(echo $SERVICE_CONFIG | jq -c '.loadBalancers // []')" \
          --service-registries "$(echo $SERVICE_CONFIG | jq -c '.serviceRegistries // []')" \
          --tags "$(echo $SERVICE_CONFIG | jq -c '.tags // []')" \
          --enable-execute-command "$(echo $SERVICE_CONFIG | jq -r '.enableExecuteCommand // false')"
    fi
done

echo "✅ ECS 服務部署完成！"
```

### 3. 設定 Application Load Balancer

```bash
#!/bin/bash
# setup_ecs_alb.sh
source config.sh

echo "🔧 設定 Application Load Balancer..."

# 獲取公有子網路
PUBLIC_SUBNET_IDS=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$TARGET_VPC_ID" \
              "Name=tag:Type,Values=Public" \
              "Name=state,Values=available" \
    --query 'Subnets[].SubnetId' --output text --region $TARGET_REGION)

# 建立 ALB 安全群組
ALB_SECURITY_GROUP_ID=$(aws ec2 create-security-group \
    --group-name "ecs-alb-sg-$(date +%s)" \
    --description "Security group for ECS ALB" \
    --vpc-id $TARGET_VPC_ID \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Purpose,Value=ECS-ALB},{Key=Name,Value=ecs-alb-sg}]" \
    --query 'GroupId' --output text --region $TARGET_REGION)

# 加入 HTTP/HTTPS 規則
aws ec2 authorize-security-group-ingress \
    --group-id $ALB_SECURITY_GROUP_ID \
    --protocol tcp --port 80 --cidr 0.0.0.0/0 \
    --region $TARGET_REGION

aws ec2 authorize-security-group-ingress \
    --group-id $ALB_SECURITY_GROUP_ID \
    --protocol tcp --port 443 --cidr 0.0.0.0/0 \
    --region $TARGET_REGION

# 建立 Application Load Balancer
ALB_ARN=$(aws elbv2 create-load-balancer \
    --name ecs-migration-alb \
    --subnets $PUBLIC_SUBNET_IDS \
    --security-groups $ALB_SECURITY_GROUP_ID \
    --scheme internet-facing \
    --type application \
    --ip-address-type ipv4 \
    --tags Key=Purpose,Value=ECS-Migration \
    --query 'LoadBalancers[0].LoadBalancerArn' \
    --output text --region $TARGET_REGION)

echo "ALB ARN: $ALB_ARN"
echo $ALB_ARN > alb_arn.txt

# 建立目標群組
TARGET_GROUP_ARN=$(aws elbv2 create-target-group \
    --name ecs-migration-targets \
    --protocol HTTP \
    --port 80 \
    --vpc-id $TARGET_VPC_ID \
    --target-type ip \
    --health-check-enabled \
    --health-check-path /health \
    --health-check-protocol HTTP \
    --health-check-interval-seconds 30 \
    --health-check-timeout-seconds 5 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 3 \
    --tags Key=Purpose,Value=ECS-Migration \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text --region $TARGET_REGION)

echo "Target Group ARN: $TARGET_GROUP_ARN"
echo $TARGET_GROUP_ARN > target_group_arn.txt

# 建立監聽器
aws elbv2 create-listener \
    --load-balancer-arn $ALB_ARN \
    --protocol HTTP \
    --port 80 \
    --default-actions Type=forward,TargetGroupArn=$TARGET_GROUP_ARN \
    --region $TARGET_REGION

echo "✅ Application Load Balancer 設定完成！"
```

## 驗證和測試

### 驗證 ECS 遷移

```bash
#!/bin/bash
# verify_ecs_migration.sh
source config.sh

echo "🔍 驗證 ECS 遷移狀態..."

# 1. 檢查叢集狀態
echo "檢查叢集狀態："
aws ecs describe-clusters \
    --clusters $CLUSTER_NAME \
    --region $TARGET_REGION \
    --query 'clusters[0].{Name:clusterName,Status:status,ActiveServicesCount:activeServicesCount,RunningTasksCount:runningTasksCount}'

# 2. 檢查服務狀態
echo "檢查服務狀態："
aws ecs list-services \
    --cluster $CLUSTER_NAME \
    --region $TARGET_REGION \
    --query 'serviceArns' \
    --output text | while read service_arn; do
    service_name=$(basename $service_arn)
    aws ecs describe-services \
        --cluster $CLUSTER_NAME \
        --services $service_arn \
        --region $TARGET_REGION \
        --query 'services[0].{Name:serviceName,Status:status,DesiredCount:desiredCount,RunningCount:runningCount,PendingCount:pendingCount}'
done

# 3. 檢查任務狀態
echo "檢查任務狀態："
aws ecs list-tasks \
    --cluster $CLUSTER_NAME \
    --region $TARGET_REGION \
    --query 'taskArns' \
    --output text | while read task_arn; do
    aws ecs describe-tasks \
        --cluster $CLUSTER_NAME \
        --tasks $task_arn \
        --region $TARGET_REGION \
        --query 'tasks[0].{TaskArn:taskArn,LastStatus:lastStatus,HealthStatus:healthStatus,CreatedAt:createdAt}'
done

# 4. 檢查 ALB 健康狀態
if [ -f "target_group_arn.txt" ]; then
    TARGET_GROUP_ARN=$(cat target_group_arn.txt)
    echo "檢查 ALB 目標健康狀態："
    aws elbv2 describe-target-health \
        --target-group-arn $TARGET_GROUP_ARN \
        --region $TARGET_REGION \
        --query 'TargetHealthDescriptions[].{Target:Target.Id,Health:TargetHealth.State,Description:TargetHealth.Description}'
fi

# 5. 檢查 ALB DNS 名稱
if [ -f "alb_arn.txt" ]; then
    ALB_ARN=$(cat alb_arn.txt)
    ALB_DNS=$(aws elbv2 describe-load-balancers \
        --load-balancer-arns $ALB_ARN \
        --query 'LoadBalancers[0].DNSName' \
        --output text --region $TARGET_REGION)
    
    echo "ALB DNS 名稱: $ALB_DNS"
    echo "測試 ALB 連通性："
    curl -f "http://$ALB_DNS/health" || echo "健康檢查失敗，請檢查服務狀態"
fi

echo "✅ ECS 遷移驗證完成！"
```

## 流量切換

### DNS 流量切換

```bash
#!/bin/bash
# switch_dns_traffic.sh
source config.sh

SERVICE_TYPE="ecs"
DOMAIN_NAME="your-domain.com"  # 替換為實際域名

echo "🔄 開始 DNS 流量切換..."

# 獲取 ECS ALB 端點
if [ -f "alb_arn.txt" ]; then
    ALB_ARN=$(cat alb_arn.txt)
    TARGET_ENDPOINT=$(aws elbv2 describe-load-balancers \
        --load-balancer-arns $ALB_ARN \
        --query 'LoadBalancers[0].DNSName' \
        --output text --region $TARGET_REGION)
else
    echo "錯誤：找不到 ALB ARN 檔案"
    exit 1
fi

if [[ -z "$TARGET_ENDPOINT" ]]; then
    echo "錯誤：無法獲取目標 ALB 端點"
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

SERVICE_TYPE="ecs"
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
# complete_ecs_migration.sh
source config.sh

echo "🚀 開始完整 ECS 遷移流程..."

# 1. 匯出設定
./export_ecs_config.sh

# 2. 部署叢集和服務
./deploy_ecs_cluster.sh

# 3. 設定 Load Balancer
./setup_ecs_alb.sh

# 4. 驗證遷移
./verify_ecs_migration.sh

echo "✅ ECS 遷移完成！"
echo "下一步：執行 ./switch_dns_traffic.sh 進行流量切換"
```

## 使用說明

### 快速開始

```bash
# 1. 設定環境變數
cp config.sh.example config.sh
# 編輯 config.sh 填入實際值

# 2. 準備 VPC 基礎設施
./replicate_vpc_from_source.sh

# 3. 執行完整遷移
./complete_ecs_migration.sh

# 4. 驗證遷移結果
./verify_ecs_migration.sh

# 5. 執行流量切換
./switch_dns_traffic.sh

# 6. 如需回滾
./emergency_rollback.sh
```

### 注意事項

1. **任務定義版本**：確保容器映像在目標區域的 ECR 中可用
2. **IAM 角色**：確認任務角色和執行角色在目標區域有效
3. **服務發現**：如使用 Service Discovery，需要重新配置命名空間
4. **負載平衡器**：確認目標群組健康檢查設定正確
5. **環境變數**：檢查所有環境變數是否正確更新

### 故障排除

- **任務無法啟動**：檢查任務定義中的映像 URI 和 IAM 角色
- **服務無法達到期望數量**：檢查子網路容量和安全群組設定
- **健康檢查失敗**：確認應用程式健康檢查端點和路徑
- **負載平衡器無法訪問**：檢查安全群組和網路 ACL 設定
