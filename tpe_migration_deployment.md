# AWS 跨區域工作負載遷移部署指南

## 概述

# AWS 跨區域工作負載遷移部署總覽

## 概述

本指南提供 Tokyo Region → Taipei Region 遷移的總覽和協調，包含 EKS、ECS、EC2 三種計算服務的完整遷移流程。

## 📋 部署指南結構

### 核心檔案

| 檔案名稱 | 用途 | 適用服務 |
|---------|------|----------|
| `tpe_migration_deployment.md` | **總覽指南**（本檔案） | 所有服務 |
| `eks_migration_deployment.md` | EKS 專用部署指南 | Kubernetes 叢集 |
| `ecs_migration_deployment.md` | ECS 專用部署指南 | 容器服務 |
| `ec2_migration_deployment.md` | EC2 專用部署指南 | 虛擬機器 |

### 共用模組

| 檔案名稱 | 用途 | 說明 |
|---------|------|------|
| `common_functions.sh` | 共用函數庫 | VPC、安全群組、ECR、RDS、DNS 管理 |
| `config.sh.example` | 設定檔範本 | 統一的環境變數設定 |

## 🚀 快速開始

### 1. 環境準備

```bash
# 1. 複製設定檔範本
cp config.sh.example config.sh

# 2. 編輯設定檔，填入實際值
vim config.sh
# 或使用其他編輯器：nano config.sh, code config.sh

# 3. 驗證設定
./config.sh
```

### 2. 選擇遷移方案

根據您的服務類型選擇對應的部署指南：

#### 🎯 EKS 遷移
```bash
# 適用於：Kubernetes 叢集和容器化應用程式
./eks_migration_deployment.md

# 快速執行
cd eks_migration
./complete_eks_migration.sh
```

#### 🎯 ECS 遷移
```bash
# 適用於：ECS 服務和 Fargate 任務
./ecs_migration_deployment.md

# 快速執行
cd ecs_migration
./complete_ecs_migration.sh
```

#### 🎯 EC2 遷移
```bash
# 適用於：虛擬機器和 Auto Scaling 群組
./ec2_migration_deployment.md

# 快速執行
cd ec2_migration
./complete_ec2_migration.sh
```

### 3. 混合環境遷移

如果您的環境包含多種服務，可以並行執行：

```bash
#!/bin/bash
# complete_mixed_migration.sh
source common_functions.sh
load_config
validate_basic_config

echo "🚀 開始混合環境遷移..."

# 準備共用基礎設施
echo "📋 階段 1：準備基礎設施"
get_vpc_resources

# 設定 ECR 複製（背景執行）
if [[ "$ECR_REPLICATION_ENABLED" == "true" ]]; then
    setup_ecr_replication &
    ECR_PID=$!
fi

# 遷移 RDS 資料庫（背景執行）
if [[ "$RDS_MIGRATION_ENABLED" == "true" && -n "$DB_INSTANCE_ID" ]]; then
    migrate_rds_database &
    RDS_PID=$!
fi

# 並行執行服務遷移
echo "📋 階段 2：並行服務遷移"

# EKS 遷移
if [[ -f "eks_migration_deployment.md" ]]; then
    echo "啟動 EKS 遷移..."
    (cd eks_migration && ./complete_eks_migration.sh) &
    EKS_PID=$!
fi

# ECS 遷移
if [[ -f "ecs_migration_deployment.md" ]]; then
    echo "啟動 ECS 遷移..."
    (cd ecs_migration && ./complete_ecs_migration.sh) &
    ECS_PID=$!
fi

# EC2 遷移
if [[ -f "ec2_migration_deployment.md" ]]; then
    echo "啟動 EC2 遷移..."
    (cd ec2_migration && ./complete_ec2_migration.sh) &
    EC2_PID=$!
fi

# 等待所有遷移完成
echo "📋 階段 3：等待遷移完成"

if [[ -n "$EKS_PID" ]]; then
    wait $EKS_PID
    echo "✅ EKS 遷移完成"
fi

if [[ -n "$ECS_PID" ]]; then
    wait $ECS_PID
    echo "✅ ECS 遷移完成"
fi

if [[ -n "$EC2_PID" ]]; then
    wait $EC2_PID
    echo "✅ EC2 遷移完成"
fi

if [[ -n "$ECR_PID" ]]; then
    wait $ECR_PID
    echo "✅ ECR 複製完成"
fi

if [[ -n "$RDS_PID" ]]; then
    wait $RDS_PID
    echo "✅ RDS 遷移完成"
fi

echo "📋 階段 4：驗證所有服務"
verify_migration_status "eks"
verify_migration_status "ecs"
verify_migration_status "ec2"

echo "✅ 混合環境遷移完成！"
```

## 🏗️ VPC 基礎設施準備

所有服務遷移都需要先準備 VPC 基礎設施：

### 方案 A：複製來源區域 VPC 設定（推薦）

```bash
#!/bin/bash
# replicate_vpc_from_source.sh
source common_functions.sh
load_config
validate_basic_config

echo "🔍 分析來源區域 VPC 設定..."

# 使用共用函數複製 VPC
# 詳細實作請參考 common_functions.sh 中的 get_vpc_resources 函數

# 1. 獲取來源 VPC 資訊
SOURCE_VPC_NAME="${VPC_NAME:-migration-vpc}"
SOURCE_VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=$SOURCE_VPC_NAME" "Name=state,Values=available" \
    --query 'Vpcs[0].VpcId' --output text --region $SOURCE_REGION)

if [[ "$SOURCE_VPC_ID" == "None" || -z "$SOURCE_VPC_ID" ]]; then
    echo "❌ 找不到來源 VPC '$SOURCE_VPC_NAME'，請確認 VPC 名稱或使用方案 B"
    exit 1
fi

echo "✅ 找到來源 VPC: $SOURCE_VPC_ID"

# 2. 生成 CloudFormation 模板並部署
# 詳細實作請參考原始的 replicate_vpc_from_source.sh

echo "🚀 部署 VPC 基礎設施到目標區域..."
# ... CloudFormation 部署邏輯 ...

echo "✅ VPC 複製完成！"
```

### 方案 B：使用預定義模板

```bash
#!/bin/bash
# create_new_vpc.sh
source common_functions.sh
load_config
validate_basic_config

echo "🏗️ 使用預定義模板建立 VPC..."

# 直接部署預定義的 VPC 模板
aws cloudformation deploy \
    --template-file vpc-infrastructure-template.yaml \
    --stack-name vpc-infrastructure \
    --parameter-overrides VpcCidr=$VPC_CIDR VpcName=$VPC_NAME \
    --region $TARGET_REGION

echo "✅ VPC 建立完成！"
```

## 📊 遷移狀態監控

### 統一驗證腳本

```bash
#!/bin/bash
# verify_all_migrations.sh
source common_functions.sh
load_config

echo "🔍 驗證所有服務遷移狀態..."

# 檢查 VPC 基礎設施
echo "=== VPC 基礎設施 ==="
get_vpc_resources

# 檢查各服務狀態
echo "=== EKS 服務 ==="
verify_migration_status "eks"

echo "=== ECS 服務 ==="
verify_migration_status "ecs"

echo "=== EC2 服務 ==="
verify_migration_status "ec2"

# 檢查 RDS 狀態
if [[ -n "$DB_INSTANCE_ID" ]]; then
    echo "=== RDS 資料庫 ==="
    aws rds describe-db-instances \
        --db-instance-identifier "${DB_INSTANCE_ID}-taipei" \
        --query 'DBInstances[0].{Status:DBInstanceStatus,Endpoint:Endpoint.Address}' \
        --region $TARGET_REGION 2>/dev/null || echo "RDS 執行個體不存在"
fi

echo "✅ 驗證完成！"
```

## 🔄 DNS 流量切換

### 統一流量切換

```bash
#!/bin/bash
# switch_all_traffic.sh
source common_functions.sh
load_config

if [[ -z "$HOSTED_ZONE_ID" ]]; then
    echo "⚠️  HOSTED_ZONE_ID 未設定，跳過 DNS 切換"
    exit 0
fi

echo "🔄 開始統一流量切換..."

# EKS 流量切換
if kubectl get service -n default your-service >/dev/null 2>&1; then
    EKS_ENDPOINT=$(kubectl get service -n default your-service -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    switch_dns_traffic "eks" "$EKS_ENDPOINT"
fi

# ECS 流量切換
if [ -f "ecs_migration/alb_arn.txt" ]; then
    ALB_ARN=$(cat ecs_migration/alb_arn.txt)
    ECS_ENDPOINT=$(aws elbv2 describe-load-balancers \
        --load-balancer-arns $ALB_ARN \
        --query 'LoadBalancers[0].DNSName' \
        --output text --region $TARGET_REGION)
    switch_dns_traffic "ecs" "$ECS_ENDPOINT"
fi

# EC2 流量切換
if [ -f "ec2_migration/alb_arn.txt" ]; then
    ALB_ARN=$(cat ec2_migration/alb_arn.txt)
    EC2_ENDPOINT=$(aws elbv2 describe-load-balancers \
        --load-balancer-arns $ALB_ARN \
        --query 'LoadBalancers[0].DNSName' \
        --output text --region $TARGET_REGION)
    switch_dns_traffic "ec2" "$EC2_ENDPOINT"
fi

echo "✅ 統一流量切換完成！"
```

## 🚨 緊急回滾

### 統一回滾腳本

```bash
#!/bin/bash
# emergency_rollback_all.sh
source common_functions.sh
load_config

echo "🚨 執行統一緊急回滾..."

# 回滾所有服務的 DNS 記錄
emergency_rollback "eks" "$SOURCE_EKS_ENDPOINT"
emergency_rollback "ecs" "$SOURCE_ECS_ENDPOINT"
emergency_rollback "ec2" "$SOURCE_EC2_ENDPOINT"

echo "✅ 統一緊急回滾完成！所有流量已切回 Tokyo Region"
```

## 📁 檔案組織建議

建議的專案結構：

```
tpe-region-migration-guidance/
├── README.md                           # 專案總覽
├── tpe_migration.md                    # 架構設計指南
├── tpe_migration_deployment.md         # 部署總覽（本檔案）
├── common_functions.sh                 # 共用函數庫
├── config.sh.example                   # 設定檔範本
├── config.sh                          # 實際設定檔（使用者建立）
├── generated-diagrams/                 # 架構圖目錄
│   ├── eks_migration_architecture.png
│   ├── ecs_migration_architecture.png
│   └── ec2_migration_architecture.png
├── eks_migration_deployment.md         # EKS 專用指南
├── ecs_migration_deployment.md         # ECS 專用指南
├── ec2_migration_deployment.md         # EC2 專用指南
├── complete_mixed_migration.sh         # 混合環境遷移
├── verify_all_migrations.sh           # 統一驗證
├── switch_all_traffic.sh              # 統一流量切換
└── emergency_rollback_all.sh           # 統一緊急回滾
```

