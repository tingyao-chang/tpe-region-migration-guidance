#!/bin/bash
# common_functions.sh - 共用函數和設定

# 載入基本設定
load_config() {
    if [ ! -f "config.sh" ]; then
        echo "❌ 錯誤：找不到 config.sh 檔案"
        echo "請先複製 config.sh.example 並設定必要的環境變數"
        exit 1
    fi
    source config.sh
}

# 驗證基本設定
validate_basic_config() {
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
    
    if [[ ${#errors[@]} -gt 0 ]]; then
        echo "❌ 基本設定錯誤："
        printf '  - %s\n' "${errors[@]}"
        exit 1
    fi
    
    echo "✅ 基本設定驗證通過"
}

# 獲取 VPC 資源（通用版本）
get_vpc_resources() {
    local vpc_name=${VPC_NAME:-"migration-vpc"}
    
    echo "🔍 獲取 VPC 資源..."
    
    # 查找 VPC
    TARGET_VPC_ID=$(aws ec2 describe-vpcs \
        --filters "Name=tag:Name,Values=$vpc_name" "Name=state,Values=available" \
        --query 'Vpcs[0].VpcId' --output text --region $TARGET_REGION)
    
    if [[ "$TARGET_VPC_ID" == "None" || -z "$TARGET_VPC_ID" ]]; then
        echo "❌ 錯誤：在 $TARGET_REGION 找不到名為 '$vpc_name' 的 VPC"
        echo "請確認 VPC 存在或設定正確的 VPC_NAME 環境變數"
        echo "可以執行以下命令建立 VPC："
        echo "  ./replicate_vpc_from_source.sh"
        echo "  或 ./create_new_vpc.sh"
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
    
    # 驗證子網路存在
    if [[ -z "$PRIVATE_SUBNET_IDS" ]]; then
        echo "❌ 錯誤：找不到私有子網路"
        echo "請確認 VPC 中有標記為 'Type=Private' 的子網路"
        exit 1
    fi
    
    if [[ -z "$PUBLIC_SUBNET_IDS" ]]; then
        echo "❌ 錯誤：找不到公有子網路"
        echo "請確認 VPC 中有標記為 'Type=Public' 的子網路"
        exit 1
    fi
    
    # 驗證子網路數量（至少需要 2 個不同 AZ）
    PRIVATE_AZ_COUNT=$(aws ec2 describe-subnets \
        --subnet-ids $PRIVATE_SUBNET_IDS \
        --query 'length(Subnets[].AvailabilityZone | sort(@) | unique(@))' \
        --output text --region $TARGET_REGION 2>/dev/null || echo "0")
    
    PUBLIC_AZ_COUNT=$(aws ec2 describe-subnets \
        --subnet-ids $PUBLIC_SUBNET_IDS \
        --query 'length(Subnets[].AvailabilityZone | sort(@) | unique(@))' \
        --output text --region $TARGET_REGION 2>/dev/null || echo "0")
    
    if [[ "$PRIVATE_AZ_COUNT" -lt 2 ]]; then
        echo "⚠️  警告：私有子網路僅跨越 $PRIVATE_AZ_COUNT 個可用區域，建議至少 2 個以確保高可用性"
    fi
    
    if [[ "$PUBLIC_AZ_COUNT" -lt 2 ]]; then
        echo "⚠️  警告：公有子網路僅跨越 $PUBLIC_AZ_COUNT 個可用區域，建議至少 2 個以確保高可用性"
    fi
    
    echo "✅ VPC 資源獲取完成："
    echo "  VPC ID: $TARGET_VPC_ID"
    echo "  私有子網路: $PRIVATE_SUBNET_IDS"
    echo "  公有子網路: $PUBLIC_SUBNET_IDS"
    echo "  私有子網路跨越 AZ 數: $PRIVATE_AZ_COUNT"
    echo "  公有子網路跨越 AZ 數: $PUBLIC_AZ_COUNT"
    
    # 匯出變數供其他腳本使用
    export TARGET_VPC_ID
    export PRIVATE_SUBNET_IDS
    export PUBLIC_SUBNET_IDS
    export PRIVATE_AZ_COUNT
    export PUBLIC_AZ_COUNT
}

# 建立或獲取安全群組
create_or_get_security_group() {
    local purpose=$1
    local group_name_prefix=$2
    local description=$3
    
    echo "🔒 處理安全群組 ($purpose)..."
    
    # 查找現有安全群組
    SECURITY_GROUP_ID=$(aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=$TARGET_VPC_ID" \
                  "Name=tag:Purpose,Values=$purpose" \
        --query 'SecurityGroups[0].GroupId' --output text --region $TARGET_REGION)
    
    if [[ "$SECURITY_GROUP_ID" == "None" || -z "$SECURITY_GROUP_ID" ]]; then
        echo "建立新的安全群組..."
        SECURITY_GROUP_ID=$(aws ec2 create-security-group \
            --group-name "${group_name_prefix}-$(date +%s)" \
            --description "$description" \
            --vpc-id $TARGET_VPC_ID \
            --tag-specifications "ResourceType=security-group,Tags=[{Key=Purpose,Value=$purpose},{Key=Name,Value=${group_name_prefix}}]" \
            --query 'GroupId' --output text --region $TARGET_REGION)
        
        echo "新建立的安全群組 ID: $SECURITY_GROUP_ID"
    else
        echo "使用現有的安全群組 ID: $SECURITY_GROUP_ID"
    fi
    
    echo $SECURITY_GROUP_ID
}

# 加入安全群組規則
add_security_group_rules() {
    local sg_id=$1
    local rule_type=$2  # web, app, database, etc.
    
    echo "🔧 設定安全群組規則 ($rule_type)..."
    
    case $rule_type in
        "web")
            # HTTP/HTTPS 規則
            aws ec2 authorize-security-group-ingress \
                --group-id $sg_id \
                --protocol tcp --port 80 --cidr 0.0.0.0/0 \
                --region $TARGET_REGION 2>/dev/null || echo "HTTP 規則已存在"
            
            aws ec2 authorize-security-group-ingress \
                --group-id $sg_id \
                --protocol tcp --port 443 --cidr 0.0.0.0/0 \
                --region $TARGET_REGION 2>/dev/null || echo "HTTPS 規則已存在"
            ;;
        "app")
            # 應用程式內部通訊
            aws ec2 authorize-security-group-ingress \
                --group-id $sg_id \
                --protocol tcp --port 80 --cidr 10.0.0.0/8 \
                --region $TARGET_REGION 2>/dev/null || echo "內部 HTTP 規則已存在"
            
            aws ec2 authorize-security-group-ingress \
                --group-id $sg_id \
                --protocol tcp --port 443 --cidr 10.0.0.0/8 \
                --region $TARGET_REGION 2>/dev/null || echo "內部 HTTPS 規則已存在"
            
            aws ec2 authorize-security-group-ingress \
                --group-id $sg_id \
                --protocol tcp --port 22 --cidr 10.0.0.0/8 \
                --region $TARGET_REGION 2>/dev/null || echo "SSH 規則已存在"
            ;;
        "database")
            # 資料庫存取
            aws ec2 authorize-security-group-ingress \
                --group-id $sg_id \
                --protocol tcp --port 3306 --cidr 10.0.0.0/8 \
                --region $TARGET_REGION 2>/dev/null || echo "MySQL 規則已存在"
            
            aws ec2 authorize-security-group-ingress \
                --group-id $sg_id \
                --protocol tcp --port 5432 --cidr 10.0.0.0/8 \
                --region $TARGET_REGION 2>/dev/null || echo "PostgreSQL 規則已存在"
            ;;
    esac
}

# ECR 跨區域複製
setup_ecr_replication() {
    echo "🔄 設定 ECR 跨區域複製..."
    
    # 獲取來源區域的 ECR 儲存庫清單
    REPOSITORIES=$(aws ecr describe-repositories \
        --region $SOURCE_REGION \
        --query 'repositories[].repositoryName' \
        --output text)
    
    if [[ -z "$REPOSITORIES" ]]; then
        echo "⚠️  警告：來源區域沒有找到 ECR 儲存庫"
        return 0
    fi
    
    # 在目標區域建立相同的儲存庫
    for repo in $REPOSITORIES; do
        echo "處理儲存庫: $repo"
        
        # 檢查目標區域是否已存在
        if aws ecr describe-repositories --repository-names $repo --region $TARGET_REGION >/dev/null 2>&1; then
            echo "  儲存庫 $repo 已存在於目標區域"
        else
            echo "  在目標區域建立儲存庫 $repo"
            aws ecr create-repository \
                --repository-name $repo \
                --region $TARGET_REGION >/dev/null
        fi
        
        # 複製映像
        copy_ecr_images $repo
    done
    
    echo "✅ ECR 複製設定完成"
}

# 複製 ECR 映像
copy_ecr_images() {
    local repo_name=$1
    
    echo "  複製映像從儲存庫: $repo_name"
    
    # 獲取來源儲存庫的映像清單
    IMAGES=$(aws ecr list-images \
        --repository-name $repo_name \
        --region $SOURCE_REGION \
        --query 'imageIds[?imageTag!=null].imageTag' \
        --output text)
    
    if [[ -z "$IMAGES" ]]; then
        echo "    沒有找到映像標籤"
        return 0
    fi
    
    # 複製每個映像
    for tag in $IMAGES; do
        echo "    複製映像標籤: $tag"
        
        # 拉取映像
        docker pull $AWS_ACCOUNT_ID.dkr.ecr.$SOURCE_REGION.amazonaws.com/$repo_name:$tag
        
        # 重新標記
        docker tag $AWS_ACCOUNT_ID.dkr.ecr.$SOURCE_REGION.amazonaws.com/$repo_name:$tag \
                   $AWS_ACCOUNT_ID.dkr.ecr.$TARGET_REGION.amazonaws.com/$repo_name:$tag
        
        # 推送到目標區域
        docker push $AWS_ACCOUNT_ID.dkr.ecr.$TARGET_REGION.amazonaws.com/$repo_name:$tag
        
        # 清理本地映像
        docker rmi $AWS_ACCOUNT_ID.dkr.ecr.$SOURCE_REGION.amazonaws.com/$repo_name:$tag
        docker rmi $AWS_ACCOUNT_ID.dkr.ecr.$TARGET_REGION.amazonaws.com/$repo_name:$tag
    done
}

# RDS 遷移（快照方式）
migrate_rds_database() {
    local db_instance_id=${DB_INSTANCE_ID}
    local target_db_id="${DB_INSTANCE_ID}-taipei"
    
    echo "🗄️  開始 RDS 資料庫遷移..."
    
    if [[ -z "$db_instance_id" ]]; then
        echo "⚠️  警告：DB_INSTANCE_ID 未設定，跳過 RDS 遷移"
        return 0
    fi
    
    # 建立快照
    local snapshot_id="migration-snapshot-$(date +%Y%m%d-%H%M%S)"
    echo "建立資料庫快照: $snapshot_id"
    
    aws rds create-db-snapshot \
        --db-instance-identifier $db_instance_id \
        --db-snapshot-identifier $snapshot_id \
        --region $SOURCE_REGION
    
    # 等待快照完成
    echo "⏳ 等待快照建立完成..."
    aws rds wait db-snapshot-completed \
        --db-snapshot-identifier $snapshot_id \
        --region $SOURCE_REGION
    
    # 複製快照到目標區域
    echo "複製快照到目標區域..."
    aws rds copy-db-snapshot \
        --source-db-snapshot-identifier "arn:aws:rds:$SOURCE_REGION:$AWS_ACCOUNT_ID:snapshot:$snapshot_id" \
        --target-db-snapshot-identifier $snapshot_id \
        --region $TARGET_REGION
    
    # 等待快照複製完成
    echo "⏳ 等待快照複製完成..."
    aws rds wait db-snapshot-completed \
        --db-snapshot-identifier $snapshot_id \
        --region $TARGET_REGION
    
    # 從快照還原資料庫
    echo "從快照還原資料庫..."
    aws rds restore-db-instance-from-db-snapshot \
        --db-instance-identifier $target_db_id \
        --db-snapshot-identifier $snapshot_id \
        --region $TARGET_REGION
    
    # 等待資料庫可用
    echo "⏳ 等待資料庫還原完成..."
    aws rds wait db-instance-available \
        --db-instance-identifier $target_db_id \
        --region $TARGET_REGION
    
    echo "✅ RDS 資料庫遷移完成"
    echo "新資料庫識別符: $target_db_id"
}

# DNS 流量切換
switch_dns_traffic() {
    local service_type=$1
    local target_endpoint=$2
    local domain_name=${DOMAIN_NAME:-"your-domain.com"}
    local hosted_zone_id=${HOSTED_ZONE_ID}
    
    if [[ -z "$hosted_zone_id" ]]; then
        echo "⚠️  警告：HOSTED_ZONE_ID 未設定，跳過 DNS 切換"
        return 0
    fi
    
    echo "🔄 開始 DNS 流量切換..."
    echo "服務類型: $service_type"
    echo "目標端點: $target_endpoint"
    echo "域名: $domain_name"
    
    # 漸進式流量切換
    for weight in 10 25 50 75 100; do
        echo "切換 $weight% 流量到 Taipei Region..."
        
        aws route53 change-resource-record-sets \
            --hosted-zone-id $hosted_zone_id \
            --change-batch "{
                \"Changes\": [{
                    \"Action\": \"UPSERT\",
                    \"ResourceRecordSet\": {
                        \"Name\": \"$domain_name\",
                        \"Type\": \"CNAME\",
                        \"SetIdentifier\": \"Taipei-$service_type\",
                        \"Weight\": $weight,
                        \"TTL\": 60,
                        \"ResourceRecords\": [{\"Value\": \"$target_endpoint\"}]
                    }
                }]
            }"
        
        echo "等待 2 分鐘觀察流量..."
        sleep 120
        
        # 檢查健康狀態
        curl -f "http://$target_endpoint/health" || echo "健康檢查失敗"
    done
    
    echo "✅ DNS 流量切換完成！"
}

