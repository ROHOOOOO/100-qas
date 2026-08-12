# 2026-08-12 已完成事项

- 用户反馈最新版 `supabase/schema.sql` 已运行成功。
- 确认本轮 SQL 升级目标是 Friends Tycoon 玩家颜色同步：
  - `tycoon_players.color_id`
  - `tycoon_pick_color_id`
  - `tycoon_update_player_color`
- 保留前端兼容兜底：即使旧 SQL 未升级，创建/加入房间仍会回退到默认颜色流程。
- 执行线上 Supabase RPC 验证时发现：
  - `tycoon_create_room` 已能写入房主 `colorId`。
  - `tycoon_join_room` 已能避让被占用颜色。
  - `tycoon_update_player_color` 调用了不存在的旧辅助函数 `tycoon_require_player`，导致开局前修改颜色失败。
- 已修复 `supabase/schema.sql`：`tycoon_update_player_color` 改为直接按房间、玩家 key 或账号 token 校验玩家身份。
- 已更新 `scripts/verify-static.mjs`，防止 SQL 再次调用缺失的 `tycoon_require_player`。
- 已运行 `node --check src/app.js` 与 `node scripts/verify-static.mjs`，结果通过。
