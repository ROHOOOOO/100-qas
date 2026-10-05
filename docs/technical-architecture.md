# 技术架构

## 架构原则

- 先做可运行、可验证的最小闭环。
- 避免过早引入复杂账号系统。
- `Friends Games` 采用多游戏入口，每个小游戏拥有独立路由和数据域。
- 数据模型提前按多人房间设计，方便后续接入真实数据库。
- 前端交互先稳定，再逐步接入后端。

## 当前信息架构

- `#home`：Friends Games 游戏大厅。
- `#qa`：100 Q&As 首页。
- `#qa/create`：100 Q&As 创建房间。
- `#qa/room/:code`：100 Q&As 房间。
- `#qa/export/:code`：100 Q&As PDF 导出版。
- `#room/:code`：旧版 100 Q&As 房间兼容路由。
- `#tycoon`：Friends Tycoon 创建/加入入口。
- `#tycoon/room/:code`：Friends Tycoon 房间。
- `#spin`：What’s Next? 创建与加入转盘。
- `#spin/room/:code`：转盘、共享历史、成员与房主设置。
- `#account`：登录或当前账号记录。
- `#account/register`：注册账号、用户名及一个密保问题。
- `#account/settings`：修改用户名。
- `#account/recover`：输入账号、验证密保、重设密码。

## 开发阶段策略

### 阶段 1：本地交互原型

目标：

- 不依赖网络。
- 不依赖构建工具。
- 直接打开 `index.html` 即可体验。
- 使用浏览器 `localStorage` 模拟房间、玩家、草稿、提交、结果页。

价值：

- 快速验证完整用户流程。
- 方便非技术用户直接看效果。
- 降低第一步开发风险。

限制：

- 无法跨设备同步。
- 朋友不能真正远程共享答案。

### 阶段 2：真实多人版本

目标：

- 接入线上数据库。
- 支持不同设备加入同一房间。
- 支持真实邀请链接。
- 三个模块要求登录后参与，支持跨设备恢复记录和旧匿名记录手动绑定。
- 支持房间级题库：每个房间创建时绑定自己的题库；默认 100 题，自定义 1 到 100 题。

当前推荐技术：

- 前端：静态 HTML/CSS/JS。
- 数据库：Supabase Postgres。
- 数据访问：Supabase RPC 函数。
- 部署：GitHub Pages。

说明：

- 为了马上可用，当前不引入 React / Next.js。
- 静态网页可以直接部署到 GitHub Pages。
- Supabase 负责在线保存房间、玩家和答案。
- 自定义 `game_accounts` / `game_account_sessions` 负责朋友账号名 + 密码登录。
- 没有 Supabase 配置时，网页自动使用本地模式。

### 阶段 3：Friends Games 多游戏底座

目标：

- 把原 `100 Q&As` 单页入口升级为 `Friends Games` 游戏大厅。
- 保持 `100 Q&As` 现有线上流程稳定。
- 为 `Friends Tycoon` 预留独立路由、文档和后续数据模型。

### 阶段 4：Friends Tycoon 真实多人版本

建议技术：

- 前端继续使用静态 HTML/CSS/JS，先做轻量可玩的 MVP。
- 后端继续使用 Supabase Postgres 和 RPC。
- 房间状态以服务端为准，前端只提交玩家动作。
- 每个玩家动作通过 RPC 校验当前回合、玩家身份、现金和资产状态。
- 聊天和游戏记录分开保存；聊天只保留近期内容或单局临时内容。

## 配置模式

配置文件：

```text
src/config.js
```

本地模式：

```js
window.QA_CONFIG = {
  backend: "local",
  supabaseUrl: "",
  supabaseAnonKey: ""
};
```

在线模式：

```js
window.QA_CONFIG = {
  backend: "supabase",
  supabaseUrl: "你的 Supabase Project URL",
  supabaseAnonKey: "你的 Supabase anon public key"
};
```

数据库初始化 SQL：

```text
supabase/schema.sql
```

## 数据模型

