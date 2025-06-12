# AWS 跨區域遷移指南：Tokyo Region 到 Taipei Region

## 概述

本指南提供從 Tokyo Region (ap-northeast-1) 遷移到 Taipei Region (ap-east-2) 的完整策略，主要針對使用 Amazon EKS、Amazon RDS 和 Amazon ECR 的客戶。

## 遷移架構圖

![完整遷移架構](./generated-diagrams/complete_migration_architecture.png)

## 適用客戶條件

### ✅ 最適合的客戶特徵

**技術架構**：
- 使用 Amazon EKS + Amazon RDS + Amazon ECR 的組合架構
- 手動透過 AWS Console 或 AWS CLI 建立的服務
- 缺乏完整的 AWS CloudFormation 或 AWS CDK 管理
- 已在 Tokyo Region 使用多可用區部署

**業務需求**：
- 需要完全一致的配置複製到新區域
- 要求最小停機時間（RTO < 30分鐘）
- 資料遺失容忍度低（RPO < 15分鐘）
- 有明確的遷移時間窗口

**組織能力**：
- 具備 AWS CLI 和 kubectl 操作經驗
- 有 24/7 監控和應急響應能力
- 能承受 1-2 週的雙重環境成本
- 有測試環境可以先行驗證

### ❌ 不適用的客戶類型

- 已完全使用 AWS CloudFormation 或 AWS CDK 管理基礎設施
- 純 Serverless 架構（AWS Lambda + Amazon API Gateway + Amazon DynamoDB）
- 只使用單一 AWS 服務的簡單架構
- 缺乏 Kubernetes 和容器技術經驗

## 遷移策略

### 1. Amazon RDS 遷移策略

**推薦方法**：多層次備份 + AWS DMS 持續同步

**技術實作**：
```bash
# 1. 設定 AWS Backup 跨區域備份
aws backup create-backup-plan \
  --backup-plan BackupPlanName="RDS-CrossRegion-Migration" \
  --region ap-northeast-1

# 2. 配置跨區域快照複製
aws rds modify-db-instance \
  --db-instance-identifier tokyo-db \
  --backup-retention-period 7 \
  --copy-tags-to-snapshot \
  --region ap-northeast-1

# 3. AWS DMS 持續複製設定
aws dms create-replication-instance \
  --replication-instance-identifier migration-instance \
  --replication-instance-class dms.t3.medium \
  --allocated-storage 100 \
  --region ap-east-2
```

**預期指標**：
- **RPO**: 5-15 分鐘（透過 AWS DMS 持續同步）
- **RTO**: 15-30 分鐘（自動化切換）

### 2. Amazon EKS 遷移策略

**推薦方法**：配置即代碼 + 應用程式狀態遷移

**技術實作**：
```bash
# 1. 匯出完整叢集配置
eksctl utils write-kubeconfig --cluster tokyo-cluster --region ap-northeast-1
kubectl get all --all-namespaces -o yaml > cluster-backup.yaml

# 2. 使用 eksctl 配置檔重建
eksctl create cluster --config-file=taipei-cluster-config.yaml --region ap-east-2

# 3. 應用程式部署
kubectl apply -f cluster-backup.yaml --region ap-east-2
```

### 3. Amazon ECR 遷移策略

**推薦方法**：ECR 跨區域自動複製

**複製配置**：
```json
{
  "rules": [
    {
      "destinations": [
        {
          "region": "ap-east-2",
          "registryId": "123456789012"
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
}
```

**現有映像遷移**：
```bash
# 設定 ECR 複製規則
aws ecr put-replication-configuration \
  --replication-configuration file://replication-config.json \
  --region ap-northeast-1

# 手動觸發現有映像複製
for repo in $(aws ecr describe-repositories --region ap-northeast-1 --query 'repositories[].repositoryName' --output text); do
  aws ecr batch-get-image --repository-name $repo --region ap-northeast-1 \
    --image-ids imageTag=latest --query 'images[].imageManifest' --output text | \
  aws ecr put-image --repository-name $repo --region ap-east-2 \
    --image-manifest file:///dev/stdin --image-tag latest
done
```

## 遷移時程規劃

### 第 0 週：規劃與準備
- [ ] 災難恢復需求評估（RTO/RPO）
- [ ] 依賴關係分析和風險評估
- [ ] Amazon ECR 複製規則配置（提前開始背景同步）
- [ ] 測試環境建立和驗證

