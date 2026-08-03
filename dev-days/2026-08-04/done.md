# 已完成

- 用户在 Supabase SQL Editor 运行 `supabase/schema.sql`，返回 `Success. No rows returned.`。
- 通过 Supabase RPC 探测确认 `qa_get_room` 函数已经可访问。
- 新增 `scripts/verify-online.mjs`，用于验证 GitHub Pages 线上网页和 Supabase 后端的完整答题流程。
- 完成线上双玩家自动化验收：测试房间 `0AE672` 中 2 位玩家均提交 100 题，结果页显示 100 个题目卡和 200 条答案。
- 验证提交后不可修改：结果页没有可编辑输入框，并显示答案锁定状态。
- 验证移动端首页首屏可正常显示创建房间入口和视觉图片。
- 更新 `README.md` 和 `docs/deployment-guide.md`，记录当前线上已可用状态和线上验收命令。
