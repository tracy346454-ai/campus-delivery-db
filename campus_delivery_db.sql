-- =================================================================
-- 项目名称：校园外卖两段式配送数据库系统 (campus_delivery_db)
-- 文件名称：campus_delivery_db.sql
-- 设计规范：严格遵循3NF / 完备外键级联 / 核心业务高并发防超卖机制
-- 适用环境：MySQL 8.0+ (支持 WINDOW FUNCTION 与高级 SIGNAL 语法)
-- =================================================================

SET NAMES utf8mb4;

CREATE DATABASE IF NOT EXISTS campus_delivery_db DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
USE campus_delivery_db;

-- -----------------------------------------------------------------
-- 0. 安全重置环境：环境清理机制
-- -----------------------------------------------------------------
SET FOREIGN_KEY_CHECKS = 0;
DROP VIEW IF EXISTS vw_pickup_point_analytics;
DROP VIEW IF EXISTS vw_merchant_sales_rank;
DROP PROCEDURE IF EXISTS sp_create_order;
DROP PROCEDURE IF EXISTS sp_arrive_at_pickup_point;
DROP PROCEDURE IF EXISTS sp_stage2_deliver;
DROP PROCEDURE IF EXISTS sp_cancel_order;
DROP TRIGGER IF EXISTS trg_check_dish_stock_before_order;
DROP TRIGGER IF EXISTS trg_reduce_dish_stock_after_order;
DROP TRIGGER IF EXISTS trg_check_rider_type_before_insert;
DROP TRIGGER IF EXISTS trg_check_rider_type_before_update;
DROP TRIGGER IF EXISTS trg_rider_delivering_insert;
DROP TRIGGER IF EXISTS trg_rider_delivering_update;
DROP TRIGGER IF EXISTS trg_check_pickup_point_capacity;
DROP TABLE IF EXISTS order_items;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS riders;
DROP TABLE IF EXISTS pickup_points;
DROP TABLE IF EXISTS dishes;
DROP TABLE IF EXISTS merchants;
DROP TABLE IF EXISTS users;
SET FOREIGN_KEY_CHECKS = 1;


-- -----------------------------------------------------------------
-- 1. 基础实体层建立 (DDL)
-- -----------------------------------------------------------------

