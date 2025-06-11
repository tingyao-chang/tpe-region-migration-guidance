# EC2 跨區域遷移部署指南

## 概述

本指南提供 EC2 執行個體從 Tokyo Region → Taipei Region 遷移的具體執行命令和腳本。

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

# EC2 相關設定
export INSTANCE_ID="i-1234567890abcdef0"  # 替換為實際的執行個體 ID
export KEY_PAIR_NAME="my-key-pair"        # 替換為實際的金鑰對名稱

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
    
    if [[ -z "$INSTANCE_ID" ]]; then
        errors+=("INSTANCE_ID 未設定")
    fi
    
    if [[ -z "$KEY_PAIR_NAME" ]]; then
        errors+=("KEY_PAIR_NAME 未設定")
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

## EC2 遷移步驟

### 1. 建立和複製 AMI

```bash
#!/bin/bash
# create_and_copy_ami.sh
source config.sh

AMI_NAME="migration-ami-$(date +%Y%m%d-%H%M%S)"

echo "🖼️ 建立和複製 AMI..."

# 1. 從來源區域的 EC2 執行個體建立 AMI
echo "建立 AMI 從執行個體 $INSTANCE_ID..."
SOURCE_AMI_ID=$(aws ec2 create-image \
    --instance-id $INSTANCE_ID \
    --name "$AMI_NAME" \
    --description "Application AMI for Taipei migration" \
    --no-reboot \
    --region $SOURCE_REGION \
    --query 'ImageId' \
    --output text)

echo "來源 AMI ID: $SOURCE_AMI_ID"

# 2. 等待 AMI 建立完成
echo "⏳ 等待 AMI 建立完成..."
aws ec2 wait image-available \
    --image-ids $SOURCE_AMI_ID \
    --region $SOURCE_REGION

# 3. 複製 AMI 到目標區域
echo "複製 AMI 到目標區域..."
TARGET_AMI_ID=$(aws ec2 copy-image \
    --source-image-id $SOURCE_AMI_ID \
    --source-region $SOURCE_REGION \
    --name "$AMI_NAME-taipei" \
    --description "Application AMI copied to Taipei region" \
    --query 'ImageId' \
    --output text \
    --region $TARGET_REGION)

echo "目標 AMI ID: $TARGET_AMI_ID"

# 4. 儲存 AMI ID 供後續使用
echo $TARGET_AMI_ID > target_ami_id.txt

# 5. 等待 AMI 複製完成
echo "⏳ 等待 AMI 複製完成..."
aws ec2 wait image-available \
    --image-ids $TARGET_AMI_ID \
    --region $TARGET_REGION

echo "✅ AMI 建立和複製完成！"
echo "來源 AMI ID: $SOURCE_AMI_ID"
echo "目標 AMI ID: $TARGET_AMI_ID"
```

### 2. 設定 EC2 基礎設施

