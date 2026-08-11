# 已完成

- 明确账号方案改为朋友账号名 + 密码，不再依赖邮箱验证码。
- 前端账号输入框 placeholder 已展示规则：
  - 账号名：`2-20位，支持中文/英文/数字/下划线`
  - 密码：`至少4位，请勿使用重要账号密码`
- 前端在线 RPC 已统一传入 `p_account_token`，用于多端找回玩家身份。
- Supabase SQL 新增 `game_accounts`、`game_account_sessions`、`account_register`、`account_login`、`account_logout`。
- Supabase SQL 将 Q&A 和 Tycoon 的账号归属从 `auth.users` 改为 `game_accounts`。
- `100 Q&As` 导出版新增 `下载 PDF`、`打开 PDF 预览`，保留 `打印 / 系统保存`。
- 自动验收脚本已更新，覆盖朋友账号、placeholder、PDF 直接下载和预览入口。
- 文档已同步账号与 PDF 导出新方案。
