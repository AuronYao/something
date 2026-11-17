-- =====================================================================
-- OCAP（SPC 失控处置）+ Q-Time Over 双场景实施要素包 · PostgreSQL 版
-- PostgreSQL 12+ · 自包含：建表 + 伪造数据 + 演示/验收 SQL
-- 时间基准：执行日为演示日（NOW() - INTERVAL 随执行时间对齐）
-- 与 MySQL 版差异：ENUM→CHECK 约束；AUTO_INCREMENT→BIGSERIAL；
--   JSON→JSONB；TINYINT→SMALLINT；INTERVAL 语法；TIMESTAMPDIFF→EXTRACT；
--   updated_at 用触发器维护；ON UPDATE CURRENT_TIMESTAMP 不支持
-- =====================================================================

-- =====================================================================
-- 第一部分 · 通用地基表（两场景共用）
-- =====================================================================

-- 1. 统一任务表（六态状态机；uk_scene_biz 唯一索引兼作单飞锁）
CREATE TABLE rpt_task (
  task_id        VARCHAR(32)  NOT NULL,                     -- 任务号
  scene          VARCHAR(16)  NOT NULL,                     -- 场景: OCAP / QTIME
  biz_key        VARCHAR(64)  NOT NULL,                     -- 业务键: OCAP=OOC单号, QTIME=超时记录号
  biz_id         VARCHAR(64)  DEFAULT NULL,                 -- 关联明细表主键
  title          VARCHAR(200) NOT NULL,                     -- 任务标题
  owner_role     VARCHAR(32)  DEFAULT NULL,                 -- 当前责任角色
  owner_user     VARCHAR(32)  DEFAULT NULL,                 -- 当前责任人(Sponsor)
  status         VARCHAR(14)  NOT NULL DEFAULT 'PENDING'
                 CHECK (status IN ('PENDING','PROCESSING','WAIT_CONFIRM','CLOSED','CANCELLED')),
  action_map     VARCHAR(200) DEFAULT NULL,                 -- 列表页action字段: RELEASE_HOLD|TRANSFER|CLOSE 等
  priority       VARCHAR(2)   NOT NULL DEFAULT 'P1' CHECK (priority IN ('P0','P1','P2')),
  created_at     TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMP NOT NULL DEFAULT NOW(),
  closed_at      TIMESTAMP DEFAULT NULL,
  close_type     VARCHAR(8)  DEFAULT NULL CHECK (close_type IN ('AUTO','MANUAL')),  -- 关单方式
  close_reason   VARCHAR(200) DEFAULT NULL,
  CONSTRAINT pk_rpt_task PRIMARY KEY (task_id),
  CONSTRAINT uk_scene_biz UNIQUE (scene, biz_key)
);
COMMENT ON TABLE rpt_task IS '统一任务表(单飞锁+六态状态机)';

-- updated_at 自动维护（替代 MySQL 的 ON UPDATE CURRENT_TIMESTAMP）
CREATE OR REPLACE FUNCTION fn_set_updated_at() RETURNS trigger AS $$
BEGIN
  NEW.updated_at := NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_rpt_task_updated
BEFORE UPDATE ON rpt_task
FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- 2. 回证核对日志（Q-Time 自动关单与 OCAP 结果确认共用）
CREATE TABLE rpt_task_check_log (
  check_id    BIGSERIAL PRIMARY KEY,
  task_id     VARCHAR(32) NOT NULL,
  check_round INT NOT NULL,                               -- 第几轮核对
  check_time  TIMESTAMP NOT NULL DEFAULT NOW(),
  check_name  VARCHAR(64) NOT NULL,                       -- 核对SQL名称, 如 qtime_gone_check
  result      VARCHAR(8) NOT NULL CHECK (result IN ('GONE','EXISTS','BOUNCE')),  -- 消失/仍存在/回弹
  note        VARCHAR(200) DEFAULT NULL
);
COMMENT ON TABLE rpt_task_check_log IS '回证核对日志';
CREATE INDEX idx_tcl_task ON rpt_task_check_log (task_id, check_round);