```bash
#!/bin/bash
# setup_ec2_infrastructure.sh
source config.sh

TARGET_AMI_ID=$(cat target_ami_id.txt)

echo "🏗️ 設定 EC2 基礎設施..."

# 獲取必要的資源 ID
get_ec2_vpc_resources() {
    local vpc_name=${VPC_NAME:-"migration-vpc"}
    
    # 查找 VPC
    TARGET_VPC_ID=$(aws ec2 describe-vpcs \
        --filters "Name=tag:Name,Values=$vpc_name" "Name=state,Values=available" \
        --query 'Vpcs[0].VpcId' --output text --region $TARGET_REGION)
    
    if [[ "$TARGET_VPC_ID" == "None" || -z "$TARGET_VPC_ID" ]]; then
        echo "錯誤：找不到 VPC '$vpc_name'"
        exit 1
    fi
    
    # 獲取私有子網路（用於 EC2 執行個體）
    PRIVATE_SUBNET_IDS=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$TARGET_VPC_ID" \
                  "Name=tag:Type,Values=Private" \
                  "Name=state,Values=available" \
        --query 'Subnets[].SubnetId' --output text --region $TARGET_REGION)
    
    # 獲取公有子網路（用於 Load Balancer）
    PUBLIC_SUBNET_IDS=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$TARGET_VPC_ID" \
                  "Name=tag:Type,Values=Public" \
                  "Name=state,Values=available" \
        --query 'Subnets[].SubnetId' --output text --region $TARGET_REGION)
    
    # 驗證子網路存在
    if [[ -z "$PRIVATE_SUBNET_IDS" ]]; then
        echo "錯誤：找不到私有子網路"
        exit 1
    fi
    
    if [[ -z "$PUBLIC_SUBNET_IDS" ]]; then
        echo "錯誤：找不到公有子網路"
        exit 1
    fi
    
    # 查找或建立 EC2 安全群組
    SECURITY_GROUP_ID=$(aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=$TARGET_VPC_ID" \
                  "Name=tag:Purpose,Values=EC2-App" \
        --query 'SecurityGroups[0].GroupId' --output text --region $TARGET_REGION)
    
    if [[ "$SECURITY_GROUP_ID" == "None" || -z "$SECURITY_GROUP_ID" ]]; then
        echo "建立 EC2 應用程式安全群組..."
        SECURITY_GROUP_ID=$(aws ec2 create-security-group \
            --group-name "ec2-app-sg-$(date +%s)" \
            --description "Security group for EC2 application migration" \
            --vpc-id $TARGET_VPC_ID \
            --tag-specifications "ResourceType=security-group,Tags=[{Key=Purpose,Value=EC2-App},{Key=Name,Value=ec2-app-sg}]" \
            --query 'GroupId' --output text --region $TARGET_REGION)
        
        # 加入 HTTP/HTTPS 規則
        aws ec2 authorize-security-group-ingress \
            --group-id $SECURITY_GROUP_ID \
            --protocol tcp --port 80 --cidr 10.0.0.0/8 \
            --region $TARGET_REGION
        
        aws ec2 authorize-security-group-ingress \
            --group-id $SECURITY_GROUP_ID \
            --protocol tcp --port 443 --cidr 10.0.0.0/8 \
            --region $TARGET_REGION
        
        # 加入 SSH 規則（僅限 VPC 內部）
        aws ec2 authorize-security-group-ingress \
            --group-id $SECURITY_GROUP_ID \
            --protocol tcp --port 22 --cidr 10.0.0.0/8 \
            --region $TARGET_REGION
    fi
    
    echo "✅ EC2 VPC 資源獲取完成："
    echo "  VPC ID: $TARGET_VPC_ID"
    echo "  私有子網路: $PRIVATE_SUBNET_IDS"
    echo "  公有子網路: $PUBLIC_SUBNET_IDS"
    echo "  安全群組: $SECURITY_GROUP_ID"
}

get_ec2_vpc_resources

# 建立 User Data 腳本（更新資料庫連線）
cat > user_data.sh << EOF
#!/bin/bash
yum update -y

# 更新應用程式設定指向新的資料庫
sed -i 's/${DB_INSTANCE_ID}/${DB_INSTANCE_ID}-taipei/g' /etc/myapp/config.properties
systemctl restart myapp
EOF

# 建立啟動範本
echo "建立啟動範本..."
LAUNCH_TEMPLATE_ID=$(aws ec2 create-launch-template \
    --launch-template-name taipei-app-launch-template \
    --launch-template-data "{
        \"ImageId\": \"$TARGET_AMI_ID\",
        \"InstanceType\": \"t3.medium\",
        \"KeyName\": \"$KEY_PAIR_NAME\",
        \"SecurityGroupIds\": [\"$SECURITY_GROUP_ID\"],
        \"UserData\": \"$(base64 -w 0 user_data.sh)\",
        \"TagSpecifications\": [{
            \"ResourceType\": \"instance\",
            \"Tags\": [
                {\"Key\": \"Name\", \"Value\": \"taipei-app-instance\"},
                {\"Key\": \"Environment\", \"Value\": \"production\"},
                {\"Key\": \"Project\", \"Value\": \"taipei-migration\"}
            ]
        }]
    }" \
    --query 'LaunchTemplate.LaunchTemplateId' \
    --output text \
    --region $TARGET_REGION)

echo "啟動範本 ID: $LAUNCH_TEMPLATE_ID"
echo $LAUNCH_TEMPLATE_ID > launch_template_id.txt

# 建立 Application Load Balancer
echo "建立 Application Load Balancer..."
ALB_ARN=$(aws elbv2 create-load-balancer \
    --name taipei-ec2-alb \
    --subnets $PUBLIC_SUBNET_IDS \
    --security-groups $SECURITY_GROUP_ID \
    --scheme internet-facing \
    --type application \
    --ip-address-type ipv4 \
    --tags Key=Purpose,Value=EC2-Migration \
    --query 'LoadBalancers[0].LoadBalancerArn' \
    --output text \
    --region $TARGET_REGION)

echo "ALB ARN: $ALB_ARN"
echo $ALB_ARN > alb_arn.txt

# 建立目標群組
TARGET_GROUP_ARN=$(aws elbv2 create-target-group \
    --name taipei-ec2-targets \
    --protocol HTTP \
    --port 80 \
    --vpc-id $TARGET_VPC_ID \
    --target-type instance \
    --health-check-enabled \
    --health-check-path /health \
    --health-check-protocol HTTP \
    --health-check-interval-seconds 30 \
    --health-check-timeout-seconds 5 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 3 \
    --tags Key=Purpose,Value=EC2-Migration \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text \
    --region $TARGET_REGION)

echo "Target Group ARN: $TARGET_GROUP_ARN"
echo $TARGET_GROUP_ARN > target_group_arn.txt

# 建立監聽器
aws elbv2 create-listener \
    --load-balancer-arn $ALB_ARN \
    --protocol HTTP \
    --port 80 \
    --default-actions Type=forward,TargetGroupArn=$TARGET_GROUP_ARN \
    --region $TARGET_REGION

echo "✅ EC2 基礎設施設定完成！"
```

