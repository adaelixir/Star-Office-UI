#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────
# Star Office UI — Klaw Plugin one-click installer
#
# Usage:
#   bash install-klaw-plugin.sh <office-url> <join-key> [agent-name]
#
# Example:
#   bash install-klaw-plugin.sh https://office.example.com ocj_abc123 "My Bot"
#
# What it does:
#   1. Creates plugin files in ~/.openclaw/extensions/kclaw-office-ui/
#   2. Registers the plugin via `openclaw plugins install --link`
#   3. Configures officeUrl, joinKey, and agentName
#   4. Reminds you to restart the gateway
# ─────────────────────────────────────────────────────────────────
set -euo pipefail

OFFICE_URL="${1:-}"
JOIN_KEY="${2:-}"
AGENT_NAME="${3:-Klaw}"

if [[ -z "$OFFICE_URL" || -z "$JOIN_KEY" ]]; then
  echo "Usage: bash install-klaw-plugin.sh <office-url> <join-key> [agent-name]"
  echo ""
  echo "  office-url  — Star Office UI 地址 (例如 http://192.168.1.100:19000)"
  echo "  join-key    — 加入房间的密钥     (例如 ocj_abc123)"
  echo "  agent-name  — 显示的名字         (默认: Klaw)"
  exit 1
fi

# ── Locate openclaw config ────────────────────────────────────────
OPENCLAW_DIR="${HOME}/.openclaw"
OPENCLAW_CONFIG="${OPENCLAW_DIR}/openclaw.json"

if [[ ! -d "$OPENCLAW_DIR" ]]; then
  echo "❌ 未找到 ~/.openclaw 目录。请先安装并启动一次 Klaw/OpenClaw。"
  exit 1
fi

PLUGIN_DIR="${OPENCLAW_DIR}/extensions/kclaw-office-ui"
mkdir -p "$PLUGIN_DIR"

echo "📦 正在写入插件文件到 $PLUGIN_DIR ..."

# ── package.json ─────────────────────────────────────────────────
cat > "$PLUGIN_DIR/package.json" << 'PKGJSON'
{
  "name": "kclaw-office-ui",
  "version": "0.1.0",
  "description": "Star Office UI integration for Klaw — pushes agent state to the pixel office dashboard",
  "type": "module",
  "license": "MIT",
  "peerDependencies": {
    "openclaw": "*"
  },
  "openclaw": {
    "extensions": [
      "./index.ts"
    ]
  }
}
PKGJSON

# ── openclaw.plugin.json ────────────────────────────────────────
cat > "$PLUGIN_DIR/openclaw.plugin.json" << 'MANIFEST'
{
  "id": "kclaw-office-ui",
  "name": "Kclaw Office UI",
  "description": "Star Office UI integration — shows Klaw agent state in the pixel office dashboard",
  "configSchema": {
    "type": "object",
    "additionalProperties": false,
    "properties": {
      "officeUrl": {
        "type": "string",
        "description": "Star Office UI backend URL, e.g. http://127.0.0.1:19000"
      },
      "joinKey": {
        "type": "string",
        "description": "Join key issued by the office owner (e.g. ocj_klaw01)"
      },
      "agentName": {
        "type": "string",
        "description": "Display name shown in the dashboard (default: Klaw)"
      },
      "pushInterval": {
        "type": "number",
        "description": "Heartbeat push interval in milliseconds (default: 15000)"
      }
    }
  }
}
MANIFEST

# ── index.ts (plugin source) ────────────────────────────────────
cat > "$PLUGIN_DIR/index.ts" << 'PLUGINSRC'
/**
 * kclaw-office-ui — Star Office UI integration plugin for Klaw
 *
 * Pushes the current Klaw agent state to a Star Office UI backend so it
 * appears as a live visitor in the pixel office dashboard.
 */

import type { OpenClawPluginApi } from "openclaw/plugin-sdk";

type AgentState = "idle" | "writing" | "researching" | "executing" | "syncing" | "error";