当前已实现数据模型用于 `100 Q&As`。

### Room

- `id`: 房间唯一 ID。
- `code`: 短房间码。
- `title`: 房间标题，默认 `100 Q&As`。
- `questions`: 房间题库，`jsonb` 数组；自定义房间保存 1 到 100 题，老房间或默认房间为空时由前端回退到内置默认题库。
- `created_at`: 创建时间。
- `is_locked`: 是否关闭新玩家加入，第一版可不实现。

### Player

- `id`: 玩家唯一 ID。
- `room_id`: 所属房间 ID。
- `nickname`: 玩家昵称。
- `player_key`: 匿名身份密钥，当前版本仍以原始 key 存储；账号绑定后，新设备可通过账号找回身份。
- `account_id`: 登录账号 ID，关联 `game_accounts`。
- `created_at`: 加入时间。
- `submitted_at`: 提交时间，未提交为空。

### Answer

- `id`: 答案唯一 ID。
- `room_id`: 所属房间 ID。
- `player_id`: 所属玩家 ID。
- `question_index`: 题号，1 到 100；实际可答范围由当前房间题库数量决定。
- `content`: 答案文本。
- `updated_at`: 更新时间。

### Question Bank

题库属于房间数据，不单独建表。

- 前端内置默认 100 题，用于默认创建和老房间兼容。
- 自定义题库以 `qa_rooms.questions` 的 `jsonb` 数组保存。
- 自定义题库允许 1 到 100 题；100 是当前 `qa_answers.question_index` 约束和产品上限。
- 创建后不提供修改题库入口，避免玩家之间题目不一致。

## Friends Tycoon MVP 数据模型

Friends Tycoon 使用独立的 `tycoon_*` 表和 RPC，不复用 `qa_*` 表：

- `tycoon_rooms`：房间、房主、状态、胜利条件、回合上限、地图配置、最终结果。
- `tycoon_players`：玩家昵称、身份密钥、账号 ID、现金、位置、是否破产、是否房主。
- `tycoon_properties`：房间内地产归属、等级、价格、租金。
- `tycoon_logs`：游戏记录，保留关键行动。
- `tycoon_messages`：聊天消息，可设置较短保留周期或只保留当前局。

当前回合信息直接保存在 `tycoon_rooms`：

- `current_turn`
- `current_player_id`
- `turn_phase`
- `last_dice`
- `pending_action`：当前掷骰后等待玩家选择的动作，取值为 `buy` / `upgrade` / `null`。
- `action_cell_index`：当前待操作对应的地图格子。
- `action_deadline`：买地或升级选择的 8 秒截止时间，超时默认跳过。

关键 RPC：

- `tycoon_create_room`
- `tycoon_join_room`
- `tycoon_start_game`
- `tycoon_roll_dice`
- `tycoon_buy_property`
- `tycoon_upgrade_property`
- `tycoon_end_turn`
- `tycoon_skip_action`
- `tycoon_auto_skip_action`
- `tycoon_remove_player`
- `tycoon_restart_room`
- `tycoon_close_room`
- `tycoon_send_message`

并发策略：

- 服务端校验是否轮到当前玩家行动。
- 掷骰、买地、升级、结算租金和破产应放在同一个 RPC 事务中。
- `tycoon_roll_dice` 会直接完成移动、强制费用、机会、租金、破产判断，并只在可购买/可升级时设置 `pending_action`。
- 买地或升级成功后，服务端立即调用换人逻辑；前端不再需要手动“结束回合”。
- 倒计时结束后，任一已登录房间成员可以调用 `tycoon_auto_skip_action` 推进房间，避免当前玩家临时离开后卡住。
- 客户端先定时刷新房间状态；如后续需要更顺滑体验，再接 Supabase Realtime。
- 服务端通过有效会话对应的 `account_id` 校验玩家身份和权限。旧 `player_key` 只用于历史匿名记录绑定。
- 同一账号刷新、关闭页面或换设备后可恢复原玩家状态。
- 玩家主动退出会调用 `tycoon_exit_game`，服务端将其置为 `bankrupt`，释放其地产并在必要时推进回合。
- 房主移除玩家会调用 `tycoon_remove_player`，被移除玩家按破产处理，名下地产释放为无主地。
- 房主退出时，服务端自动移交 `host_player_id` 给下一位未破产玩家；没有可移交玩家时关闭或结束房间。
- 游戏结束后 `tycoon_messages` 会清空，`tycoon_rooms.final_results` 与 `tycoon_logs` 保留最终结果和关键记录。