### 3. 建立 Auto Scaling 群組

```bash
#!/bin/bash
# create_autoscaling_group.sh
source config.sh

TARGET_GROUP_ARN=$(cat target_group_arn.txt)
LAUNCH_TEMPLATE_ID=$(cat launch_template_id.txt)

echo "🔄 建立 Auto Scaling 群組..."

# 獲取私有子網路 ID（用於 EC2 執行個體）
get_asg_vpc_resources() {
    local vpc_name=${VPC_NAME:-"migration-vpc"}
    
    TARGET_VPC_ID=$(aws ec2 describe-vpcs \
        --filters "Name=tag:Name,Values=$vpc_name" "Name=state,Values=available" \
        --query 'Vpcs[0].VpcId' --output text --region $TARGET_REGION)
    
    if [[ "$TARGET_VPC_ID" == "None" || -z "$TARGET_VPC_ID" ]]; then
        echo "錯誤：找不到 VPC '$vpc_name'"
        exit 1
    fi
    
    PRIVATE_SUBNET_IDS=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$TARGET_VPC_ID" \
                  "Name=tag:Type,Values=Private" \
                  "Name=state,Values=available" \
        --query 'Subnets[].SubnetId' --output text --region $TARGET_REGION)
    
    if [[ -z "$PRIVATE_SUBNET_IDS" ]]; then
        echo "錯誤：找不到私有子網路"
        exit 1
    fi
    
    # 驗證子網路跨越多個 AZ
    AZ_COUNT=$(aws ec2 describe-subnets \
        --subnet-ids $PRIVATE_SUBNET_IDS \
        --query 'length(Subnets[].AvailabilityZone | sort(@) | unique(@))' \
        --output text --region $TARGET_REGION)
    
    if [[ "$AZ_COUNT" -lt 2 ]]; then
        echo "警告：Auto Scaling 群組僅跨越 $AZ_COUNT 個可用區域，建議至少 2 個以確保高可用性"
    fi
    
    echo "✅ Auto Scaling VPC 資源驗證完成："
    echo "  VPC ID: $TARGET_VPC_ID"
    echo "  私有子網路: $PRIVATE_SUBNET_IDS"
    echo "  跨越可用區域數: $AZ_COUNT"
}

get_asg_vpc_resources

# 建立 Auto Scaling 群組
aws autoscaling create-auto-scaling-group \
    --auto-scaling-group-name taipei-app-asg \
    --launch-template "{
        \"LaunchTemplateId\": \"$LAUNCH_TEMPLATE_ID\",
        \"Version\": \"\$Latest\"
    }" \
    --min-size 2 \
    --max-size 10 \
    --desired-capacity 3 \
    --vpc-zone-identifier "$(echo $PRIVATE_SUBNET_IDS | tr ' ' ',')" \
    --target-group-arns $TARGET_GROUP_ARN \
    --health-check-type ELB \
    --health-check-grace-period 300 \
    --default-cooldown 300 \
    --tags "Key=Name,Value=taipei-app-asg-instance,PropagateAtLaunch=true,ResourceId=taipei-app-asg,ResourceType=auto-scaling-group" \
    --region $TARGET_REGION

# 建立擴展政策
aws autoscaling put-scaling-policy \
    --auto-scaling-group-name taipei-app-asg \
    --policy-name scale-up-policy \
    --policy-type TargetTrackingScaling \
    --target-tracking-configuration "{
        \"TargetValue\": 70.0,
        \"PredefinedMetricSpecification\": {
            \"PredefinedMetricType\": \"ASGAverageCPUUtilization\"
        }
    }" \
    --region $TARGET_REGION

echo "✅ Auto Scaling 群組建立完成！"

# 檢查 Auto Scaling 群組狀態
aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names taipei-app-asg \
    --query 'AutoScalingGroups[0].{DesiredCapacity:DesiredCapacity,MinSize:MinSize,MaxSize:MaxSize,Instances:length(Instances)}' \
    --region $TARGET_REGION
```

