# OCAP 与 Q-Time Over 双场景实施路径

> 配套文件：ocap_qtime_impl_pg.sql（15 张表建表 + 伪造数据 + S1–S12 演示/验收 SQL，Postgresql可直接执行）。
> 两场景均按「报表发现 → 任务/表单交互 → Flow 编排执行 → 调 MES → 回证关单」五段落地。

## 〇、两个场景实施边界

| | OCAP（SPC 失控处置） | Q-Time Over |
|---|---|---|
| 主单 | `spc_ooc_record` 失控单 | `qtime_over_record` 超时记录 |
| 人工介入点 | PE 判定是否复测、选片、选 ReasonCode + Final Action、审批 | Sponsor 点 Action（解 Hold / 转办 / 关闭） |
| 编排复杂度 | 高：含人工表单节点、事件等待、回流环 | 低：技术节点为主，Flow 秒级结束 |
| 关单方式 | OOC 单状态机推进 + MES 回执确认 | 观测判据自动关单（连续 2 轮 GONE + 确认窗口） |
| 写 MES | 是（7 个出口） | 是（release-hold 1 个出口） |



## 一、数据模型（15 张表）

### 1.1 通用地基（4 张）

| 表 | 作用 | 关键口径 |
|---|---|---|
| `rpt_task` | 两场景统一任务，六态状态机 | `uk_scene_biz` 唯一索引兼作单飞锁；`action_map` 即列表页 action 字段 |
| `rpt_task_check_log` | 每轮回证核对日志 | `GONE/EXISTS/BOUNCE` 三值；关单判据直接查它 |
| `rpt_callback_log` | 引擎/MES 回调落地 | `uk_request` 重放去重，重复回调直接拒绝 |
| `rpt_escalation_rule` | 四级升级链 | POC 阶段角色写死，正式版接排班表 |

### 1.2 OCAP 专属（8 张）

```
spc_chart_def（控制图）
  └─ spc_data_point（测量点，超 USL/超 UCL 判定）
       └─ spc_ooc_record（失控单：OPEN→REMEASURING→PENDING_FINAL→EXECUTING→CLOSED）
            ├─ ocap_judgement（PE 判定：是否复测）
            ├─ ocap_remeasure（复测任务：选片→WAITING→DONE→结论 OOS/NO_OOS）
            │      └─ 回流：OOS → 重新判定；NO_OOS → 走 Release 出口
            ├─ ocap_final_action（ReasonCode + 七出口之一 + 审批）
            └─ ocap_exec_log（MES 执行回执，request_id 幂等）
ocap_reason_code（ReasonCode 字典，含默认出口）
```

状态机与流程图对应：`OPEN`=OOC 产生 → `REMEASURING`=PE 判定复测+选片中 → `PENDING_FINAL`=选 ReasonCode/Final Action + 审批 → `EXECUTING`=调 MES → `CLOSED`=回执确认。

### 1.3 Q-Time 专属（3 张）

```
qtime_rule（规则：route+step_from→step_to+limit_hours）
  └─ qtime_tracking（在站计时）
       └─ qtime_over_record（超时记录，active_flag=违规是否仍在）
```

`active_flag` 是整条链路的关键开关：mock MES 解 Hold 成功后置 0 → 触发 SQL 自然查不到 → 回证判 GONE。正式环境中等价于解 Hold 后计时停止、违规记录不再产生。

## 二、WFA 编排节点清单

### 2.1 OCAP（12 节点）

| # | 节点类型 | 配置要点 | 出口 |
|---|---|---|---|
| 1 | HTTP Trigger | 接收报表侧 OOC 开单事件 | → 2 |
| 2 | SQL | `UPDATE rpt_task SET status='PROCESSING' WHERE ...`（锁任务） | → 3 |
| 3 | SQL | 查失控单详情 + 控制图上下限 | → 4 |
| 4 | 人工表单 | PE 判定是否复测（写 `ocap_judgement`） | → 5 |
| 5 | IF | `need_remeasure='YES'` | Yes→6 / No→10 |
| 6 | 人工表单 | 选复测片（写 `ocap_remeasure`，状态 WAITING） | → 7 |
| 7 | 事件等待 | 等测量系统回调 / 轮询 `result_status='DONE'` | → 8 |
| 8 | IF | `conclusion='OOS'`？ | Yes→回到 4（Redo Monitor 回流）/ No→10 |
| 9 | SQL | 回写 OOC 单 `PENDING_FINAL` | → 10 |
| 10 | 人工表单 | 选 ReasonCode + Final Action（七选一，写 `ocap_final_action`） | → 11 |
| 11 | 审批节点 | PE Lead Approve；`action_type` 含报废/终止时加签厂长 | → 12 |
| 12 | HTTP + SQL | 按 `action_type` 路由调 MES（幂等键透传）→ 回执落 `ocap_exec_log` → 回调报表 | 结束 |

注：10→12 之间存在两条支路（复测 No 直接跳 10），画图时 9 号节点挂在 Yes 支路上。若 WFA 暂无人工表单/审批节点，POC 先用报表侧表单 + HTTP 回调替代，节点 4/6/10/11 的落库动作不变。

### 2.2 Q-Time Over（7 节点）

| # | 节点类型 | 配置要点 | 出口 |
|---|---|---|---|
| 1 | HTTP Trigger | 接收报表 CRON 命中的建单事件 | → 2 |
| 2 | SQL | 锁任务：`status→PROCESSING`，带 `uk_scene_biz` 防重 | → 3 |
| 3 | SQL | 前置校验：lot 状态 / Hold 原因码 | → 4 |
| 4 | IF | 处置策略：工程 Hold / MRB 类 → 转人工 | Yes→6 / No→5 |
| 5 | HTTP | `mes_release_hold`，幂等键 `task_id:节点:attempt` | → 6 |
| 6 | SQL | 回写 `rpt_task → WAIT_CONFIRM`，action 按钮置空 | → 7 |
| 7 | RESPOND | 返回执行结果；**关单不由 Flow 做**，由报表 CRON 回证（S8/S9） | 结束 |

