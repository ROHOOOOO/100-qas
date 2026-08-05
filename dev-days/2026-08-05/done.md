# 已完成

- 确认账号第一版采用邮箱 + 密码；手机号入口预留，等短信服务配置后再正式启用。
- 确认登录后支持绑定当前设备匿名记录到账号。
- 确认 100 Q&As PDF 导出范围为“所有已提交玩家的答案”。
- 新增顶部导航的账号入口，未登录显示“登录”，登录后进入“我的记录”。
- 实现 Supabase Auth 邮箱 + 密码登录、注册、退出和 session 刷新。
- 新增“我的记录”页面，支持查看账号下的 100 Q&As 与 Friends Tycoon 房间。
- 新增绑定当前设备匿名记录到当前登录账号的流程。
- 新增 100 Q&As 结果页 `导出 PDF` 按钮和 `#qa/export/:code` 打印排版页。
- 更新 `supabase/schema.sql`，加入账号归属字段、登录账号授权、`account_bind_records`、`account_get_records`。
- 更新本地/线上验证脚本，覆盖账号入口和 PDF 导出页。
- 通过 `node scripts/verify-static.mjs` 静态验证。
- 通过 `node --check` 检查 `src/app.js` 与验证脚本语法。
- 通过 `node scripts/verify-browser.mjs` 本地完整浏览器验收：Friends Tycoon、100 Q&As、PDF 导出、账号记录页和移动端大厅均通过。
- 用户已在 Supabase SQL Editor 运行最新版 `supabase/schema.sql`，反馈运行成功。
- 已通过 GitHub API 发布到 GitHub `main`，提交为 `f85a0a3 Add account records and QA PDF export`。
- 已确认 GitHub Pages `src/app.js` 可访问新版账号代码。
- 已通过 `scripts/verify-online.mjs` 线上验收：100 Q&As 测试房间 `6D2763` 跑通 3 题双玩家提交和 PDF 导出，Friends Tycoon 测试房间 `9592F8` 跑通退出破产、最终结果和聊天清空。
- 修复注册/登录失败时的前端提示，明确显示邮件限流、邮箱不可用、邮箱未确认、密码太短等原因。