### 第 1 週：基礎設施準備
- [ ] Taipei Region 基礎網路建立（Amazon VPC、子網路）
- [ ] IAM 角色和安全群組配置
- [ ] Amazon ECR 複製驗證
- [ ] AWS DMS 複製執行個體建立

### 第 2 週：資料庫遷移執行
- [ ] Amazon RDS 快照建立和跨區域復原
- [ ] AWS DMS 複製任務啟動和監控
- [ ] 資料一致性驗證
- [ ] 效能基準測試

### 第 3 週：EKS 叢集建立與應用部署
- [ ] Amazon EKS 叢集建立
- [ ] 應用程式配置部署
- [ ] 服務發現和負載平衡配置
- [ ] 功能和整合測試

### 第 4 週：流量切換與驗證
- [ ] Amazon Route 53 DNS 記錄準備
- [ ] 漸進式流量切換（10% → 50% → 100%）
- [ ] 監控和效能驗證
- [ ] 完成遷移確認

## 監控與驗證

### Amazon RDS 遷移監控
```bash
# AWS DMS 任務狀態監控
aws dms describe-replication-tasks \
  --filters Name=replication-task-id,Values=task-id \
  --region ap-east-2

# 資料一致性檢查
aws rds describe-db-instances \
  --db-instance-identifier taipei-db \
  --region ap-east-2
```

### Amazon EKS 健康檢查
```bash
# 叢集狀態驗證
kubectl get nodes --show-labels
kubectl get pods --all-namespaces
kubectl get services --all-namespaces
```

### Amazon ECR 同步狀態
```bash
# 複製狀態檢查
aws ecr describe-registry --region ap-east-2 \
  --query 'replicationConfiguration.rules[].destinations[].region'

# 映像完整性驗證
aws ecr describe-images --repository-name app-repo --region ap-east-2
```

## 成本最佳化

### 預期成本項目
- **Amazon ECR 複製**：跨區域資料傳輸 $0.02/GB + 雙重儲存成本
- **AWS DMS**：複製執行個體按小時計費 + 跨區域資料傳輸
- **雙重環境**：1-2 週並行運行成本

### 最佳化建議
- 使用 VPC Peering 降低資料傳輸成本
- 選擇適當的 AWS DMS 執行個體大小
- 遷移完成後及時清理暫時資源
- 考慮使用 Amazon EC2 Spot 執行個體進行測試

## 風險控制與回滾策略

### 快速回滾機制
```bash
# Amazon Route 53 DNS 快速切回
aws route53 change-resource-record-sets \
  --hosted-zone-id Z123456789 \
  --change-batch file://rollback-changeset.json
```

### 資料一致性保證
- AWS DMS 雙向同步配置
- 15 分鐘內完成流量切回
- 多重備份機制確保資料安全

### 風險緩解措施
- 完整的測試環境驗證
- 分階段流量切換
- 24/7 監控和告警機制
- 詳細的回滾程序文件

## 成功指標

### 技術指標
- **RTO 達成**：< 30 分鐘
- **RPO 達成**：< 15 分鐘
- **配置一致性**：100% 相同
- **應用程式可用性**：99.9%+

### 業務指標
- **遷移時程**：4 週內完成
- **成本控制**：預算範圍內
- **零資料遺失**：確保資料完整性
- **使用者體驗**：無感知切換

## 支援資源

### AWS 服務文件
- [Amazon RDS 跨區域災難恢復](https://docs.aws.amazon.com/prescriptive-guidance/latest/dr-standard-edition-amazon-rds/design-cross-region-dr.html)
- [Amazon ECR 跨區域複製](https://docs.aws.amazon.com/AmazonECR/latest/userguide/replication.html)
- [Amazon EKS 最佳實踐](https://docs.aws.amazon.com/eks/latest/best-practices/)
- [AWS Database Migration Service 最佳實踐](https://docs.aws.amazon.com/dms/latest/userguide/CHAP_BestPractices.html)

### 聯絡支援
如需進一步協助，請聯絡您的 AWS Solutions Architect 或透過 AWS Support 提交技術支援請求。

---

**版本**: 1.0  
**最後更新**: 2025-06-12  
**適用區域**: Tokyo Region (ap-northeast-1) → Taipei Region (ap-east-2)
