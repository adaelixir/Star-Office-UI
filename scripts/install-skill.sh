#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────
# Star Office UI — Install the "join-office" skill for Klaw
#
# This installs a skill that lets you configure the pixel office
# plugin just by chatting with Klaw. No code editing needed.
#
# Usage:
#   bash install-skill.sh
#
# After running this, tell Klaw:
#   "帮我加入像素办公室 <url> <join-key>"
# ─────────────────────────────────────────────────────────────────
set -euo pipefail

SKILL_DIR="${HOME}/.openclaw/skills/join-office"

if [[ ! -d "${HOME}/.openclaw" ]]; then
  echo "❌ 未找到 ~/.openclaw 目录。请先安装并启动一次 Klaw。"
  exit 1
fi

mkdir -p "$SKILL_DIR"

echo "📦 正在安装 join-office skill ..."

# Download SKILL.md from the repo (or write inline)
# For offline/self-hosted use, the file is written inline below.
cat > "$SKILL_DIR/SKILL.md" << 'SKILLEOF'
---
openclaw:
  always: false
  emoji: 🏢
  invocation:
    userInvocable: true
---

# 加入像素办公室（Star Office UI）

当用户说"加入像素办公室"、"join office"、"配置办公室看板"等类似意思时，按照下面步骤执行。

## 你需要向用户确认的信息

只需要两个（第三个可选）：

1. **办公室地址** — Star Office UI 的 URL（例如 `http://192.168.1.100:19000` 或 `https://office.example.com`）
2. **加入密钥** — join key（格式 `ocj_xxx`，由办公室主人提供）
3. **显示名字**（可选）— 你在办公室里显示的名字，默认用 "Klaw"

如果用户一次性给了这些信息（比如"加入 http://xxx ocj_xxx 小明"），直接继续，不要多问。

## 执行步骤

### Step 1: 写入插件文件

在 `~/.openclaw/extensions/kclaw-office-ui/` 目录下创建 3 个文件。

**文件 1: `package.json`**
```json
{
  "name": "kclaw-office-ui",
  "version": "0.1.0",
  "description": "Star Office UI integration for Klaw",
  "type": "module",
  "license": "MIT",
  "peerDependencies": { "openclaw": "*" },
  "openclaw": { "extensions": ["./index.ts"] }
}
```

**文件 2: `openclaw.plugin.json`**
```json
{
  "id": "kclaw-office-ui",
  "name": "Kclaw Office UI",
  "description": "Star Office UI integration — shows Klaw agent state in the pixel office dashboard",
  "configSchema": {
    "type": "object",
    "properties": {
      "officeUrl": { "type": "string" },
      "joinKey": { "type": "string" },
      "agentName": { "type": "string" },
      "pushInterval": { "type": "number" }
    }
  }
}
```

**文件 3: `index.ts`**

写入以下完整插件代码（这是核心，不要省略任何部分）：

