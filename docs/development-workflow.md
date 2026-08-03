# 开发执行标准

## 总原则

项目按小步推进：

1. 每一步只完成一个清晰目标。
2. 每一步都能运行或检查。
3. 不提前做大而复杂的功能。
4. 需求变化必须同步更新文档。
5. 每天必须记录完成事项和待办事项。

## 每日开发记录

每日开发文件夹位置：

```text
dev-days/YYYY-MM-DD/
```

每个开发日包含：

- `README.md`：当天目标和上下文。
- `done.md`：当天已完成事项。
- `todo.md`：当天待办事项。

当天开始工作时：

1. 如果当天文件夹不存在，先创建。
2. 阅读前一天的 `todo.md`。
3. 把今天准备做的小目标写入当天 `README.md` 或 `todo.md`。

当天结束工作时：

1. 把完成内容写入 `done.md`。
2. 把未完成内容写入 `todo.md`。
3. 如有需求或架构变化，更新 `docs/` 中对应文件。

## 自动化与手动兜底

项目包含一个每日记录辅助脚本：

```text
scripts/new-dev-day.sh
```

用途：

- 创建当天 `dev-days/YYYY-MM-DD/` 文件夹。
- 初始化 `README.md`、`done.md`、`todo.md`。
- 已存在时不覆盖已有记录。

Codex 也应在每天开发结束时自动更新当天记录。若自动化未执行，手动运行脚本并补写记录。

## 代码开发规则

- 第一阶段优先做零依赖本地原型。
- 不引入复杂框架，除非进入真实多人版本。
- 不一次性实现所有功能。
- 每次新增功能后，至少完成一次手动流程验证。
- 文件命名清晰，避免无意义缩写。
- 用户可见文案使用中文。

## 当前验证脚本

静态检查：

```bash
/Users/rohooooo/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node scripts/verify-static.mjs
```

检查内容：

- 题库数量为 100。
- 第 23 题为“现在想吃什么?”。
- 入口文件引用正确。
- 提交确认使用页面内弹窗。

完整浏览器流程：

```bash
/Users/rohooooo/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node scripts/verify-browser.mjs
```

检查内容：

- 创建房间。
- 输入昵称。
- 填写 100 题。
- 取消一次提交确认后不会提交。
- 再次确认提交后进入结果页。
- 提交后没有可编辑输入框。
- 结果页展示 100 个题目卡片和 100 条答案。
- 可新增第二个本地玩家。
- 未提交玩家不能查看结果。
- 可切回已提交玩家查看结果。
- 本地存储中玩家状态与答案数量正确。

## 变更记录规则

任何影响产品行为的变更，都要同步更新：

- `docs/product-requirements.md`
- `docs/technical-architecture.md`
- `docs/development-plan.md`
- 当天 `dev-days/YYYY-MM-DD/done.md`

任何影响视觉和交互的变更，都要同步更新：

- `docs/design-guidelines.md`
- 当天 `dev-days/YYYY-MM-DD/done.md`