## 🎯 使用建議

### 單一服務遷移
- 直接使用對應的專用部署指南
- 例如：只有 EKS → 使用 `eks_migration_deployment.md`

### 混合環境遷移
- 使用本檔案提供的統一腳本
- 可以並行處理多種服務

### 大型企業環境
- 建議分階段執行，先測試環境後生產環境
- 使用統一的監控和回滾機制

## 📞 支援資源

- **架構設計問題**：參考 `tpe_migration.md`
- **EKS 特定問題**：參考 `eks_migration_deployment.md`
- **ECS 特定問題**：參考 `ecs_migration_deployment.md`
- **EC2 特定問題**：參考 `ec2_migration_deployment.md`
- **共用函數問題**：參考 `common_functions.sh` 中的說明

## 前置準備

### 環境變數設定

建立並設定環境變數檔案：

```bash
#!/bin/bash
# config.sh - 設定環境變數
export SOURCE_REGION="ap-northeast-1"
export TARGET_REGION="ap-east-2"
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export CLUSTER_NAME="your-cluster"
export DB_INSTANCE_ID="your-db-instance"

# VPC 相關設定
export VPC_NAME="migration-vpc"  # 目標區域的 VPC 名稱
export VPC_CIDR="10.0.0.0/16"   # 如果需要建立新 VPC 時使用

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

### CloudFormation 代碼生成

```bash
#!/bin/bash
# generate_cloudformation_code.sh
generate_cloudformation_code() {
    echo "📝 生成 CloudFormation 模板..."
    
    cd iac-output/cloudformation
    
    # 準備資源清單
    case $MIGRATION_TYPE in
        "eks")
            generate_eks_resources_list
            ;;
        "ecs")
            generate_ecs_resources_list
            ;;
        "ec2")
            generate_ec2_resources_list
            ;;
        "all")
            generate_all_resources_list
            ;;
    esac
    
    # 使用 AWS IaC Generator
    TEMPLATE_NAME="migration-template-$(date +%s)"
    
    echo "🔄 建立 CloudFormation 生成模板..."
    aws cloudformation create-generated-template \
        --generated-template-name $TEMPLATE_NAME \
        --resources file://resource-list.json \
        --region $TARGET_REGION
    
    # 等待模板生成完成
    echo "⏳ 等待 CloudFormation 模板生成..."
    aws cloudformation wait template-generation-complete \
        --generated-template-name $TEMPLATE_NAME \
        --region $TARGET_REGION
    
    # 下載生成的模板
    aws cloudformation get-generated-template \
        --generated-template-name $TEMPLATE_NAME \
        --region $TARGET_REGION \
        --query 'TemplateBody' \
        --output text > infrastructure-template.yaml
    
    # 生成參數檔案
    cat > parameters.json << EOF
[
  {
    "ParameterKey": "SourceRegion",
    "ParameterValue": "$SOURCE_REGION"
  },
  {
    "ParameterKey": "TargetRegion",
    "ParameterValue": "$TARGET_REGION"
  },
  {
    "ParameterKey": "ClusterName",
    "ParameterValue": "$CLUSTER_NAME"
  },
  {
    "ParameterKey": "Environment",
    "ParameterValue": "production"
  }
]
EOF
    
    # 生成部署腳本
    cat > deploy.sh << 'EOF'
#!/bin/bash
# CloudFormation 部署腳本

STACK_NAME="migration-infrastructure"
TEMPLATE_FILE="infrastructure-template.yaml"
PARAMETERS_FILE="parameters.json"

echo "🚀 部署 CloudFormation Stack..."

aws cloudformation deploy \
  --template-file $TEMPLATE_FILE \
  --stack-name $STACK_NAME \
  --parameter-overrides file://$PARAMETERS_FILE \
  --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
  --region $TARGET_REGION

if [ $? -eq 0 ]; then
    echo "✅ CloudFormation Stack 部署成功！"
    echo "Stack 名稱: $STACK_NAME"
    echo "區域: $TARGET_REGION"
else
    echo "❌ CloudFormation Stack 部署失敗"
    exit 1
fi
EOF
    
    chmod +x deploy.sh
    
    echo "✅ CloudFormation 模板生成完成！"
    echo "模板: iac-output/cloudformation/infrastructure-template.yaml"
    echo "參數: iac-output/cloudformation/parameters.json"
    echo "部署腳本: iac-output/cloudformation/deploy.sh"
    
    cd ../..
}

# 生成 EKS 資源清單
generate_eks_resources_list() {
    echo "📋 準備 EKS 資源清單..."
    
    # 獲取 VPC ID
    if [[ -z "$TARGET_VPC_ID" ]]; then
        TARGET_VPC_ID=$(aws ec2 describe-vpcs \
            --filters "Name=tag:Name,Values=${VPC_NAME:-migration-vpc}" \
            --query 'Vpcs[0].VpcId' --output text --region $TARGET_REGION)
    fi
    
    cat > resource-list.json << EOF
[
  {
    "ResourceType": "AWS::EKS::Cluster",
    "ResourceIdentifier": {
      "ClusterName": "$CLUSTER_NAME"
    }
  },
  {
    "ResourceType": "AWS::EC2::VPC",
    "ResourceIdentifier": {
      "VpcId": "$TARGET_VPC_ID"
    }
  },
  {
    "ResourceType": "AWS::IAM::Role",
    "ResourceIdentifier": {
      "RoleName": "eksServiceRole"
    }
  }
]
EOF
}

# 生成 ECS 資源清單
generate_ecs_resources_list() {
    echo "📋 準備 ECS 資源清單..."
    
    cat > resource-list.json << EOF
[
  {
    "ResourceType": "AWS::ECS::Cluster",
    "ResourceIdentifier": {
      "ClusterName": "$CLUSTER_NAME"
    }
  },
  {
    "ResourceType": "AWS::EC2::VPC",
    "ResourceIdentifier": {
      "VpcId": "$TARGET_VPC_ID"
    }
  },
  {
    "ResourceType": "AWS::ElasticLoadBalancingV2::LoadBalancer",
    "ResourceIdentifier": {
      "LoadBalancerArn": "$(cat alb_arn.txt 2>/dev/null || echo 'arn:aws:elasticloadbalancing:region:account:loadbalancer/app/name/id')"
    }
  }
]
EOF
}

# 生成 EC2 資源清單
generate_ec2_resources_list() {
    echo "📋 準備 EC2 資源清單..."
    
    cat > resource-list.json << EOF
[
  {
    "ResourceType": "AWS::EC2::VPC",
    "ResourceIdentifier": {
      "VpcId": "$TARGET_VPC_ID"
    }
  },
  {
    "ResourceType": "AWS::AutoScaling::AutoScalingGroup",
    "ResourceIdentifier": {
      "AutoScalingGroupName": "tpe-app-asg"
    }
  },
  {
    "ResourceType": "AWS::EC2::LaunchTemplate",
    "ResourceIdentifier": {
      "LaunchTemplateName": "tpe-app-launch-template"
    }
  },
  {
    "ResourceType": "AWS::ElasticLoadBalancingV2::LoadBalancer",
    "ResourceIdentifier": {
      "LoadBalancerArn": "$(cat alb_arn.txt 2>/dev/null || echo 'arn:aws:elasticloadbalancing:region:account:loadbalancer/app/name/id')"
    }
  }
]
EOF
}

# 生成所有資源清單
generate_all_resources_list() {
    echo "📋 準備完整資源清單..."
    
    cat > resource-list.json << EOF
[
  {
    "ResourceType": "AWS::EKS::Cluster",
    "ResourceIdentifier": {
      "ClusterName": "$CLUSTER_NAME"
    }
  },
  {
    "ResourceType": "AWS::ECS::Cluster",
    "ResourceIdentifier": {
      "ClusterName": "$CLUSTER_NAME"
    }
  },
  {
    "ResourceType": "AWS::EC2::VPC",
    "ResourceIdentifier": {
      "VpcId": "$TARGET_VPC_ID"
    }
  },
  {
    "ResourceType": "AWS::RDS::DBInstance",
    "ResourceIdentifier": {
      "DBInstanceIdentifier": "${DB_INSTANCE_ID}-tpe"
    }
  },
  {
    "ResourceType": "AWS::AutoScaling::AutoScalingGroup",
    "ResourceIdentifier": {
      "AutoScalingGroupName": "tpe-app-asg"
    }
  }
]
EOF
}
```

### 整合的遷移 + CloudFormation 腳本

```bash
#!/bin/bash
# migrate_with_cloudformation.sh
source config.sh

MIGRATION_TYPE="$1"  # eks, ecs, ec2

echo "🚀 開始遷移 + CloudFormation 轉換流程..."

# 階段 1：執行遷移
echo "📋 階段 1：執行環境遷移"
case $MIGRATION_TYPE in
    "eks")
        ./export_eks_config.sh
        ./modify_eks_config.sh
        ./deploy_eks_cluster.sh &
        MIGRATION_PID=$!
        ;;
    "ecs")
        ./export_ecs_config.sh
        ./deploy_ecs_cluster.sh &
        MIGRATION_PID=$!
        ;;
    "ec2")
        ./create_and_copy_ami.sh
        ./setup_ec2_infrastructure.sh &
        MIGRATION_PID=$!
        ;;
esac

# 階段 2：並行生成 CloudFormation 模板
echo "📋 階段 2：生成 CloudFormation 模板"
./generate_cloudformation_from_existing.sh $MIGRATION_TYPE &
CF_PID=$!

# 等待兩個程序完成
wait $MIGRATION_PID
wait $CF_PID

# 階段 3：驗證 CloudFormation 模板
echo "📋 階段 3：驗證 CloudFormation 模板"
cd iac-output/cloudformation

aws cloudformation validate-template \
    --template-body file://infrastructure-template.yaml \
    --region $TARGET_REGION

if [ $? -eq 0 ]; then
    echo "✅ CloudFormation 模板驗證成功！"
else
    echo "❌ CloudFormation 模板驗證失敗"
    exit 1
fi

cd ../..

echo "✅ 遷移 + CloudFormation 轉換完成！"
echo "📁 遷移結果：已部署到 $TARGET_REGION"
echo "📁 CloudFormation 模板：iac-output/cloudformation/"
echo ""
echo "🚀 下一步：使用 CloudFormation 管理基礎設施"
echo "   cd iac-output/cloudformation/"
echo "   ./deploy.sh"
```

## 前置準備

### VPC 基礎設施準備

#### 方案 1：複製來源區域 VPC 設定（推薦）

```bash
#!/bin/bash
# replicate_vpc_from_source.sh
source config.sh

echo "🔍 分析來源區域 VPC 設定..."

# 1. 獲取來源 VPC 資訊
SOURCE_VPC_NAME="${VPC_NAME:-migration-vpc}"
SOURCE_VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=$SOURCE_VPC_NAME" "Name=state,Values=available" \
    --query 'Vpcs[0].VpcId' --output text --region $SOURCE_REGION)