分工原则：Flow 管执行不管关单；关单判据（连续 2 轮 GONE + 确认窗口 + 回弹回退）全部在报表 CRON 的 S8/S9 里，防止 Flow 与报表双头改状态。

## 三、MES 接口契约（入参 / 出参）

统一约定：Header 带 `X-Request-Id`（幂等键）；重复请求返回 `409` 并携带原单号；业务失败返回 `200` + `result=FAIL`。

### 3.1 OCAP 七出口（按 `action_type` 路由）

| action_type | 接口 | 入参 | 出参 |
|---|---|---|---|
| LOT_REWORK | `POST /mes/api/lot/rework` | `{lotId, oocId, reasonCode, targetRoute, requestId}` | `{result, lotId, newState, message}` |
| HOLD_TO_SCRAP | `POST /mes/api/lot/hold` | `{lotId, holdType:'SCRAP', reasonCode, requestId}` | `{result, lotId, holdId, message}` |
| RELEASE_TRACK_OUT | `POST /mes/api/lot/release` | `{lotId, reasonCode, requestId}` | `{result, lotId, newState:'RELEASED', message}` |
| HOLD_TO_OWNER | `POST /mes/api/lot/hold` | `{lotId, holdType:'OWNER', ownerRole, requestId}` | `{result, lotId, holdId, message}` |
| LOT_TERMINATE | `POST /mes/api/lot/terminate` | `{lotId, reasonCode, approver, requestId}` | `{result, lotId, newState:'TERMINATED', message}` |
| EQ_RELEASE | `POST /mes/api/eqp/state` | `{eqpId, state:'UP', reasonCode, requestId}` | `{result, eqpId, newState, message}` |
| EQ_DOWN | `POST /mes/api/eqp/state` | `{eqpId, state:'DOWN', reasonCode, requestId}` | `{result, eqpId, newState, message}` |

失败样例（幂等冲突）：`{"result":"FAIL","errorCode":"409_DUPLICATE","originTaskId":"TASK-OCAP-0001"}`

### 3.2 Q-Time Over（1 写 1 查）

```
POST /mes/api/lot/release-hold
  入参: {lotId, holdId?, reasonCode:'QTIME_OVER', operator:'WFA', requestId}
  出参: {result:'SUCCESS', lotId, holdState:'RELEASED', message}

GET /mes/api/lot/hold-state?lotId=T26F001
  出参: {lotId, holdState:'HELD|RELEASED', holdReasonCode, sinceTime}
```

POC 无真 MES 时，mock MES 最低实现 = 两个 POST + 一个 GET 按契约返回，解 Hold 成功后把 `qtime_over_record.active_flag` 置 0（模拟计时停止），另给一个手动触发回调的工具口。

## 四、回调报表平台规范

统一报文，POST 到报表平台 `/api/callback`：

```json
{
  "eventType": "MES_ACTION_DONE",
  "scene": "OCAP | QTIME",
  "taskId": "TASK-OCAP-0001",
  "bizKey": "OOC-2026-0001",
  "result": "SUCCESS",
  "requestId": "REQ-20261118-0001",
  "timestamp": 1795000000,
  "signature": "HMAC-SHA256(body, secret)"
}
```

四条硬规则：
1. **验签**：HMAC-SHA256，密钥双端配置，验签失败落 `rpt_callback_log` 且 `status=REJECTED`；
2. **重放去重**：`request_id` 唯一索引，重复回调直接 409；
3. **MES 侧重试**：回调失败按 30s / 2m / 10m 重试 3 次后进死信；
4. **状态归属唯一**：任务状态机只由报表平台推进（Flow 只报执行结果），避免双写冲突。

## 五、验证测试（对应 SQL 文件 S1–S12）

| 步骤 | 操作 | 执行 SQL | 预期 |
|---|---|---|---|
| 1 | Q-Time 触发命中 | S1 | 返回 QTO-2026-0001（T26F001 超时 40min） |
| 2 | 建任务 | S2 | `TASK-QTIME-0003` PENDING |
| 3 | 列表 action 按钮映射 | S3 | PENDING 显示三按钮，其他态置空 |
| 4 | OCAP 开单扫描 | S4 | 返回 OOC-2026-0002（0001 已有任务不重复开） |
| 5 | 测量回调 → 复测 NO_OOS | S5 | `RM-2026-0001` → DONE/NO_OOS |
| 6 | 选 Final Action + 审批 | S6 | `FA-2026-0002` APPROVED |
| 7 | 调 MES（mock 返回成功） | S7 | 回执 SUCCESS，OOC 单 CLOSED，任务 WAIT_CONFIRM |
| 8 | 回证核对 | S8 | TASK-QTIME-0002 → GONE（已 1 轮） |
| 9 | 第二轮 GONE → 自动关单 | S9 | `close_type=AUTO` |
| 10 | 回弹演示（负向） | S10 | 造一条 EXISTS → 任务回退 PENDING |
| 11 | 升级链演示 | S11 | 超时任务列出升级级别与目标角色 |
| 12 | 验收台账 | S12 | 四+1 条任务全景 |

负向用例（演示最值钱的部分）：
- **回调重放**：同 `request_id` 再 POST 一次 → 被拒（`uk_request`），报表无重复动作；
- **谎报关单捕获**：关单后手动把 `active_flag` 置回 1 → S1 重新命中生成新任务，系统能抓出自己的误判。