# 緊急回滾
emergency_rollback() {
    local service_type=$1
    local source_endpoint=$2
    local domain_name=${DOMAIN_NAME:-"your-domain.com"}
    local hosted_zone_id=${HOSTED_ZONE_ID}
    
    if [[ -z "$hosted_zone_id" ]]; then
        echo "⚠️  警告：HOSTED_ZONE_ID 未設定，無法執行 DNS 回滾"
        return 1
    fi
    
    echo "🚨 執行緊急回滾..."
    
    # 立即將所有流量切回來源區域
    aws route53 change-resource-record-sets \
        --hosted-zone-id $hosted_zone_id \
        --change-batch "{
            \"Changes\": [{
                \"Action\": \"UPSERT\",
                \"ResourceRecordSet\": {
                    \"Name\": \"$domain_name\",
                    \"Type\": \"CNAME\",
                    \"SetIdentifier\": \"Tokyo-$service_type\",
                    \"Weight\": 100,
                    \"TTL\": 60,
                    \"ResourceRecords\": [{\"Value\": \"$source_endpoint\"}]
                }
            }]
        }"
    
    echo "✅ 緊急回滾完成！流量已切回 Tokyo Region"
}

# 驗證遷移狀態
verify_migration_status() {
    local service_type=$1
    
    echo "🔍 驗證 $service_type 遷移狀態..."
    
    case $service_type in
        "eks")
            verify_eks_status
            ;;
        "ecs")
            verify_ecs_status
            ;;
        "ec2")
            verify_ec2_status
            ;;
    esac
}

