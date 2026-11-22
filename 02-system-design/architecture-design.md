# 系统总体架构与物理部署设计

## 1. 系统设计目标与核心工程原则

依据 `01-project-management/use-case-and-scope.md` 界定的业务边界与非功能性指标（区域 200 笔运单/30 辆车 3 秒内完成调度、100 辆车 GPS 高频写入、异常快速响应），总体架构设计严格遵循软件工程以下四项核心原则：

1. **高内聚、低耦合**：按业务领域划分 5 大独立功能模块，模块内部围绕单一职责实现**功能内聚**；模块之间仅通过明确定义的内部服务接口或异步事件通信，杜绝跨模块直接读写对方数据库表。
2. **关注点分离**：采用分层体系结构，将用户交互、安全网关、业务规则与数据持久化彻底解耦，便于并行开发与单元测试。
3. **信息隐藏与外部依赖隔离**：将易变的外部地图 API（高德）与短信网关封装在独立的适配器层背后，并提供降级兜底策略，屏蔽外部接口变动与超时故障对核心调度的冲击。
4. **事件驱动解耦**：针对在途 GPS 高频轨迹与车辆故障告警，采用“发布—订阅”异步机制，避免非核心通知阻塞核心运单与派单事务。

---

## 2. 系统总体逻辑架构设计

系统采用 **“四层分层架构 + 模块化单体 + 异步事件总线”** 的混合体系结构，逻辑分层与组件交互如下：

```mermaid
flowchart TB
    subgraph L1 ["1. 表现层（Presentation Layer）"]
        direction LR
        WebUI["PC 调度管理大屏<br/>（Vue / ECharts）"]
        DriverApp["司机移动端小程序<br/>（任务/GPS/异常上报）"]
        CustApp["货主端小程序<br/>（下单/轨迹查询）"]
        PdaUI["仓管员 PDA / Web<br/>（扫码入库/分拣）"]
    end

    subgraph L2 ["2. 接入与网关层（Gateway & Access Layer）"]
        Gateway["Nginx + API Gateway<br/>（HTTPS / JWT鉴权 / 限流 / WebSocket长连接）"]
    end

    subgraph L3 ["3. 业务逻辑层（Modular Business Layer - 模块化单体）"]
        direction TB
        subgraph CoreMods ["五大高内聚业务领域模块"]
            direction LR
            M_Order["订单与运单模块<br/>（运单状态机/计费）"]
            M_Station["网点与仓储模块<br/>（入库/分拣/出库）"]
            M_Dispatch["智能调度引擎模块<br/>（策略引擎/车货匹配）"]
            M_Track["车辆与在途监控模块<br/>（车辆档案/异常检测）"]
            M_Stat["统计与结算模块<br/>（满载率/准时率KPI）"]
        end

        subgraph InfraMods ["通用支撑与解耦基础设施"]
            direction LR
            EventBus["异步事件总线 / 消息队列<br/>（RabbitMQ：异常告警/轨迹削峰/通知推送）"]
            MapAdapter["地图服务适配器（MapApiAdapter）<br/>（路网距离缓存 + 直线距离降级兜底）"]
        end
    end

    subgraph L4 ["4. 数据持久与缓存层（Data Persistence Layer）"]
        direction LR
        MySQL[("MySQL 8.0 主从集群<br/>（核心事务表/运单/调度单）")]
        Redis[("Redis 缓存与GEO引擎<br/>（车辆实时经纬度/热点数据/分布式锁）")]
    end

    subgraph L5 ["5. 外部支撑服务（External Services）"]
        direction LR
        ExtMap[["高德 / 百度地图 API<br/>（地理编码 / 路径ETA）"]]
        ExtSms[["短信 / 微信推送网关<br/>（异常延误提醒）"]]
    end

    WebUI & DriverApp & CustApp & PdaUI --> Gateway
    Gateway --> M_Order & M_Station & M_Dispatch & M_Track & M_Stat

    M_Dispatch -. "接口调用：查询待派运单/空闲车辆" .-> M_Order
    M_Dispatch -. "接口调用" .-> M_Track
    M_Dispatch --> MapAdapter
    M_Track --> EventBus
    M_Dispatch --> EventBus
    EventBus -. "订阅：大屏弹窗告警 / 客户通知" .-> Gateway
    EventBus --> ExtSms

    CoreMods --> MySQL
    M_Track & M_Dispatch --> Redis
    MapAdapter --> ExtMap

    classDef layer fill:#F8FAFC,stroke:#94A3B8,stroke-width:1.5px,color:#0F172A
    classDef core fill:#DBEAFE,stroke:#2563EB,color:#1E3A8A,stroke-width:1.5px
    classDef highlight fill:#FEF3C7,stroke:#D97706,color:#92400E,stroke-width:2px
    classDef infra fill:#D1FAE5,stroke:#059669,color:#065F46,stroke-width:1.5px
    classDef db fill:#EDE9FE,stroke:#7C3AED,color:#4C1D95,stroke-width:1.5px

    class M_Order,M_Station,M_Track,M_Stat core
    class M_Dispatch highlight
    class EventBus,MapAdapter infra
    class MySQL,Redis db
```

---

## 3. 核心业务子系统划分与内聚/耦合设计

