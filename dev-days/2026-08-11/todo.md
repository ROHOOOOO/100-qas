# 待办

- 已完成：运行 `node --check src/app.js`、`node scripts/verify-static.mjs`、`node scripts/verify-browser.mjs`。
- 已完成：用户在 Supabase SQL Editor 再次运行最新版 `supabase/schema.sql`，同步 `extensions.crypt` / `extensions.gen_salt` 修复。
- 已完成：重新执行 `scripts/verify-online.mjs`，验证账号注册/登录、记录归属、跨设备恢复和 PDF 下载。
- 如旧手机仍无法下载 PDF，追加 Web Share 文件分享方案作为移动端兜底。
- 已完成：用户在 Supabase SQL Editor 运行最新版 `supabase/schema.sql`，升级 `tycoon_rooms.pending_action` / `action_cell_index` / `action_deadline` 与新增 RPC。
- 已完成：线上验收通过，覆盖双玩家 Tycoon 创建、加入、聊天、开始、掷骰、跳过/自动换人、退出破产、重新进入恢复和最终结果。
- 后续可追加更细的线上专项验收：
  - 房主移除玩家。
  - 8 秒超时自动跳过。
  - 桌面房间页与手机房间页截图检查。
