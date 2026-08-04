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
- `#room/:code`：旧版 100 Q&As 房间兼容路由。
- `#tycoon`：Friends Tycoon 创建/加入入口。
- `#tycoon/room/:code`：Friends Tycoon 房间。

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
- 保持无账号体验。
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
- `player_key_hash`: 玩家身份密钥哈希。
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
- `tycoon_players`：玩家昵称、身份密钥哈希、现金、位置、是否破产、是否房主。
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

## 本地身份方案

第一版在浏览器保存：

- 当前房间 ID。
- 当前玩家 ID。
- 当前玩家本地密钥。

后续接入数据库时：

- 浏览器保存原始 `player_key`。
- 服务端只保存 `player_key_hash`。
- 通过 `room_id + player_id + player_key` 校验编辑权限。
