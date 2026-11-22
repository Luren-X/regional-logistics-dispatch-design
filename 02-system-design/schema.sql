-- ============================================================================
-- 项目名称：区域物流管理与调度系统（Regional Logistics Management & Dispatch System）
-- 数据库版本：MySQL 8.0+
-- 字符集：utf8mb4 / InnoDB 事务引擎
-- ============================================================================

CREATE DATABASE IF NOT EXISTS regional_logistics
    DEFAULT CHARACTER SET utf8mb4
    DEFAULT COLLATE utf8mb4_unicode_ci;

USE regional_logistics;

-- 1. 区域网点与分拨中心表
CREATE TABLE station (
                         station_id    BIGINT        NOT NULL AUTO_INCREMENT COMMENT '网点主键ID',
                         station_code  VARCHAR(32)   NOT NULL COMMENT '网点唯一编码',
                         station_name  VARCHAR(100)  NOT NULL COMMENT '网点名称',
                         station_type  VARCHAR(20)   NOT NULL COMMENT '类型: HUB(分拨中心)/BRANCH(末端网点)',
                         address       VARCHAR(255)  NOT NULL COMMENT '网点详细地址',
                         lng           DECIMAL(10,6) NOT NULL COMMENT '经度',
                         lat           DECIMAL(10,6) NOT NULL COMMENT '纬度',
                         created_at    DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
                         PRIMARY KEY (station_id),
                         UNIQUE KEY uk_station_code (station_code)
) ENGINE=InnoDB COMMENT='区域网点与分拨中心表';

-- 2. 系统统一用户表（货主/调度员/司机/仓管员）
CREATE TABLE sys_user (
                          user_id       BIGINT        NOT NULL AUTO_INCREMENT COMMENT '用户主键ID',
                          username      VARCHAR(64)   NOT NULL COMMENT '登录账号',
                          password_hash VARCHAR(128)  NOT NULL COMMENT '加密密码哈希',
                          real_name     VARCHAR(64)   NOT NULL COMMENT '真实姓名',
                          phone         VARCHAR(20)   NOT NULL COMMENT '联系电话',
                          role          VARCHAR(20)   NOT NULL COMMENT '角色: CUSTOMER/DISPATCHER/DRIVER/CLERK',
                          station_id    BIGINT        NULL COMMENT '所属网点ID',
                          created_at    DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
                          PRIMARY KEY (user_id),
                          UNIQUE KEY uk_username (username),
                          KEY idx_user_role_station (role, station_id),
                          CONSTRAINT fk_user_station FOREIGN KEY (station_id) REFERENCES station(station_id)
) ENGINE=InnoDB COMMENT='系统用户表';

-- 3. 配送车辆档案表
CREATE TABLE vehicle (
                         vehicle_id        BIGINT        NOT NULL AUTO_INCREMENT COMMENT '车辆主键ID',
                         plate_no          VARCHAR(16)   NOT NULL COMMENT '车牌号',
                         station_id        BIGINT        NOT NULL COMMENT '归属网点ID',
                         default_driver_id BIGINT        NULL COMMENT '默认绑定司机ID',
                         max_weight_kg     DECIMAL(8,2)  NOT NULL COMMENT '最大载重(kg)',
                         max_volume_m3     DECIMAL(8,2)  NOT NULL COMMENT '最大容积(m3)',
                         status            VARCHAR(20)   NOT NULL DEFAULT 'IDLE' COMMENT '状态: IDLE/LOCKED/IN_TRANSIT/FAULT/MAINTENANCE',
                         version           INT           NOT NULL DEFAULT 0 COMMENT '乐观锁版本号',
                         updated_at        DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',
                         PRIMARY KEY (vehicle_id),
                         UNIQUE KEY uk_plate_no (plate_no),
                         KEY idx_vehicle_station_status (station_id, status),
                         CONSTRAINT fk_vehicle_station FOREIGN KEY (station_id) REFERENCES station(station_id),
                         CONSTRAINT fk_vehicle_driver  FOREIGN KEY (default_driver_id) REFERENCES sys_user(user_id)
) ENGINE=InnoDB COMMENT='配送车辆档案表';