## 权限规则

- 玩家只能编辑自己的答案。
- 玩家提交后不可修改。
- 玩家未提交时不能查看其他玩家答案。
- 结果页只展示已提交玩家的答案。
- 房间不公开索引，只有拿到链接或房间码的人可以进入。
- 客户端只能通过 RPC 创建房间、加入房间、保存答案和提交答案，不直接开放表访问。
- 登录账号后，RPC 继续使用 Supabase anon key 调用，同时传入 `p_account_token`，服务端通过 token 哈希查找账号并绑定/查询记录。
- 未登录请求被拒绝；公开 anon key 仅是 RPC 入口，不能替代账号凭证。

## 账号与记录同步

账号第一版使用轻量朋友账号：

- 账号名 + 密码可用，不依赖邮箱验证码或短信。
- 账号名规则：2-20 位，支持中文、英文、数字、下划线。
- 密码规则：至少 4 位，前端提醒不要使用重要账号密码。
- 浏览器本地保存账号 session token。
- `supabaseRpc` 始终使用 anon key 调用 RPC；登录后额外传入 `p_account_token`。

新增账号字段：

- `game_accounts.id`
- `game_accounts.username`
- `game_accounts.username_key`
- `game_accounts.password_hash`
- `game_account_sessions.token_hash`
- `game_account_sessions.account_id`
- `game_account_sessions.expires_at`
- `qa_rooms.owner_account_id`
- `qa_players.account_id`
- `tycoon_rooms.owner_account_id`
- `tycoon_players.account_id`

新增账号 RPC：

- `account_register`：注册账号名 + 密码，并返回 session token。
- `account_login`：校验账号名 + 密码，并返回 session token。
- `account_logout`：注销当前 session token。
- `account_refresh`：验证并续期现有 token，保持同一设备的登录。
- `account_bind_records`：把当前设备中仍保存 `player_key` 的匿名玩家记录绑定到当前登录账号。
- `account_get_records`：返回当前账号的 100 Q&As、Friends Tycoon 和 What’s Next? 房间列表。

跨设备恢复策略：

- 新设备登录后，从“我的记录”进入房间。
- 前端请求房间时即使没有 `player_key`，服务端也会使用 `p_account_token` 查找该账号在房间中的玩家。
- 找到后返回 `currentPlayerId`，前端把它缓存为当前设备身份。

## PDF 导出

100 Q&As 结果页新增导出流程：

- `#qa/export/:code` 渲染导出版页面。
- 页面提供 `下载 PDF` 主按钮，直接在前端生成 PDF 文件。
- 页面提供 `打开 PDF 预览`，用于旧手机下载兜底。
- 页面保留 `打印 / 系统保存` 作为辅助方式。
- 页面只展示已提交玩家的答案。
- 未提交玩家不能导出其他人的答案。
- PDF 文件由前端 canvas 分页生成，不再依赖打印弹窗作为唯一导出方式。

## 登录记忆与账号隔离

- 在线会话保存于 `friends-games-auth-session-v1`，本地试玩使用独立的 `friends-games-local-auth-session-v1`。
- 服务端只保存 token 哈希；每次有效账号请求将到期时间延后 90 天，过期或注销的会话不会恢复。
- 前端在页面恢复或切换路由时刷新会话，间隔至少一分钟。网络失败保留本机会话；明确失效时回登录页。
- 在线 QA/Tycoon 缓存与玩家身份按账号 ID 分开保存；异步响应返回时再检查账号是否改变。
- 旧的匿名缓存保留用于手动绑定，绑定函数只接受原始玩家密钥及尚未归属其他账号的记录。
- 邀请路由存入当前标签页的 sessionStorage，登录或注册完成后返回。

