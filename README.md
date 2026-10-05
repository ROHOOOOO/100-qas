# Friends Games

给熟人朋友玩的私密网页小游戏集合。当前源码包含 `100 Q&As`、`Friends Tycoon`、`What’s Next?` 和 `Board Games`。

`100 Q&As` 是问答游戏：每位参与者独立回答同一房间的一组问题，完成提交后才能查看同一房间内其他朋友的答案。默认题库是 100 题，自定义题库支持 1 到 100 题。

`Friends Tycoon` 是文字版线上大富翁：支持 2 到 6 位朋友同房间游玩，房主开始/重开/解散，轮流掷骰、买地、升级，聊天区与游戏记录分开。

## 2026-10-03 功能更新

- 新增 **What’s Next?** 随机转盘模块，支持共同抽取、各自抽取及房间共享历史。
- 三个模块统一要求登录，登录状态在同一浏览器中记忆并自动续期。
- 已完成实现及隔离环境验收；正式网站需要先升级 Supabase SQL，再发布前端。完整规格见 [What’s Next? 产品需求](docs/whats-next-requirements.md)。

## 2026-10-04 账号更新

- 登录账号与游戏用户名分开，用户名允许重复，可在“我的记录 → 账号设置”修改。
- 游戏自动使用用户名，不再重复输入房间昵称；已有历史保留当时名称。
- 注册时设置一个密保问题，从登录页的“忘记密码”可以重设密码，成功后所有设备需要重新登录。
- 文案统一为“所有功能共用账号”。本轮没有旧账号补填流程。
- 新版源码待发布，需要配套运行最新版 `supabase/schema.sql`。