-- 4. 电子运单表
CREATE TABLE waybill (
                         waybill_id         BIGINT        NOT NULL AUTO_INCREMENT COMMENT '运单主键ID',
                         waybill_no         VARCHAR(32)   NOT NULL COMMENT '电子运单号',
                         customer_id        BIGINT        NOT NULL COMMENT '托运货主ID',
                         origin_station_id  BIGINT        NOT NULL COMMENT '始发/当前分拣网点ID',
                         sender_name        VARCHAR(64)   NOT NULL COMMENT '寄件人姓名',
                         sender_phone       VARCHAR(20)   NOT NULL COMMENT '寄件人电话',
                         receiver_name      VARCHAR(64)   NOT NULL COMMENT '收件人姓名',
                         receiver_phone     VARCHAR(20)   NOT NULL COMMENT '收件人电话',
                         receiver_addr      VARCHAR(255)  NOT NULL COMMENT '收货详细地址',
                         receiver_lng       DECIMAL(10,6) NOT NULL COMMENT '收货点经度',
                         receiver_lat       DECIMAL(10,6) NOT NULL COMMENT '收货点纬度',
                         weight_kg          DECIMAL(8,2)  NOT NULL COMMENT '货物重量(kg)',
                         volume_m3          DECIMAL(8,2)  NOT NULL COMMENT '货物体积(m3)',
                         priority           TINYINT       NOT NULL DEFAULT 1 COMMENT '紧急度: 1普通/2加急/3特急',
                         deadline_time      DATETIME      NOT NULL COMMENT '期望最晚送达时间窗',
                         status             VARCHAR(24)   NOT NULL DEFAULT 'PENDING_PICKUP'
                             COMMENT '状态: PENDING_PICKUP/SORTING/READY_FOR_DISPATCH/DISPATCHED/IN_TRANSIT/EXCEPTION_HOLD/OUT_FOR_DELIVERY/SIGNED',
                         freight_fee        DECIMAL(10,2) NOT NULL DEFAULT 0.00 COMMENT '预估运费(元)',
                         version            INT           NOT NULL DEFAULT 0 COMMENT '乐观锁版本号',
                         created_at         DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '下单时间',
                         updated_at         DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',
                         PRIMARY KEY (waybill_id),
                         UNIQUE KEY uk_waybill_no (waybill_no),
                         KEY idx_waybill_dispatch_pool (origin_station_id, status, deadline_time),
                         KEY idx_waybill_customer (customer_id),
                         CONSTRAINT fk_waybill_customer FOREIGN KEY (customer_id) REFERENCES sys_user(user_id),
                         CONSTRAINT fk_waybill_station  FOREIGN KEY (origin_station_id) REFERENCES station(station_id)
) ENGINE=InnoDB COMMENT='电子运单核心表';

-- 5. 调度任务单表
CREATE TABLE dispatch_task (
                               task_id               BIGINT        NOT NULL AUTO_INCREMENT COMMENT '调度任务主键ID',
                               task_no               VARCHAR(32)   NOT NULL COMMENT '任务单号',
                               vehicle_id            BIGINT        NOT NULL COMMENT '指派车辆ID',
                               driver_id             BIGINT        NOT NULL COMMENT '执行司机ID',
                               dispatcher_id         BIGINT        NOT NULL COMMENT '创建调度员ID',
                               strategy_type         VARCHAR(32)   NOT NULL COMMENT '调度策略: SHORTEST_DISTANCE/MAX_LOAD_RATE/URGENT_TIME_WINDOW',
                               load_rate_weight      DECIMAL(5,2)  NOT NULL DEFAULT 0.00 COMMENT '载重满载率(%)',
                               estimated_distance_km DECIMAL(8,2)  NOT NULL DEFAULT 0.00 COMMENT '预估总行驶里程(km)',
                               route_plan_json       JSON          NULL COMMENT '规划路径节点与顺序JSON快照',
                               task_status           VARCHAR(20)   NOT NULL DEFAULT 'CREATED' COMMENT '任务状态: CREATED/IN_TRANSIT/COMPLETED/ABORTED',
                               version               INT           NOT NULL DEFAULT 0 COMMENT '乐观锁版本号',
                               created_at            DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '派单时间',
                               updated_at            DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',
                               PRIMARY KEY (task_id),
                               UNIQUE KEY uk_task_no (task_no),
                               KEY idx_task_vehicle_status (vehicle_id, task_status),
                               KEY idx_task_driver_status (driver_id, task_status),
                               CONSTRAINT fk_task_vehicle    FOREIGN KEY (vehicle_id) REFERENCES vehicle(vehicle_id),
                               CONSTRAINT fk_task_driver     FOREIGN KEY (driver_id) REFERENCES sys_user(user_id),
                               CONSTRAINT fk_task_dispatcher FOREIGN KEY (dispatcher_id) REFERENCES sys_user(user_id)
) ENGINE=InnoDB COMMENT='智能调度任务单表';