```typescript
import type { OpenClawPluginApi } from "openclaw/plugin-sdk";
type AgentState = "idle" | "writing" | "researching" | "executing" | "syncing" | "error";
async function officePost(url: string, path: string, body: Record<string, unknown>): Promise<unknown> {
  try { const res = await fetch(`${url.replace(/\/$/, "")}${path}`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body), signal: AbortSignal.timeout(8_000) }); return await res.json(); } catch { return null; }
}
function toolNameToState(toolName: string): AgentState {
  const name = toolName.toLowerCase();
  if (["search","read","get","fetch","list","query","find"].some(k => name.includes(k))) return "researching";
  if (["write","edit","create","update","push","send","post"].some(k => name.includes(k))) return "writing";
  return "executing";
}
function buildToolDetail(toolName: string, params: Record<string, unknown>): string {
  const name = toolName.toLowerCase(); const str = (v: unknown) => (typeof v === "string" && v.trim() ? v.trim() : null); const basename = (p: string) => p.split(/[/\\]/).filter(Boolean).pop() ?? p;
  if (["browser","navigate","open_url","fetch"].some(k => name.includes(k))) { const url = str(params.url) ?? str(params.href); if (url) { try { const u = new URL(url); return `打开 ${u.hostname}`; } catch { return `打开 ${url.slice(0,50)}`; } } }
  if (["read","view_file","cat"].some(k => name.includes(k))) { const p = str(params.path) ?? str(params.file); if (p) return `读取 ${basename(p)}`; }
  if (["write","edit","create_file","update_file"].some(k => name.includes(k))) { const p = str(params.path) ?? str(params.file); if (p) return `写入 ${basename(p)}`; }
  if (["bash","shell","run_command","execute"].some(k => name.includes(k))) { const cmd = str(params.command) ?? str(params.cmd); if (cmd) return `运行 ${cmd.slice(0,50)}`; }
  if (["search","grep","find"].some(k => name.includes(k))) { const q = str(params.query) ?? str(params.pattern); if (q) return `搜索 "${q.slice(0,40)}"`; }
  if (["send","message","reply"].some(k => name.includes(k))) { const msg = str(params.message) ?? str(params.text); if (msg) return `发送: ${msg.slice(0,45)}`; }
  for (const [k, v] of Object.entries(params)) { const s = str(v); if (s && s.length > 3 && !["type","format","mode"].includes(k)) return `${toolName}: ${s.slice(0,45)}`; }
  return `调用 ${toolName}`;
}
const plugin = { id: "kclaw-office-ui", name: "Kclaw Office UI", description: "Pushes Klaw agent state to Star Office UI pixel dashboard",
  register(api: OpenClawPluginApi) {
    const raw = (api.pluginConfig ?? {}) as Record<string, unknown>;
    const officeUrl = typeof raw.officeUrl === "string" ? raw.officeUrl.trim() : "";
    const joinKey = typeof raw.joinKey === "string" ? raw.joinKey.trim() : "";
    const agentName = typeof raw.agentName === "string" ? raw.agentName.trim() : "Klaw";
    const pushInterval = typeof raw.pushInterval === "number" && raw.pushInterval > 0 ? raw.pushInterval : 15_000;
    if (!officeUrl || !joinKey) { api.logger.warn("kclaw-office-ui: officeUrl and joinKey required. Plugin disabled."); return; }
    let agentId: string | null = null; let heartbeatTimer: ReturnType<typeof setInterval> | null = null; let lastPushedState: AgentState = "idle"; let lastPushedDetail = ""; let lastUserMessage = "";
    async function joinOffice(): Promise<void> { const res = (await officePost(officeUrl, "/join-agent", { name: agentName, joinKey, state: "idle", detail: "刚刚上线" })) as Record<string, unknown> | null; if (res?.ok) { agentId = String(res.agentId ?? ""); api.logger.info?.(`kclaw-office-ui: joined, agentId=${agentId}`); } else { api.logger.warn(`kclaw-office-ui: join failed`); } }
    async function leaveOffice(): Promise<void> { if (!agentId) return; await officePost(officeUrl, "/leave-agent", { agentId, name: agentName }); agentId = null; }
    async function pushState(state: AgentState, detail = ""): Promise<void> { if (state === lastPushedState && detail === lastPushedDetail) return; if (!agentId) { await joinOffice(); if (!agentId) return; } const res = (await officePost(officeUrl, "/agent-push", { agentId, joinKey, name: agentName, state, detail })) as Record<string, unknown> | null; if (res?.ok) { lastPushedState = state; lastPushedDetail = detail; } else if (res && typeof res === "object" && "msg" in res && typeof res.msg === "string" && (res.msg.includes("未注册") || res.msg.includes("join"))) { await joinOffice(); if (agentId) { await officePost(officeUrl, "/agent-push", { agentId, joinKey, name: agentName, state, detail }); lastPushedState = state; lastPushedDetail = detail; } } }
    function startHeartbeat(): void { if (heartbeatTimer) return; heartbeatTimer = setInterval(async () => { if (agentId) await officePost(officeUrl, "/agent-push", { agentId, joinKey, name: agentName, state: lastPushedState, detail: lastPushedDetail }); }, pushInterval); }
    function stopHeartbeat(): void { if (heartbeatTimer) { clearInterval(heartbeatTimer); heartbeatTimer = null; } }
    api.on("gateway_start", async () => { await joinOffice(); startHeartbeat(); });
    api.on("gateway_stop", async () => { stopHeartbeat(); await leaveOffice(); });
    api.on("before_agent_start", async (event) => { let detail = "思考中..."; const msgs = event.messages; if (Array.isArray(msgs) && msgs.length > 0) { for (let i = msgs.length - 1; i >= 0; i--) { const m = msgs[i] as Record<string, unknown>; if (m?.role === "user") { const content = m.content; const text = typeof content === "string" ? content : Array.isArray(content) ? (content as Array<Record<string, unknown>>).filter(c => c?.type === "text").map(c => c.text as string).join(" ") : ""; if (text.trim()) { detail = text.trim().slice(0, 80); lastUserMessage = detail; } break; } } } await pushState("executing", detail); });
    api.on("before_tool_call", async (event) => { await pushState(toolNameToState(event.toolName ?? ""), buildToolDetail(event.toolName ?? "", event.params ?? {})); });
    api.on("agent_end", async (event) => { if (event.success) { await pushState("idle", lastUserMessage ? `刚完成: ${lastUserMessage.slice(0, 60)}` : "待命中"); } else { await pushState("error", event.error ? event.error.slice(0, 80) : "执行出错"); setTimeout(() => { pushState("idle", "待命中").catch(() => {}); }, 60_000); } });
    api.logger.info?.(`kclaw-office-ui: loaded (office=${officeUrl}, agent=${agentName})`);
  },
};
export default plugin;
```

