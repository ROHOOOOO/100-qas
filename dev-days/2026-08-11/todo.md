# 待办

- 已完成：运行 `node --check src/app.js`、`node scripts/verify-static.mjs`、`node scripts/verify-browser.mjs`。
- 已完成：用户在 Supabase SQL Editor 再次运行最新版 `supabase/schema.sql`，同步 `extensions.crypt` / `extensions.gen_salt` 修复。
- 已完成：重新执行 `scripts/verify-online.mjs`，验证账号注册/登录、记录归属、跨设备恢复和 PDF 下载。
- 如旧手机仍无法下载 PDF，追加 Web Share 文件分享方案作为移动端兜底。
- 用户需要在 Supabase SQL Editor 运行最新版 `supabase/schema.sql`，升级 `tycoon_rooms.pending_action` / `action_cell_index` / `action_deadline` 与新增 RPC。
- SQL 运行成功后，执行线上验收：
  - 双玩家 Tycoon 创建、加入、聊天、开始、掷骰、跳过、退出破产。
  - 房主移除玩家。
  - 8 秒超时自动跳过。
  - 刷新/重新进入后恢复状态。
  - 桌面和手机布局截图检查。
- 线上验收通过后，同步发布到 GitHub Pages。