-- 3. 回调日志（request_id 兼作重放去重）
CREATE TABLE rpt_callback_log (
  callback_id   BIGSERIAL PRIMARY KEY,
  task_id       VARCHAR(32) DEFAULT NULL,
  scene         VARCHAR(16) NOT NULL,
  event_type    VARCHAR(48) NOT NULL,                     -- FLOW_EXECUTED / MES_ACTION_DONE / MES_ACTION_FAIL
  request_id    VARCHAR(64) NOT NULL,                     -- 幂等键, 重复回调直接拒绝
  payload       JSONB DEFAULT NULL,
  recv_time     TIMESTAMP NOT NULL DEFAULT NOW(),
  status        VARCHAR(10) NOT NULL DEFAULT 'RECEIVED'
                CHECK (status IN ('RECEIVED','PROCESSED','REJECTED')),
  reject_reason VARCHAR(200) DEFAULT NULL,
  CONSTRAINT uk_cb_request UNIQUE (request_id)
);
COMMENT ON TABLE rpt_callback_log IS '回调日志(验签+重放去重)';

-- 4. 升级链规则（超时未处理按级别升级）
CREATE TABLE rpt_escalation_rule (
  rule_id        INT PRIMARY KEY,
  scene          VARCHAR(16) NOT NULL,
  level          INT NOT NULL,                            -- 升级级别 1-4
  trigger_hours  NUMERIC(5,1) NOT NULL,                   -- 超时多少小时升级
  target_role    VARCHAR(32) NOT NULL,
  notify_channel VARCHAR(32) NOT NULL                     -- EMAIL/DINGTALK/SMS
);
COMMENT ON TABLE rpt_escalation_rule IS '升级链规则';

-- =====================================================================
-- 第二部分 · OCAP（SPC 失控处置）场景表
-- =====================================================================

-- 5. SPC 控制图定义
CREATE TABLE spc_chart_def (
  chart_id    VARCHAR(32) PRIMARY KEY,
  chart_name  VARCHAR(100) NOT NULL,
  process_id  VARCHAR(32) NOT NULL,                       -- 工序
  eqp_id      VARCHAR(32) NOT NULL,                       -- 机台
  chart_type  VARCHAR(8) NOT NULL DEFAULT 'Xbar-R' CHECK (chart_type IN ('Xbar-R','Xbar-S','P')),
  cl          NUMERIC(10,4) NOT NULL,                     -- 中心线
  ucl         NUMERIC(10,4) NOT NULL,                     -- 控制上限
  lcl         NUMERIC(10,4) NOT NULL,                     -- 控制下限
  usl         NUMERIC(10,4) DEFAULT NULL,                 -- 规格上限(OOS判据)
  lsl         NUMERIC(10,4) DEFAULT NULL,                 -- 规格下限(OOS判据)
  sample_size INT NOT NULL DEFAULT 1,
  active_flag SMALLINT NOT NULL DEFAULT 1
);
COMMENT ON TABLE spc_chart_def IS 'SPC 控制图定义';

-- 6. SPC 测量数据点
CREATE TABLE spc_data_point (
  point_id     BIGSERIAL PRIMARY KEY,
  chart_id     VARCHAR(32) NOT NULL,
  lot_id       VARCHAR(32) NOT NULL,
  wafer_no     VARCHAR(8)  NOT NULL,                      -- 片号 01-25
  meas_value   NUMERIC(10,4) NOT NULL,
  collect_time TIMESTAMP NOT NULL
);
COMMENT ON TABLE spc_data_point IS 'SPC 测量数据点';
CREATE INDEX idx_sdp_chart ON spc_data_point (chart_id, collect_time);

