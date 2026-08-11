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
- `#account`：登录、注册、我的记录。

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
- 保持匿名可玩，同时支持登录账号跨设备同步记录。
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

关键 RPC：

- `tycoon_create_room`
- `tycoon_join_room`
- `tycoon_start_game`
- `tycoon_roll_dice`
- `tycoon_buy_property`
- `tycoon_upgrade_property`
- `tycoon_end_turn`
- `tycoon_restart_room`
- `tycoon_close_room`
- `tycoon_send_message`

并发策略：

- 服务端校验是否轮到当前玩家行动。
- 掷骰、买地、升级、结算租金和破产应放在同一个 RPC 事务中。
- 客户端先定时刷新房间状态；如后续需要更顺滑体验，再接 Supabase Realtime。
- 玩家身份仍采用 `player_key`：浏览器保存原始 key，服务端通过 `room_id + player_id + player_key` 校验操作权限。
- 登录账号后，服务端也允许通过 `account_id = game_account_id_from_token(p_account_token)` 找回同一玩家身份。
- 玩家刷新、关闭页面或闪退后，同一浏览器可通过本地身份 key 恢复到原玩家状态。
- 玩家主动退出会调用 `tycoon_exit_game`，服务端将其置为 `bankrupt`，释放其地产并在必要时推进回合。
- 游戏结束后 `tycoon_messages` 会清空，`tycoon_rooms.final_results` 与 `tycoon_logs` 保留最终结果和关键记录。

## 权限规则

- 玩家只能编辑自己的答案。
- 玩家提交后不可修改。
- 玩家未提交时不能查看其他玩家答案。
- 结果页只展示已提交玩家的答案。
- 房间不公开索引，只有拿到链接或房间码的人可以进入。
- 客户端只能通过 RPC 创建房间、加入房间、保存答案和提交答案，不直接开放表访问。
- 登录账号后，RPC 继续使用 Supabase anon key 调用，同时传入 `p_account_token`，服务端通过 token 哈希查找账号并绑定/查询记录。
- 匿名模式继续使用 anon key 与本地保存的 `player_key`。

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
- `account_bind_records`：把当前设备中仍保存 `player_key` 的匿名玩家记录绑定到当前登录账号。
- `account_get_records`：返回当前账号参与过的 100 Q&As 和 Friends Tycoon 房间列表。

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

## 本地身份方案

第一版在浏览器保存：

- 当前房间 ID。
- 当前玩家 ID。
- 当前玩家本地密钥。

后续接入数据库时：

- 当前实现中，浏览器保存原始 `player_key`，服务端也保存 `player_key`，并通过 `room_id + player_id + player_key` 校验匿名玩家权限。
- 登录账号后，服务端也允许通过 `account_id = game_account_id_from_token(p_account_token)` 校验同一玩家权限。
- 后续若要进一步加强安全性，可以迁移为服务端保存 `player_key_hash`。