if [[ "$SOURCE_VPC_ID" == "None" || -z "$SOURCE_VPC_ID" ]]; then
    echo "❌ 找不到來源 VPC '$SOURCE_VPC_NAME'，請確認 VPC 名稱或使用方案 2"
    exit 1
fi

echo "✅ 找到來源 VPC: $SOURCE_VPC_ID"

# 2. 匯出來源 VPC 設定
echo "📤 匯出來源 VPC 設定..."

# 獲取 VPC 基本資訊
aws ec2 describe-vpcs --vpc-ids $SOURCE_VPC_ID --region $SOURCE_REGION \
    --query 'Vpcs[0].{CidrBlock:CidrBlock,Tags:Tags}' > source-vpc-config.json

# 獲取子網路設定
aws ec2 describe-subnets --filters "Name=vpc-id,Values=$SOURCE_VPC_ID" --region $SOURCE_REGION \
    --query 'Subnets[].{SubnetId:SubnetId,CidrBlock:CidrBlock,AvailabilityZone:AvailabilityZone,Tags:Tags,MapPublicIpOnLaunch:MapPublicIpOnLaunch}' \
    > source-subnets-config.json

# 獲取路由表設定
aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$SOURCE_VPC_ID" --region $SOURCE_REGION \
    --query 'RouteTables[].{RouteTableId:RouteTableId,Routes:Routes,Associations:Associations,Tags:Tags}' \
    > source-route-tables-config.json

# 獲取安全群組設定
aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$SOURCE_VPC_ID" --region $SOURCE_REGION \
    --query 'SecurityGroups[].{GroupId:GroupId,GroupName:GroupName,Description:Description,IpPermissions:IpPermissions,IpPermissionsEgress:IpPermissionsEgress,Tags:Tags}' \
    > source-security-groups-config.json

# 獲取網際網路閘道設定
aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$SOURCE_VPC_ID" --region $SOURCE_REGION \
    --query 'InternetGateways[].{InternetGatewayId:InternetGatewayId,Tags:Tags}' \
    > source-igw-config.json

# 獲取 NAT 閘道設定
aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$SOURCE_VPC_ID" --region $SOURCE_REGION \
    --query 'NatGateways[].{NatGatewayId:NatGatewayId,SubnetId:SubnetId,Tags:Tags,State:State}' \
    > source-nat-gateways-config.json

echo "✅ VPC 設定匯出完成"

# 3. 生成目標區域的 CloudFormation 模板
echo "📝 生成目標區域 CloudFormation 模板..."

# 允許使用者自訂 CIDR（可選）
read -p "是否要修改 VPC CIDR？(y/N): " modify_cidr
if [[ "$modify_cidr" =~ ^[Yy]$ ]]; then
    read -p "請輸入新的 VPC CIDR (預設: $VPC_CIDR): " new_cidr
    VPC_CIDR=${new_cidr:-$VPC_CIDR}
fi

cat > vpc-infrastructure-template.yaml << EOF
AWSTemplateFormatVersion: '2010-09-09'
Description: 'VPC Infrastructure replicated from source region'

Parameters:
  VpcCidr:
    Type: String
    Default: '$VPC_CIDR'
    Description: 'CIDR block for the VPC'
  
  VpcName:
    Type: String
    Default: '$VPC_NAME'
    Description: 'Name for the VPC'

Resources:
  # VPC
  VPC:
    Type: AWS::EC2::VPC
    Properties:
      CidrBlock: !Ref VpcCidr
      EnableDnsHostnames: true
      EnableDnsSupport: true
      Tags:
        - Key: Name
          Value: !Ref VpcName
        - Key: Purpose
          Value: Migration
        - Key: SourceRegion
          Value: '$SOURCE_REGION'

EOF

# 動態生成子網路配置
echo "  # Subnets" >> vpc-infrastructure-template.yaml
python3 << EOF
import json
import ipaddress
import subprocess
import os

# 讀取來源子網路配置
with open('source-subnets-config.json', 'r') as f:
    source_subnets = json.load(f)

# 獲取目標區域的可用區域
target_region = os.environ.get('TARGET_REGION', 'ap-east-2')
target_azs = subprocess.check_output([
    'aws', 'ec2', 'describe-availability-zones', 
    '--region', target_region,
    '--query', 'AvailabilityZones[].ZoneName',
    '--output', 'text'
]).decode().strip().split()

# 生成新的子網路 CIDR
vpc_cidr = os.environ.get('VPC_CIDR', '10.0.0.0/16')
vpc_network = ipaddress.IPv4Network(vpc_cidr)
subnet_size = 24  # /24 子網路

public_subnets = []
private_subnets = []

# 分類來源子網路
for subnet in source_subnets:
    is_public = subnet.get('MapPublicIpOnLaunch', False)
    subnet_type = 'Public' if is_public else 'Private'
    
    # 從標籤中獲取類型
    for tag in subnet.get('Tags', []):
        if tag['Key'] == 'Type':
            subnet_type = tag['Value']
            break
    
    if subnet_type == 'Public':
        public_subnets.append(subnet)
    else:
        private_subnets.append(subnet)

# 生成 CloudFormation 子網路資源
subnet_counter = 1
for i, az in enumerate(target_azs[:2]):  # 限制為前兩個 AZ
    # 公有子網路
    if i < len(public_subnets):
        cidr = str(list(vpc_network.subnets(new_prefix=subnet_size))[subnet_counter])
        print(f'''  PublicSubnet{i+1}:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref VPC
      CidrBlock: {cidr}
      AvailabilityZone: {az}
      MapPublicIpOnLaunch: true
      Tags:
        - Key: Name
          Value: Public-{i+1}
        - Key: Type
          Value: Public
''')
        subnet_counter += 1
    
    # 私有子網路
    if i < len(private_subnets):
        cidr = str(list(vpc_network.subnets(new_prefix=subnet_size))[subnet_counter + 10])
        print(f'''  PrivateSubnet{i+1}:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref VPC
      CidrBlock: {cidr}
      AvailabilityZone: {az}
      MapPublicIpOnLaunch: false
      Tags:
        - Key: Name
          Value: Private-{i+1}
        - Key: Type
          Value: Private
''')

EOF

# 加入網際網路閘道和 NAT 閘道
cat >> vpc-infrastructure-template.yaml << 'EOF'

  # Internet Gateway
  InternetGateway:
    Type: AWS::EC2::InternetGateway
    Properties:
      Tags:
        - Key: Name
          Value: !Sub '${VpcName}-igw'

  AttachGateway:
    Type: AWS::EC2::VPCGatewayAttachment
    Properties:
      VpcId: !Ref VPC
      InternetGatewayId: !Ref InternetGateway

  # NAT Gateway
  NATGatewayEIP:
    Type: AWS::EC2::EIP
    DependsOn: AttachGateway
    Properties:
      Domain: vpc

  NATGateway:
    Type: AWS::EC2::NatGateway
    Properties:
      AllocationId: !GetAtt NATGatewayEIP.AllocationId
      SubnetId: !Ref PublicSubnet1
      Tags:
        - Key: Name
          Value: !Sub '${VpcName}-nat'

  # Route Tables
  PublicRouteTable:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref VPC
      Tags:
        - Key: Name
          Value: Public-RT

  PrivateRouteTable:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref VPC
      Tags:
        - Key: Name
          Value: Private-RT

  # Routes
  PublicRoute:
    Type: AWS::EC2::Route
    DependsOn: AttachGateway
    Properties:
      RouteTableId: !Ref PublicRouteTable
      DestinationCidrBlock: 0.0.0.0/0
      GatewayId: !Ref InternetGateway

  PrivateRoute:
    Type: AWS::EC2::Route
    Properties:
      RouteTableId: !Ref PrivateRouteTable
      DestinationCidrBlock: 0.0.0.0/0
      NatGatewayId: !Ref NATGateway

  # Route Table Associations
  PublicSubnetRouteTableAssociation1:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PublicSubnet1
      RouteTableId: !Ref PublicRouteTable

  PublicSubnetRouteTableAssociation2:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PublicSubnet2
      RouteTableId: !Ref PublicRouteTable

  PrivateSubnetRouteTableAssociation1:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PrivateSubnet1
      RouteTableId: !Ref PrivateRouteTable

  PrivateSubnetRouteTableAssociation2:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PrivateSubnet2
      RouteTableId: !Ref PrivateRouteTable

Outputs:
  VpcId:
    Description: 'VPC ID'
    Value: !Ref VPC
    Export:
      Name: !Sub '${AWS::StackName}-VpcId'

  PublicSubnets:
    Description: 'Public Subnet IDs'
    Value: !Join [',', [!Ref PublicSubnet1, !Ref PublicSubnet2]]
    Export:
      Name: !Sub '${AWS::StackName}-PublicSubnets'

  PrivateSubnets:
    Description: 'Private Subnet IDs'
    Value: !Join [',', [!Ref PrivateSubnet1, !Ref PrivateSubnet2]]
    Export:
      Name: !Sub '${AWS::StackName}-PrivateSubnets'
EOF

echo "✅ CloudFormation 模板生成完成: vpc-infrastructure-template.yaml"

# 4. 部署 VPC 基礎設施
echo "🚀 部署 VPC 基礎設施到目標區域..."

aws cloudformation deploy \
    --template-file vpc-infrastructure-template.yaml \
    --stack-name vpc-infrastructure \
    --parameter-overrides VpcCidr=$VPC_CIDR VpcName=$VPC_NAME \
    --region $TARGET_REGION

if [ $? -eq 0 ]; then
    echo "✅ VPC 基礎設施部署成功！"
    
    # 獲取部署結果
    VPC_ID=$(aws cloudformation describe-stacks \
        --stack-name vpc-infrastructure \
        --query 'Stacks[0].Outputs[?OutputKey==`VpcId`].OutputValue' \
        --output text --region $TARGET_REGION)
    
    echo "新建立的 VPC ID: $VPC_ID"
    echo "VPC 資訊已儲存到環境變數"
    
    # 更新 config.sh
    echo "export TARGET_VPC_ID=$VPC_ID" >> config.sh
else
    echo "❌ VPC 基礎設施部署失敗"
    exit 1
fi

echo "🎉 VPC 複製完成！"
```

#### 方案 2：使用預定義 CloudFormation 模板

如果來源區域沒有合適的 VPC 或需要全新建立，可以使用以下模板：

```bash
#!/bin/bash
# create_new_vpc.sh
source config.sh

echo "🏗️ 使用預定義模板建立 VPC..."

# 直接部署預定義的 VPC 模板
aws cloudformation deploy \
    --template-file vpc-infrastructure-template.yaml \
    --stack-name vpc-infrastructure \
    --parameter-overrides VpcCidr=$VPC_CIDR VpcName=$VPC_NAME \
    --region $TARGET_REGION