### 4. 驗證 EC2 部署

```bash
#!/bin/bash
# verify_ec2_deployment.sh
source config.sh

ALB_ARN=$(cat alb_arn.txt)

echo "🔍 驗證 EC2 部署狀態..."

# 1. 檢查 ALB 狀態
echo "檢查 Application Load Balancer 狀態："
aws elbv2 describe-load-balancers \
    --load-balancer-arns $ALB_ARN \
    --query 'LoadBalancers[0].{Name:LoadBalancerName,State:State.Code,DNSName:DNSName}' \
    --region $TARGET_REGION

# 2. 檢查目標群組健康狀態
TARGET_GROUP_ARN=$(cat target_group_arn.txt)
echo "檢查目標群組健康狀態："
aws elbv2 describe-target-health \
    --target-group-arn $TARGET_GROUP_ARN \
    --query 'TargetHealthDescriptions[].{Target:Target.Id,Health:TargetHealth.State,Description:TargetHealth.Description}' \
    --region $TARGET_REGION

# 3. 檢查 Auto Scaling 群組狀態
echo "Auto Scaling 群組狀態："
aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names taipei-app-asg \
    --query 'AutoScalingGroups[0].{DesiredCapacity:DesiredCapacity,Instances:Instances[].{InstanceId:InstanceId,HealthStatus:HealthStatus,LifecycleState:LifecycleState}}' \
    --region $TARGET_REGION

# 4. 檢查執行個體健康狀態
INSTANCE_IDS=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names taipei-app-asg \
    --query 'AutoScalingGroups[0].Instances[].InstanceId' \
    --output text \
    --region $TARGET_REGION)

if [[ -n "$INSTANCE_IDS" ]]; then
    echo "檢查 EC2 執行個體狀態："
    aws ec2 describe-instances \
        --instance-ids $INSTANCE_IDS \
        --query 'Reservations[].Instances[].{InstanceId:InstanceId,State:State.Name,PrivateIpAddress:PrivateIpAddress}' \
        --region $TARGET_REGION
fi

# 5. 測試 ALB 連通性
ALB_DNS=$(aws elbv2 describe-load-balancers \
    --load-balancer-arns $ALB_ARN \
    --query 'LoadBalancers[0].DNSName' \
    --output text \
    --region $TARGET_REGION)

echo "ALB DNS 名稱: $ALB_DNS"
echo "測試 ALB 連通性："
curl -f "http://$ALB_DNS/health" || echo "健康檢查失敗，請檢查應用程式狀態"

echo "✅ EC2 部署驗證完成！"
```

