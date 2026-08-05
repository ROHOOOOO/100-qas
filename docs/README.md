# docs 文件夹说明

这里存放项目开发相关的稳定标准文件。除非需求真的变化，否则开发时应遵循这些文件，而不是临时改变方向。

## 文件索引

- [product-requirements.md](product-requirements.md)：产品需求、用户流程、功能边界。
- [question-bank.md](question-bank.md)：100 个问题的正式题库。
- [friends-tycoon-requirements.md](friends-tycoon-requirements.md)：Friends Tycoon 的已确认玩法、UI 和后续待确认项。
- [account-and-export-requirements.md](account-and-export-requirements.md)：账号、多端同步和 PDF 导出需求。
- [technical-architecture.md](technical-architecture.md)：技术路线、数据模型、权限方案。
- [design-guidelines.md](design-guidelines.md)：视觉、交互、移动端设计规范。
- [development-workflow.md](development-workflow.md)：开发节奏、每日记录、变更规则。
- [development-plan.md](development-plan.md)：分阶段开发步骤。
- [deployment-guide.md](deployment-guide.md)：Supabase 与 GitHub Pages 上线说明。
- [acceptance-criteria.md](acceptance-criteria.md)：每个阶段如何判断完成。

## 使用规则

1. 产品功能以 `product-requirements.md` 为准。
2. 问题文案以 `question-bank.md` 为准。
3. 代码实现以 `technical-architecture.md` 和 `development-plan.md` 为准。
4. 页面表现以 `design-guidelines.md` 为准。
5. 每次开发完成后，必须更新 `dev-days/YYYY-MM-DD/`。
6. 如果实际实现和文档发生偏差，优先修正文档或代码，让两者重新一致。