## What’s Next? 数据与同步

- `src/spin.js` 管理入口、邀请、转盘动画、历史和房主表单。
- `spin_rooms` 保存房主、名称、2–50 个不重复选项、模式及配置版本。
- `spin_members` 保存账号与房间成员关系，创建者自动成为成员。
- `spin_draws` 保存每一次结果，包括账号、成员名称、模式、选项快照、结果索引、开始/结束时间和请求 UUID。
- `spin_create_room` / `spin_join_room` / `spin_get_room` 负责房间；`spin_update_room` 校验房主及配置版本。
- `spin_draw` 锁住房间行后校验成员及活动抽取，再由数据库等概率选取结果；允许重复抽中。
- 共同模式同房间最多一轮活动抽取；各自模式只限制同账号，不同成员可分别旋转。旋转期为四秒，期间不能修改配置。
- 同一房间、账号、请求 UUID 唯一。网络重试沿用原 UUID，避免一次点击留下多条历史。
- 结果先提交数据库再播放动画；前端根据服务器时间校准动画，停留或重新进入均能恢复结果。
- 房间每 1.5 秒同步一次；各自模式只更新本人转盘，成员的其他结果更新到共享历史。
- 历史按 ID 倒序、每批 25 条，用游标加载更早记录；编辑配置不修改历史快照。
- 三张表开启 RLS 并撤销直接读写权限，客户端只能访问校验会话、房主和成员的 RPC。

## 本地试玩

`src/local-backend.js` 模拟账号和转盘 RPC，PBKDF2 保存试玩密码摘要，账号、成员、历史保存在当前浏览器。QA/Tycoon 的本地玩家也按账号区分，不再提供跳过账号的玩家切换入口。

此模式用于单浏览器体验，不能跨设备同步。多人和权限验证应使用 PostgreSQL 测试环境。正式账号和试玩账号的存储键分开，互不代替。

## 2026-10-04 用户名与密保实现

- `src/account.js` 管理登录、注册、设置和三步找回密码界面；重设凭证仅保留在当前页面内存中，不放入 URL、localStorage 或 sessionStorage。
- 保留 `game_accounts.username` / `username_key` 作为登录账号，新增 `display_name` 作为可重名的游戏用户名。账号响应给本人返回两者，游戏 RPC 只返回显示名称与内部 ID。
- `account_register` 改为五个必填参数：账号、密码、用户名、密保问题编号与答案；删除旧的两个参数入口，不能绕过密保注册。
- `account_update_profile` 校验登录并更新用户名及 QA/Tycoon 的当前玩家名称；`spin_members` 查询账号当前用户名。
- `qa_players.submitted_name` 保存提交时的名字，结果页和 PDF 使用该快照。Tycoon 的聊天、日志、最终结果及转盘历史不随改名更新。
- 密码使用 pgcrypto bcrypt，成本 10；限制最多 72 UTF-8 字节，避免截断。密保答案规范化后先 SHA-256，再用独立盐 bcrypt；本地试玩用独立盐 PBKDF2。
- `account_recovery_question` 只返回问题编号，不返回账号资料或答案。不存在的账号也返回相同形状的响应。
- `account_verify_recovery` 锁定账号行，记录验证失败次数与窗口，达到上限后只限制恢复操作。失败返回普通结果使计数可以提交，不抛出导致事务回滚的异常。
- 成功验证生成 32 字节随机重设凭证，`game_account_recoveries` 仅保存其 SHA-256 摘要，有效期 10 分钟，同一账号只保留一个。
- `account_reset_password` 在同一事务内消费凭证、更新密码、删除所有登录会话。凭证重放或过期均失败。
- 登录、会话校验和恢复操作遵循账号行优先的锁顺序，避免旧密码登录与重设密码竞争时留下有效旧会话。
- 新恢复表开启 RLS，撤销直接读取和写入权限，只开放所需 RPC。
- 本地试玩以浏览器锁保证恢复操作串行执行，试玩账号仍与正式账号分开。