echo "✅ VPC 建立完成！"
```

## ECR 跨區域複製設定

## ECR 跨區域複製（所有案例通用）

### 設定自動複製規則

```bash
#!/bin/bash
# setup_ecr_replication.sh
source config.sh

echo "🔄 設定 ECR 跨區域複製規則..."

aws ecr put-replication-configuration \
  --replication-configuration '{
    "rules": [
      {
        "destinations": [
          {
            "region": "'$TARGET_REGION'",
            "registryId": "'$AWS_ACCOUNT_ID'"
          }
        ],
        "repositoryFilters": [
          {
            "filter": "*",
            "filterType": "PREFIX_MATCH"
          }
        ]
      }
    ]
  }' \
  --region $SOURCE_REGION

echo "✅ ECR 跨區域複製規則設定完成！"

# 驗證複製狀態
echo "🔍 驗證映像複製狀態..."
sleep 30
aws ecr describe-repositories --region $TARGET_REGION --query 'repositories[].repositoryName' --output table
```

### ECR 複製驗證

```bash
#!/bin/bash
# verify_ecr_replication.sh
source config.sh

echo "🔍 驗證 ECR 映像複製狀態..."

echo "來源區域 ($SOURCE_REGION) 的儲存庫："
aws ecr describe-repositories --region $SOURCE_REGION --query 'repositories[].repositoryName' --output table

echo "目標區域 ($TARGET_REGION) 的儲存庫："
aws ecr describe-repositories --region $TARGET_REGION --query 'repositories[].repositoryName' --output table

# 比較映像標籤
for repo in $(aws ecr describe-repositories --region $SOURCE_REGION --query 'repositories[].repositoryName' --output text); do
    echo "檢查儲存庫: $repo"
    echo "來源區域映像："
    aws ecr list-images --repository-name $repo --region $SOURCE_REGION --query 'imageIds[].imageTag' --output table
    echo "目標區域映像："
    aws ecr list-images --repository-name $repo --region $TARGET_REGION --query 'imageIds[].imageTag' --output table
    echo "---"
done
```

## 案例一：EKS 叢集完整遷移

### 搬遷步驟順序
1. **Week 1**: 設定 ECR 跨區域複製（背景執行）
2. **Week 2**: 匯出 EKS 叢集設定 → 修改區域參數 → 部署到 Taipei Region
3. **Week 3**: RDS 快照遷移 + DMS 差異同步 + Kubernetes 應用程式部署
4. **Week 4**: 測試驗證 + DNS 流量切換

### 1. 匯出 EKS 叢集設定

```bash
#!/bin/bash
# export_eks_config.sh
source config.sh

echo "📤 匯出 EKS 叢集設定..."

# 1. 匯出叢集基本設定
aws eks describe-cluster \
  --name $CLUSTER_NAME \
  --region $SOURCE_REGION \
  --query 'cluster.{name:name,version:version,roleArn:roleArn,resourcesVpcConfig:resourcesVpcConfig,logging:logging,encryptionConfig:encryptionConfig,tags:tags}' \
  > eks-cluster-config.json

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
      --query 'nodegroup.{nodegroupName:nodegroupName,scalingConfig:scalingConfig,instanceTypes:instanceTypes,amiType:amiType,capacityType:capacityType,diskSize:diskSize,nodeRole:nodeRole,subnets:subnets,remoteAccess:remoteAccess,labels:labels,tags:tags}' \
      > "nodegroup-${nodegroup}-config.json"
done

# 3. 匯出附加元件設定
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
      --query 'addon.{addonName:addonName,addonVersion:addonVersion,serviceAccountRoleArn:serviceAccountRoleArn,configurationValues:configurationValues,tags:tags}' \
      > "addon-${addon}-config.json"
done

echo "✅ EKS 設定匯出完成！"
```

### 2. 修改區域特定設定

```bash
#!/bin/bash
# modify_eks_config.sh
source config.sh

echo "🔧 修改區域特定設定..."

