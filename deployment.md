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

## 🚀 快速開始

### 1. 環境準備

```bash
# 1. 複製設定檔範本
cp config.sh.example config.sh

# 2. 編輯設定檔，填入實際值
vim config.sh

# 3. 驗證設定
source config.sh && validate_config
```

### 2. 選擇遷移方案

根據您的服務類型選擇對應的部署指南：

- **EKS 遷移**：參考 `eks.md`
- **ECS 遷移**：參考 `ecs.md`  
- **EC2 遷移**：參考 `ec2.md`

## 🏗️ 共用基礎設施準備

所有服務遷移都需要先準備以下共用基礎設施：

### VPC 網路基礎設施

#### 方案 A：複製來源區域 VPC 設定（推薦）

```bash
#!/bin/bash
# 1. 分析來源 VPC
SOURCE_VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=${VPC_NAME}" \
    --query 'Vpcs[0].VpcId' --output text --region $SOURCE_REGION)

# 2. 匯出 VPC 設定
aws ec2 describe-vpcs --vpc-ids $SOURCE_VPC_ID --region $SOURCE_REGION > source-vpc.json
aws ec2 describe-subnets --filters "Name=vpc-id,Values=$SOURCE_VPC_ID" --region $SOURCE_REGION > source-subnets.json
aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$SOURCE_VPC_ID" --region $SOURCE_REGION > source-routes.json

# 3. 生成 CloudFormation 模板
cat > vpc-template.yaml << 'EOF'
AWSTemplateFormatVersion: '2010-09-09'
Description: 'Replicated VPC Infrastructure'

Parameters:
  VpcCidr:
    Type: String
    Default: '10.0.0.0/16'
  VpcName:
    Type: String
    Default: 'migration-vpc'

Resources:
  VPC:
    Type: AWS::EC2::VPC
    Properties:
      CidrBlock: !Ref VpcCidr
      EnableDnsHostnames: true
      EnableDnsSupport: true
      Tags:
        - Key: Name
          Value: !Ref VpcName

  # 公有子網路
  PublicSubnet1:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [0, !Cidr [!Ref VpcCidr, 4, 8]]
      AvailabilityZone: !Select [0, !GetAZs '']
      MapPublicIpOnLaunch: true
      Tags:
        - Key: Name
          Value: Public-1
        - Key: Type
          Value: Public

  PublicSubnet2:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [1, !Cidr [!Ref VpcCidr, 4, 8]]
      AvailabilityZone: !Select [1, !GetAZs '']
      MapPublicIpOnLaunch: true
      Tags:
        - Key: Name
          Value: Public-2
        - Key: Type
          Value: Public

  # 私有子網路
  PrivateSubnet1:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [2, !Cidr [!Ref VpcCidr, 4, 8]]
      AvailabilityZone: !Select [0, !GetAZs '']
      Tags:
        - Key: Name
          Value: Private-1
        - Key: Type
          Value: Private

  PrivateSubnet2:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [3, !Cidr [!Ref VpcCidr, 4, 8]]
      AvailabilityZone: !Select [1, !GetAZs '']
      Tags:
        - Key: Name
          Value: Private-2
        - Key: Type
          Value: Private

  # 網際網路閘道
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

  # NAT 閘道
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

  # 路由表
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

  # 路由
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

  # 路由表關聯
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

# 4. 部署 VPC
aws cloudformation deploy \
    --template-file vpc-template.yaml \
    --stack-name vpc-infrastructure \
    --parameter-overrides VpcCidr=$VPC_CIDR VpcName=$VPC_NAME \
    --region $TARGET_REGION
```

#### 方案 B：使用標準 VPC 模板

如果來源區域沒有合適的 VPC，使用上述 CloudFormation 模板直接部署標準 VPC。

### RDS 資料庫遷移

```bash
#!/bin/bash
# RDS 跨區域遷移（快照方式）

# 1. 建立快照
SNAPSHOT_ID="migration-snapshot-$(date +%Y%m%d-%H%M%S)"
aws rds create-db-snapshot \
    --db-instance-identifier $DB_INSTANCE_ID \
    --db-snapshot-identifier $SNAPSHOT_ID \
    --region $SOURCE_REGION

# 2. 等待快照完成
aws rds wait db-snapshot-completed \
    --db-snapshot-identifier $SNAPSHOT_ID \
    --region $SOURCE_REGION

# 3. 複製快照到目標區域
aws rds copy-db-snapshot \
    --source-db-snapshot-identifier "arn:aws:rds:$SOURCE_REGION:$AWS_ACCOUNT_ID:snapshot:$SNAPSHOT_ID" \
    --target-db-snapshot-identifier $SNAPSHOT_ID \
    --region $TARGET_REGION

# 4. 等待複製完成
aws rds wait db-snapshot-completed \
    --db-snapshot-identifier $SNAPSHOT_ID \
    --region $TARGET_REGION

# 5. 從快照還原
aws rds restore-db-instance-from-db-snapshot \
    --db-instance-identifier "${DB_INSTANCE_ID}-taipei" \
    --db-snapshot-identifier $SNAPSHOT_ID \
    --region $TARGET_REGION

# 6. 等待資料庫可用
aws rds wait db-instance-available \
    --db-instance-identifier "${DB_INSTANCE_ID}-taipei" \
    --region $TARGET_REGION
```

