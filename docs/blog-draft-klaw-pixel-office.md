# 把 AI 助手搬进像素办公室：Star Office UI × Klaw 实践记录

> 让 AI 不再是一个看不见的黑盒——用像素风看板实时可视化 Agent 的工作状态。

## 前言：AI 到底在干什么？

自从在公司内部用上了 Klaw（基于 OpenClaw 的企业定制版 AI 助手），一个问题反复出现：**我让 AI 去做事了，但完全不知道它现在在干什么。**

等待的过程中你会忍不住猜测——是在搜索？在写代码？卡住了？还是已经完成了但没告诉我？

带着这个痛点，我发现了 [Star Office UI](https://github.com/ringhyacinth/Star-Office-UI) 这个开源项目——一个像素风格的 AI 办公室看板。它能把 AI 助手的实时状态映射成一只在办公室里走来走去的像素角色：写代码时坐到工位上、待命时窝在休息区沙发上、遇到 bug 就跑去 bug 区。

我决定把它和 Klaw 打通，让 AI 的工作过程真正"可见"。

---

## 一、Star Office UI 是什么

Star Office UI 是一个用 **Python Flask + Phaser.js** 构建的像素风实时看板：

- **前端**：基于 Phaser 3 游戏引擎渲染的 2D 像素办公室，角色根据状态在不同区域走动
- **后端**：Flask 提供 36 个 REST API，管理 Agent 注册、状态推送、资产管理等
- **协议简单**：所有交互都是标准 HTTP + JSON，任何能发请求的系统都能接入

它的核心设计非常清晰——**6 种状态映射到 3 个区域**：

| 状态 | 办公室区域 | 场景 |
|------|-----------|------|
| `idle` | 🛋 休息区 | 待命、任务完成 |
| `writing` | 💻 工作区 | 写代码、写文档 |
| `researching` | 💻 工作区 | 搜索、调研 |
| `executing` | 💻 工作区 | 执行命令 |
| `syncing` | 💻 工作区 | 同步数据 |
| `error` | 🐛 Bug 区 | 出错排查 |

还有一些温馨细节：

- **昨日小记**：自动从 `memory/` 目录读取按日期命名的 Markdown 文件，脱敏后展示工作要点 + 随机名句
- **多 Agent 协作**：通过 Join Key 机制，多个 AI 助手可以同时出现在同一间办公室
- **中英日三语**：一键切换界面语言
- **AI 装修**：接入 Gemini 用 AI 给办公室换背景

部署也很简单，5 行命令搞定：

```bash
git clone https://github.com/ringhyacinth/Star-Office-UI.git
cd Star-Office-UI
python3 -m pip install -r backend/requirements.txt
cp state.sample.json state.json
cd backend && python3 app.py
```

打开 `http://127.0.0.1:19000`，就能看到一间像素办公室了。

---

## 二、Klaw 集成方案设计

Star Office UI 本身是通用的——用 `set_state.py` 脚本或 API 都能推状态。但要和 Klaw 深度集成，我需要解决几个问题：

1. **自动状态同步**：不需要手动切状态，Klaw 做什么办公室就实时反映
2. **详情展示**：不只是"工作中"，要能看到具体在做什么——读哪个文件、搜什么关键词
3. **零配置安装**：其他同事不需要懂代码也能一键接入
4. **上下线管理**：Klaw 启动时自动加入，关闭时自动离开

### 方案：OpenClaw 插件

OpenClaw（Klaw 的上游开源项目）的插件系统提供了完整的 Agent 生命周期钩子。我写了一个 `kclaw-office-ui` 插件，hook 进 5 个关键事件：

```
gateway_start  → 加入办公室 + 启动心跳
gateway_stop   → 离开办公室
before_agent_start → 提取用户消息，设为 "executing"
before_tool_call   → 根据工具类型设置详细状态
agent_end      → 任务完成/出错，恢复 idle 或 error
```

**核心数据流：**

```
用户发消息 → Klaw 处理 → 插件 hook 触发 → HTTP POST → Star Office UI 后端 → 前端轮询渲染
```

整个过程对 Klaw 的主逻辑零侵入——插件的所有 HTTP 请求都设了超时和异常吞没，即使办公室后端挂了也不影响 AI 正常工作。

---

## 三、让状态有"细节"

最初的版本只能显示"工作中"这样的粗粒度状态，但实际使用中你更想知道**具体在做什么**。

我实现了一个 `buildToolDetail()` 函数，根据 Klaw 调用的工具名称和参数，提取人类可读的详情：

```typescript
function buildToolDetail(toolName: string, params: Record<string, unknown>): string {
  // browser → 提取 URL
  if (toolName === "browser") return `浏览 ${extractDomain(params.url)}`;
  // read_file → 提取文件名
  if (toolName === "read_file") return `读取 ${basename(params.path)}`;
  // bash → 提取命令
  if (toolName === "bash") return `执行 ${truncate(params.command)}`;
  // search → 提取关键词
  if (toolName === "search") return `搜索 "${params.query}"`;
  // ...
}
```

效果是这样的——前端气泡会显示：

- `读取 game.js`（正在看代码）
- `搜索 "chart library"`（正在调研）
- `执行 npm install`（正在跑命令）
- `浏览 stackoverflow.com`（正在查资料）

比单纯的"工作中"有意义多了。

---

## 四、让安装变成一句话

技术方案搞定后，最大的挑战变成了**分发**。总不能让每个同事都克隆仓库、手动编辑配置文件。

### 方案一：一键安装脚本

写了一个 Shell 脚本，嵌入了完整的插件源码：

```bash
bash install-klaw-plugin.sh http://office.example.com:19000 ocj_xxx "我的龙虾"
```

脚本会：
1. 在 `~/.openclaw/extensions/kclaw-office-ui/` 下创建 3 个插件文件
2. 用 Python 直接操作 JSON 配置（不依赖 `openclaw` CLI）
3. 提示重启 Klaw 生效

### 方案二：对话式安装（更有趣）

既然 Klaw 本身就是个 AI 助手，为什么不能让它自己帮用户完成安装？

我写了一个 SKILL.md，安装到 `~/.openclaw/skills/join-office/`。用户只需要对 Klaw 说：

> "帮我加入像素办公室"

Klaw 就会：
1. 询问办公室地址和 Join Key
2. 自动创建插件文件
3. 更新配置
4. 测试连通性
5. 提示重启

**用 AI 安装 AI 插件**——这可能是最符合 AI-first 理念的安装方式了。

---

## 五、多 Agent 同屏

一个人的办公室太冷清。Star Office UI 的 Join Key 机制天然支持多 Agent：

- 每个 Join Key 有并发上限（`maxConcurrent`），默认 3
- 不同的 Klaw 实例使用不同的 Key 加入
- 每个 Agent 有独立的名字、状态、头像、区域

效果就是，办公室里能同时看到多只"龙虾"：有的在工位写代码，有的在休息区待命，有的跑去 bug 区排查问题——像一个真正在运转的小团队。

对于演示场景，也可以用 API 模拟：

```bash
curl -X POST http://127.0.0.1:19000/join-agent \
  -H "Content-Type: application/json" \
  -d '{"name": "小红", "joinKey": "ocj_demo", "state": "idle", "detail": "摸鱼中"}'
```

办公室瞬间热闹起来。

---

## 六、架构总览

```
┌──────────────────────────────────────────────────┐
│  用户                                              │
│  打开浏览器 → http://office:19000                   │
└────────────────────┬─────────────────────────────┘
                     │  轮询 /agents, /status
                     ▼
┌──────────────────────────────────────────────────┐
│  Star Office UI (Flask + Phaser.js)               │
│                                                    │
│  ┌──────────┐  ┌─────────┐  ┌──────────────────┐ │
│  │ Agent 管理 │  │状态存储  │  │ 昨日小记 / 装修  │ │
│  │ join/push │  │state.json│  │ memory/*.md      │ │
│  └────┬─────┘  └─────────┘  └──────────────────┘ │
└───────┼──────────────────────────────────────────┘
        │  HTTP POST (join/push/leave)
        │
┌───────┴──────────────────────────────────────────┐
│  Klaw (OpenClaw 插件: kclaw-office-ui)            │
│                                                    │
│  gateway_start ──→ 加入办公室 + 心跳               │
│  before_agent_start ──→ 设置 "executing"           │
│  before_tool_call ──→ 细粒度状态 + 详情             │
│  agent_end ──→ idle / error                        │
│  gateway_stop ──→ 离开办公室                        │
└──────────────────────────────────────────────────┘
```

---

## 七、踩过的坑

### 1. 配置路径的归属

Star Office UI 的后端在确定 `MEMORY_DIR` 时，用的是项目根目录的**上级**目录：

```python
MEMORY_DIR = os.path.join(os.path.dirname(ROOT_DIR), "memory")
```

所以 `memory/` 文件夹不是在项目内部，而是在项目旁边。初次排查"昨日小记为空"时被这里绊了一下。

### 2. 插件 import 路径

开发时 `kclaw-office-ui` 直接引用了相对路径 `../../src/plugins/types.js`，本地跑没问题。但打包分发后路径断了。改成标准的 `import type { OpenClawPluginApi } from "openclaw/plugin-sdk"` 后解决。

### 3. 状态推送去重

如果不做去重，Klaw 每次心跳都会推送一样的状态，导致前端频繁刷新。加了简单的 `lastPushedState + lastPushedDetail` 比对，只在状态真正变化时才推送。

### 4. 错误状态自恢复

Agent 出错时设为 `error` 状态没问题，但如果一直留在 bug 区就不对了。加了一个 60 秒后自动回 `idle` 的定时器，配合前端的 `"刚完成: ..."` 提示，体验更自然。

---

## 八、后续计划

- [ ] **npm publish**：把插件发布到 npm，`openclaw plugin install kclaw-office-ui` 一行搞定
- [ ] **Docker 一键部署**：已经写好了 Dockerfile，计划推到 Docker Hub
- [ ] **中心化托管**：提供一个公共的 Star Office UI 实例，注册即用
- [ ] **更多细节展示**：比如代码 diff 预览、搜索结果摘要等
- [ ] **桌面版**：项目自带 Electron 桌面宠物版，可以把办公室放在桌面上常驻

---

## 九、总结

Star Office UI 把"AI 在做什么"这个抽象问题变成了一个可爱且直观的像素画面。而 Klaw 插件让这个画面与 AI 的真实工作流完全同步——不是模拟，是实时反映。

整个集成过程的工作量并不大（核心插件约 300 行 TypeScript），但带来的体验提升很明显：**你终于能"看见" AI 在工作了**。

如果你也在用 OpenClaw 或其他支持插件的 AI 助手，推荐试试这个项目。即使不接入 AI，单独作为一个像素风状态看板也很有趣。

---

## 附录：五分钟开一间属于你的像素办公室

### 第一步：开设办公室（主人）

部署 Star Office UI：

```bash
git clone https://github.com/ringhyacinth/Star-Office-UI.git
cd Star-Office-UI
pip install -r backend/requirements.txt
cp state.sample.json state.json
cp join-keys.sample.json join-keys.json
cd backend && python3 app.py
```

编辑根目录的 `join-keys.json`，添加一个邀请码：

```json
{
  "keys": [
    {
      "key": "ocj_myteam_01",
      "reusable": true,
      "maxConcurrent": 10
    }
  ]
}
```

然后把这两样东西发给团队成员：

- **办公室地址**：`http://你的局域网IP:19000`（或公网地址）
- **邀请码**：`ocj_myteam_01`

> 成员可以先访问 `http://你的IP:19000/health`，看到 `"status":"ok"` 就说明网络通了。

---

### 第二步：加入办公室（成员）

Star Office UI 内置了技能分发接口，成员只需对自己的 Klaw 说**一句话**：

```
帮我把 http://办公室IP:19000/skill.md 下载保存到
~/.openclaw/skills/join-office/SKILL.md，
然后加入像素办公室 http://办公室IP:19000 ocj_myteam_01 我的昵称
```

Klaw 会自动完成：
1. 下载并安装 `join-office` 技能
2. 创建 `kclaw-office-ui` 插件文件（3 个文件写入 `~/.openclaw/extensions/`）
3. 更新 `~/.openclaw/openclaw.json` 配置
4. 验证连通性
5. 提示重启

重启 Klaw 后，成员的小龙虾就会出现在办公室里。

---

### 第三步：查看在线成员（主人）

浏览器打开 `http://localhost:19000` 直接看看板，或者问 Klaw：

> "办公室里现在有谁？"

Klaw 会查询 `/agents` 接口并列出所有在线成员的名字、状态和最后活动时间。

---

### 常见问题

**Q：成员在局域网外怎么加入？**  
A：需要内网穿透（Tailscale、frp 等）或把 Star Office UI 部署到公网服务器。Docker 方式部署更方便：`docker compose up -d`。

**Q：办公室名字怎么改？**  
A：编辑 `~/.openclaw/workspace/IDENTITY.md` 中的 `Name` 字段，格式会自动变成「XXX的办公室」。

**Q：我的 Klaw 在办公室里的名字怎么改？**  
A：直接对 Klaw 说"把我在像素办公室的名字改成 XXX"，或手动编辑 `~/.openclaw/openclaw.json` 中 `plugins.entries.kclaw-office-ui.config.agentName`。

---

**相关链接：**
- Star Office UI：https://github.com/ringhyacinth/Star-Office-UI
- OpenClaw：https://github.com/openclaw/openclaw

---

*本文作者日常使用 Klaw（快手内部 AI 助手）进行开发工作，文中涉及的实践均在公司内部环境验证。*