# 驗證 EKS 狀態
verify_eks_status() {
    echo "檢查 EKS 叢集狀態："
    aws eks describe-cluster \
        --name $CLUSTER_NAME \
        --region $TARGET_REGION \
        --query 'cluster.{Name:name,Status:status,Version:version,Endpoint:endpoint}' 2>/dev/null || echo "EKS 叢集不存在或無法訪問"
}

# 驗證 ECS 狀態
verify_ecs_status() {
    echo "檢查 ECS 叢集狀態："
    aws ecs describe-clusters \
        --clusters $CLUSTER_NAME \
        --region $TARGET_REGION \
        --query 'clusters[0].{Name:clusterName,Status:status,ActiveServicesCount:activeServicesCount,RunningTasksCount:runningTasksCount}' 2>/dev/null || echo "ECS 叢集不存在或無法訪問"
}

# 驗證 EC2 狀態
verify_ec2_status() {
    echo "檢查 Auto Scaling 群組狀態："
    aws autoscaling describe-auto-scaling-groups \
        --auto-scaling-group-names taipei-app-asg \
        --query 'AutoScalingGroups[0].{DesiredCapacity:DesiredCapacity,MinSize:MinSize,MaxSize:MaxSize,Instances:length(Instances)}' \
        --region $TARGET_REGION 2>/dev/null || echo "Auto Scaling 群組不存在或無法訪問"
}

# 清理函數
cleanup_temp_files() {
    echo "🧹 清理暫存檔案..."
    rm -f *.json *.txt *.yaml *.sh.tmp 2>/dev/null || true
    echo "✅ 清理完成"
}

# 顯示說明
show_help() {
    cat << EOF
共用函數說明：

主要函數：
  load_config                    - 載入設定檔
  validate_basic_config          - 驗證基本設定
  get_vpc_resources             - 獲取 VPC 資源
  create_or_get_security_group  - 建立或獲取安全群組
  add_security_group_rules      - 加入安全群組規則
  setup_ecr_replication         - 設定 ECR 複製
  migrate_rds_database          - 遷移 RDS 資料庫
  switch_dns_traffic            - DNS 流量切換
  emergency_rollback            - 緊急回滾
  verify_migration_status       - 驗證遷移狀態
  cleanup_temp_files            - 清理暫存檔案

使用方式：
  source common_functions.sh
  load_config
  validate_basic_config
  get_vpc_resources
  # ... 其他函數調用

EOF
}

# 如果直接執行此腳本，顯示說明
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    show_help
fi
