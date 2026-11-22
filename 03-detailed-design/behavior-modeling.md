# 动态行为建模：运单状态机与核心业务顺序图

## 1. 电子运单全生命周期状态机图（State Machine Diagram）

为彻底杜绝“未分拣直接派车”、“已签收运单被重复改派”等业务数据错乱，系统对 `waybill.status` 字段建立严格的状态机守卫，并完整刻画了**在途异常挂起 → 释放运力 → 二次改派**的工程闭环。

```mermaid
stateDiagram-v2
    direction LR

    [*] --> PENDING_PICKUP : 客户下单支付
    PENDING_PICKUP : 待揽收
    PENDING_PICKUP --> SORTING : 仓管员扫码入库

    SORTING : 区域分拣中
    SORTING --> READY_FOR_DISPATCH : 分区核验完成

    READY_FOR_DISPATCH : 待调度（进入运单池）
    READY_FOR_DISPATCH --> DISPATCHED : 调度员确认派车

    DISPATCHED : 已派车待装货
    DISPATCHED --> IN_TRANSIT : 司机扫码发车

    IN_TRANSIT : 在途运输中
    IN_TRANSIT --> OUT_FOR_DELIVERY : 抵达末端派送点
    IN_TRANSIT --> EXCEPTION_HOLD : 车损/严重堵车上报

    EXCEPTION_HOLD : 异常挂起
    EXCEPTION_HOLD --> READY_FOR_DISPATCH : 调度员触发二次改派（释放回池）

    OUT_FOR_DELIVERY : 末端派送中
    OUT_FOR_DELIVERY --> SIGNED : 客户电子签收
    OUT_FOR_DELIVERY --> EXCEPTION_HOLD : 拒收/联系不上挂起

    SIGNED : 已签收（终态）
    SIGNED --> [*]
```

### 非法状态跃迁拦截规则（状态守卫表）

| 当前状态 | 禁止的非法操作 | 系统拦截策略与错误码 |
| :--- | :--- | :--- |
| `PENDING_PICKUP` / `SORTING` | 直接纳入智能一键派单 | 仅拉取 `status = READY_FOR_DISPATCH` 的运单，接口层直接过滤 |
| `DISPATCHED` / `IN_TRANSIT` | 另一名调度员再次将其派给其他车辆 | 依托 Redis 锁 + `waybill.version` 乐观锁拦截，返回 `40901 运单状态已变更` |
| `SIGNED` | 触发异常挂起或二次改派 | 状态机判定为终态不可逆，返回 `40005 已签收运单不允许变更状态` |

---

## 2. 核心业务顺序图：智能一键派单与地图降级流程

本顺序图对应核心用例 `UC-04`，完整展示调度员触发派单后，从**分布式加锁、外部地图超时降级、策略引擎求解、乐观锁事务提交**到**异步推送司机端**的全链路交互。

```mermaid
sequenceDiagram
    autonumber
    actor Dispatcher as 区域调度员(Web)
    participant Ctrl as DispatchController
    participant Ctx as DispatchContext
    participant Map as MapApiAdapter
    participant DB as MySQL / Redis
    participant MQ as RabbitMQ(司机端)

    Dispatcher->>Ctrl: POST /dispatch/auto-assign (网点ID, 策略类型)
    Ctrl->>DB: Redis SETNX 申请区域调度互斥锁(TTL=10s)
    DB-->>Ctrl: 加锁成功

    Ctrl->>DB: 查询待调度运单(READY)与空闲车辆(IDLE)
    DB-->>Ctrl: 返回运单列表 & 可用车辆列表

    Ctrl->>Ctx: executeDispatch(策略, 运单, 车辆)
    Ctx->>Map: getDistanceMatrix(网点与收货点坐标集)

    alt 外部地图 API 正常响应 (<= 1.5s)
        Map-->>Ctx: 返回真实路网距离与 ETA 矩阵
    else 地图 API 超时或限流（容错降级）
        Map->>Map: 执行哈弗辛直线距离 × 1.35 绕行系数
        Map-->>Ctx: 返回降级估算距离矩阵（标记 degraded=true）
    end

    Ctx->>Ctx: 执行选定策略算法（聚类 + 约束贪心匹配）
    Ctx-->>Ctrl: 返回 DispatchPlan（已匹配方案 + 未分配兜底清单）

    Ctrl->>DB: 开启 ACID 事务：写任务单 & 乐观锁更新运单/车辆状态
    DB-->>Ctrl: 事务提交成功 & 释放 Redis 锁

    Ctrl-)MQ: 异步发布 TaskAssignedEvent（推送任务至司机小程序）
    Ctrl-->>Dispatcher: 返回 200 OK（派单结果、各车满载率与路线快照）
```

---

## 3. 异常场景交互说明（二次改派链路）

当在途司机通过移动端调用异常上报接口时，系统执行**异步解耦 + 空间就近救援**两步闭环：
1. **同步写入 + 异步广播**：`VehicleMonitorSubject` 写入 `tracking_log` 后，将异常事件投递至 RabbitMQ；三个观察者并发完成“未签收运单置为 `EXCEPTION_HOLD`”、“WebSocket 推红框告警至调度大屏”、“异步短信通知受影响货主”。
2. **就近救援改派**：调度员在大屏点击“一键改派”时，系统调用 Redis `GEORADIUS` 指令检索事故经纬度周边 $10\text{ km}$ 内的 `IDLE` 空闲车辆，自动复用 `UrgentTimeWindowStrategy` 生成接驳任务单，并在 `dispatch_task_waybill` 中将原明细标记为 `REASSIGNED`、插入新任务明细，实现历史全程可追溯。