凭证时效、单次使用、尝试限制和旧会话注销参考 [OWASP Forgot Password Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Forgot_Password_Cheat_Sheet.html)。本产品按已确认范围使用一个密保问题，不包含邮件或短信恢复渠道。


## 2026-10-04 转盘展示与输入修正

- 密保答案默认 `type="text"`、`inputmode="text"`，中文合成输入在注册和找回两处验证；显示按钮可切换为密码遮罩。数据校验和摘要算法无需变更。
- 折叠使用原生 `details/summary`；`whats-next-panels:<accountId>:<roomCode>` 保存两个面板的布尔状态。点击时立即保存目标状态，`toggle` 事件补充同步，防止快速刷新漏存。仅处理仍连接到当前房间的节点。
- 抽取算法保留本地 Web Crypto + 拒绝采样、SQL `floor(random()*选项数)`。随机性审计调用真实 `spin_draw`，分布与相邻重复率分别检查；统计样本不构成绝对随机性证明。
- 动画用抽取编号和创建时间生成稳定的视觉参数，控制 4–6 圈和扇区 20%–80% 内部落点。此计算不参与选项选择。最终角度保存在当前显示状态，重载时从抽取历史恢复；客户端显示同一个保存结果。
- 请求幂等性继续依靠房间、账号与请求编号唯一约束；响应丢失后重试只恢复原结果，下一次主动抽取使用新的编号。

## Board Games（2026-10-04）

路由：`#board`、`#board/room/:code`、`#board/replay/:id`，全部沿用统一账号。`src/board/ui.js` 负责棋盘和房间；`rules.js` 是浏览器、本地后台、Worker 共用的纯规则引擎。SQL 独立重复验证规则，客户端不能绕过轮次、自将或权限校验。

- `board_rooms`：房主/客人或电脑、准备状态、在线时间、局数、当前对局和版本号。
- `board_matches`：固定参与账号、开局用户名/难度快照、当前棋盘、规范走法、重复局面索引、操作事件、结果与时间。
- `board_requests`：房间 + 账号 + 请求 UUID 唯一；网络重试返回原操作后的房间，不重复落子。
- 五个公开 RPC：`board_create_room`、`board_get_room`、`board_action`、`board_get_match`、`board_records`。基础表启用 RLS 并撤销客户端权限；内部规则函数不对 anon/authenticated 开放。
- 每次写入验证账号，锁定房间，检查版本并原子更新。过期版本拒绝并刷新；前端忽略晚到的旧版本。每 2 秒同步一次，后台标签页暂停；相同版本只更新在线状态，保留当前棋子选择。
- 真人有双方同意的悔棋、求和流程；人机悔棋即时执行。悔棋回滚规范走法及重复计数，但保留原落子和撤回事件。
- 每个事件包含棋盘、轮次、结果快照；回放读取事件快照，不会遗漏后来撤回的走法。棋谱仅开放给该盘参与账号。
- 暂离不会自动判负。服务端按最后活动时间判断是否已满 5 分钟；在线对手主动结束为 `interrupted`。无真人对手的人机房间不会因此终止。
- 本地试玩使用 `src/board/local.js`，并入原账号存储和跨标签页串行锁；数据留在当前浏览器，不能跨设备联机。

### 电脑

`ai.js` 在 `worker.js` 中执行，界面可继续响应。简单从评分较高的候选中选择；普通和困难使用迭代加深、alpha-beta 搜索。两种棋都优先立即获胜；普通/困难五子棋显式防单步成五，象棋合法性过滤自将，按子力和兵位置评分。

| 难度 | 最大搜索深度（半步） | 分支上限 | 节点上限 | 搜索时间预算 |
| --- | --- | --- | --- | --- |
| 简单 | 1 | 评分前 4 个候选 | 不展开搜索树 | — |
| 普通 | 2 | 12 | 1,800 | 400 ms |
| 困难 | 4 | 18 | 12,000 | 1,400 ms |

