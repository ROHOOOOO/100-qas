# 100 Q&As

给熟人朋友玩的私密网页问答游戏。每位参与者独立回答 100 个问题，完成提交后才能查看同一房间内其他朋友的答案。

## 项目文件指引

- 产品需求：[docs/product-requirements.md](docs/product-requirements.md)
- 100 题题库：[docs/question-bank.md](docs/question-bank.md)
- 技术架构：[docs/technical-architecture.md](docs/technical-architecture.md)
- 设计规范：[docs/design-guidelines.md](docs/design-guidelines.md)
- 开发执行标准：[docs/development-workflow.md](docs/development-workflow.md)
- 分步开发计划：[docs/development-plan.md](docs/development-plan.md)
- 上线与分享指南：[docs/deployment-guide.md](docs/deployment-guide.md)
- 验收标准：[docs/acceptance-criteria.md](docs/acceptance-criteria.md)
- 每日开发记录：[dev-days/](dev-days/)
- 对外交付文件：[outputs/](outputs/)

## 工作说明

开发遵循“小步推进、每步可验证”的原则。

每次开始开发前：

1. 先阅读 `README.md` 和 `docs/README.md`。
2. 确认当前阶段对应的 `docs/development-plan.md`。
3. 查看当天 `dev-days/YYYY-MM-DD/` 下的完成事项和待办事项。

每次完成开发后：

1. 更新当天 `done.md`。
2. 更新当天 `todo.md`。
3. 如需求、技术、设计规则发生变化，同步更新 `docs/` 中对应标准文件。
4. 在最终回复中说明完成了什么、验证了什么、下一步建议做什么。

## 当前状态

截至 2026-08-03：

- 已读取并整理用户提供的 `100 Q&As.docx`。
- 已确认 MVP 需求。
- 已确定第一版不做账号系统，采用私密房间 + 昵称 + 本地身份密钥。
- 已确认每页 5 题，共 20 页。
- 已确认提交后不可修改。
- 已确认结果页默认按题目查看大家答案。
- 已修正第 23 题为“现在想吃什么?”。
- 已创建阶段 1 本地交互原型基础文件。
- 已完成创建房间、加入昵称、分页答题、草稿保存的冒烟验证。
- 已完成 100 题填满、提交确认、提交锁定、结果页展示的完整自动化验证。
- 已完成本地多人模拟：可新增/切换本地玩家，展示房间人数和提交人数，并验证未提交玩家不能查看结果。
- 已加入 Supabase 在线模式配置入口，支持后续部署到 GitHub Pages 后直接多人在线填写。

## 验证命令

```bash
/Users/rohooooo/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node scripts/verify-static.mjs
/Users/rohooooo/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node scripts/verify-browser.mjs
```
