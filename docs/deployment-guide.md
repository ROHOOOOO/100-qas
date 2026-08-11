# 上线与分享指南

## 当前推荐方式

为了让朋友们直接在网页里选择小游戏、填写、提交、查看结果，第一版推荐：

- 网页托管：GitHub Pages
- 在线数据库：Supabase
- 前端形式：静态 HTML/CSS/JS，无需构建工具

这个组合的好处：

- 朋友只需要打开一个网页链接。
- 不需要注册账号。
- 不需要手动发答案包。
- GitHub Pages 可以免费托管静态网页。
- Supabase 保存房间、玩家和答案。

## 当前项目地址

- GitHub 仓库：[https://github.com/ROHOOOOO/100-qas](https://github.com/ROHOOOOO/100-qas)
- GitHub Pages：[https://rohooooo.github.io/100-qas/](https://rohooooo.github.io/100-qas/)
- Supabase Project URL：`https://yexwacezlklxqlmwgtfe.supabase.co`

当前状态：

- GitHub Pages 已发布。
- `src/config.js` 已切换到 Supabase 在线模式。
- 首页已升级为 `Friends Games` 游戏大厅。
- 基础多人答题版已在 Supabase SQL Editor 中运行过 `supabase/schema.sql`。
- 基础线上双玩家验收已通过。
- 房间级自定义题库 SQL 已运行。
- 自定义题库线上双玩家验收已通过。
- 最新规则已改为自定义题库 1 到 100 题，并已通过线上 3 题双玩家验收。
- Friends Games 游戏大厅和 Friends Tycoon 入口已发布到 GitHub Pages。
- Friends Games 线上验收已通过，最新 100 Q&As 测试房间 `6E22A5` 中 2 位玩家均提交 3 题，结果页正常展示 6 条答案。
- Friends Tycoon 线上双玩家验收已通过，测试房间 `5D1C74` 跑通创建、加入、聊天、开始、掷骰、结束回合、退出即破产、重新进入恢复和最终结果。
- 最新 `supabase/schema.sql` 额外加入“已结束/已解散房间不能再退出”的后端保护；线上页面已先隐藏该入口，方便时可再次运行 SQL 让数据库层同步这条保护。
- 账号登录/注册已从 Supabase Auth 邮箱方案改为轻量朋友账号名 + 密码方案。
- 100 Q&As PDF 导出已从“仅打印保存”升级为“直接下载 PDF + 预览兜底 + 打印辅助”。
- 线上生效前需要再次在 Supabase SQL Editor 运行最新版 `supabase/schema.sql`，然后发布前端并执行线上验收。

## 使用流程

### 100 Q&As

1. 打开网页。
2. 在游戏大厅选择 `100 Q&As`。
3. 创建房间时选择默认题库或自定义题库，也可以打开你发的房间链接。
4. 输入昵称。
5. 分页填写当前房间题库的全部题目。
6. 提交。
7. 提交后自动看到同一房间里已提交朋友的答案。

### Friends Tycoon

1. 打开网页。
2. 在游戏大厅选择 `Friends Tycoon`。
3. 房主填写昵称，选择胜利条件，创建房间。
4. 房主复制邀请链接或房间码发给朋友。
5. 朋友打开链接或输入房间码，填写昵称加入。
6. 2 到 6 人加入后，由房主开始游戏。
7. 玩家轮流掷骰、移动、买地、升级、聊天。
8. 玩家主动退出后状态变为破产，其他人继续。
9. 游戏结束后查看最终结果。

## Supabase 设置

### 1. 创建 Supabase 项目

在 Supabase 创建一个新项目。

需要从项目中拿到：

- Project URL
- anon public key

它们在 Supabase 项目的 `Settings → API` 中。

### 2. 运行数据库 SQL

打开 Supabase 项目，进入：

```text
SQL Editor → New query
```

然后复制并运行：

```text
supabase/schema.sql
```

这个 SQL 会创建：

- `qa_rooms`
- `qa_players`
- `qa_answers`
- `tycoon_rooms`
- `tycoon_players`
- `tycoon_properties`
- `tycoon_logs`
- `tycoon_messages`
- `game_accounts`
- `game_account_sessions`
- `account_register`
- `account_login`
- `account_logout`
- `qa_create_room`
- `qa_get_room`
- `qa_join_room`
- `qa_save_answer`
- `qa_submit_player`
- `tycoon_create_room`
- `tycoon_get_room`
- `tycoon_join_room`
- `tycoon_start_game`
- `tycoon_roll_dice`
- `tycoon_buy_property`
- `tycoon_upgrade_property`
- `tycoon_end_turn`
- `tycoon_exit_game`
- `tycoon_restart_room`
- `tycoon_close_room`
- `tycoon_send_message`
- `account_bind_records`
- `account_get_records`

网页通过这些函数读写数据，不直接开放数据表。

如果后续更新了 `supabase/schema.sql`，可以在 SQL Editor 中再次运行整个文件。该文件会兼容已有表和已有房间。

### 3. 账号方案说明

账号第一版使用朋友账号名 + 密码，不需要配置 Supabase Auth 邮箱或短信。

需要确认：

- 已运行最新版 `supabase/schema.sql`。
- 数据库中存在 `game_accounts` 与 `game_account_sessions`。
- 前端账号页显示账号名 placeholder：`2-20位，支持中文/英文/数字/下划线`。
- 前端账号页显示密码 placeholder：`至少4位，请勿使用重要账号密码`。

### 4. 配置网页

编辑：

```text
src/config.js
```

把默认本地模式：

```js
window.QA_CONFIG = {
  backend: "local",
  supabaseUrl: "",
  supabaseAnonKey: ""
};
```

改成：

```js
window.QA_CONFIG = {
  backend: "supabase",
  supabaseUrl: "你的 Project URL",
  supabaseAnonKey: "你的 anon public key"
};
```

本项目已经填好：

```js
window.QA_CONFIG = {
  backend: "supabase",
  supabaseUrl: "https://yexwacezlklxqlmwgtfe.supabase.co",
  supabaseAnonKey: "sb_publishable_oKxZ2ME69FONBMxap55C6A_PLlKGHXu"
};
```

说明：

- anon public key 是前端公开 key，可以放在静态网页中。
- 不要把 Supabase service role key 放进网页。

## GitHub Pages 上传方式

### 方式 A：上传到用户主页仓库

如果你的 GitHub 用户名是 `yourname`，创建仓库：

```text
yourname.github.io
```

把本项目文件上传到这个仓库根目录，开启 GitHub Pages 后，访问：

```text
https://yourname.github.io/
```

### 方式 B：上传到普通项目仓库

也可以创建普通仓库，例如：

```text
100-qas
```

开启 GitHub Pages 后，访问：

```text
https://yourname.github.io/100-qas/
```

当前代码使用相对路径，适合这两种方式。

## 上线前检查

上线前运行：

```bash
/Users/rohooooo/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node scripts/verify-static.mjs
```

如果本机允许浏览器自动化，也运行：

```bash
/Users/rohooooo/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node scripts/verify-browser.mjs
```

线上环境验收运行：

```bash
/Users/rohooooo/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node scripts/verify-online.mjs
```

说明：线上验收会创建自定义题库测试房间和测试答案，用于确认 GitHub Pages 与 Supabase 的真实连接状态。

## 重要限制

第一版是熟人私密玩法，不是强安全系统。

- 拿到房间链接的人可以加入房间。
- 不做注册账号。
- 用户换浏览器或清除浏览器数据后，可能无法继续原来的草稿。
- 提交后不能修改。
- 自定义题库第一版只支持纯文本文件或直接粘贴，不直接解析 Word `.docx`。