超出预算使用最后完整搜索的结果；设备较慢时深度可能更浅。房主当前页面负责电脑搜索，服务端只验证并保存合法结果，避免在数据库锁内执行搜索。房主离开时暂停电脑，返回会继续。搜索内层不完全预演重复判罚，根节点与实际落子由完整规则判断；这是休闲电脑，不宣称等级分或专业棋力。

首版限定标准走法与休闲重复规则：同棋盘、同轮次第三次出现时，单方在重复区间每步将军则该方负，其余重复和棋，不实现完整竞赛长捉裁决。

## Board Games 扩展（2026-10-05，覆盖首版同名约定）

- 棋类补齐 `chess`、`flight`、`halma`。`chess.js` 保存易位权、合法吃过路兵格、50 回合计数及重复局面；`race.js` 保存多人轮次、骰子与排名。浏览器、Worker、本地后台共用这些纯函数，SQL 独立校验每次转换。
- `board_seats` 按房间和座号保存 2–6 席真人或电脑，唯一索引防同账号占多席。旧双人房间、进行中棋局及待处理投票可迁移，已有事件保留。
- `board_matches.controls` 仅供飞行棋临时托管：手动/离线接管来源、难度、待交还标志。接回在本回合结束生效，6 的额外投掷也属于当前回合。
- `board_messages` 独立保存房间持续聊天，用户名为发送时快照，正文原样以转义文本呈现。新增 `board_chat_list` / `board_chat_send` 后共有七个公开棋类 RPC。按房间与递增 ID 分页，每批 50 条；房间、账号、请求 UUID 唯一，响应丢失重发不会重复。
- 新表开启 RLS 并撤销客户端直接访问。仅校验成员的聊天 RPC 可读写消息；规则函数、星形棋盘几何表及内部辅助函数不对客户端开放。
- `view.js` 渲染五种棋盘；`chat.js` 单独维护聊天节点。房间版本变化只替换棋盘和席位区域，保留聊天输入框、焦点和合成输入。未读及折叠偏好在账号/房间范围保存，草稿与未确认发送凭证在 sessionStorage 保存。
- 多人悔棋要求其他真人全部同意；中断要求存在未完成且离线满 5 分钟的真人，其他未完成在线真人全部同意。投票确认时再次检查离线条件，若人已回来则取消中断申请。完成者不再参与中断投票。
- 每个新事件包含完整规则状态快照（排除递归走法和重复表）；逐步回放覆盖骰子、移动、投票、撤回和托管事件，并兼容首版事件格式。
- 电脑执行者改为座位顺序中第一个最近 45 秒活跃的真人页面，服务端校验执行者并锁房间。其他在线成员可以在房主离开后继续驱动电脑；全部离线停止。棋子移动与掷骰用同一版本号/请求去重约束，客户端不能选择骰子结果。
- 准备、加入、席位设置等可安全重复的操作在版本冲突时自动同步，最多重试两次。多人投票绑定申请 UUID，仅在同一申请仍待处理时重试确认；不把旧确认用于另一项申请。落子保留原来的冲突拒绝与重新选择流程。

### 新棋类电脑能力

- 国际象棋：简单从较优候选中选取；普通最多 2 半步，困难最多 4 半步，均优先立即将死。按时间、节点预算截断，不承诺竞技等级分。
- 跳棋：最小成本匹配让 10 枚棋子对应不同目标孔；普通按推进、离开本营和避免重复的位置评分，困难再看一轮可达位置。按己方位置识别往返，避免其他玩家移动掩盖重复。简单允许从多个较优候选中选择。
- 飞行棋：简单选择合法飞机；普通考虑推进、起飞、碰撞和到终点；困难额外考虑被撞风险和保留活动飞机。任何难度都不预测或修改骰子。
- `worker.js` 加载 `rules.js`、`chess.js`、`race.js`、`ai.js`、`ai-extra.js`；搜索不阻塞页面输入。
