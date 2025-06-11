# AWS 跨區域工作負載遷移部署指南

## 概述

本指南提供 NRT Region → TPE Region 遷移的具體執行命令和腳本，包含 EKS、ECS、EC2 三種計算服務的完整遷移流程。

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

# 載入設定
source config.sh
```

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
2. **Week 2**: 匯出 EKS 叢集設定 → 修改區域參數 → 部署到 TPE Region
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
TARGET_VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=your-vpc" --query 'Vpcs[0].VpcId' --output text --region $TARGET_REGION)
TARGET_SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$TARGET_VPC_ID" --query 'Subnets[].SubnetId' --output text --region $TARGET_REGION)
TARGET_SECURITY_GROUP_ID=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$TARGET_VPC_ID" "Name=group-name,Values=eks-cluster-sg" --query 'SecurityGroups[0].GroupId' --output text --region $TARGET_REGION)

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

### 3. 部署到 TPE Region

```bash
#!/bin/bash
# deploy_eks_cluster.sh
source config.sh

echo "🚀 在 TPE Region 部署 EKS 叢集..."

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
        
        aws eks create-nodegroup \
          --region $TARGET_REGION \
          --cluster-name $CLUSTER_NAME \
          --nodegroup-name $NODEGROUP_NAME \
          --scaling-config "$(echo $NODEGROUP_CONFIG | jq -c '.scalingConfig')" \
          --instance-types "$(echo $NODEGROUP_CONFIG | jq -r '.instanceTypes[]')" \
          --ami-type "$(echo $NODEGROUP_CONFIG | jq -r '.amiType')" \
          --capacity-type "$(echo $NODEGROUP_CONFIG | jq -r '.capacityType // "ON_DEMAND"')" \
          --disk-size "$(echo $NODEGROUP_CONFIG | jq -r '.diskSize // 20')" \
          --node-role "$(echo $NODEGROUP_CONFIG | jq -r '.nodeRole')" \
          --subnets "$(echo $NODEGROUP_CONFIG | jq -r '.subnets[]')" \
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
2. **Week 2**: 匯出 ECS 叢集設定 → 自動修改映像路徑 → 部署到 TPE Region
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
      --query 'taskDefinition | del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .registeredAt, .registeredBy, .compatibilities)' \
      > "taskdef-${task_def_name}-config.json"
done

echo "✅ ECS 設定匯出完成！"
```

### 2. 部署 ECS 叢集

```bash
#!/bin/bash
# deploy_ecs_cluster.sh
source config.sh

echo "🚀 在 TPE Region 部署 ECS 叢集..."

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
TARGET_VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=your-vpc" --query 'Vpcs[0].VpcId' --output text --region $TARGET_REGION)
TARGET_SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$TARGET_VPC_ID" --query 'Subnets[].SubnetId' --output text --region $TARGET_REGION)
TARGET_SECURITY_GROUP_ID=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$TARGET_VPC_ID" --query 'SecurityGroups[0].GroupId' --output text --region $TARGET_REGION)

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
kubectl config use-context $SOURCE_CLUSTER_CONTEXT
kubectl config rename-context $SOURCE_CLUSTER_CONTEXT source-cluster

kubectl config use-context $TARGET_CLUSTER_CONTEXT  
kubectl config rename-context $TARGET_CLUSTER_CONTEXT target-cluster

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
  --description "Application AMI for TPE migration" \
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
  --description "Application AMI copied to TPE region" \
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
TARGET_VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=your-vpc" --query 'Vpcs[0].VpcId' --output text --region $TARGET_REGION)
PRIVATE_SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$TARGET_VPC_ID" "Name=tag:Type,Values=Private" --query 'Subnets[].SubnetId' --output text --region $TARGET_REGION)
PUBLIC_SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$TARGET_VPC_ID" "Name=tag:Type,Values=Public" --query 'Subnets[].SubnetId' --output text --region $TARGET_REGION)
SECURITY_GROUP_ID=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$TARGET_VPC_ID" "Name=group-name,Values=ec2-app-sg" --query 'SecurityGroups[0].GroupId' --output text --region $TARGET_REGION)
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
    \"UserData\": \"$(base64 -w 0 user-data.sh)\",
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
TARGET_VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=your-vpc" --query 'Vpcs[0].VpcId' --output text --region $TARGET_REGION)
PRIVATE_SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$TARGET_VPC_ID" "Name=tag:Type,Values=Private" --query 'Subnets[].SubnetId' --output text --region $TARGET_REGION)

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
  --description "Application AMI for TPE migration" \
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
  --description "Application AMI copied to TPE region" \
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
TARGET_VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=your-vpc" --query 'Vpcs[0].VpcId' --output text --region $TARGET_REGION)
PRIVATE_SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$TARGET_VPC_ID" "Name=tag:Type,Values=Private" --query 'Subnets[].SubnetId' --output text --region $TARGET_REGION)
PUBLIC_SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$TARGET_VPC_ID" "Name=tag:Type,Values=Public" --query 'Subnets[].SubnetId' --output text --region $TARGET_REGION)
SECURITY_GROUP_ID=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$TARGET_VPC_ID" "Name=group-name,Values=ec2-app-sg" --query 'SecurityGroups[0].GroupId' --output text --region $TARGET_REGION)
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
    \"UserData\": \"$(base64 -w 0 user-data.sh)\",
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
TARGET_VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=your-vpc" --query 'Vpcs[0].VpcId' --output text --region $TARGET_REGION)
PRIVATE_SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$TARGET_VPC_ID" "Name=tag:Type,Values=Private" --query 'Subnets[].SubnetId' --output text --region $TARGET_REGION)

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
TARGET_VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=your-vpc" --query 'Vpcs[0].VpcId' --output text --region $TARGET_REGION)
TARGET_SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$TARGET_VPC_ID" --query 'Subnets[].SubnetId' --output text --region $TARGET_REGION)

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
    echo "切換 $weight% 流量到 TPE Region..."
    
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

# 2. 執行完整遷移
./complete_migration.sh all eks    # EKS + ECR + RDS
./complete_migration.sh all ecs    # ECS + ECR + RDS  
./complete_migration.sh all ec2    # EC2 + ECR + RDS

# 3. 驗證遷移結果
./verify_migration.sh eks
./verify_migration.sh ecs
./verify_migration.sh ec2

# 4. 執行流量切換
./switch_dns_traffic.sh eks
./switch_dns_traffic.sh ecs
./switch_dns_traffic.sh ec2

# 5. 如需回滾
./emergency_rollback.sh eks
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

這個部署指南提供了完整的可執行命令，涵蓋 EKS、ECS、EC2 三種計算服務的遷移，以及 ECR、RDS、DMS 的整合，讓您可以直接執行跨區域遷移！
