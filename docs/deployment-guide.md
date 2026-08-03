# 上线与分享指南

## 当前推荐方式

为了让朋友们直接在网页里填写、提交、查看结果，第一版推荐：

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
- 已在 Supabase SQL Editor 中运行 `supabase/schema.sql`。
- 线上双玩家验收已通过。

## 使用流程

上线后，朋友的流程是：

1. 打开网页。
2. 创建房间或打开你发的房间链接。
3. 输入昵称。
4. 分页填写 100 题。
5. 提交。
6. 提交后自动看到同一房间里已提交朋友的答案。

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
- `qa_create_room`
- `qa_get_room`
- `qa_join_room`
- `qa_save_answer`
- `qa_submit_player`

网页通过这些函数读写数据，不直接开放数据表。

### 3. 配置网页

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

说明：线上验收会创建测试房间和测试答案，用于确认 GitHub Pages 与 Supabase 的真实连接状态。

## 重要限制

第一版是熟人私密玩法，不是强安全系统。

- 拿到房间链接的人可以加入房间。
- 不做注册账号。
- 用户换浏览器或清除浏览器数据后，可能无法继续原来的草稿。
- 提交后不能修改。
