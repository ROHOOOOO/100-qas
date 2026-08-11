# 待办

- 已完成：运行 `node --check src/app.js`、`node scripts/verify-static.mjs`、`node scripts/verify-browser.mjs`。
- 已完成：用户在 Supabase SQL Editor 再次运行最新版 `supabase/schema.sql`，同步 `extensions.crypt` / `extensions.gen_salt` 修复。
- 已完成：重新执行 `scripts/verify-online.mjs`，验证账号注册/登录、记录归属、跨设备恢复和 PDF 下载。
- 如旧手机仍无法下载 PDF，追加 Web Share 文件分享方案作为移动端兜底。
- 已完成：用户在 Supabase SQL Editor 运行最新版 `supabase/schema.sql`，升级 `tycoon_rooms.pending_action` / `action_cell_index` / `action_deadline` 与新增 RPC。
- 已完成：线上验收通过，覆盖双玩家 Tycoon 创建、加入、聊天、开始、掷骰、跳过/自动换人、退出破产、重新进入恢复和最终结果。
- 已完成：线上专项验收房主移除玩家，测试房间 `A33652`。
- 已完成：线上专项验收 8 秒超时自动跳过，测试房间 `28CF70`。
- 后续可追加桌面房间页与手机房间页截图检查。
- 已完成：发布 Friends Tycoon 地图 UI 优化到 GitHub Pages，提交 `2ab74a25de146588467f6f09bf1019f43f42a88c`。
- 已完成：只读抓取线上 `src/app.js` 与 `src/styles.css`，确认地点详情代码和宽屏样式已上线。
- 后续仍建议补一次真实页面截图检查：桌面宽屏地图卡片尺寸、地点详情悬停/点击浮层、手机端底部详情浮层。
- 需要在 Supabase SQL Editor 运行最新版 `supabase/schema.sql`，让线上 Friends Tycoon 玩家颜色选择能够跨设备同步。
- 已完成：发布 Friends Tycoon 横向棋盘和颜色收敛方案到 GitHub Pages，提交 `da6b39cbcdc663c2975c532779a8a33228bea26e`。
- 需要查看线上页面：桌面宽屏棋盘是否已经明显变成长方形，地点名是否能读清；手机端点击地点详情是否正常。