# 獲取目標區域的 VPC 資源
get_vpc_resources() {
    local vpc_name=${VPC_NAME:-"migration-vpc"}
    
    # 查找 VPC
    TARGET_VPC_ID=$(aws ec2 describe-vpcs \
        --filters "Name=tag:Name,Values=$vpc_name" "Name=state,Values=available" \
        --query 'Vpcs[0].VpcId' --output text --region $TARGET_REGION)
    
    if [[ "$TARGET_VPC_ID" == "None" || -z "$TARGET_VPC_ID" ]]; then
        echo "錯誤：在 $TARGET_REGION 找不到名為 '$vpc_name' 的 VPC"
        echo "請確認 VPC 存在或設定正確的 VPC_NAME 環境變數"
        exit 1
    fi
    
    # 獲取私有子網路（確保多 AZ 分佈）
    PRIVATE_SUBNET_IDS=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$TARGET_VPC_ID" \
                  "Name=tag:Type,Values=Private" \
                  "Name=state,Values=available" \
        --query 'Subnets[].{SubnetId:SubnetId,AZ:AvailabilityZone} | sort_by(@, &AZ) | [].SubnetId' \
        --output text --region $TARGET_REGION)
    
    # 獲取公有子網路（確保多 AZ 分佈）
    PUBLIC_SUBNET_IDS=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$TARGET_VPC_ID" \
                  "Name=tag:Type,Values=Public" \
                  "Name=state,Values=available" \
        --query 'Subnets[].{SubnetId:SubnetId,AZ:AvailabilityZone} | sort_by(@, &AZ) | [].SubnetId' \
        --output text --region $TARGET_REGION)
    
    # 驗證子網路數量（至少需要 2 個不同 AZ）
    PRIVATE_AZ_COUNT=$(aws ec2 describe-subnets \
        --subnet-ids $PRIVATE_SUBNET_IDS \
        --query 'length(Subnets[].AvailabilityZone | sort(@) | unique(@))' \
        --output text --region $TARGET_REGION 2>/dev/null || echo "0")
    
    if [[ "$PRIVATE_AZ_COUNT" -lt 2 ]]; then
        echo "警告：私有子網路未跨越至少 2 個可用區域，這可能影響高可用性"
    fi
    
    # 查找或建立 EKS 安全群組
    EKS_SECURITY_GROUP_ID=$(aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=$TARGET_VPC_ID" \
                  "Name=tag:Purpose,Values=EKS-Cluster" \
        --query 'SecurityGroups[0].GroupId' --output text --region $TARGET_REGION)
    
    if [[ "$EKS_SECURITY_GROUP_ID" == "None" || -z "$EKS_SECURITY_GROUP_ID" ]]; then
        echo "建立 EKS 叢集安全群組..."
        EKS_SECURITY_GROUP_ID=$(aws ec2 create-security-group \
            --group-name "eks-cluster-sg-$(date +%s)" \
            --description "Security group for EKS cluster migration" \
            --vpc-id $TARGET_VPC_ID \
            --tag-specifications "ResourceType=security-group,Tags=[{Key=Purpose,Value=EKS-Cluster},{Key=Name,Value=eks-cluster-sg}]" \
            --query 'GroupId' --output text --region $TARGET_REGION)
    fi
    
    echo "✅ VPC 資源獲取完成："
    echo "  VPC ID: $TARGET_VPC_ID"
    echo "  私有子網路: $PRIVATE_SUBNET_IDS"
    echo "  公有子網路: $PUBLIC_SUBNET_IDS"
    echo "  EKS 安全群組: $EKS_SECURITY_GROUP_ID"
}

# 執行 VPC 資源獲取
get_vpc_resources

# 設定變數供後續使用
TARGET_SUBNET_IDS="$PRIVATE_SUBNET_IDS $PUBLIC_SUBNET_IDS"
TARGET_SECURITY_GROUP_ID="$EKS_SECURITY_GROUP_ID"

# 更新叢集設定檔
jq --arg subnets "$(echo $TARGET_SUBNET_IDS | tr ' ' ',')" \
   --arg sg "$TARGET_SECURITY_GROUP_ID" \
   '.resourcesVpcConfig.subnetIds = ($subnets | split(",")) | 
    .resourcesVpcConfig.securityGroupIds = [$sg]' \
   eks-cluster-config.json > eks-cluster-config-modified.json

# 修改節點群組設定中的子網路
for nodegroup_file in nodegroup-*-config.json; do
    if [ -f "$nodegroup_file" ]; then
        echo "修改 $nodegroup_file"
        jq --arg subnets "$(echo $TARGET_SUBNET_IDS | tr ' ' ',')" \
           '.subnets = ($subnets | split(","))' \
           "$nodegroup_file" > "${nodegroup_file%.json}-modified.json"
    fi
done

echo "✅ 設定修改完成！"
```

### 3. 部署到 Taipei Region

```bash
#!/bin/bash
# deploy_eks_cluster.sh
source config.sh

echo "🚀 在 Taipei Region 部署 EKS 叢集..."

# 1. 建立 EKS 叢集
CLUSTER_CONFIG=$(cat eks-cluster-config-modified.json)
aws eks create-cluster \
  --region $TARGET_REGION \
  --name $CLUSTER_NAME \
  --version $(echo $CLUSTER_CONFIG | jq -r '.version') \
  --role-arn $(echo $CLUSTER_CONFIG | jq -r '.roleArn') \
  --resources-vpc-config "$(echo $CLUSTER_CONFIG | jq -c '.resourcesVpcConfig')" \
  --logging "$(echo $CLUSTER_CONFIG | jq -c '.logging // {}')" \
  --tags "$(echo $CLUSTER_CONFIG | jq -c '.tags // {}')"

# 等待叢集建立完成
echo "⏳ 等待 EKS 叢集建立完成..."
aws eks wait cluster-active --name $CLUSTER_NAME --region $TARGET_REGION

# 2. 建立節點群組
for nodegroup_file in nodegroup-*-modified.json; do
    if [ -f "$nodegroup_file" ]; then
        echo "建立節點群組: $nodegroup_file"
        NODEGROUP_CONFIG=$(cat "$nodegroup_file")
        NODEGROUP_NAME=$(echo $NODEGROUP_CONFIG | jq -r '.nodegroupName')
        
        # 準備參數
        INSTANCE_TYPES=$(echo $NODEGROUP_CONFIG | jq -r '.instanceTypes | join(" ")')
        SUBNET_IDS=$(echo $NODEGROUP_CONFIG | jq -r '.subnets | join(" ")')
        
        aws eks create-nodegroup \
          --region $TARGET_REGION \
          --cluster-name $CLUSTER_NAME \
          --nodegroup-name $NODEGROUP_NAME \
          --scaling-config "$(echo $NODEGROUP_CONFIG | jq -c '.scalingConfig')" \
          --instance-types $INSTANCE_TYPES \
          --ami-type "$(echo $NODEGROUP_CONFIG | jq -r '.amiType')" \
          --capacity-type "$(echo $NODEGROUP_CONFIG | jq -r '.capacityType // "ON_DEMAND"')" \
          --disk-size "$(echo $NODEGROUP_CONFIG | jq -r '.diskSize // 20')" \
          --node-role "$(echo $NODEGROUP_CONFIG | jq -r '.nodeRole')" \
          --subnets $SUBNET_IDS \
          --labels "$(echo $NODEGROUP_CONFIG | jq -c '.labels // {}')" \
          --tags "$(echo $NODEGROUP_CONFIG | jq -c '.tags // {}')"
        
        # 等待節點群組建立完成
        aws eks wait nodegroup-active --cluster-name $CLUSTER_NAME --nodegroup-name $NODEGROUP_NAME --region $TARGET_REGION
    fi
done

# 3. 安裝附加元件
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
          --service-account-role-arn "$(echo $ADDON_CONFIG | jq -r '.serviceAccountRoleArn // empty')" \
          --configuration-values "$(echo $ADDON_CONFIG | jq -r '.configurationValues // empty')" \
          --tags "$(echo $ADDON_CONFIG | jq -c '.tags // {}')"
    fi
done

echo "✅ EKS 叢集部署完成！"
```

## 案例二：ECS 叢集完整遷移

### 搬遷步驟順序
1. **Week 1**: 設定 ECR 跨區域複製（背景執行）
2. **Week 2**: 匯出 ECS 叢集設定 → 自動修改映像路徑 → 部署到 Taipei Region
3. **Week 3**: RDS 快照遷移 + DMS 差異同步 + ECS 服務部署
4. **Week 4**: 測試驗證 + DNS 流量切換

### 1. 匯出 ECS 設定

```bash
#!/bin/bash
# export_ecs_config.sh
source config.sh

echo "📤 匯出 ECS 叢集設定..."

# 1. 匯出叢集設定
aws ecs describe-clusters \
  --clusters $CLUSTER_NAME \
  --region $SOURCE_REGION \
  --query 'clusters[0].{clusterName:clusterName,tags:tags,settings:settings,configuration:configuration,capacityProviders:capacityProviders,defaultCapacityProviderStrategy:defaultCapacityProviderStrategy}' \
  > ecs-cluster-config.json

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
      --services $service_name \
      --region $SOURCE_REGION \
      --query 'services[0].{serviceName:serviceName,taskDefinition:taskDefinition,desiredCount:desiredCount,launchType:launchType,platformVersion:platformVersion,networkConfiguration:networkConfiguration,loadBalancers:loadBalancers,serviceRegistries:serviceRegistries,tags:tags,enableExecuteCommand:enableExecuteCommand,capacityProviderStrategy:capacityProviderStrategy}' \
      > "service-${service_name}-config.json"
done

# 3. 匯出任務定義
aws ecs list-task-definitions \
  --family-prefix your-app \
  --region $SOURCE_REGION \
  --query 'taskDefinitionArns[-1]' \
  --output text | while read task_def_arn; do
    task_def_name=$(basename $task_def_arn | cut -d':' -f1)
    echo "匯出任務定義: $task_def_name"
    
    aws ecs describe-task-definition \
      --task-definition $task_def_arn \
      --region $SOURCE_REGION \
      --query 'taskDefinition' \
      > "taskdef-${task_def_name}-raw.json"
    
    # 移除不需要的欄位
    jq 'del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .registeredAt, .registeredBy, .compatibilities)' \
      "taskdef-${task_def_name}-raw.json" > "taskdef-${task_def_name}-config.json"
done

echo "✅ ECS 設定匯出完成！"
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
  --region $TARGET_REGION \
  --cluster-name $CLUSTER_NAME \
  --tags "$(echo $CLUSTER_CONFIG | jq -c '.tags // []')" \
  --settings "$(echo $CLUSTER_CONFIG | jq -c '.settings // []')" \
  --configuration "$(echo $CLUSTER_CONFIG | jq -c '.configuration // {}')"

# 2. 註冊任務定義（自動修改映像 URI 和資料庫連線）
for taskdef_file in taskdef-*-config.json; do
    if [ -f "$taskdef_file" ]; then
        echo "註冊任務定義: $taskdef_file"
        
        # 修改容器映像 URI 和環境變數
        jq '.containerDefinitions[].image |= sub("ap-northeast-1"; "ap-east-2") |
            .containerDefinitions[].environment[]? |= if .name == "DB_HOST" then .value |= sub("'$DB_INSTANCE_ID'"; "'$DB_INSTANCE_ID'-tpe") else . end' \
           "$taskdef_file" > "${taskdef_file%.json}-modified.json"
        
        aws ecs register-task-definition \
          --region $TARGET_REGION \
          --cli-input-json file://"${taskdef_file%.json}-modified.json"
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
          --launch-type "$(echo $SERVICE_CONFIG | jq -r '.launchType')" \
          --platform-version "$(echo $SERVICE_CONFIG | jq -r '.platformVersion // "LATEST"')" \
          --network-configuration "$(echo $SERVICE_CONFIG | jq -c '.networkConfiguration')" \
          --load-balancers "$(echo $SERVICE_CONFIG | jq -c '.loadBalancers // []')" \
          --service-registries "$(echo $SERVICE_CONFIG | jq -c '.serviceRegistries // []')" \
          --tags "$(echo $SERVICE_CONFIG | jq -c '.tags // []')" \
          --enable-execute-command "$(echo $SERVICE_CONFIG | jq -r '.enableExecuteCommand // false')"
        
        # 等待服務穩定
        aws ecs wait services-stable --cluster $CLUSTER_NAME --services $SERVICE_NAME --region $TARGET_REGION
    fi
done

### 4. Kubernetes 應用程式遷移

```bash
#!/bin/bash
# migrate_k8s_apps.sh
source config.sh

SOURCE_CLUSTER_CONTEXT="arn:aws:eks:$SOURCE_REGION:$AWS_ACCOUNT_ID:cluster/$CLUSTER_NAME"
TARGET_CLUSTER_CONTEXT="arn:aws:eks:$TARGET_REGION:$AWS_ACCOUNT_ID:cluster/$CLUSTER_NAME"
NAMESPACE="default"

echo "🚀 遷移 Kubernetes 應用程式..."

# 1. 設定 kubectl context
# 更新 kubeconfig
aws eks update-kubeconfig --region $SOURCE_REGION --name $CLUSTER_NAME --alias source-cluster
aws eks update-kubeconfig --region $TARGET_REGION --name $CLUSTER_NAME --alias target-cluster

# 切換到目標 context
kubectl config use-context source-cluster

# 2. 匯出所有應用程式資源
echo "📤 匯出 Kubernetes 資源..."
kubectl --context=source-cluster get deployments,services,configmaps,secrets,ingresses,persistentvolumeclaims \
  -n $NAMESPACE -o yaml > k8s-resources-export.yaml

# 3. 自動修改映像路徑和資料庫連線
echo "🔧 修改容器映像路徑和資料庫設定..."
sed "s/ap-northeast-1/ap-east-2/g" k8s-resources-export.yaml | \
sed "s/${DB_INSTANCE_ID}/${DB_INSTANCE_ID}-tpe/g" > k8s-resources-modified.yaml

# 4. 部署到目標叢集
echo "🚀 部署到目標叢集..."
kubectl --context=target-cluster apply -f k8s-resources-modified.yaml -n $NAMESPACE

# 5. 驗證部署
echo "🔍 驗證部署狀態..."
kubectl --context=target-cluster get pods -n $NAMESPACE
kubectl --context=target-cluster get services -n $NAMESPACE

echo "✅ Kubernetes 應用程式遷移完成！"
```

## 案例三：EC2 工作負載完整遷移

### 搬遷步驟順序
1. **Week 1**: 建立和複製 AMI + 基礎設施準備
2. **Week 2**: 建立啟動範本 + Auto Scaling 群組 + Load Balancer
3. **Week 3**: RDS 快照遷移 + DMS 差異同步 + 應用程式配置更新
4. **Week 4**: 測試驗證 + DNS 流量切換

### 1. 建立和複製 AMI

```bash
#!/bin/bash
# create_and_copy_ami.sh
source config.sh

INSTANCE_ID="i-1234567890abcdef0"  # 替換為實際的執行個體 ID
AMI_NAME="my-app-ami-$(date +%Y%m%d-%H%M%S)"

echo "🖼️ 建立和複製 AMI..."

# 從來源區域的 EC2 執行個體建立 AMI
aws ec2 create-image \
  --instance-id $INSTANCE_ID \
  --name "$AMI_NAME" \
  --description "Application AMI for Taipei migration" \
  --no-reboot \
  --region $SOURCE_REGION

# 獲取建立的 AMI ID
SOURCE_AMI_ID=$(aws ec2 describe-images --owners self --filters "Name=name,Values=$AMI_NAME" --query 'Images[0].ImageId' --output text --region $SOURCE_REGION)

# 等待 AMI 建立完成
echo "⏳ 等待 AMI 建立完成..."
aws ec2 wait image-available \
  --image-ids $SOURCE_AMI_ID \
  --region $SOURCE_REGION

# 複製 AMI 到目標區域
TARGET_AMI_ID=$(aws ec2 copy-image \
  --source-image-id $SOURCE_AMI_ID \
  --source-region $SOURCE_REGION \
  --name "$AMI_NAME-tpe" \
  --description "Application AMI copied to Taipei region" \
  --query 'ImageId' \
  --output text \
  --region $TARGET_REGION)

echo "來源 AMI ID: $SOURCE_AMI_ID"
echo "目標 AMI ID: $TARGET_AMI_ID"

# 儲存 AMI ID 供後續使用
echo $TARGET_AMI_ID > target_ami_id.txt

# 等待 AMI 複製完成
echo "⏳ 等待 AMI 複製完成..."
aws ec2 wait image-available \
  --image-ids $TARGET_AMI_ID \
  --region $TARGET_REGION

echo "✅ AMI 建立和複製完成！"
```

### 2. 建立啟動範本和 Load Balancer

```bash
#!/bin/bash
# setup_ec2_infrastructure.sh
source config.sh

TARGET_AMI_ID=$(cat target_ami_id.txt)

echo "🏗️ 建立 EC2 基礎設施..."

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
KEY_PAIR_NAME="my-key-pair"  # 替換為實際的金鑰對名稱

# 準備 User Data 腳本
cat > user-data.sh << EOF
#!/bin/bash
yum update -y
# 安裝應用程式相依性
yum install -y docker
systemctl start docker
systemctl enable docker

# 更新應用程式設定指向新的資料庫
sed -i 's/${DB_INSTANCE_ID}/${DB_INSTANCE_ID}-tpe/g' /etc/myapp/config.properties
systemctl restart myapp
EOF

# 建立啟動範本
aws ec2 create-launch-template \
  --launch-template-name tpe-app-launch-template \
  --launch-template-data "{
    \"ImageId\": \"$TARGET_AMI_ID\",
    \"InstanceType\": \"t3.medium\",
    \"KeyName\": \"$KEY_PAIR_NAME\",
    \"SecurityGroupIds\": [\"$SECURITY_GROUP_ID\"],
    \"UserData\": \"$(if [[ \"$OSTYPE\" == \"darwin\"* ]]; then base64 -i user-data.sh; else base64 -w 0 user-data.sh; fi)\",
    \"IamInstanceProfile\": {
      \"Name\": \"EC2-App-InstanceProfile\"
    },
    \"TagSpecifications\": [{
      \"ResourceType\": \"instance\",
      \"Tags\": [
        {\"Key\": \"Name\", \"Value\": \"tpe-app-instance\"},
        {\"Key\": \"Environment\", \"Value\": \"production\"},
        {\"Key\": \"Project\", \"Value\": \"tpe-migration\"}
      ]
    }]
  }" \
  --region $TARGET_REGION

# 建立 Application Load Balancer
ALB_ARN=$(aws elbv2 create-load-balancer \
  --name tpe-ec2-alb \
  --subnets $PUBLIC_SUBNET_IDS \
  --security-groups $SECURITY_GROUP_ID \
  --scheme internet-facing \
  --type application \
  --ip-address-type ipv4 \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text \
  --region $TARGET_REGION)

# 建立目標群組
TARGET_GROUP_ARN=$(aws elbv2 create-target-group \
  --name tpe-ec2-targets \
  --protocol HTTP \
  --port 80 \
  --vpc-id $TARGET_VPC_ID \
  --target-type instance \
  --health-check-enabled \
  --health-check-path /health \
  --health-check-interval-seconds 30 \
  --health-check-timeout-seconds 5 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 3 \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text \
  --region $TARGET_REGION)

# 建立監聽器
aws elbv2 create-listener \
  --load-balancer-arn $ALB_ARN \
  --protocol HTTP \
  --port 80 \
  --default-actions Type=forward,TargetGroupArn=$TARGET_GROUP_ARN \
  --region $TARGET_REGION

# 儲存 ARN 供後續使用
echo $ALB_ARN > alb_arn.txt
echo $TARGET_GROUP_ARN > target_group_arn.txt

echo "ALB ARN: $ALB_ARN"
echo "Target Group ARN: $TARGET_GROUP_ARN"
echo "✅ EC2 基礎設施建立完成！"
```

### 3. 建立 Auto Scaling 群組

```bash
#!/bin/bash
# create_autoscaling_group.sh
source config.sh

TARGET_GROUP_ARN=$(cat target_group_arn.txt)

echo "📈 建立 Auto Scaling 群組..."

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
  --auto-scaling-group-name tpe-app-asg \
  --launch-template "{
    \"LaunchTemplateName\": \"tpe-app-launch-template\",
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
  --tags "Key=Name,Value=tpe-app-asg-instance,PropagateAtLaunch=true,ResourceId=tpe-app-asg,ResourceType=auto-scaling-group" \
  --region $TARGET_REGION

# 建立擴展政策
aws autoscaling put-scaling-policy \
  --auto-scaling-group-name tpe-app-asg \
  --policy-name scale-up-policy \
  --policy-type TargetTrackingScaling \
  --target-tracking-configuration '{
    "TargetValue": 70.0,
    "PredefinedMetricSpecification": {
      "PredefinedMetricType": "ASGAverageCPUUtilization"
    }
  }' \
  --region $TARGET_REGION

# 等待執行個體啟動
echo "⏳ 等待 Auto Scaling 群組執行個體啟動..."
sleep 120

# 檢查 Auto Scaling 群組狀態
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names tpe-app-asg \
  --query 'AutoScalingGroups[0].{DesiredCapacity:DesiredCapacity,MinSize:MinSize,MaxSize:MaxSize,Instances:length(Instances)}' \
  --region $TARGET_REGION

echo "✅ Auto Scaling 群組建立完成！"
```

### 4. 驗證 EC2 部署

```bash
#!/bin/bash
# verify_ec2_deployment.sh
source config.sh

ALB_ARN=$(cat alb_arn.txt)
TARGET_GROUP_ARN=$(cat target_group_arn.txt)

echo "🔍 驗證 EC2 部署狀態..."

# 檢查 Auto Scaling 群組狀態
echo "Auto Scaling 群組狀態："
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names tpe-app-asg \
  --query 'AutoScalingGroups[0].{DesiredCapacity:DesiredCapacity,Instances:Instances[].{InstanceId:InstanceId,HealthStatus:HealthStatus,LifecycleState:LifecycleState}}' \
  --region $TARGET_REGION

# 檢查執行個體健康狀態
INSTANCE_IDS=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names tpe-app-asg \
  --query 'AutoScalingGroups[0].Instances[].InstanceId' \
  --output text \
  --region $TARGET_REGION)

echo "執行個體詳細狀態："
aws ec2 describe-instances \
  --instance-ids $INSTANCE_IDS \
  --query 'Reservations[].Instances[].{InstanceId:InstanceId,State:State.Name,InstanceType:InstanceType,LaunchTime:LaunchTime}' \
  --region $TARGET_REGION

# 檢查 Load Balancer 目標健康
echo "Load Balancer 目標健康狀態："
aws elbv2 describe-target-health \
  --target-group-arn $TARGET_GROUP_ARN \
  --query 'TargetHealthDescriptions[].{TargetId:Target.Id,HealthStatus:TargetHealth.State,Description:TargetHealth.Description}' \
  --region $TARGET_REGION

# 獲取 ALB DNS 名稱並測試應用程式
ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns $ALB_ARN \
  --query 'LoadBalancers[0].DNSName' \
  --output text \
  --region $TARGET_REGION)

echo "應用程式端點: http://$ALB_DNS"
echo "測試應用程式健康檢查..."
curl -f http://$ALB_DNS/health || echo "健康檢查失敗，請檢查應用程式狀態"

echo "✅ EC2 部署驗證完成！"
```

## RDS 資料庫遷移（所有案例通用）

### RDS 快照 + DMS 差異同步

```bash
#!/bin/bash
# migrate_rds_with_dms.sh
source config.sh

SNAPSHOT_ID="migration-snapshot-$(date +%Y%m%d-%H%M%S)"

echo "🚀 開始 RDS 資料庫遷移（快照 + DMS 策略）..."

# 1. 建立 RDS 快照
echo "📸 建立 RDS 快照: $SNAPSHOT_ID"
aws rds create-db-snapshot \
  --db-instance-identifier $DB_INSTANCE_ID \
  --db-snapshot-identifier $SNAPSHOT_ID \
  --region $SOURCE_REGION

# 2. 等待快照完成
echo "⏳ 等待快照建立完成..."
aws rds wait db-snapshot-completed \
  --db-snapshot-identifier $SNAPSHOT_ID \
  --region $SOURCE_REGION

# 3. 複製快照到目標區域
echo "📋 複製快照到目標區域..."
aws rds copy-db-snapshot \
  --source-db-snapshot-identifier arn:aws:rds:$SOURCE_REGION:$AWS_ACCOUNT_ID:snapshot:$SNAPSHOT_ID \
  --target-db-snapshot-identifier $SNAPSHOT_ID \
  --region $TARGET_REGION

# 4. 等待快照複製完成
echo "⏳ 等待快照複製完成..."
aws rds wait db-snapshot-completed \
  --db-snapshot-identifier $SNAPSHOT_ID \
  --region $TARGET_REGION

# 5. 從快照還原資料庫
echo "🔄 從快照還原資料庫..."
aws rds restore-db-instance-from-db-snapshot \
  --db-instance-identifier ${DB_INSTANCE_ID}-tpe \
  --db-snapshot-identifier $SNAPSHOT_ID \
  --region $TARGET_REGION

# 6. 等待資料庫可用
echo "⏳ 等待資料庫還原完成..."
aws rds wait db-instance-available \
  --db-instance-identifier ${DB_INSTANCE_ID}-tpe \
  --region $TARGET_REGION

# 7. 設定 DMS 進行差異同步
echo "🔧 設定 DMS 差異同步..."

# 獲取目標 VPC 資訊
get_dms_vpc_resources() {
    local vpc_name=${VPC_NAME:-"migration-vpc"}
    
    TARGET_VPC_ID=$(aws ec2 describe-vpcs \
        --filters "Name=tag:Name,Values=$vpc_name" "Name=state,Values=available" \
        --query 'Vpcs[0].VpcId' --output text --region $TARGET_REGION)
    
    if [[ "$TARGET_VPC_ID" == "None" || -z "$TARGET_VPC_ID" ]]; then
        echo "錯誤：找不到 VPC '$vpc_name'"
        exit 1
    fi
    
    # 獲取私有子網路（DMS 複製執行個體應該在私有子網路中）
    TARGET_SUBNET_IDS=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$TARGET_VPC_ID" \
                  "Name=tag:Type,Values=Private" \
                  "Name=state,Values=available" \
        --query 'Subnets[].SubnetId' --output text --region $TARGET_REGION)
    
    if [[ -z "$TARGET_SUBNET_IDS" ]]; then
        echo "錯誤：找不到私有子網路用於 DMS"
        exit 1
    fi
    
    # 驗證至少有 2 個不同 AZ 的子網路（DMS 要求）
    AZ_COUNT=$(aws ec2 describe-subnets \
        --subnet-ids $TARGET_SUBNET_IDS \
        --query 'length(Subnets[].AvailabilityZone | sort(@) | unique(@))' \
        --output text --region $TARGET_REGION)
    
    if [[ "$AZ_COUNT" -lt 2 ]]; then
        echo "錯誤：DMS 需要至少 2 個不同可用區域的子網路，目前只有 $AZ_COUNT 個"
        exit 1
    fi
    
    echo "✅ DMS VPC 資源驗證完成："
    echo "  VPC ID: $TARGET_VPC_ID"
    echo "  私有子網路: $TARGET_SUBNET_IDS"
    echo "  跨越可用區域數: $AZ_COUNT"
}

get_dms_vpc_resources

# 建立 DMS 子網路群組
aws dms create-replication-subnet-group \
  --replication-subnet-group-identifier dms-subnet-group \
  --replication-subnet-group-description "DMS subnet group for migration" \
  --subnet-ids $TARGET_SUBNET_IDS \
  --region $TARGET_REGION

# 建立 DMS 複製執行個體
aws dms create-replication-instance \
  --replication-instance-identifier dms-migration-instance \
  --replication-instance-class dms.t3.micro \
  --replication-subnet-group-identifier dms-subnet-group \
  --region $TARGET_REGION

# 等待 DMS 執行個體可用
echo "⏳ 等待 DMS 執行個體準備完成..."
aws dms wait replication-instance-available \
  --filters "Name=replication-instance-id,Values=dms-migration-instance" \
  --region $TARGET_REGION

echo "✅ RDS 遷移完成！DMS 已準備好進行差異同步。"
```

### RDS 遷移驗證

```bash
#!/bin/bash
# verify_rds_migration.sh
source config.sh

SOURCE_DB=$DB_INSTANCE_ID
TARGET_DB="${DB_INSTANCE_ID}-tpe"

echo "🔍 驗證 RDS 遷移狀態..."

# 檢查來源資料庫狀態
echo "來源資料庫狀態："
aws rds describe-db-instances \
  --db-instance-identifier $SOURCE_DB \
  --region $SOURCE_REGION \
  --query 'DBInstances[0].{Status:DBInstanceStatus,Engine:Engine,Version:EngineVersion,Size:DBInstanceClass}' \
  --output table

# 檢查目標資料庫狀態
echo "目標資料庫狀態："
aws rds describe-db-instances \
  --db-instance-identifier $TARGET_DB \
  --region $TARGET_REGION \
  --query 'DBInstances[0].{Status:DBInstanceStatus,Engine:Engine,Version:EngineVersion,Size:DBInstanceClass}' \
  --output table

# 檢查 DMS 複製執行個體狀態
echo "DMS 複製執行個體狀態："
aws dms describe-replication-instances \
  --filters "Name=replication-instance-id,Values=dms-migration-instance" \
  --region $TARGET_REGION \
  --query 'ReplicationInstances[0].{Status:ReplicationInstanceStatus,Class:ReplicationInstanceClass}' \
  --output table
```

## 完整自動化遷移腳本

### 主控制腳本

```bash
#!/bin/bash
# complete_migration.sh
MIGRATION_TYPE="$1"  # eks, ecs, ec2, or rds

# 載入設定
source config.sh

# 前置作業：設定 ECR 複製
echo "🔄 設定 ECR 跨區域複製..."
./setup_ecr_replication.sh

case $MIGRATION_TYPE in
    "eks")
        echo "🚀 開始 EKS 完整遷移..."
        # 並行執行 RDS 遷移
        ./migrate_rds_with_dms.sh &
        RDS_PID=$!
        
        # 執行 EKS 遷移
        ./export_eks_config.sh
        ./modify_eks_config.sh
        ./deploy_eks_cluster.sh
        
        # 等待 RDS 遷移完成
        wait $RDS_PID
        
        # 部署 Kubernetes 應用程式
        ./migrate_k8s_apps.sh
        echo "✅ EKS 完整遷移完成！"
        ;;
    "ecs")
        echo "🚀 開始 ECS 完整遷移..."
        # 並行執行 RDS 遷移
        ./migrate_rds_with_dms.sh &
        RDS_PID=$!
        
        # 執行 ECS 遷移
        ./export_ecs_config.sh
        ./deploy_ecs_cluster.sh
        
        # 等待 RDS 遷移完成
        wait $RDS_PID
        echo "✅ ECS 完整遷移完成！"
        ;;
    "ec2")
        echo "🚀 開始 EC2 完整遷移..."
        # 並行執行 RDS 遷移
        ./migrate_rds_with_dms.sh &
        RDS_PID=$!
        
        # 執行 EC2 遷移
        ./create_and_copy_ami.sh
        ./setup_ec2_infrastructure.sh
        ./create_autoscaling_group.sh
        
        # 等待 RDS 遷移完成
        wait $RDS_PID
        
        # 驗證部署
        ./verify_ec2_deployment.sh
        echo "✅ EC2 完整遷移完成！"
        ;;
    "rds")
        echo "🚀 開始 RDS 遷移..."
        ./migrate_rds_with_dms.sh
        echo "✅ RDS 遷移完成！"
        ;;
    "all")
        echo "🚀 開始完整遷移..."
        ./setup_ecr_replication.sh
        ./migrate_rds_with_dms.sh &
        ./$0 $2  # eks, ecs, or ec2
        wait
        echo "✅ 完整遷移完成！"
        ;;
    *)
        echo "使用方式: $0 [eks|ecs|ec2|rds|all] [eks|ecs|ec2]"
        echo "範例: $0 all eks  # 同時遷移 ECR + RDS + EKS"
        echo "範例: $0 all ecs  # 同時遷移 ECR + RDS + ECS"
        echo "範例: $0 all ec2  # 同時遷移 ECR + RDS + EC2"
        exit 1
        ;;
esac
```

## 驗證檢查清單

### 綜合驗證腳本

```bash
#!/bin/bash
# verify_migration.sh
source config.sh

SERVICE_TYPE="$1"  # eks, ecs, or ec2

echo "🔍 開始驗證遷移結果..."

# 1. 驗證 ECR 複製
echo "1️⃣ 驗證 ECR 映像複製..."
./verify_ecr_replication.sh

# 2. 驗證 RDS 遷移
echo "2️⃣ 驗證 RDS 資料庫遷移..."
./verify_rds_migration.sh

# 3. 驗證計算服務
case $SERVICE_TYPE in
    "eks")
        echo "3️⃣ 驗證 EKS 遷移..."
        aws eks describe-cluster --name $CLUSTER_NAME --region $TARGET_REGION --query 'cluster.status'
        kubectl get nodes
        kubectl get pods --all-namespaces
        kubectl get services --all-namespaces
        ;;
    "ecs")
        echo "3️⃣ 驗證 ECS 遷移..."
        aws ecs describe-clusters --clusters $CLUSTER_NAME --region $TARGET_REGION --query 'clusters[0].status'
        aws ecs list-services --cluster $CLUSTER_NAME --region $TARGET_REGION
        
        # 檢查服務健康狀態
        for service in $(aws ecs list-services --cluster $CLUSTER_NAME --region $TARGET_REGION --query 'serviceArns' --output text); do
            service_name=$(basename $service)
            echo "檢查服務: $service_name"
            aws ecs describe-services --cluster $CLUSTER_NAME --services $service_name --region $TARGET_REGION \
              --query 'services[0].{Status:status,Running:runningCount,Desired:desiredCount}'
        done
        ;;
    "ec2")
        echo "3️⃣ 驗證 EC2 遷移..."
        ./verify_ec2_deployment.sh
        ;;
esac

echo "✅ 驗證完成！"
```

## DNS 流量切換

### Route 53 流量切換腳本

```bash
#!/bin/bash
# switch_dns_traffic.sh
source config.sh

SERVICE_TYPE="$1"  # eks, ecs, or ec2
HOSTED_ZONE_ID="Z123456789"  # 替換為實際的 Hosted Zone ID
DOMAIN_NAME="app.example.com"

echo "🔄 開始 DNS 流量切換..."

# 根據服務類型獲取目標端點
case $SERVICE_TYPE in
    "eks")
        # 獲取 EKS Ingress 或 LoadBalancer 端點
        TARGET_ENDPOINT=$(kubectl --context=target-cluster get ingress -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')
        ;;
    "ecs")
        # 獲取 ECS ALB 端點
        TARGET_ENDPOINT=$(aws elbv2 describe-load-balancers --names tpe-ecs-alb --query 'LoadBalancers[0].DNSName' --output text --region $TARGET_REGION)
        ;;
    "ec2")
        # 獲取 EC2 ALB 端點
        ALB_ARN=$(cat alb_arn.txt)
        TARGET_ENDPOINT=$(aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN --query 'LoadBalancers[0].DNSName' --output text --region $TARGET_REGION)
        ;;
esac

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
            \"SetIdentifier\": \"TPE-$SERVICE_TYPE\",
            \"Weight\": $weight,
            \"TTL\": 60,
            \"ResourceRecords\": [{\"Value\": \"$TARGET_ENDPOINT\"}]
          }
        }]
      }"
    
    echo "等待 2 分鐘觀察流量..."
    sleep 120
    
    # 檢查健康狀態
    echo "檢查應用程式健康狀態..."
    curl -f http://$TARGET_ENDPOINT/health || echo "健康檢查失敗！"
    
    read -p "繼續下一階段切換？(y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "流量切換暫停在 $weight%"
        exit 1
    fi
done

echo "✅ DNS 流量切換完成！"
```

## 回滾腳本

### 緊急回滾腳本

```bash
#!/bin/bash
# emergency_rollback.sh
source config.sh

SERVICE_TYPE="$1"  # eks, ecs, or ec2
HOSTED_ZONE_ID="Z123456789"
DOMAIN_NAME="app.example.com"

echo "🚨 執行緊急回滾..."

# 1. DNS 立即切換回原區域
echo "1️⃣ DNS 立即切換回原區域..."
aws route53 change-resource-record-sets \
  --hosted-zone-id $HOSTED_ZONE_ID \
  --change-batch "{
    \"Changes\": [{
      \"Action\": \"DELETE\",
      \"ResourceRecordSet\": {
        \"Name\": \"$DOMAIN_NAME\",
        \"Type\": \"CNAME\",
        \"SetIdentifier\": \"TPE-$SERVICE_TYPE\",
        \"Weight\": 100,
        \"TTL\": 60,
        \"ResourceRecords\": [{\"Value\": \"original-endpoint.com\"}]
      }
    }]
  }"

# 2. 服務特定回滾
case $SERVICE_TYPE in
    "eks")
        echo "2️⃣ EKS 回滾..."
        kubectl config use-context source-cluster
        kubectl apply -f original-deployment.yaml
        ;;
    "ecs")
        echo "2️⃣ ECS 回滾..."
        aws ecs update-service \
          --cluster original-ecs-cluster \
          --service my-app-service \
          --desired-count 3 \
          --region $SOURCE_REGION
        ;;
    "ec2")
        echo "2️⃣ EC2 回滾..."
        aws autoscaling update-auto-scaling-group \
          --auto-scaling-group-name original-app-asg \
          --desired-capacity 3 \
          --region $SOURCE_REGION
        ;;
esac

echo "✅ 緊急回滾完成！"
```

## 使用說明

### 快速開始

```bash
# 1. 設定環境變數
cp config.sh.example config.sh
# 編輯 config.sh 填入實際值

# 2. 準備 VPC 基礎設施
# 方案 A：複製來源區域設定（推薦）
./replicate_vpc_from_source.sh

# 方案 B：建立全新 VPC
./create_new_vpc.sh

# 3. 執行遷移
./complete_migration.sh all eks    # EKS + ECR + RDS
./complete_migration.sh all ecs    # ECS + ECR + RDS  
./complete_migration.sh all ec2    # EC2 + ECR + RDS

# 4. 驗證遷移結果
./verify_migration.sh eks
./verify_migration.sh ecs
./verify_migration.sh ec2

# 5. 執行流量切換
./switch_dns_traffic.sh eks
./switch_dns_traffic.sh ecs
./switch_dns_traffic.sh ec2

# 6. 如需回滾
./emergency_rollback.sh eks
```

### CloudFormation 模板使用

```bash
# CloudFormation 使用方式
cd iac-output/cloudformation/

# 驗證模板
aws cloudformation validate-template \
  --template-body file://infrastructure-template.yaml

# 部署 Stack
./deploy.sh

# 或手動部署
aws cloudformation deploy \
  --template-file infrastructure-template.yaml \
  --stack-name migration-infrastructure \
  --parameter-overrides file://parameters.json \
  --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM
```

## 🚀 **進階選項：同步生成 CloudFormation 模板**

如果您希望在遷移的同時將環境轉換為 CloudFormation 管理，可以使用以下腳本：

### 進階遷移方案

```bash
# 遷移 + CloudFormation 轉換
./migrate_with_cloudformation.sh eks     # 遷移 EKS 並生成 CloudFormation 模板
./migrate_with_cloudformation.sh ecs     # 遷移 ECS 並生成 CloudFormation 模板
./migrate_with_cloudformation.sh ec2     # 遷移 EC2 並生成 CloudFormation 模板
```

### 腳本權限設定

```bash
# 設定所有腳本為可執行
chmod +x *.sh

# 或個別設定
chmod +x complete_migration.sh
chmod +x verify_migration.sh
chmod +x switch_dns_traffic.sh
```

---

## 🚀 **進階選項：CloudFormation 模板生成**

### CloudFormation 模板生成腳本

```bash
#!/bin/bash
# generate_cloudformation_from_existing.sh
source config.sh

MIGRATION_TYPE="$1"  # eks, ecs, ec2, or all

echo "🔧 開始生成 CloudFormation 模板..."
echo "遷移類型: $MIGRATION_TYPE"

# 建立輸出目錄
mkdir -p iac-output/cloudformation

generate_cloudformation_code

echo "✅ CloudFormation 模板生成完成！"
```

### CloudFormation 代碼生成

```bash
#!/bin/bash
# generate_cloudformation_code.sh
generate_cloudformation_code() {
    echo "📝 生成 CloudFormation 模板..."
    
    cd iac-output/cloudformation
    
    # 準備資源清單
    case $MIGRATION_TYPE in
        "eks")
            generate_eks_resources_list
            ;;
        "ecs")
            generate_ecs_resources_list
            ;;
        "ec2")
            generate_ec2_resources_list
            ;;
        "all")
            generate_all_resources_list
            ;;
    esac
    
    # 使用 AWS IaC Generator
    TEMPLATE_NAME="migration-template-$(date +%s)"
    
    echo "🔄 建立 CloudFormation 生成模板..."
    aws cloudformation create-generated-template \
        --generated-template-name $TEMPLATE_NAME \
        --resources file://resource-list.json \
        --region $TARGET_REGION
    
    # 等待模板生成完成
    echo "⏳ 等待 CloudFormation 模板生成..."
    aws cloudformation wait template-generation-complete \
        --generated-template-name $TEMPLATE_NAME \
        --region $TARGET_REGION
    
    # 下載生成的模板
    aws cloudformation get-generated-template \
        --generated-template-name $TEMPLATE_NAME \
        --region $TARGET_REGION \
        --query 'TemplateBody' \
        --output text > infrastructure-template.yaml
    
    # 生成參數檔案
    cat > parameters.json << EOF
[
  {
    "ParameterKey": "SourceRegion",
    "ParameterValue": "$SOURCE_REGION"
  },
  {
    "ParameterKey": "TargetRegion",
    "ParameterValue": "$TARGET_REGION"
  },
  {
    "ParameterKey": "ClusterName",
    "ParameterValue": "$CLUSTER_NAME"
  },
  {
    "ParameterKey": "Environment",
    "ParameterValue": "production"
  }
]
EOF
    
    # 生成部署腳本
    cat > deploy.sh << 'EOF'
#!/bin/bash
# CloudFormation 部署腳本

STACK_NAME="migration-infrastructure"
TEMPLATE_FILE="infrastructure-template.yaml"
PARAMETERS_FILE="parameters.json"

echo "🚀 部署 CloudFormation Stack..."

aws cloudformation deploy \
  --template-file $TEMPLATE_FILE \
  --stack-name $STACK_NAME \
  --parameter-overrides file://$PARAMETERS_FILE \
  --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
  --region $TARGET_REGION

if [ $? -eq 0 ]; then
    echo "✅ CloudFormation Stack 部署成功！"
    echo "Stack 名稱: $STACK_NAME"
    echo "區域: $TARGET_REGION"
else
    echo "❌ CloudFormation Stack 部署失敗"
    exit 1
fi
EOF
    
    chmod +x deploy.sh
    
    echo "✅ CloudFormation 模板生成完成！"
    echo "模板: iac-output/cloudformation/infrastructure-template.yaml"
    echo "參數: iac-output/cloudformation/parameters.json"
    echo "部署腳本: iac-output/cloudformation/deploy.sh"
    
    cd ../..
}

# 生成 EKS 資源清單
generate_eks_resources_list() {
    echo "📋 準備 EKS 資源清單..."
    
    # 獲取 VPC ID
    if [[ -z "$TARGET_VPC_ID" ]]; then
        TARGET_VPC_ID=$(aws ec2 describe-vpcs \
            --filters "Name=tag:Name,Values=${VPC_NAME:-migration-vpc}" \
            --query 'Vpcs[0].VpcId' --output text --region $TARGET_REGION)
    fi
    
    cat > resource-list.json << EOF
[
  {
    "ResourceType": "AWS::EKS::Cluster",
    "ResourceIdentifier": {
      "ClusterName": "$CLUSTER_NAME"
    }
  },
  {
    "ResourceType": "AWS::EC2::VPC",
    "ResourceIdentifier": {
      "VpcId": "$TARGET_VPC_ID"
    }
  },
  {
    "ResourceType": "AWS::IAM::Role",
    "ResourceIdentifier": {
      "RoleName": "eksServiceRole"
    }
  }
]
EOF
}

# 生成 ECS 資源清單
generate_ecs_resources_list() {
    echo "📋 準備 ECS 資源清單..."
    
    cat > resource-list.json << EOF
[
  {
    "ResourceType": "AWS::ECS::Cluster",
    "ResourceIdentifier": {
      "ClusterName": "$CLUSTER_NAME"
    }
  },
  {
    "ResourceType": "AWS::EC2::VPC",
    "ResourceIdentifier": {
      "VpcId": "$TARGET_VPC_ID"
    }
  },
  {
    "ResourceType": "AWS::ElasticLoadBalancingV2::LoadBalancer",
    "ResourceIdentifier": {
      "LoadBalancerArn": "$(cat alb_arn.txt 2>/dev/null || echo 'arn:aws:elasticloadbalancing:region:account:loadbalancer/app/name/id')"
    }
  }
]
EOF
}

# 生成 EC2 資源清單
generate_ec2_resources_list() {
    echo "📋 準備 EC2 資源清單..."
    
    cat > resource-list.json << EOF
[
  {
    "ResourceType": "AWS::EC2::VPC",
    "ResourceIdentifier": {
      "VpcId": "$TARGET_VPC_ID"
    }
  },
  {
    "ResourceType": "AWS::AutoScaling::AutoScalingGroup",
    "ResourceIdentifier": {
      "AutoScalingGroupName": "tpe-app-asg"
    }
  },
  {
    "ResourceType": "AWS::EC2::LaunchTemplate",
    "ResourceIdentifier": {
      "LaunchTemplateName": "tpe-app-launch-template"
    }
  },
  {
    "ResourceType": "AWS::ElasticLoadBalancingV2::LoadBalancer",
    "ResourceIdentifier": {
      "LoadBalancerArn": "$(cat alb_arn.txt 2>/dev/null || echo 'arn:aws:elasticloadbalancing:region:account:loadbalancer/app/name/id')"
    }
  }
]
EOF
}

# 生成所有資源清單
generate_all_resources_list() {
    echo "📋 準備完整資源清單..."
    
    cat > resource-list.json << EOF
[
  {
    "ResourceType": "AWS::EKS::Cluster",
    "ResourceIdentifier": {
      "ClusterName": "$CLUSTER_NAME"
    }
  },
  {
    "ResourceType": "AWS::ECS::Cluster",
    "ResourceIdentifier": {
      "ClusterName": "$CLUSTER_NAME"
    }
  },
  {
    "ResourceType": "AWS::EC2::VPC",
    "ResourceIdentifier": {
      "VpcId": "$TARGET_VPC_ID"
    }
  },
  {
    "ResourceType": "AWS::RDS::DBInstance",
    "ResourceIdentifier": {
      "DBInstanceIdentifier": "${DB_INSTANCE_ID}-tpe"
    }
  },
  {
    "ResourceType": "AWS::AutoScaling::AutoScalingGroup",
    "ResourceIdentifier": {
      "AutoScalingGroupName": "tpe-app-asg"
    }
  }
]
EOF
}
```

### 整合的遷移 + CloudFormation 腳本

```bash
#!/bin/bash
# migrate_with_cloudformation.sh
source config.sh

MIGRATION_TYPE="$1"  # eks, ecs, ec2

echo "🚀 開始遷移 + CloudFormation 轉換流程..."

# 階段 1：執行遷移
echo "📋 階段 1：執行環境遷移"
case $MIGRATION_TYPE in
    "eks")
        ./export_eks_config.sh
        ./modify_eks_config.sh
        ./deploy_eks_cluster.sh &
        MIGRATION_PID=$!
        ;;
    "ecs")
        ./export_ecs_config.sh
        ./deploy_ecs_cluster.sh &
        MIGRATION_PID=$!
        ;;
    "ec2")
        ./create_and_copy_ami.sh
        ./setup_ec2_infrastructure.sh &
        MIGRATION_PID=$!
        ;;
esac

# 階段 2：並行生成 CloudFormation 模板
echo "📋 階段 2：生成 CloudFormation 模板"
./generate_cloudformation_from_existing.sh $MIGRATION_TYPE &
CF_PID=$!

# 等待兩個程序完成
wait $MIGRATION_PID
wait $CF_PID

# 階段 3：驗證 CloudFormation 模板
echo "📋 階段 3：驗證 CloudFormation 模板"
cd iac-output/cloudformation

aws cloudformation validate-template \
    --template-body file://infrastructure-template.yaml \
    --region $TARGET_REGION

if [ $? -eq 0 ]; then
    echo "✅ CloudFormation 模板驗證成功！"
else
    echo "❌ CloudFormation 模板驗證失敗"
    exit 1
fi

cd ../..

echo "✅ 遷移 + CloudFormation 轉換完成！"
echo "📁 遷移結果：已部署到 $TARGET_REGION"
echo "📁 CloudFormation 模板：iac-output/cloudformation/"
echo ""
echo "🚀 下一步：使用 CloudFormation 管理基礎設施"
echo "   cd iac-output/cloudformation/"
echo "   ./deploy.sh"
```

這個部署指南提供了完整的可執行命令，涵蓋 EKS、ECS、EC2 三種計算服務的遷移，以及 ECR、RDS、DMS 的整合，讓您可以直接執行跨區域遷移！
