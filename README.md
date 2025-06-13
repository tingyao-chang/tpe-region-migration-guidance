# AWS 跨區域遷移指南：Tokyo Region 到 Taipei Region

>  此指南全部由 Amazon Q Developer CLI + MCP Server 產生

## 概述

本指南提供從 Tokyo Region (ap-northeast-1) 遷移到 Taipei Region (ap-east-2) 的完整策略，主要針對使用 Amazon EKS、Amazon RDS 和 Amazon ECR 的客戶。

## 遷移架構圖

![更新版遷移架構](./generated-diagrams/updated_migration_architecture.png)

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

**推薦方法**：RDS 跨區域自動備份複製 + AWS DMS 持續同步

**實作步驟**：

**階段一：建立跨區域備份基礎**
1. **啟用跨區域自動備份複製**
   - 在 Taipei Region 啟用來源 RDS 實例的自動備份複製
   - 設定適當的備份保留期間（建議 7-14 天）
   - 確認備份複製狀態和完整性

2. **從跨區域備份建立目標資料庫**
   - 使用時間點恢復功能從跨區域備份建立新實例
   - 選擇與來源相同或更高的實例規格
   - 配置相同的資料庫引擎版本和參數群組

**階段二：設定持續資料同步**
3. **準備 DMS 環境**
   - 建立適當規格的 DMS 複製執行個體
   - 確保網路連線和安全群組設定正確
   - 準備資料表對應規則檔案（支援全部資料表或特定篩選）

4. **建立 DMS 端點**
   - 設定來源端點：連接 Tokyo Region 的 RDS 實例
   - 設定目標端點：連接 Taipei Region 的 RDS 實例
   - 測試端點連線確保網路通暢

5. **啟動持續資料複製**
   - 建立 CDC（Change Data Capture）複製任務
   - 監控初始資料載入進度
   - 確認持續變更資料同步正常運作

**預期指標**：
- **RPO**: 5-15 分鐘（透過 AWS DMS 持續同步）
- **RTO**: 15-30 分鐘（自動化切換）

### 2. Amazon EKS 遷移策略

**推薦方法**：配置匯出 + 基礎設施重建 + 應用程式狀態遷移

**關鍵注意事項**：
- EKS 叢集無法直接跨區域遷移，必須重新建立
- 需要保留所有 Kubernetes 資源配置和狀態
- 注意 LoadBalancer 和 Ingress 的區域特定設定
- 確保 IAM 角色和 RBAC 權限正確對應

**實作步驟**：

**階段一：現有叢集配置匯出**
1. **匯出叢集基本配置**
   - 記錄 EKS 叢集版本、節點群組配置
   - 匯出 VPC、子網路、安全群組設定
   - 備份 IAM 角色和服務帳戶配置

2. **匯出 Kubernetes 資源**
   - 匯出所有 Deployment、Service、ConfigMap 配置
   - 備份 Persistent Volume Claims 和 Storage Classes
   - 記錄 Ingress Controller 和 Load Balancer 設定
   - 匯出 Secrets（注意安全性，避免明文儲存）

3. **匯出應用程式特定配置**
   - 記錄 Helm Charts 和版本資訊
   - 備份自定義 CRDs (Custom Resource Definitions)
   - 匯出 Service Mesh 配置（如 Istio）
   - 記錄監控和日誌收集配置

**階段二：目標區域叢集建立**
4. **準備叢集配置檔**
   - 建立 eksctl 配置檔或 Terraform 模組
   - 確保節點群組規格與來源一致
   - 配置相同的網路和安全設定
   - 設定適當的 IAM 角色和權限

5. **建立新 EKS 叢集**
   - 在 Taipei Region 建立新的 EKS 叢集
   - 配置節點群組和自動擴展設定
   - 安裝必要的 Add-ons（如 AWS Load Balancer Controller）
   - 驗證叢集健康狀態和網路連線

**階段三：應用程式部署和驗證**
6. **部署核心基礎設施**
   - 安裝 Ingress Controller 和 Service Mesh
   - 配置 Storage Classes 和 Persistent Volumes
   - 部署監控和日誌收集系統
   - 設定 DNS 和服務發現

7. **應用程式遷移部署**
   - 按依賴順序部署應用程式
   - 更新容器映像標籤指向新區域的 ECR
   - 配置環境變數和連線字串
   - 驗證應用程式功能和整合測試

### 3. Amazon ECR 遷移策略

**推薦方法**：ECR 跨區域自動複製

**實作步驟**：

1. **設定複製規則配置**
   - 建立複製規則 JSON 配置檔
   - 指定目標區域為 ap-east-2
   - 設定儲存庫篩選條件（可選擇全部或特定前綴）

2. **啟用跨區域複製**
   - 在來源區域 (ap-northeast-1) 套用複製配置
   - 驗證複製規則已正確設定
   - 確認目標區域的儲存庫已自動建立

3. **處理現有映像**
   - 識別需要遷移的現有容器映像
   - 手動觸發現有映像的跨區域複製
   - 驗證所有標籤和映像層都已正確複製

4. **驗證複製完整性**
   - 檢查目標區域的映像清單
   - 比對映像摘要確保一致性
   - 測試從新區域拉取映像的功能

**複製規則配置範例結構**：
```json
{
  "rules": [
    {
      "destinations": [
        {
          "region": "ap-east-2",
          "registryId": "您的帳戶ID"
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
- [ ] 準備 DMS 相關配置檔案

### 第 2 週：資料庫遷移執行
- [ ] 啟用 RDS 跨區域自動備份複製
- [ ] 從自動備份恢復建立新的 DB 實例
- [ ] 建立 table-mappings.json 配置檔
- [ ] 建立 AWS DMS 複製執行個體和端點
- [ ] AWS DMS 複製任務啟動和監控
- [ ] 資料一致性驗證
- [ ] 效能基準測試

### 第 3 週：EKS 叢集建立與應用部署
- [ ] 匯出現有 EKS 叢集配置和資源
- [ ] 建立 Taipei 叢集配置檔（taipei-cluster-config.yaml）
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
**關鍵監控項目**：
- AWS DMS 任務狀態和進度監控
- 資料同步延遲時間追蹤
- 錯誤日誌和異常事件檢查
- 目標資料庫效能指標驗證

**驗證步驟**：
- 比對來源和目標資料庫的資料筆數
- 執行資料完整性檢查查詢
- 驗證索引和約束條件是否正確複製
- 測試應用程式連線和查詢效能

### Amazon EKS 健康檢查
**叢集層級檢查**：
- 節點狀態和資源使用率
- 控制平面 API 回應時間
- 網路連線和 DNS 解析功能
- 儲存類別和持久化磁碟區狀態

**應用程式層級檢查**：
- Pod 運行狀態和重啟次數
- Service 端點和負載平衡功能
- Ingress 路由和 SSL 憑證狀態
- ConfigMap 和 Secret 載入狀況

### Amazon ECR 同步狀態
**複製狀態檢查**：
- 複製規則配置和啟用狀態
- 目標區域儲存庫建立狀況
- 映像複製進度和完成狀態
- 複製失敗的映像和錯誤原因

**映像完整性驗證**：
- 比對映像摘要值確保一致性
- 驗證所有標籤都已正確複製
- 測試從新區域拉取映像的功能
- 檢查映像層的完整性和可用性

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
**DNS 切換回滾**：
- 準備 Amazon Route 53 回滾變更集
- 使用預先配置的 DNS 記錄快速切回
- 確保 TTL 設定允許快速生效

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
