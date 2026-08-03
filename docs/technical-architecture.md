# 技术架构

## 架构原则

- 先做可运行、可验证的最小闭环。
- 避免过早引入复杂账号系统。
- 数据模型提前按多人房间设计，方便后续接入真实数据库。
- 前端交互先稳定，再逐步接入后端。

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
- 支持房间级题库：每个房间创建时绑定自己的 100 题。

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

### Room

- `id`: 房间唯一 ID。
- `code`: 短房间码。
- `title`: 房间标题，默认 `100 Q&As`。
- `questions`: 房间题库，`jsonb` 数组；老房间或默认房间为空时由前端回退到内置默认题库。
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
- `question_index`: 题号，1 到 100。
- `content`: 答案文本。
- `updated_at`: 更新时间。

### Question Bank

题库属于房间数据，不单独建表。

- 前端内置默认 100 题，用于默认创建和老房间兼容。
- 自定义题库以 `qa_rooms.questions` 的 `jsonb` 数组保存。
- 第一版固定要求 100 题，与现有 `qa_answers.question_index` 的 1 到 100 范围保持一致。
- 创建后不提供修改题库入口，避免玩家之间题目不一致。

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