### Step 2: 更新 Klaw 配置

读取 `~/.openclaw/openclaw.json`，用 Python 更新 JSON：

```python
import json, os
config_path = os.path.expanduser("~/.openclaw/openclaw.json")
with open(config_path, "r") as f:
    cfg = json.load(f)
cfg.setdefault("plugins", {})
cfg["plugins"].setdefault("load", {})
cfg["plugins"]["load"].setdefault("paths", [])
cfg["plugins"].setdefault("entries", {})
plugin_dir = os.path.expanduser("~/.openclaw/extensions/kclaw-office-ui")
if plugin_dir not in cfg["plugins"]["load"]["paths"]:
    cfg["plugins"]["load"]["paths"].append(plugin_dir)
cfg["plugins"]["entries"]["kclaw-office-ui"] = {
    "enabled": True,
    "config": {
        "officeUrl": "<用户提供的 URL>",
        "joinKey": "<用户提供的 key>",
        "agentName": "<用户提供的名字或默认 Klaw>"
    }
}
with open(config_path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
```

### Step 3: 验证连通性

```bash
curl -s <办公室URL>/health
```

如果返回 `"status":"ok"`，告诉用户一切就绪。

### Step 4: 提示重启

> ✅ 配置完成！重启 Klaw 后你就会出现在像素办公室里了。
>
> **macOS：** 点击菜单栏 Klaw 图标 → 重启
> **命令行：** `openclaw gateway restart`

## 卸载

如果用户想退出：
```bash
rm -rf ~/.openclaw/extensions/kclaw-office-ui
```
然后从 `~/.openclaw/openclaw.json` 删除相关配置，重启即可。
SKILLEOF

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Skill 安装完成！"
echo ""
echo "  现在跟 Klaw 说："
echo ""
echo '  💬 "帮我加入像素办公室 http://xxx:19000 ocj_xxx"'
echo ""
echo "  Klaw 会自动帮你配置好一切，不需要改任何代码！"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
