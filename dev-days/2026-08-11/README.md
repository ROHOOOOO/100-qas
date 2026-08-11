# 2026-08-11 开发日

## 今日主题

- 修正账号体系：从 Supabase Auth 邮箱登录改为 Friends Games 轻量账号名 + 密码。
- 完善 `100 Q&As` PDF 导出：直接下载 PDF、打开预览、保留打印兜底。
- 记录用户补充要求：账号规则需直接展示在输入框空态 placeholder 中。

## 相关文档

- 账号与导出需求：`docs/account-and-export-requirements.md`
- 技术架构：`docs/technical-architecture.md`
- 验收标准：`docs/acceptance-criteria.md`
- 部署说明：`docs/deployment-guide.md`
- 数据库脚本：`supabase/schema.sql`

## 工作说明

- 先在本地完成代码与静态验收。
- 线上发布前，必须先在 Supabase SQL Editor 运行最新版 `supabase/schema.sql`。
- SQL 运行成功后，再发布 GitHub Pages 并执行线上验收。