## 流量切換

### DNS 流量切換

```bash
#!/bin/bash
# switch_dns_traffic.sh
source config.sh

SERVICE_TYPE="ec2"
DOMAIN_NAME="your-domain.com"  # 替換為實際域名

echo "🔄 開始 DNS 流量切換..."

# 獲取 EC2 ALB 端點
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

SERVICE_TYPE="ec2"
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
# complete_ec2_migration.sh
source config.sh

echo "🚀 開始完整 EC2 遷移流程..."

# 1. 建立和複製 AMI
./create_and_copy_ami.sh

# 2. 設定基礎設施
./setup_ec2_infrastructure.sh

# 3. 建立 Auto Scaling 群組
./create_autoscaling_group.sh

# 4. 驗證部署
./verify_ec2_deployment.sh

echo "✅ EC2 遷移完成！"
echo "下一步：執行 ./switch_dns_traffic.sh 進行流量切換"
```

## 使用說明

### 快速開始

```bash
# 1. 設定環境變數
cp config.sh.example config.sh
# 編輯 config.sh 填入實際值，特別是 INSTANCE_ID 和 KEY_PAIR_NAME

# 2. 準備 VPC 基礎設施
./replicate_vpc_from_source.sh

# 3. 執行完整遷移
./complete_ec2_migration.sh

# 4. 驗證遷移結果
./verify_ec2_deployment.sh

# 5. 執行流量切換
./switch_dns_traffic.sh

# 6. 如需回滾
./emergency_rollback.sh
```

### 注意事項

1. **執行個體 ID**：確保 INSTANCE_ID 指向要遷移的執行個體
2. **金鑰對**：確認目標區域有相同名稱的金鑰對，或建立新的金鑰對
3. **應用程式狀態**：確保應用程式能正確處理資料庫連線變更
4. **User Data 腳本**：根據實際應用程式調整 User Data 腳本
5. **執行個體類型**：確認目標區域支援所選的執行個體類型

### 故障排除

- **AMI 建立失敗**：檢查執行個體狀態和權限設定
- **執行個體無法啟動**：檢查安全群組、子網路和 User Data 腳本
- **健康檢查失敗**：確認應用程式正確啟動和健康檢查端點
- **Auto Scaling 無法擴展**：檢查 IAM 角色和子網路容量
- **負載平衡器無法訪問**：檢查安全群組和網路 ACL 設定

### 最佳實踐

1. **測試環境先行**：在測試環境完整驗證遷移流程
2. **監控設定**：設定 CloudWatch 警示監控執行個體和應用程式狀態
3. **備份策略**：確保重要資料有完整備份
4. **文件記錄**：記錄所有配置變更和決策過程
5. **團隊協作**：確保所有相關團隊了解遷移計畫和時程