| 子系统 / 模块名称 | 核心职责（功能内聚） | 对外暴露接口（低耦合边界） | 关键数据归属 |
| :--- | :--- | :--- | :--- |
| **订单与运单管理模块** | 运单创建、运费估算、电子运单状态机校验、签收核销 | `getReadyWaybills()`, `batchUpdateStatus()`, `releaseWaybills()` | `waybill`, `sys_user` |
| **区域网点与仓储模块** | 区域分拨中心与末端网点管理、入库扫描、片区分拣、出库核验 | `getStationByZone()`, `confirmInboundSorting()` | `station` |
| **智能调度与路径规划模块** | 待派运单聚合、调度策略动态切换、约束车货匹配、异常改派生成 | `generateDispatchPlan()`, `confirmTask()`, `reassignTask()` | `dispatch_task`, `dispatch_task_waybill` |
| **车辆与在途监控模块** | 车辆/司机档案维护、GPS 坐标高频接收、偏航/车损异常事件发布 | `getAvailableVehicles()`, `lockVehicle()`, `reportException()` | `vehicle`, `tracking_log` |
| **数据统计与结算模块** | 定时汇总各车满载率、准时送达率、异常率及基础运费对账报表 | `queryDailyKpiReport()`, `exportBillingSummary()` | 只读聚合视图（不直接修改核心表） |

---

## 4. 关键架构级技术机制

1. **高并发 GPS 轨迹削峰与冷热分离**：
   * 车辆每 10 秒上报一次坐标，直接高频 `INSERT` 关系型数据库易引发锁竞争。架构设计采用 **Redis GEO 实时覆盖写（供调度大屏毫秒级拉取车辆最新点位） + RabbitMQ 异步批量消费落盘 MySQL（供历史轨迹回放）** 的冷热分离策略。
2. **车辆锁定与防“一单多派”并发控制**：
   * 当两名调度员同时点击“一键派单”或执行“异常改派”时，利用 **Redis 分布式锁（按区域网点粒度加锁） + 数据库 `version` 乐观锁** 双重校验，确保同一运单不会被重复分配给两辆车，同一车辆不会被超载锁单。
3. **外部地图服务容错与降级机制**：
   * `MapApiAdapter` 内部对常用网点与片区间的路网距离做 Redis 缓存（TTL 15 分钟），减少外部 API 调用频次；当外部地图接口超时（$> 1.5\text{ s}$）或返回限流错误时，自动降级为本地算法估算路径，保障调度主链路永不中断。

---

## 5. 系统物理部署架构设计

面向区域级物流企业的中小规模并发与高可用诉求，物理部署采用“轻量双机高可用 + 数据主从分离”方案，既控制服务器硬件成本，又消除单点故障。

```mermaid
flowchart TB
    subgraph ClientZone ["客户端网络区域（公网 / 4G / 5G）"]
        C1["调度员浏览器<br/>（HTTPS / WSS）"]
        C2["司机/货主小程序<br/>（HTTPS）"]
        C3["网点 PDA 终端<br/>（HTTPS）"]
    end

    subgraph DMZ ["接入层（DMZ 区）"]
        LB["Nginx 反向代理与负载均衡节点<br/>（SSL 卸载 / 静态资源托管 / 限流）"]
    end

    subgraph AppZone ["应用服务区（内网安全区）"]
        App1["业务应用节点 1<br/>（模块化单体实例 + WebSocket）"]
        App2["业务应用节点 2<br/>（高可用热备 / 负载分担）"]
        MQ["RabbitMQ 消息中间件节点<br/>（事件队列与削峰）"]
    end

    subgraph DataZone ["数据存储区（内网隔离区）"]
        RedisNode[("Redis 节点<br/>（GEO实时位置 / 分布式锁 / 缓存）")]
        DBMaster[("MySQL 主库<br/>（事务写 + 实时读）")]
        DBSlave[("MySQL 从库<br/>（KPI报表统计查询 / 热备）")]
    end

    subgraph ExtCloud ["外部云服务"]
        MapCloud[["高德 / 百度地图云 API"]]
        SmsCloud[["短信 / 推送云网关"]]
    end

    C1 & C2 & C3 --> LB
    LB --> App1 & App2
    App1 & App2 <--> MQ
    App1 & App2 <--> RedisNode
    App1 & App2 --> DBMaster
    App1 & App2 -. "只读报表查询" .-> DBSlave
    DBMaster == "Binlog 异步复制" ==> DBSlave
    App1 & App2 -. "HTTPS 出站" .-> MapCloud
    MQ -. "异步回调推送" .-> SmsCloud
```

### 建议部署资源规格参考

| 逻辑节点 | 节点数量 | 建议配置 | 部署职责说明 |
| :--- | :--- | :--- | :--- |
| **Nginx 网关节点** | 1 台（可扩展 Keepalived 双机） | 2 核 4G | 统一公网入口、HTTPS 证书终止、动静分离及请求转发 |
| **核心应用节点** | 2 台（双活负载均衡） | 4 核 8G / 台 | 运行区域物流模块化单体应用，承载业务 API 与实时调度算法计算 |
| **消息与缓存节点** | 1 台（容器化隔离部署） | 4 核 8G | 部署 Redis（GEO 与锁）与 RabbitMQ（轨迹削峰、异常告警队列） |
| **MySQL 数据库** | 1 主 1 从 | 4 核 16G / 台（SSD） | 主库承接核心事务写入；从库承接统计报表查询与灾备恢复 |