async function officePost(
  url: string,
  path: string,
  body: Record<string, unknown>,
): Promise<unknown> {
  try {
    const res = await fetch(`${url.replace(/\/$/, "")}${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(8_000),
    });
    return await res.json();
  } catch {
    return null;
  }
}

function toolNameToState(toolName: string): AgentState {
  const name = toolName.toLowerCase();
  if (["search", "read", "get", "fetch", "list", "query", "find"].some((k) => name.includes(k)))
    return "researching";
  if (["write", "edit", "create", "update", "push", "send", "post"].some((k) => name.includes(k)))
    return "writing";
  return "executing";
}

function buildToolDetail(toolName: string, params: Record<string, unknown>): string {
  const name = toolName.toLowerCase();
  const str = (v: unknown) => (typeof v === "string" && v.trim() ? v.trim() : null);
  const basename = (p: string) => p.split(/[/\\]/).filter(Boolean).pop() ?? p;

  if (["browser", "navigate", "open_url", "fetch"].some((k) => name.includes(k))) {
    const url = str(params.url) ?? str(params.href) ?? str(params.link);
    if (url) {
      try { const u = new URL(url); return `打开 ${u.hostname}${u.pathname !== "/" ? u.pathname.slice(0, 30) : ""}`; }
      catch { return `打开 ${url.slice(0, 55)}`; }
    }
  }
  if (["read", "view_file", "cat"].some((k) => name.includes(k))) {
    const p = str(params.path) ?? str(params.file) ?? str(params.filename);
    if (p) return `读取 ${basename(p)}`;
  }
  if (["write", "edit", "create_file", "update_file", "insert"].some((k) => name.includes(k))) {
    const p = str(params.path) ?? str(params.file) ?? str(params.filename);
    if (p) return `写入 ${basename(p)}`;
  }
  if (["bash", "shell", "run_command", "execute"].some((k) => name.includes(k))) {
    const cmd = str(params.command) ?? str(params.cmd) ?? str(params.script);
    if (cmd) return `运行 ${cmd.slice(0, 55)}`;
  }
  if (["search", "grep", "find"].some((k) => name.includes(k))) {
    const q = str(params.query) ?? str(params.q) ?? str(params.keyword) ?? str(params.pattern);
    if (q) return `搜索 "${q.slice(0, 45)}"`;
  }
  if (["send", "message", "reply"].some((k) => name.includes(k))) {
    const msg = str(params.message) ?? str(params.text) ?? str(params.content) ?? str(params.body);
    if (msg) return `发送: ${msg.slice(0, 50)}`;
  }
  if (["list", "ls"].some((k) => name.includes(k))) {
    const p = str(params.path) ?? str(params.dir) ?? str(params.directory);
    if (p) return `列出 ${basename(p) || p}`;
  }
  for (const [k, v] of Object.entries(params)) {
    const s = str(v);
    if (s && s.length > 3 && !["type", "format", "mode"].includes(k))
      return `${toolName}: ${s.slice(0, 50)}`;
  }
  return `调用 ${toolName}`;
}

const plugin = {
  id: "kclaw-office-ui",
  name: "Kclaw Office UI",
  description: "Pushes Klaw agent state to Star Office UI pixel dashboard",

  register(api: OpenClawPluginApi) {
    const raw = (api.pluginConfig ?? {}) as Record<string, unknown>;
    const officeUrl = typeof raw.officeUrl === "string" ? raw.officeUrl.trim() : "";
    const joinKey = typeof raw.joinKey === "string" ? raw.joinKey.trim() : "";
    const agentName = typeof raw.agentName === "string" ? raw.agentName.trim() : "Klaw";
    const pushInterval =
      typeof raw.pushInterval === "number" && raw.pushInterval > 0 ? raw.pushInterval : 15_000;

    if (!officeUrl || !joinKey) {
      api.logger.warn(
        "kclaw-office-ui: officeUrl and joinKey are required. Plugin is disabled.\n" +
          "  Set them via: openclaw config set plugins.kclaw-office-ui.officeUrl <url>\n" +
          "                openclaw config set plugins.kclaw-office-ui.joinKey <key>",
      );
      return;
    }

    let agentId: string | null = null;
    let heartbeatTimer: ReturnType<typeof setInterval> | null = null;
    let lastPushedState: AgentState = "idle";
    let lastPushedDetail = "";
    let lastUserMessage = "";

    async function joinOffice(): Promise<void> {
      const res = (await officePost(officeUrl, "/join-agent", {
        name: agentName, joinKey, state: "idle", detail: "刚刚上线",
      })) as Record<string, unknown> | null;
      if (res?.ok) {
        agentId = String(res.agentId ?? "");
        api.logger.info?.(`kclaw-office-ui: joined office, agentId=${agentId}`);
      } else {
        api.logger.warn(`kclaw-office-ui: join failed — ${JSON.stringify(res)}`);
      }
    }

    async function leaveOffice(): Promise<void> {
      if (!agentId) return;
      await officePost(officeUrl, "/leave-agent", { agentId, name: agentName });
      agentId = null;
    }

    async function pushState(state: AgentState, detail = ""): Promise<void> {
      if (state === lastPushedState && detail === lastPushedDetail) return;
      if (!agentId) { await joinOffice(); if (!agentId) return; }
      const res = (await officePost(officeUrl, "/agent-push", {
        agentId, joinKey, name: agentName, state, detail,
      })) as Record<string, unknown> | null;
      if (res?.ok) { lastPushedState = state; lastPushedDetail = detail; }
      else if (res && typeof res === "object" && "msg" in res &&
               typeof res.msg === "string" &&
               (res.msg.includes("未注册") || res.msg.includes("join"))) {
        await joinOffice();
        if (agentId) {
          await officePost(officeUrl, "/agent-push", {
            agentId, joinKey, name: agentName, state, detail,
          });
          lastPushedState = state; lastPushedDetail = detail;
        }
      }
    }

    function startHeartbeat(): void {
      if (heartbeatTimer) return;
      heartbeatTimer = setInterval(async () => {
        if (agentId) {
          await officePost(officeUrl, "/agent-push", {
            agentId, joinKey, name: agentName, state: lastPushedState, detail: lastPushedDetail,
          });
        }
      }, pushInterval);
    }

    function stopHeartbeat(): void {
      if (heartbeatTimer) { clearInterval(heartbeatTimer); heartbeatTimer = null; }
    }

    api.on("gateway_start", async () => { await joinOffice(); startHeartbeat(); });
    api.on("gateway_stop", async () => { stopHeartbeat(); await leaveOffice(); });

    api.on("before_agent_start", async (event) => {
      let detail = "思考中...";
      const msgs = event.messages;
      if (Array.isArray(msgs) && msgs.length > 0) {
        for (let i = msgs.length - 1; i >= 0; i--) {
          const m = msgs[i] as Record<string, unknown>;
          if (m?.role === "user") {
            const content = m.content;
            const text = typeof content === "string" ? content
              : Array.isArray(content)
                ? (content as Array<Record<string, unknown>>)
                    .filter((c) => c?.type === "text").map((c) => c.text as string).join(" ")
                : "";
            if (text.trim()) { detail = text.trim().slice(0, 80); lastUserMessage = detail; }
            break;
          }
        }
      }
      await pushState("executing", detail);
    });

    api.on("before_tool_call", async (event) => {
      const toolState = toolNameToState(event.toolName ?? "");
      const detail = buildToolDetail(event.toolName ?? "", event.params ?? {});
      await pushState(toolState, detail);
    });

    api.on("agent_end", async (event) => {
      if (event.success) {
        const idleDetail = lastUserMessage ? `刚完成: ${lastUserMessage.slice(0, 60)}` : "待命中";
        await pushState("idle", idleDetail);
      } else {
        await pushState("error", event.error ? event.error.slice(0, 80) : "执行出错");
        setTimeout(() => { pushState("idle", "待命中").catch(() => {}); }, 60_000);
      }
    });

    api.logger.info?.(`kclaw-office-ui: loaded (office=${officeUrl}, agent=${agentName})`);
  },
};

export default plugin;
PLUGINSRC

echo "✅ 插件文件已写入"

# ── Register plugin in openclaw.json ────────────────────────────
echo "⚙️  正在配置 Klaw ..."

# Use Python to safely update the JSON config (no jq dependency needed)
python3 << PYEOF
import json, os

config_path = os.path.expanduser("${OPENCLAW_CONFIG}")

# Load existing config or create minimal one
if os.path.exists(config_path):
    with open(config_path, "r") as f:
        cfg = json.load(f)
else:
    cfg = {}

# Ensure plugins structure
cfg.setdefault("plugins", {})
cfg["plugins"].setdefault("load", {})
cfg["plugins"]["load"].setdefault("paths", [])
cfg["plugins"].setdefault("entries", {})

plugin_dir = os.path.expanduser("${PLUGIN_DIR}")

# Add load path if not already present
if plugin_dir not in cfg["plugins"]["load"]["paths"]:
    cfg["plugins"]["load"]["paths"].append(plugin_dir)

# Set plugin entry config
cfg["plugins"]["entries"]["kclaw-office-ui"] = {
    "enabled": True,
    "config": {
        "officeUrl": "${OFFICE_URL}",
        "joinKey": "${JOIN_KEY}",
        "agentName": "${AGENT_NAME}"
    }
}

with open(config_path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)

print("✅ 配置已写入", config_path)
PYEOF

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ 安装完成！"
echo ""
echo "  📍 Office URL:  $OFFICE_URL"
echo "  🔑 Join Key:    $JOIN_KEY"
echo "  🤖 Agent Name:  $AGENT_NAME"
echo ""
echo "  下一步：重启 Klaw 即可在像素办公室看到你的 Agent！"
echo ""
echo "  macOS 菜单栏 → Klaw → 重启"
echo "  或者: openclaw gateway restart"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