### ECR 映像複製

```bash
#!/bin/bash
# ECR 跨區域映像複製

# 1. 獲取來源儲存庫清單
REPOSITORIES=$(aws ecr describe-repositories \
    --region $SOURCE_REGION \
    --query 'repositories[].repositoryName' \
    --output text)

# 2. 在目標區域建立儲存庫並複製映像
for repo in $REPOSITORIES; do
    # 建立目標儲存庫
    aws ecr create-repository --repository-name $repo --region $TARGET_REGION 2>/dev/null || true
    
    # 獲取映像清單
    IMAGES=$(aws ecr list-images \
        --repository-name $repo \
        --region $SOURCE_REGION \
        --query 'imageIds[?imageTag!=null].imageTag' \
        --output text)
    
    # 複製每個映像
    for tag in $IMAGES; do
        # 拉取映像
        docker pull $AWS_ACCOUNT_ID.dkr.ecr.$SOURCE_REGION.amazonaws.com/$repo:$tag
        
        # 重新標記
        docker tag $AWS_ACCOUNT_ID.dkr.ecr.$SOURCE_REGION.amazonaws.com/$repo:$tag \
                   $AWS_ACCOUNT_ID.dkr.ecr.$TARGET_REGION.amazonaws.com/$repo:$tag
        
        # 推送到目標區域
        docker push $AWS_ACCOUNT_ID.dkr.ecr.$TARGET_REGION.amazonaws.com/$repo:$tag
        
        # 清理本地映像
        docker rmi $AWS_ACCOUNT_ID.dkr.ecr.$SOURCE_REGION.amazonaws.com/$repo:$tag
        docker rmi $AWS_ACCOUNT_ID.dkr.ecr.$TARGET_REGION.amazonaws.com/$repo:$tag
    done
done
```

## 🔄 DNS 流量切換

### 漸進式流量切換

```bash
#!/bin/bash
# DNS 流量切換（適用所有服務）

SERVICE_TYPE=$1  # eks, ecs, ec2
TARGET_ENDPOINT=$2

# 漸進式切換
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
    
    # 健康檢查
    curl -f "http://$TARGET_ENDPOINT/health" || echo "健康檢查失敗"
done
```

### 緊急回滾

```bash
#!/bin/bash
# 緊急回滾到來源區域

SERVICE_TYPE=$1
SOURCE_ENDPOINT=$2

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
```

## 📊 遷移驗證

### 統一驗證腳本

```bash
#!/bin/bash
# 驗證所有服務遷移狀態

echo "=== VPC 基礎設施 ==="
aws ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=$VPC_NAME" \
    --query 'Vpcs[0].{VpcId:VpcId,State:State,CidrBlock:CidrBlock}' \
    --region $TARGET_REGION

echo "=== RDS 資料庫 ==="
aws rds describe-db-instances \
    --db-instance-identifier "${DB_INSTANCE_ID}-taipei" \
    --query 'DBInstances[0].{Status:DBInstanceStatus,Endpoint:Endpoint.Address}' \
    --region $TARGET_REGION 2>/dev/null || echo "RDS 執行個體不存在"

echo "=== EKS 叢集 ==="
aws eks describe-cluster \
    --name $CLUSTER_NAME \
    --query 'cluster.{Status:status,Endpoint:endpoint}' \
    --region $TARGET_REGION 2>/dev/null || echo "EKS 叢集不存在"

echo "=== ECS 叢集 ==="
aws ecs describe-clusters \
    --clusters $CLUSTER_NAME \
    --query 'clusters[0].{Status:status,ActiveServicesCount:activeServicesCount}' \
    --region $TARGET_REGION 2>/dev/null || echo "ECS 叢集不存在"

echo "=== EC2 Auto Scaling ==="
aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names taipei-app-asg \
    --query 'AutoScalingGroups[0].{DesiredCapacity:DesiredCapacity,Instances:length(Instances)}' \
    --region $TARGET_REGION 2>/dev/null || echo "Auto Scaling 群組不存在"
```

## 📁 使用流程

### 單一服務遷移
1. 準備共用基礎設施（VPC、RDS、ECR）
2. 選擇對應的專用部署指南
3. 執行服務特定的遷移步驟
4. 驗證和流量切換

### 混合環境遷移
1. 準備共用基礎設施
2. 並行執行多個服務的遷移
3. 統一驗證和流量切換

## 📞 支援資源

- **架構設計**：參考 `architecture.md`
- **EKS 遷移**：參考 `eks.md`
- **ECS 遷移**：參考 `ecs.md`
- **EC2 遷移**：參考 `ec2.md`