-- 学生/用户表
CREATE TABLE users (
    user_id INT AUTO_INCREMENT PRIMARY KEY COMMENT '学生唯一ID',
    username VARCHAR(50) NOT NULL COMMENT '姓名',
    phone VARCHAR(20) NOT NULL UNIQUE COMMENT '手机号',
    dorm_building VARCHAR(20) NOT NULL COMMENT '宿舍楼栋(如: 1期5栋)',
    room_number VARCHAR(10) NOT NULL COMMENT '房间号',
    balance DECIMAL(10,2) DEFAULT 100.00 CHECK (balance >= 0) COMMENT '校园卡钱包余额',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT '注册时间'
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='学生用户表';

-- 商家表
CREATE TABLE merchants (
    merchant_id INT AUTO_INCREMENT PRIMARY KEY COMMENT '商家唯一ID',
    merchant_name VARCHAR(100) NOT NULL COMMENT '店铺名称',
    phone VARCHAR(20) NOT NULL COMMENT '商家联系电话',
    address VARCHAR(200) NOT NULL COMMENT '档口地址(如: 丁香餐厅二楼)',
    rating DECIMAL(2,1) DEFAULT 5.0 CHECK (rating >= 1.0 AND rating <= 5.0) COMMENT '商家评分',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT '入驻时间'
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='商家信息表';

-- 菜品表 (带有严格的下架与库存检查机制)
CREATE TABLE dishes (
    dish_id INT AUTO_INCREMENT PRIMARY KEY COMMENT '菜品唯一ID',
    merchant_id INT NOT NULL COMMENT '所属商家ID',
    dish_name VARCHAR(100) NOT NULL COMMENT '菜品名称',
    price DECIMAL(8,2) NOT NULL CHECK (price > 0) COMMENT '单价',
    stock INT NOT NULL DEFAULT 0 CHECK (stock >= 0) COMMENT '当前实时库存',
    status TINYINT DEFAULT 1 CHECK (status IN (0, 1)) COMMENT '上架状态: 0下架, 1上架',
    CONSTRAINT fk_dish_merchant FOREIGN KEY (merchant_id) 
        REFERENCES merchants(merchant_id) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='商家菜品表';

-- 宿舍寄存点表 (创新两段式配送的中转站核心)
CREATE TABLE pickup_points (
    point_id INT AUTO_INCREMENT PRIMARY KEY COMMENT '寄存点唯一ID',
    point_name VARCHAR(50) NOT NULL COMMENT '寄存点名称(如: 1期寄存储物柜)',
    location VARCHAR(200) NOT NULL COMMENT '具体物理位置',
    capacity INT NOT NULL COMMENT '最大格子容积上限',
    current_packages INT DEFAULT 0 CHECK (current_packages >= 0) COMMENT '当前在库滞留件数',
    CONSTRAINT chk_capacity CHECK (current_packages <= capacity)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='宿舍寄存中转点表';

-- 两段式专职骑手表 (通过枚举区分干线与楼栋配送员)
CREATE TABLE riders (
    rider_id INT AUTO_INCREMENT PRIMARY KEY COMMENT '骑手唯一ID',
    rider_name VARCHAR(50) NOT NULL COMMENT '骑手姓名',
    phone VARCHAR(20) NOT NULL UNIQUE COMMENT '联系电话',
    rider_type ENUM('Stage1_Trunk', 'Stage2_Floor') NOT NULL 
        COMMENT '骑手分工: Stage1_Trunk(第一段:商家->寄存点), Stage2_Floor(第二段:寄存点->寝室)',
    status ENUM('Idle', 'Delivering', 'Offline') DEFAULT 'Idle' COMMENT '工作状态'
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='两段式特种骑手表';


-- -----------------------------------------------------------------
-- 2. 创新核心业务层建立 (两段式订单处理系统)
-- -----------------------------------------------------------------

-- 订单主表 (集成两段式状态机与双骑手复合跟踪)
CREATE TABLE orders (
    order_id INT AUTO_INCREMENT PRIMARY KEY COMMENT '订单唯一流水号',
    user_id INT NOT NULL COMMENT '下单学生ID',
    merchant_id INT NOT NULL COMMENT '下单商家ID',
    pickup_point_id INT NOT NULL COMMENT '指派的中转寄存点ID',
    total_amount DECIMAL(10,2) NOT NULL DEFAULT 0.00 COMMENT '总金额',
    
    -- 核心状态机设计
    order_status ENUM(
        'Paid',               -- 已支付，待指派干线骑手
        'Stage1_Assigned',    -- 第一段已接单(商家->寄存点)
        'Arrived_At_Point',   -- 已送达中转寄存点（包裹入库放柜）
        'Stage2_Assigned',    -- 第二段已接单(寄存点->寝室楼下/门口)
        'Completed',          -- 订单最终安全送达学生手中
        'Cancelled'           -- 异常取消
    ) DEFAULT 'Paid' COMMENT '两段式订单复合状态流转',
    
    -- 双骑手复合绑定
    stage1_rider_id INT DEFAULT NULL COMMENT '干线骑手ID',
    stage2_rider_id INT DEFAULT NULL COMMENT '楼栋骑手ID',
    
    -- 两段式全链路时间审计戳
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT '下单时间',
    stage1_completed_at TIMESTAMP NULL DEFAULT NULL COMMENT '干线送达中转柜时间',
    stage2_completed_at TIMESTAMP NULL DEFAULT NULL COMMENT '最终送达用户时间',
    
    CONSTRAINT fk_order_user FOREIGN KEY (user_id) REFERENCES users(user_id),
    CONSTRAINT fk_order_merchant FOREIGN KEY (merchant_id) REFERENCES merchants(merchant_id),
    CONSTRAINT fk_order_point FOREIGN KEY (pickup_point_id) REFERENCES pickup_points(point_id),
    CONSTRAINT fk_order_rider1 FOREIGN KEY (stage1_rider_id) REFERENCES riders(rider_id),
    CONSTRAINT fk_order_rider2 FOREIGN KEY (stage2_rider_id) REFERENCES riders(rider_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='两段式配送核心订单表';

-- 订单详情表
CREATE TABLE order_items (
    item_id INT AUTO_INCREMENT PRIMARY KEY COMMENT '明细项ID',
    order_id INT NOT NULL COMMENT '关联的主订单ID',
    dish_id INT NOT NULL COMMENT '关联的菜品ID',
    quantity INT NOT NULL CHECK (quantity > 0) COMMENT '购买数量',
    price_at_order DECIMAL(8,2) NOT NULL COMMENT '购买时的快照单价',
    CONSTRAINT fk_item_order FOREIGN KEY (order_id) REFERENCES orders(order_id) ON DELETE CASCADE,
    CONSTRAINT fk_item_dish FOREIGN KEY (dish_id) REFERENCES dishes(dish_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单商品明细表';


-- -----------------------------------------------------------------
-- 3. 性能优化：数据库高并发索引策略 (B-Tree Indexing)
-- -----------------------------------------------------------------
CREATE INDEX idx_orders_status ON orders(order_status) COMMENT '加速大屏幕对待派单、派送中订单的筛选速度';
CREATE INDEX idx_orders_created ON orders(created_at) COMMENT '加速历史订单多维度时间趋势分析';
CREATE INDEX idx_dishes_merchant ON dishes(merchant_id, status) COMMENT '复合索引：优化前端点餐大屏加载对应商家菜品的速度';
CREATE INDEX idx_orders_point_status ON orders(pickup_point_id, order_status) COMMENT '复合索引：加速寄存点容量检查与视图关联查询';


-- -----------------------------------------------------------------
-- 4. 七重防护盾：高并发防超卖、类型约束、状态自动管理与容量预警 (Triggers)
-- -----------------------------------------------------------------

DELIMITER $$

-- 触发器 1：在订单写入明细前，强制阻断超卖或下架商品的下单 (核心亮点)
CREATE TRIGGER trg_check_dish_stock_before_order
BEFORE INSERT ON order_items
FOR EACH ROW
BEGIN
    DECLARE v_stock INT;
    DECLARE v_status TINYINT;
    
    -- 获取该商品的当前最真实库存和上下架状态（加行锁防并发超卖）
    SELECT stock, status INTO v_stock, v_status
    FROM dishes WHERE dish_id = NEW.dish_id FOR UPDATE;
    
    -- 校验一：检查是否下架
    IF v_status = 0 THEN
        SIGNAL SQLSTATE '45000' 
        SET MESSAGE_TEXT = '下单失败：您选购的商品已下架！';
    END IF;
    
    -- 校验二：检查库存是否充足
    IF v_stock < NEW.quantity THEN
        SIGNAL SQLSTATE '45000' 
        SET MESSAGE_TEXT = '下单失败：手慢了！部分商品库存不足！';
    END IF;
END$$

-- 触发器 2：下单成功后，数据库引擎自动扣减核心菜品库存
CREATE TRIGGER trg_reduce_dish_stock_after_order
AFTER INSERT ON order_items
FOR EACH ROW
BEGIN
    UPDATE dishes
    SET stock = stock - NEW.quantity
    WHERE dish_id = NEW.dish_id;
END$$

-- 触发器 3 & 4：骑手类型校验 — 干线/楼栋不可混用 (约束亮点)
CREATE TRIGGER trg_check_rider_type_before_insert
BEFORE INSERT ON orders
FOR EACH ROW
BEGIN
    IF NEW.stage1_rider_id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM riders WHERE rider_id = NEW.stage1_rider_id AND rider_type = 'Stage1_Trunk') THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '指派失败：干线骑手(Stage1)必须是 Stage1_Trunk 类型！';
        END IF;
    END IF;
    IF NEW.stage2_rider_id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM riders WHERE rider_id = NEW.stage2_rider_id AND rider_type = 'Stage2_Floor') THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '指派失败：楼栋骑手(Stage2)必须是 Stage2_Floor 类型！';
        END IF;
    END IF;
END$$

CREATE TRIGGER trg_check_rider_type_before_update
BEFORE UPDATE ON orders
FOR EACH ROW
BEGIN
    IF NEW.stage1_rider_id IS NOT NULL AND (NEW.stage1_rider_id != OLD.stage1_rider_id OR OLD.stage1_rider_id IS NULL) THEN
        IF NOT EXISTS (SELECT 1 FROM riders WHERE rider_id = NEW.stage1_rider_id AND rider_type = 'Stage1_Trunk') THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '指派失败：干线骑手(Stage1)必须是 Stage1_Trunk 类型！';
        END IF;
    END IF;
    IF NEW.stage2_rider_id IS NOT NULL AND (NEW.stage2_rider_id != OLD.stage2_rider_id OR OLD.stage2_rider_id IS NULL) THEN
        IF NOT EXISTS (SELECT 1 FROM riders WHERE rider_id = NEW.stage2_rider_id AND rider_type = 'Stage2_Floor') THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '指派失败：楼栋骑手(Stage2)必须是 Stage2_Floor 类型！';
        END IF;
    END IF;
END$$

-- Trigger 5 & 6: auto rider status (assign=Delivering, done=Idle)
CREATE TRIGGER trg_rider_delivering_insert
AFTER INSERT ON orders
FOR EACH ROW
BEGIN
    IF NEW.stage1_rider_id IS NOT NULL AND NEW.order_status IN ('Paid', 'Stage1_Assigned') THEN
        UPDATE riders SET status = 'Delivering' WHERE rider_id = NEW.stage1_rider_id;
    END IF;
    IF NEW.stage2_rider_id IS NOT NULL AND NEW.order_status IN ('Arrived_At_Point', 'Stage2_Assigned') THEN
        UPDATE riders SET status = 'Delivering' WHERE rider_id = NEW.stage2_rider_id;
    END IF;
END$$

CREATE TRIGGER trg_rider_delivering_update
AFTER UPDATE ON orders
FOR EACH ROW
BEGIN
    -- 新指派干线骑手 → Delivering
    IF NEW.stage1_rider_id IS NOT NULL AND (NEW.stage1_rider_id != OLD.stage1_rider_id OR OLD.stage1_rider_id IS NULL) THEN
        UPDATE riders SET status = 'Delivering' WHERE rider_id = NEW.stage1_rider_id;
    END IF;
    -- 新指派楼栋骑手 → Delivering
    IF NEW.stage2_rider_id IS NOT NULL AND (NEW.stage2_rider_id != OLD.stage2_rider_id OR OLD.stage2_rider_id IS NULL) THEN
        UPDATE riders SET status = 'Delivering' WHERE rider_id = NEW.stage2_rider_id;
    END IF;
    -- Stage1 完成（Paid/Stage1_Assigned → Arrived_At_Point）→ 释放干线骑手
    IF NEW.order_status = 'Arrived_At_Point' AND OLD.order_status IN ('Paid', 'Stage1_Assigned') AND OLD.stage1_rider_id IS NOT NULL THEN
        UPDATE riders SET status = 'Idle' WHERE rider_id = OLD.stage1_rider_id;
    END IF;
    -- Stage2 完成 → 释放楼栋骑手
    IF NEW.order_status = 'Completed' AND OLD.order_status != 'Completed' AND OLD.stage2_rider_id IS NOT NULL THEN
        UPDATE riders SET status = 'Idle' WHERE rider_id = OLD.stage2_rider_id;
    END IF;
    -- 取消 → 释放所有骑手
    IF NEW.order_status = 'Cancelled' AND OLD.order_status != 'Cancelled' THEN
        IF OLD.stage1_rider_id IS NOT NULL THEN
            UPDATE riders SET status = 'Idle' WHERE rider_id = OLD.stage1_rider_id;
        END IF;
        IF OLD.stage2_rider_id IS NOT NULL THEN
            UPDATE riders SET status = 'Idle' WHERE rider_id = OLD.stage2_rider_id;
        END IF;
    END IF;
END$$

-- 触发器 7：下单前检查寄存点容量，满了直接拒绝（防止骑手白跑一趟）
CREATE TRIGGER trg_check_pickup_point_capacity
BEFORE INSERT ON orders
FOR EACH ROW
BEGIN
    DECLARE v_pt_current INT;
    DECLARE v_pt_capacity INT;

    -- FOR UPDATE 行级锁：防止两个用户同时看到"还剩1个格子"同时下单
    SELECT current_packages, capacity INTO v_pt_current, v_pt_capacity
    FROM pickup_points WHERE point_id = NEW.pickup_point_id FOR UPDATE;

    IF v_pt_current >= v_pt_capacity THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = '下单失败：该寄存点已满，请选择邻近寄存点下单！';
    END IF;
END$$

DELIMITER ;


-- -----------------------------------------------------------------
-- 5. 高级业务流引擎：全闭环两段式状态控制与事务管理 (Stored Procedures)
-- -----------------------------------------------------------------

DELIMITER $$

-- 存储过程 1：高并发原子性下单与扣款 (带完整的异常回滚机制 Transaction)
CREATE PROCEDURE sp_create_order(
    IN p_user_id INT,
    IN p_merchant_id INT,
    IN p_point_id INT,
    IN p_dish_id INT,
    IN p_quantity INT,
    OUT o_order_id INT
)
BEGIN
    DECLARE v_dish_price DECIMAL(8,2);
    DECLARE v_total_amount DECIMAL(10,2);
    DECLARE v_user_balance DECIMAL(10,2);
    
    -- 声明在发生任何SQL异常时，自动触发事务回滚
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL; -- 向上层抛出具体错误信息
    END;

    -- 开启严密事务保护
    START TRANSACTION;
    
    -- 获取菜品快照价格
    SELECT price INTO v_dish_price FROM dishes WHERE dish_id = p_dish_id;
    SET v_total_amount = v_dish_price * p_quantity;
    
    -- 检查学生钱包余额是否能够支付
    SELECT balance INTO v_user_balance FROM users WHERE user_id = p_user_id;
    IF v_user_balance < v_total_amount THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '核心校园卡账户余额不足，扣款失败！';
    END IF;

    -- 寄存点容量预检：FOR UPDATE 行级锁防止并发下单时容量被击穿
    BEGIN
        DECLARE v_pt_current INT;
        DECLARE v_pt_capacity INT;
        SELECT current_packages, capacity INTO v_pt_current, v_pt_capacity
        FROM pickup_points WHERE point_id = p_point_id FOR UPDATE;
        IF v_pt_current >= v_pt_capacity THEN
            SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = '下单失败：该寄存点已满，请选择邻近寄存点下单！';
        END IF;
    END;

    -- 1. 扣减学生钱包资金
    UPDATE users SET balance = balance - v_total_amount WHERE user_id = p_user_id;

    -- 2. 插入主订单表 (初始化为 Paid 状态)
    INSERT INTO orders (user_id, merchant_id, pickup_point_id, total_amount, order_status)
    VALUES (p_user_id, p_merchant_id, p_point_id, v_total_amount, 'Paid');
    
    SET o_order_id = LAST_INSERT_ID();
    
    -- 3. 插入订单明细表 (此时会触发前面的超卖防御触发器)
    INSERT INTO order_items (order_id, dish_id, quantity, price_at_order)
    VALUES (o_order_id, p_dish_id, p_quantity, v_dish_price);
    
    -- 提交事务
    COMMIT;
END$$


-- 存储过程 2：第一段配送完成，自动入库并转换中转枢纽指针
CREATE PROCEDURE sp_arrive_at_pickup_point(
    IN p_order_id INT
)
BEGIN
    DECLARE v_point_id INT;
    DECLARE v_rider_id INT;
    
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;
    
    -- 获取该订单指派的中转点ID与干线骑手ID
    SELECT pickup_point_id, stage1_rider_id INTO v_point_id, v_rider_id 
    FROM orders WHERE order_id = p_order_id;
    
    -- 1. 推进订单状态机：变更为"已送达中转寄存点"，并打上第一段完成的时间戳
    UPDATE orders
    SET order_status = 'Arrived_At_Point', stage1_completed_at = CURRENT_TIMESTAMP
    WHERE order_id = p_order_id;

    -- 2. 中转柜包裹数加1 (此处会自动触发物理容积瓶颈检查)
    UPDATE pickup_points SET current_packages = current_packages + 1 WHERE point_id = v_point_id;
    
    COMMIT;
END$$


-- 存储过程 3：第二段配送完成，送达学生手中，扣减包裹计数
CREATE PROCEDURE sp_stage2_deliver(
    IN p_order_id INT
)
BEGIN
    DECLARE v_point_id INT;
    DECLARE v_rider_id INT;
    
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;
    
    SELECT pickup_point_id, stage2_rider_id INTO v_point_id, v_rider_id 
    FROM orders WHERE order_id = p_order_id;
    
    -- 1. 标记订单完成
    UPDATE orders
    SET order_status = 'Completed', stage2_completed_at = CURRENT_TIMESTAMP
    WHERE order_id = p_order_id;

    -- 2. 中转柜包裹数减1
    UPDATE pickup_points SET current_packages = current_packages - 1 
    WHERE point_id = v_point_id AND current_packages > 0;
    
    COMMIT;
END$$


-- 存储过程 4：订单取消，退款+恢复库存+释放骑手
CREATE PROCEDURE sp_cancel_order(
    IN p_order_id INT
)
BEGIN
    DECLARE v_user_id INT;
    DECLARE v_total DECIMAL(10,2);
    DECLARE v_status VARCHAR(20);
    DECLARE v_rider1 INT;
    DECLARE v_rider2 INT;
    DECLARE v_point_id INT;
    DECLARE done INT DEFAULT 0;
    DECLARE v_dish_id INT;
    DECLARE v_qty INT;
    
    -- 游标：遍历该订单的所有明细项
    DECLARE cur CURSOR FOR 
        SELECT dish_id, quantity FROM order_items WHERE order_id = p_order_id;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;
    
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;
    
    -- 获取订单基本信息
    SELECT user_id, total_amount, order_status, stage1_rider_id, stage2_rider_id, pickup_point_id
    INTO v_user_id, v_total, v_status, v_rider1, v_rider2, v_point_id
    FROM orders WHERE order_id = p_order_id;
    
    -- 已完成或已取消的订单不能再次取消
    IF v_status IN ('Completed', 'Cancelled') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '该订单无法取消';
    END IF;
    
    -- 1. 退款
    UPDATE users SET balance = balance + v_total WHERE user_id = v_user_id;
    
    -- 2. 恢复库存
    OPEN cur;
    read_loop: LOOP
        FETCH cur INTO v_dish_id, v_qty;
        IF done THEN LEAVE read_loop; END IF;
        UPDATE dishes SET stock = stock + v_qty WHERE dish_id = v_dish_id;
    END LOOP;
    CLOSE cur;
    
    -- 3. 如果已入库寄存点，扣减包裹数
    IF v_status = 'Arrived_At_Point' OR v_status = 'Stage2_Assigned' THEN
        UPDATE pickup_points SET current_packages = current_packages - 1
        WHERE point_id = v_point_id AND current_packages > 0;
    END IF;

    -- 4. 标记取消（触发器自动释放所有关联骑手）
    UPDATE orders SET order_status = 'Cancelled' WHERE order_id = p_order_id;
    
    COMMIT;
END$$

DELIMITER ;


-- -----------------------------------------------------------------
-- 6. 数据可视化专属：多维度业务决策视图 (Views For Dashboard)
-- -----------------------------------------------------------------

-- 视图 1：寄存点动态留存件数与容量饱和度预警分析视图
CREATE VIEW vw_pickup_point_analytics AS
SELECT 
    p.point_id,
    p.point_name,
    p.capacity AS max_capacity,
    p.current_packages,
    ROUND((p.current_packages / p.capacity) * 100, 2) AS saturation_pct,
    COALESCE(sub.backlog_count, 0) AS backlog_count
FROM pickup_points p
LEFT JOIN (
    SELECT pickup_point_id, COUNT(*) AS backlog_count
    FROM orders
    WHERE order_status IN ('Arrived_At_Point', 'Stage2_Assigned')
    GROUP BY pickup_point_id
) sub ON p.point_id = sub.pickup_point_id;

-- 视图 2：校园最具人气商户销售额与销售排行热度视图
CREATE VIEW vw_merchant_sales_rank AS
SELECT 
    m.merchant_id,
    m.merchant_name,
    COUNT(DISTINCT o.order_id) AS total_orders,
    IFNULL(SUM(o.total_amount), 0) AS total_sales,
    RANK() OVER (ORDER BY IFNULL(SUM(o.total_amount), 0) DESC) AS sales_rank
FROM merchants m
LEFT JOIN orders o ON m.merchant_id = o.merchant_id AND o.order_status = 'Completed'
GROUP BY m.merchant_id;


-- -----------------------------------------------------------------
-- 7. 预置生产环境种子数据 (DML - 保证大屏一键亮起有基础数据)
-- -----------------------------------------------------------------
INSERT INTO users (username, phone, dorm_building, room_number, balance) VALUES
('张三', '10000000001', '1期5栋', 'A302', 250.00),
('李四', '10000000002', '1期5栋', 'B511', 15.00),
('王五', '10000000003', '2期12栋', '404', 500.00);

INSERT INTO merchants (merchant_name, phone, address, rating) VALUES
('一号黄焖鸡米饭', '10000000101', '丁香餐厅一楼3号档口', 4.8),
('川湘木桶饭', '10000000102', '玫瑰餐厅二楼核心区', 4.6),
('蜜雪冰城校园店', '10000000103', '下沉广场天桥旁', 4.9);

INSERT INTO dishes (merchant_id, dish_name, price, stock, status) VALUES
(1, '经典大份黄焖鸡(配饭)', 18.00, 50, 1),
(1, '香辣金针菇肥牛饭', 22.00, 0, 1), -- 故意设置一个零库存，用来待会儿测试防超卖！
(2, '辣椒炒肉木桶饭', 15.00, 100, 1),
(3, '冰鲜柠檬水(超大杯)', 4.00, 200, 1);

INSERT INTO pickup_points (point_name, location, capacity, current_packages) VALUES
('1期智能寄存柜', '1期5栋与6栋之间车棚旁', 80, 0),
('2期智能寄存柜', '2期12栋宿管值班室对面', 80, 0),
('3期智能寄存柜', '3期8栋楼下大厅', 80, 0),
('4期智能寄存柜', '4期2栋架空层', 80, 0),
('5期智能寄存柜', '5期生活广场东侧', 100, 0),
('6期智能寄存柜', '6期食堂旁', 50, 0),
('7期智能寄存柜', '7期3栋一楼楼梯间', 60, 0),
('8期智能寄存柜', '8期北门快递站旁', 120, 0),
('A区智能寄存柜', 'A区综合服务大厅', 100, 0),
('B区智能寄存柜', 'B区图书馆负一层', 90, 0),
('C区智能寄存柜', 'C区体育馆入口处', 70, 0),
('D区智能寄存柜', 'D区研究生公寓大堂', 80, 0);

INSERT INTO riders (rider_name, phone, rider_type, status) VALUES
('赵铁柱', '10000000201', 'Stage1_Trunk', 'Idle'),
('王大锤', '10000000202', 'Stage1_Trunk', 'Idle'),
('李大力', '10000000204', 'Stage1_Trunk', 'Idle'),
('周小飞', '10000000205', 'Stage1_Trunk', 'Idle'),
('刘强东', '10000000206', 'Stage1_Trunk', 'Idle'),
('吴勇军', '10000000207', 'Stage1_Trunk', 'Idle'),
('郑明达', '10000000208', 'Stage1_Trunk', 'Idle'),
('黄启航', '10000000209', 'Stage1_Trunk', 'Idle'),
('牛干劲', '10000000203', 'Stage2_Floor', 'Idle'),
('马小跳', '10000000210', 'Stage2_Floor', 'Idle'),
('林志远', '10000000211', 'Stage2_Floor', 'Idle'),
('张小凡', '10000000212', 'Stage2_Floor', 'Idle'),
('陈奕迅', '10000000213', 'Stage2_Floor', 'Idle'),
('李逍遥', '10000000214', 'Stage2_Floor', 'Idle'),
('赵灵儿', '10000000215', 'Stage2_Floor', 'Idle');