本地体验：[登录](http://127.0.0.1:8000/?backend=local#account)、[注册](http://127.0.0.1:8000/?backend=local#account/register)、[找回密码](http://127.0.0.1:8000/?backend=local#account/recover)。试玩账号只保存在当前浏览器。

## 2026-10-04 转盘与输入调整

- 密保答案支持中文、英文和数字混合输入，默认显示，可切换隐藏。
- 转盘选项与抽取历史可分别折叠，默认收起，记住本浏览器每个房间的状态。
- 动画接续上次角度，圈数与落点有所变化；抽取规则仍是等概率、独立、允许重复。
- 本地与数据库版本共 100,000 次隔离抽取样本未发现明显分布或相邻重复异常，明细见当天开发记录。

## 2026-10-04 棋类大厅

- **Board Games** 首版含五子棋和中国象棋：好友双人房间，或房主添加简单/普通/困难电脑。
- 登录后准备、开局；首局随机先手，下一局交换。支持悔棋、求和、认输；对手离线满 5 分钟可结束为中断，不计胜负。
- 账号保存棋房、结果与完整事件棋谱；可逐步、拖动进度或自动回放，包括悔棋过程。
- 详见 [棋类需求与规则](docs/board-games-requirements.md)。[本地试玩](http://127.0.0.1:8000/?backend=local#board)仅保存在当前浏览器。好友跨设备联机需要先升级 Supabase 并发布此版本。

## 2026-10-05 五种棋与房间聊天

- 补齐国际象棋、飞行棋与跳棋，支持好友或简单/普通/困难电脑；跳棋可选 2/3/4/6 人，飞行棋可选 2–4 人。
- 飞行棋和跳棋继续到完整排名，保存结果及逐步回放；飞行棋可手动托管、回合结束接回，离开与托管独立。
- 五种棋均有持续房间聊天，支持中文、英文和表情，换局后历史仍在，可折叠并保留发送失败的文字。
- 最新源码用于本地预览；正式联机仍需升级完整 SQL 后发布。详见 [已确认规则](docs/board-games-requirements.md)。

## 项目文件指引

- 产品需求：[docs/product-requirements.md](docs/product-requirements.md)
- 默认 100 题题库：[docs/question-bank.md](docs/question-bank.md)
- Friends Tycoon 需求：[docs/friends-tycoon-requirements.md](docs/friends-tycoon-requirements.md)
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

## 早期开发记录

以下为 2026-08-04 的历史状态，账号与转盘以本页最新更新为准：

- 已读取并整理用户提供的 `100 Q&As.docx`。
- 已确认项目整体名称升级为 `Friends Games`，`100 Q&As` 与 `Friends Tycoon` 为并列小游戏。
- 已新增游戏大厅和顶部导航入口。
- 已新增 `Friends Tycoon` 创建/加入入口和本地可玩 MVP。
- 已实现 `Friends Tycoon` 2 人本地闭环：创建房间、加入、房主开始、掷骰、结束回合、退出即破产、刷新恢复、最终结果。
- 已更新 `supabase/schema.sql`，加入 `Friends Tycoon` 线上多人所需的 `tycoon_*` 表和 RPC；线上 Tycoon 需要运行最新版 SQL 后再验收。
- Friends Games 游戏大厅已发布到 GitHub Pages，并通过线上双玩家回归验收。
- 已确认 MVP 需求。
- 已确定第一版不做账号系统，采用私密房间 + 昵称 + 本地身份密钥。
- 已确认每页 5 题；默认 100 题共 20 页，自定义题库页数按题量变化。
- 已确认提交后不可修改。
- 已确认结果页默认按题目查看大家答案。
- 已修正第 23 题为“现在想吃什么?”。
- 已支持创建房间时绑定题库：默认题库或 1 到 100 题的自定义题库。
- 已支持自定义题库粘贴和 `.txt` / `.md` / `.csv` 纯文本文件上传。
- 已创建阶段 1 本地交互原型基础文件。
- 已完成创建房间、加入昵称、分页答题、草稿保存的冒烟验证。
- 已完成填满当前题库、提交确认、提交锁定、结果页展示的完整自动化验证。
- 已完成本地多人模拟：可新增/切换本地玩家，展示房间人数和提交人数，并验证未提交玩家不能查看结果。
- 已加入 Supabase 在线模式配置入口，支持后续部署到 GitHub Pages 后直接多人在线填写。
- GitHub 仓库已创建：[ROHOOOOO/100-qas](https://github.com/ROHOOOOO/100-qas)
- GitHub Pages 已发布：[https://rohooooo.github.io/100-qas/](https://rohooooo.github.io/100-qas/)
- Supabase 数据库 SQL 已运行。
- 线上双玩家完整验收已通过：创建房间、加入昵称、填写题库、提交锁定、结果页按题展示 2 位玩家答案。
- 房间级自定义题库 SQL 已运行，线上自定义题库双玩家验收已通过。
- 最新规则已改为自定义题库 1 到 100 题；线上 3 题自定义题库双玩家验收已通过。
- Friends Games 游戏大厅和 Friends Tycoon 入口已上线；线上测试房间 `D51B22` 已验证 2 位玩家提交 3 题成功。

## 本地预览

项目主目录：`/Users/rohooooo/Developer/100Q&As`（不在 iCloud 的桌面或文稿目录中）。

```bash
cd "/Users/rohooooo/Developer/100Q&As"
python3 -m http.server 8000 --bind 127.0.0.1
```

访问 [What’s Next? 本地试玩](http://127.0.0.1:8000/?backend=local#spin)，注册一个试玩账号即可创建转盘。本地账号、房间和历史仅存在当前浏览器，与正式网站分开。刷新后保持登录；在“我的记录”重新进入房间。

## 当前上线状态

原有版本已上线并接入 Supabase。本次 What’s Next? 与统一登录的改动尚未发布：

[https://rohooooo.github.io/100-qas/](https://rohooooo.github.io/100-qas/)

## 验证命令

```bash
node scripts/verify-static.mjs
node scripts/verify-browser.mjs
QA_ONLINE_URL="测试站点地址" node scripts/verify-online.mjs
QA_ONLINE_URL="测试站点地址" node scripts/verify-whats-next.mjs
QA_ONLINE_URL="测试站点地址" node scripts/verify-account.mjs
QA_ONLINE_URL="测试站点地址" node scripts/verify-spin-controls.mjs
```

数据库回归使用独立的 PGlite 内存数据库，具体依赖与命令见 [部署指南](docs/deployment-guide.md#验证命令)。