-- 7. SPC 失控记录（OCAP 流程的主单）
CREATE TABLE spc_ooc_record (
  ooc_id         VARCHAR(32) PRIMARY KEY,                 -- 失控单号
  chart_id       VARCHAR(32) NOT NULL,
  lot_id         VARCHAR(32) NOT NULL,
  eqp_id         VARCHAR(32) NOT NULL,
  violate_type   VARCHAR(4) NOT NULL CHECK (violate_type IN ('OOS','OOC')),   -- 超规格/超控制限
  violate_rule   VARCHAR(32) NOT NULL,                    -- BEYOND_USL/BEYOND_LSL/BEYOND_UCL/BEYOND_LCL
  meas_value     NUMERIC(10,4) NOT NULL,                  -- 触发值
  monitor_lot_id VARCHAR(32) DEFAULT NULL,                -- 监测批
  status         VARCHAR(14) NOT NULL DEFAULT 'OPEN'
                 CHECK (status IN ('OPEN','REMEASURING','PENDING_FINAL','EXECUTING','CLOSED')),
  created_at     TIMESTAMP NOT NULL DEFAULT NOW(),
  closed_at      TIMESTAMP DEFAULT NULL
);
COMMENT ON TABLE spc_ooc_record IS 'SPC 失控记录(OCAP主单)';
CREATE INDEX idx_ooc_lot ON spc_ooc_record (lot_id, status);

-- 8. PE 判定记录（是否需要复测）
CREATE TABLE ocap_judgement (
  judgement_id   BIGSERIAL PRIMARY KEY,
  ooc_id         VARCHAR(32) NOT NULL,
  need_remeasure VARCHAR(4) NOT NULL CHECK (need_remeasure IN ('YES','NO')),
  judge_user     VARCHAR(32) NOT NULL,
  judge_role     VARCHAR(16) NOT NULL DEFAULT 'PE',
  judge_time     TIMESTAMP NOT NULL DEFAULT NOW(),
  comment        VARCHAR(200) DEFAULT NULL
);
COMMENT ON TABLE ocap_judgement IS 'PE 判定记录';
CREATE INDEX idx_jud_ooc ON ocap_judgement (ooc_id);

-- 9. 复测任务（选片 → 等结果 → 结论）
CREATE TABLE ocap_remeasure (
  remeasure_id   VARCHAR(32) PRIMARY KEY,
  ooc_id         VARCHAR(32) NOT NULL,
  monitor_lot_id VARCHAR(32) NOT NULL,
  wafer_list     VARCHAR(100) NOT NULL,                   -- 复测片号清单, 如 05,12,18
  req_time       TIMESTAMP NOT NULL DEFAULT NOW(),
  result_status  VARCHAR(8) NOT NULL DEFAULT 'WAITING' CHECK (result_status IN ('WAITING','DONE')),
  result_value   NUMERIC(10,4) DEFAULT NULL,              -- 复测值(最大偏差片)
  result_time    TIMESTAMP DEFAULT NULL,
  conclusion     VARCHAR(8) DEFAULT NULL CHECK (conclusion IN ('OOS','NO_OOS'))
);
COMMENT ON TABLE ocap_remeasure IS '复测任务';
CREATE INDEX idx_rm_ooc ON ocap_remeasure (ooc_id);

-- 10. ReasonCode 字典
CREATE TABLE ocap_reason_code (
  code           VARCHAR(32) PRIMARY KEY,
  category       VARCHAR(32) NOT NULL,                    -- EQUIPMENT/PROCESS/MATERIAL/HUMAN
  description    VARCHAR(200) NOT NULL,
  default_action VARCHAR(32) NOT NULL                     -- 默认 final action
);
COMMENT ON TABLE ocap_reason_code IS 'ReasonCode 字典';