-- 6. 调度任务-运单明细关联表（支持多站点顺序与异常改派全历史追溯）
CREATE TABLE dispatch_task_waybill (
                                       id                     BIGINT       NOT NULL AUTO_INCREMENT COMMENT '明细主键ID',
                                       task_id                BIGINT       NOT NULL COMMENT '调度任务ID',
                                       waybill_id             BIGINT       NOT NULL COMMENT '关联运单ID',
                                       stop_sequence          INT          NOT NULL COMMENT '配送站点先后顺序(1,2,3...)',
                                       estimated_arrival_time DATETIME     NULL COMMENT '预计到达该站点时间(ETA)',
                                       item_status            VARCHAR(20)  NOT NULL DEFAULT 'ASSIGNED' COMMENT '明细状态: ASSIGNED/DELIVERED/REASSIGNED',
                                       PRIMARY KEY (id),
                                       UNIQUE KEY uk_task_waybill (task_id, waybill_id),
                                       KEY idx_dtw_waybill (waybill_id),
                                       CONSTRAINT fk_dtw_task    FOREIGN KEY (task_id) REFERENCES dispatch_task(task_id),
                                       CONSTRAINT fk_dtw_waybill FOREIGN KEY (waybill_id) REFERENCES waybill(waybill_id)
) ENGINE=InnoDB COMMENT='调度任务与运单明细关联表';

-- 7. 在途GPS轨迹与异常告警日志表
CREATE TABLE tracking_log (
                              log_id       BIGINT        NOT NULL AUTO_INCREMENT COMMENT '日志主键ID',
                              task_id      BIGINT        NOT NULL COMMENT '关联调度任务ID',
                              vehicle_id   BIGINT        NOT NULL COMMENT '上报车辆ID',
                              current_lng  DECIMAL(10,6) NOT NULL COMMENT '当前经度',
                              current_lat  DECIMAL(10,6) NOT NULL COMMENT '当前纬度',
                              event_type   VARCHAR(24)   NOT NULL DEFAULT 'GPS_PING' COMMENT '事件类型: GPS_PING/CONGESTION/VEHICLE_FAULT/DEVIATION',
                              description  VARCHAR(255)  NULL COMMENT '异常详情备注',
                              reported_at  DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '上报时间',
                              PRIMARY KEY (log_id),
                              KEY idx_tracking_task_time (task_id, reported_at),
                              KEY idx_tracking_vehicle_event (vehicle_id, event_type),
                              CONSTRAINT fk_track_task    FOREIGN KEY (task_id) REFERENCES dispatch_task(task_id),
                              CONSTRAINT fk_track_vehicle FOREIGN KEY (vehicle_id) REFERENCES vehicle(vehicle_id)
) ENGINE=InnoDB COMMENT='在途GPS轨迹与异常事件表';

-- ============================================================================
-- 初始化演示数据
-- ============================================================================
INSERT INTO station (station_code, station_name, station_type, address, lng, lat) VALUES
                                                                                      ('JN-HUB-01', '济南高新区域分拨中心', 'HUB',    '山东省济南市高新区舜华路1500号', 117.139420, 36.665710),
                                                                                      ('JN-BR-01',  '历下区末端配送网点',   'BRANCH', '山东省济南市历下区经十路14717号', 117.071520, 36.652480),
                                                                                      ('JN-BR-02',  '历城区末端配送网点',   'BRANCH', '山东省济南市历城区花园路101号',   117.068340, 36.686910);