-- 11. Final Action 选取（七个出口之一 + 审批）
CREATE TABLE ocap_final_action (
  action_id      VARCHAR(32) PRIMARY KEY,
  ooc_id         VARCHAR(32) NOT NULL,
  reason_code    VARCHAR(32) NOT NULL,
  action_type    VARCHAR(20) NOT NULL CHECK (action_type IN
                 ('LOT_REWORK','HOLD_TO_SCRAP','RELEASE_TRACK_OUT','HOLD_TO_OWNER','LOT_TERMINATE','EQ_RELEASE','EQ_DOWN')),
  action_desc    VARCHAR(200) DEFAULT NULL,
  approve_status VARCHAR(10) NOT NULL DEFAULT 'PENDING'
                 CHECK (approve_status IN ('PENDING','APPROVED','REJECTED')),
  approver       VARCHAR(32) DEFAULT NULL,
  approve_time   TIMESTAMP DEFAULT NULL,
  created_at     TIMESTAMP NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE ocap_final_action IS 'Final Action 选取与审批';
CREATE INDEX idx_fa_ooc ON ocap_final_action (ooc_id);

-- 12. MES 执行回执（幂等键 request_id）
CREATE TABLE ocap_exec_log (
  exec_id     BIGSERIAL PRIMARY KEY,
  action_id   VARCHAR(32) NOT NULL,
  node_name   VARCHAR(64) NOT NULL,                       -- 发起节点
  mes_api     VARCHAR(100) NOT NULL,
  request_id  VARCHAR(64) NOT NULL,                       -- 幂等键 task_id:节点:attempt
  http_status INT DEFAULT NULL,
  mes_result  VARCHAR(8) DEFAULT NULL CHECK (mes_result IN ('SUCCESS','FAIL')),
  mes_message VARCHAR(200) DEFAULT NULL,
  exec_time   TIMESTAMP NOT NULL DEFAULT NOW(),
  CONSTRAINT uk_exec_request UNIQUE (request_id)
);
COMMENT ON TABLE ocap_exec_log IS 'MES 执行回执';

-- =====================================================================
-- 第三部分 · Q-Time Over 场景表
-- =====================================================================

-- 13. Q-Time 规则定义
CREATE TABLE qtime_rule (
  rule_id        VARCHAR(32) PRIMARY KEY,
  route_id       VARCHAR(32) NOT NULL,                    -- 工艺路线
  step_from      VARCHAR(32) NOT NULL,                    -- 起始站
  step_to        VARCHAR(32) NOT NULL,                    -- 到达站
  limit_hours    NUMERIC(6,2) NOT NULL,                   -- 间隔上限(小时)
  severity       VARCHAR(4) NOT NULL DEFAULT 'MID' CHECK (severity IN ('HIGH','MID','LOW')),
  sponsor_role   VARCHAR(32) NOT NULL,                    -- 责任角色
  alarm_freq_min INT NOT NULL DEFAULT 30,                 -- 告警频率(分钟)
  max_escalate   INT NOT NULL DEFAULT 3,                  -- 最大升级级别
  active_flag    SMALLINT NOT NULL DEFAULT 1
);
COMMENT ON TABLE qtime_rule IS 'Q-Time 规则定义';

-- 14. Q-Time 批次跟踪（在站计时）
CREATE TABLE qtime_tracking (
  track_id     VARCHAR(32) PRIMARY KEY,
  lot_id       VARCHAR(32) NOT NULL,
  rule_id      VARCHAR(32) NOT NULL,
  step_current VARCHAR(32) NOT NULL,
  enter_time   TIMESTAMP NOT NULL,
  elapsed_min  INT NOT NULL DEFAULT 0,                    -- 已历时(分钟)
  status       VARCHAR(10) NOT NULL DEFAULT 'TRACKING'
               CHECK (status IN ('TRACKING','OVER','RESET','DONE'))
);
COMMENT ON TABLE qtime_tracking IS 'Q-Time 批次跟踪';
CREATE INDEX idx_qt_lot ON qtime_tracking (lot_id, status);

-- 15. Q-Time 超时记录（active_flag 即"违规是否仍在"，触发 action 后由 mock 置 0）
CREATE TABLE qtime_over_record (
  over_id         VARCHAR(32) PRIMARY KEY,
  lot_id          VARCHAR(32) NOT NULL,
  rule_id         VARCHAR(32) NOT NULL,
  track_id        VARCHAR(32) NOT NULL,
  elapsed_min     INT NOT NULL,                           -- 超时时刻已历时
  first_over_time TIMESTAMP NOT NULL DEFAULT NOW(),
  active_flag     SMALLINT NOT NULL DEFAULT 1             -- 1=违规仍在 0=已消失(解Hold/移站/重置)
);
COMMENT ON TABLE qtime_over_record IS 'Q-Time 超时记录';
CREATE INDEX idx_qor_active ON qtime_over_record (active_flag, lot_id);

-- =====================================================================
-- 第四部分 · 伪造数据集
-- =====================================================================

-- ---------- 4.1 升级链规则 ----------
INSERT INTO rpt_escalation_rule (rule_id,scene,level,trigger_hours,target_role,notify_channel) VALUES
 (1,'QTIME',1, 2.0,'SPONSOR','EMAIL'),
 (2,'QTIME',2, 4.0,'SECTION_MANAGER','DINGTALK'),
 (3,'QTIME',3, 8.0,'DEPARTMENT_MANAGER','DINGTALK+SMS'),
 (4,'QTIME',4,24.0,'PLANT_MANAGER','SMS'),
 (5,'OCAP', 1, 4.0,'PE','EMAIL'),
 (6,'OCAP', 2, 8.0,'PE_LEAD','DINGTALK');

-- ---------- 4.2 SPC 控制图与数据点 ----------
INSERT INTO spc_chart_def (chart_id,chart_name,process_id,eqp_id,chart_type,cl,ucl,lcl,usl,lsl,sample_size,active_flag) VALUES
 ('CHART-CD-01','栅氧 CD 控制图-Xbar','PR-CVD-GATE','ETP-CVD12','Xbar-R',0.1800,0.1850,0.1750,0.1900,0.1700,5,1),
 ('CHART-THK-01','膜厚控制图-Xbar','PR-DEP-THK','ETP-DEP07','Xbar-R',2000.0,2050.0,1950.0,2060.0,1940.0,5,1);

INSERT INTO spc_data_point (chart_id,lot_id,wafer_no,meas_value,collect_time) VALUES
 ('CHART-CD-01','W26M118','01',0.1798,NOW() - INTERVAL '3 hours'),
 ('CHART-CD-01','W26M118','05',0.1805,NOW() - INTERVAL '3 hours'),
 ('CHART-CD-01','W26M118','09',0.1812,NOW() - INTERVAL '3 hours'),
 ('CHART-CD-01','W26M118','13',0.1801,NOW() - INTERVAL '3 hours'),
 ('CHART-CD-01','W26M118','17',0.1809,NOW() - INTERVAL '3 hours'),
 ('CHART-CD-01','W26M118','21',0.1920,NOW() - INTERVAL '3 hours'),
 ('CHART-CD-01','W26M121','03',0.1802,NOW() - INTERVAL '1 hour'),
 ('CHART-CD-01','W26M121','07',0.1862,NOW() - INTERVAL '1 hour'),
 ('CHART-THK-01','W26M205','02',1998.5,NOW() - INTERVAL '2 hours'),
 ('CHART-THK-01','W26M205','06',2012.0,NOW() - INTERVAL '2 hours');

-- ---------- 4.3 失控记录（两单：一单走到复测环节，一单刚开单） ----------
INSERT INTO spc_ooc_record
 (ooc_id,chart_id,lot_id,eqp_id,violate_type,violate_rule,meas_value,monitor_lot_id,status,created_at) VALUES
 ('OOC-2026-0001','CHART-CD-01','W26M118','ETP-CVD12','OOS','BEYOND_USL',0.1920,'ML-118','REMEASURING',NOW() - INTERVAL '3 hours'),
 ('OOC-2026-0002','CHART-CD-01','W26M121','ETP-CVD12','OOC','BEYOND_UCL',0.1862,'ML-121','OPEN',NOW() - INTERVAL '1 hour');

-- ---------- 4.4 PE 判定 ----------
INSERT INTO ocap_judgement (ooc_id,need_remeasure,judge_user,judge_role,judge_time,comment) VALUES
 ('OOC-2026-0001','YES','pe.zhang','PE',NOW() - INTERVAL '150 minutes','21片超USL，先复测确认');

-- ---------- 4.5 复测任务（演示：S5 把 WAITING 改成 DONE/NO_OOS） ----------
INSERT INTO ocap_remeasure
 (remeasure_id,ooc_id,monitor_lot_id,wafer_list,result_status) VALUES
 ('RM-2026-0001','OOC-2026-0001','ML-118','05,12,18','WAITING');

-- ---------- 4.6 ReasonCode 字典 ----------
INSERT INTO ocap_reason_code (code,category,description,default_action) VALUES
 ('RC-EQP-DRIFT','EQUIPMENT','机台漂移','EQ_DOWN'),
 ('RC-EQP-PM-EXP','EQUIPMENT','保养超期','EQ_DOWN'),
 ('RC-PRC-REC-ERR','PROCESS','Recipe参数异常','LOT_REWORK'),
 ('RC-PRC-NEWCTL','PROCESS','切换新管控线','RELEASE_TRACK_OUT'),
 ('RC-MAT-BAD','MATERIAL','来料异常','LOT_TERMINATE'),
 ('RC-HUMAN-ERR','HUMAN','人为操作失误','LOT_REWORK'),
 ('RC-UNKNOWN','PROCESS','待查','HOLD_TO_OWNER');

-- ---------- 4.7 Final Action（演示单已审批通过，等待调 MES） ----------
INSERT INTO ocap_final_action
 (action_id,ooc_id,reason_code,action_type,action_desc,approve_status,approver,approve_time,created_at) VALUES
 ('FA-2026-0001','OOC-2026-0001','RC-PRC-REC-ERR','LOT_REWORK','按返工SOP退回CVD重做','APPROVED','pe.lead.liu',NOW() - INTERVAL '60 minutes',NOW() - INTERVAL '90 minutes');

-- ---------- 4.8 Q-Time 规则 ----------
INSERT INTO qtime_rule (rule_id,route_id,step_from,step_to,limit_hours,severity,sponsor_role,alarm_freq_min,max_escalate,active_flag) VALUES
 ('QT-R01','RT-CVD01','STRIP','GATE_OX', 4.00,'HIGH','SPONSOR', 30,3,1),
 ('QT-R02','RT-CVD01','GATE_OX','POLY',  6.00,'MID','SPONSOR', 60,2,1),
 ('QT-R03','RT-ETCH02','LITHO','ETCH',   2.00,'HIGH','SPONSOR', 15,3,1),
 ('QT-R04','RT-CVD01','POLY','WET',     12.00,'LOW','SPONSOR',120,1,1);

-- ---------- 4.9 Q-Time 跟踪与超时记录 ----------
INSERT INTO qtime_tracking (track_id,lot_id,rule_id,step_current,enter_time,elapsed_min,status) VALUES
 ('QT-T-1001','T26F001','QT-R01','STRIP',NOW() - INTERVAL '320 minutes',320,'OVER'),
 ('QT-T-1002','T26F002','QT-R01','STRIP',NOW() - INTERVAL '200 minutes',200,'TRACKING'),
 ('QT-T-1003','T26F003','QT-R03','LITHO',NOW() - INTERVAL '150 minutes',150,'OVER'),
 ('QT-T-1004','T26F004','QT-R02','GATE_OX',NOW() - INTERVAL '100 minutes',100,'TRACKING');

INSERT INTO qtime_over_record (over_id,lot_id,rule_id,track_id,elapsed_min,first_over_time,active_flag) VALUES
 ('QTO-2026-0001','T26F001','QT-R01','QT-T-1001',320,NOW() - INTERVAL '40 minutes',1),
 ('QTO-2026-0002','T26F003','QT-R03','QT-T-1003',150,NOW() - INTERVAL '25 minutes',0);

-- ---------- 4.10 统一任务（四条，覆盖各状态） ----------
INSERT INTO rpt_task (task_id,scene,biz_key,biz_id,title,owner_role,owner_user,status,action_map,priority) VALUES
 ('TASK-OCAP-0001','OCAP','OOC-2026-0001',NULL,'SPC OOS 处置: W26M118 复测中','PE','pe.zhang','PROCESSING','REMESURE|CLOSE','P0'),
 ('TASK-OCAP-0002','OCAP','OOC-2026-0002',NULL,'SPC OOC 处置: W26M121 待PE判定','PE','pe.zhang','PENDING','REMESURE|TRANSFER|CLOSE','P1'),
 ('TASK-QTIME-0001','QTIME','QTO-2026-0001','QTO-2026-0001','Q-Time Over 4h: T26F001 STRIP->GATE_OX','SPONSOR','sp.li.wang','PENDING','RELEASE_HOLD|TRANSFER|CLOSE','P0'),
 ('TASK-QTIME-0002','QTIME','QTO-2026-0002','QTO-2026-0002','Q-Time Over 2h: T26F003 LITHO->ETCH','SPONSOR','sp.li.wang','WAIT_CONFIRM',NULL,'P1');

-- ---------- 4.11 回证核对日志（TASK-QTIME-0002 第1轮已消失，演示第2轮后自动关单） ----------
INSERT INTO rpt_task_check_log (task_id,check_round,check_name,result,note) VALUES
 ('TASK-QTIME-0002',1,'qtime_gone_check','GONE','第1轮: 记录已消失');

-- ---------- 4.12 回调日志样例 ----------
INSERT INTO rpt_callback_log (task_id,scene,event_type,request_id,payload,status) VALUES
 ('TASK-QTIME-0002','QTIME','MES_ACTION_DONE','REQ-20261118-0001',
  '{"lotId":"T26F003","action":"RELEASE_HOLD","result":"SUCCESS"}'::jsonb,'PROCESSED');

-- =====================================================================
-- 第五部分 · 演示/验收 SQL（S1-S12，按演示剧本顺序执行）
-- =====================================================================

-- S1 【Q-Time 触发SQL · CRON 每5分钟】命中 = 违规仍在 + 确实超限 + 无在飞任务(单飞锁)
SELECT o.over_id, o.lot_id, r.limit_hours, r.severity, o.elapsed_min, o.first_over_time
FROM qtime_over_record o
JOIN qtime_rule r ON r.rule_id = o.rule_id AND r.active_flag = 1
WHERE o.active_flag = 1
  AND o.elapsed_min >= r.limit_hours * 60
  AND NOT EXISTS (SELECT 1 FROM rpt_task t
                  WHERE t.scene='QTIME' AND t.biz_key=o.over_id
                    AND t.status IN ('PENDING','PROCESSING','WAIT_CONFIRM'));
-- 预期: 返回 QTO-2026-0001（T26F001）

-- S2 【Q-Time 建任务】命中后由平台写入
INSERT INTO rpt_task (task_id,scene,biz_key,biz_id,title,owner_role,owner_user,status,action_map,priority)
SELECT 'TASK-QTIME-0003','QTIME',o.over_id,o.over_id,
       'Q-Time Over ' || ROUND(o.elapsed_min/60.0,1) || 'h: ' || o.lot_id || ' ' || r.step_from || '->' || r.step_to,
       r.sponsor_role,NULL,'PENDING','RELEASE_HOLD|TRANSFER|CLOSE',
       CASE r.severity WHEN 'HIGH' THEN 'P0' WHEN 'MID' THEN 'P1' ELSE 'P2' END
FROM qtime_over_record o JOIN qtime_rule r ON r.rule_id=o.rule_id
WHERE o.over_id='QTO-2026-0001';

-- S3 【Action 映射】列表页按状态渲染按钮
SELECT task_id, status,
  CASE status WHEN 'PENDING' THEN action_map
              ELSE NULL END AS action_buttons
FROM rpt_task WHERE scene='QTIME' ORDER BY priority, created_at;

-- S4 【OCAP 开单SQL】OPEN/REMEASURING 且无在飞任务
SELECT o.ooc_id, o.lot_id, o.violate_type, o.violate_rule, o.meas_value, o.status
FROM spc_ooc_record o
WHERE o.status IN ('OPEN','REMEASURING','PENDING_FINAL')
  AND NOT EXISTS (SELECT 1 FROM rpt_task t
                  WHERE t.scene='OCAP' AND t.biz_key=o.ooc_id
                    AND t.status IN ('PENDING','PROCESSING','WAIT_CONFIRM'));

-- S5 【OCAP 复测结果回填】(演示: 测量系统回调 → NO_OOS → 走 Release)
UPDATE ocap_remeasure
SET result_status='DONE', result_value=0.1801, result_time=NOW(), conclusion='NO_OOS'
WHERE remeasure_id='RM-2026-0001';

-- S6 【OCAP Final Action 选取】复测 NO_OOS → 默认 ReasonCode + Release
INSERT INTO ocap_final_action
 (action_id,ooc_id,reason_code,action_type,action_desc,approve_status,approver,approve_time)
VALUES
 ('FA-2026-0002','OOC-2026-0001','RC-PRC-NEWCTL','RELEASE_TRACK_OUT','复测合格,切新管控线放行','APPROVED','pe.lead.liu',NOW());

-- S7 【OCAP 调MES回执】幂等键 task:节点:attempt
INSERT INTO ocap_exec_log (action_id,node_name,mes_api,request_id,http_status,mes_result,mes_message)
VALUES ('FA-2026-0002','mes_release_track_out','POST /mes/api/lot/release','TASK-OCAP-0001:mes_release_track_out:1',200,'SUCCESS','lot W26M118 released');
UPDATE spc_ooc_record SET status='CLOSED', closed_at=NOW() WHERE ooc_id='OOC-2026-0001';
UPDATE rpt_task SET status='WAIT_CONFIRM' WHERE task_id='TASK-OCAP-0001';

-- S8 【Q-Time 回证SQL · CRON】对 WAIT_CONFIRM 任务核对违规记录是否消失
SELECT t.task_id, t.biz_key,
       CASE WHEN o.over_id IS NULL THEN 'GONE' ELSE 'EXISTS' END AS check_result,
       (SELECT COUNT(*) FROM rpt_task_check_log c
         WHERE c.task_id=t.task_id AND c.result='GONE') AS gone_rounds
FROM rpt_task t
LEFT JOIN qtime_over_record o ON o.over_id=t.biz_key AND o.active_flag=1
WHERE t.scene='QTIME' AND t.status='WAIT_CONFIRM';
-- 预期: TASK-QTIME-0002 → GONE(已1轮)

-- S9 【落核对日志 + 自动关单】连续2轮GONE且过1个采样周期
INSERT INTO rpt_task_check_log (task_id,check_round,check_name,result,note)
SELECT 'TASK-QTIME-0002',2,'qtime_gone_check','GONE','第2轮: 连续确认成立';
UPDATE rpt_task
SET status='CLOSED', close_type='AUTO', closed_at=NOW(),
    close_reason='连续2轮GONE+确认窗口通过,自动关单'
WHERE task_id='TASK-QTIME-0002' AND status='WAIT_CONFIRM';

-- S10 【回弹回退】上轮GONE本轮EXISTS → 记BOUNCE,任务回退PENDING重查
UPDATE rpt_task t
SET status='PENDING', action_map='RELEASE_HOLD|TRANSFER|CLOSE'
FROM rpt_task_check_log c
WHERE c.task_id = t.task_id
  AND c.task_id='TASK-QTIME-0002' AND c.result='EXISTS' AND c.check_round=2;
-- 注: PostgreSQL 无 UPDATE...JOIN,用 UPDATE...FROM 等价改写

-- S11 【升级链查询】超时未处理任务 → 匹配升级级别
SELECT t.task_id, t.status,
       FLOOR(EXTRACT(EPOCH FROM (NOW()-t.created_at))/3600) AS wait_hours,
       e.level, e.target_role, e.notify_channel
FROM rpt_task t
JOIN rpt_escalation_rule e ON e.scene=t.scene
  AND e.trigger_hours <= FLOOR(EXTRACT(EPOCH FROM (NOW()-t.created_at))/3600)
WHERE t.scene='QTIME' AND t.status IN ('PENDING','PROCESSING')
ORDER BY t.task_id, e.level DESC;

-- S12 【验收总台账】两场景任务全景
SELECT t.task_id, t.scene, t.biz_key, t.title, t.status, t.owner_user,
       t.close_type, t.created_at, t.closed_at
FROM rpt_task t ORDER BY t.scene, t.task_id;
