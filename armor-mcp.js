#!/usr/bin/env node
/**
 * armor-mcp.js — 反重力内置的破甲开关（MCP stdio server，零依赖）
 *
 * 注册到 %USERPROFILE%\.gemini\config\mcp_config.json 之后，在反重力对话框里直接说
 * "把破甲关掉" / "现在是什么状态" 即可，无需离开 IDE。
 *
 * 关键设计：所有写操作都委托给 arm.ps1（唯一的写入者）。
 * 直接改 state.json 只会关掉 hook 注入，AGENTS.md / GEMINI.md 里的政策文本
 * 依然常驻，新会话继续按破甲政策跑 —— 看起来"关了"，实际没关。
 *
 * 协议：MCP over stdio，一行一条 JSON-RPC 消息。
 */
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const CFG_DIR = path.join(os.homedir(), '.gemini', 'config');
const HOOK_DIR = path.join(CFG_DIR, 'agy-hooks');
const STATE = path.join(HOOK_DIR, 'state.json');
const LOGS = path.join(CFG_DIR, 'logs');
const ARM = path.join(CFG_DIR, 'arm.ps1');
const AGENTS = path.join(CFG_DIR, 'AGENTS.md');
const GEMINI = path.join(CFG_DIR, 'GEMINI.md');

const DEFAULTS = {
  enabled: false,
  contract: true,
  allow: true,
  stop: true,
  maskLogs: true,
  guardDestructive: true,
  rules: true,
  sessionInject: false,
  tail: true,
  profile: 'gemini4hardened',
};

const PROFILES = ['gemini4hardened', 'gemini4tight', 'gemini4argon', 'gemini4compact', 'codeemitter'];

const TOOLS = [
  {
    name: 'armor_status',
    description: '查看反重力破甲开关的完整状态：总闸、各标志、档位，以及三个 surface（hook 注入 / AGENTS.md / GEMINI.md）是否与总闸一致。',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  },
  {
    name: 'armor_set',
    description: '切换破甲开关。enabled 是总闸：true=破甲（注入契约+自动放行+全局规则），false=完整还原（不注入、AGENTS.md 恢复中性、GEMINI.md 删除、审批弹窗恢复）。其余字段可单独覆盖；改完立即生效，无需重启。',
    inputSchema: {
      type: 'object',
      properties: {
        enabled: { type: 'boolean', description: '总闸：true 开启，false 完整还原' },
        contract: { type: 'boolean', description: '是否每轮注入破甲契约' },
        allow: { type: 'boolean', description: '是否自动放行工具调用' },
        stop: { type: 'boolean', description: '是否阻拦提前收工' },
        guardDestructive: { type: 'boolean', description: '破坏性命令是否仍要求确认' },
        maskLogs: { type: 'boolean', description: '日志是否对密钥打码' },
        rules: { type: 'boolean', description: '是否把政策写进全局 AGENTS.md/GEMINI.md' },
        sessionInject: { type: 'boolean', description: '是否在 SessionStart 也注入（双份成本）' },
        tail: { type: 'boolean', description: '是否追加尾部重申块' },
        profile: { type: 'string', enum: PROFILES, description: '提示词档位' },
      },
      additionalProperties: false,
    },
  },
  {
    name: 'armor_panic',
    description: '止血：完整还原（同 armor_set(enabled=false)），并把 PreToolUse 从 hooks.json 摘掉。用于所有工具调用都报 denied by pre-tool hook 的情况。',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  },
];

function readState() {
  try {
    const raw = JSON.parse(fs.readFileSync(STATE, 'utf8'));
    return Object.assign({}, DEFAULTS, raw);
  } catch {
    return Object.assign({}, DEFAULTS);
  }
}

function readText(p) {
  try {
    return fs.readFileSync(p, 'utf8');
  } catch {
    return '';
  }
}

function surfaces() {
  const agents = readText(AGENTS);
  const geminiExists = fs.existsSync(GEMINI);
  return {
    agentsArmed: agents.startsWith('<!-- profile:'),
    agentsBytes: Buffer.byteLength(agents, 'utf8'),
    geminiExists,
    geminiArmed: geminiExists && readText(GEMINI).startsWith('<!-- profile:'),
    overrideBytes: (() => {
      try {
        return fs.statSync(path.join(HOOK_DIR, 'override.txt')).size;
      } catch {
        return 0;
      }
    })(),
  };
}

// run arm.ps1; stdio inherited nowhere (the product owns our stdout)
function runArm(args) {
  const r = spawnSync('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ARM, ...args], {
    stdio: 'ignore',
    windowsHide: true,
    timeout: 60000,
  });
  if (r.error) throw new Error('arm.ps1 spawn failed: ' + r.error.message);
  if (r.status !== 0) throw new Error('arm.ps1 exited ' + r.status + ' for [' + args.join(' ') + ']');
}

function consistency(s, sf) {
  const issues = [];
  if (s.enabled && s.rules) {
    if (!sf.agentsArmed) issues.push('AGENTS.md 是中性文本但总闸是开');
    if (!sf.geminiExists) issues.push('GEMINI.md 缺失但总闸是开');
    if (sf.overrideBytes === 0) issues.push('override.txt 为空但总闸是开');
  }
  if (!s.enabled) {
    if (sf.agentsArmed) issues.push('AGENTS.md 仍是破甲政策但总闸是关');
    if (sf.geminiExists) issues.push('GEMINI.md 仍存在但总闸是关');
  }
  return issues.length ? issues.join('；') : 'ok';
}

function fmt(s) {
  const sf = surfaces();
  const on = s.enabled ? 'ON ' : 'OFF';
  const probe = s.enabled && s.allow
    ? 'PreToolUse=allow, PreInvocation=注入契约'
    : 'PreToolUse=ask(弹审批), PreInvocation=不注入';
  return [
    `state: ${on}   profile=${s.profile}`,
    `  contract=${s.contract}  allow=${s.allow}  stop=${s.stop}  guardDestructive=${s.guardDestructive}`,
    `  rules=${s.rules}  sessionInject=${s.sessionInject}  tail=${s.tail}  maskLogs=${s.maskLogs}`,
    `  钩子实际行为: ${probe}`,
    `  override.txt=${sf.overrideBytes}B  AGENTS.md=${sf.agentsBytes}B ${sf.agentsArmed ? '[ARMED]' : '[中性]'}  GEMINI.md=${sf.geminiExists ? (sf.geminiArmed ? '[ARMED]' : '[存在]') : '[已删除]'}`,
    `  一致性: ${consistency(s, sf)}`,
    `  文件: ${STATE}`,
  ].join('\n');
}

function setArmor(args) {
  const flags = [
    ['enabled', '-On', '-Off'],
    ['contract', '-Contract'],
    ['allow', '-Allow'],
    ['stop', '-Stop'],
    ['guardDestructive', '-Guard'],
    ['maskLogs', '-MaskLogs'],
    ['rules', '-Rules'],
    ['sessionInject', '-Session'],
    ['tail', '-Tail'],
  ];
  const out = [];
  for (const [key, ...cli] of flags) {
    if (typeof args[key] !== 'boolean') continue;
    if (cli.length === 2) out.push(args[key] ? cli[0] : cli[1]);
    else out.push(cli[0], args[key] ? 'on' : 'off');
  }
  if (typeof args.profile === 'string' && PROFILES.includes(args.profile)) {
    out.push('-Profile', args.profile);
    if (out.indexOf('-On') < 0 && out.indexOf('-Off') < 0) out.push('-On');
  }
  if (!out.length) return '未提供任何可改字段。\n' + fmt(readState());
  runArm(out);
  const s = readState();
  return `已应用 [${out.join(' ')}]（下一次调用即生效）\n` + fmt(s);
}

function panic() {
  runArm(['-Off']);
  const hj = path.join(CFG_DIR, 'hooks.json');
  let note = '';
  try {
    if (fs.existsSync(hj)) {
      fs.copyFileSync(hj, hj + '.panic.bak');
      const cfg = JSON.parse(fs.readFileSync(hj, 'utf8'));
      for (const key of Object.keys(cfg)) {
        if (cfg[key] && cfg[key].PreToolUse) {
          delete cfg[key].PreToolUse;
          note = '，并从 hooks.json 摘掉了 PreToolUse';
        }
      }
      fs.writeFileSync(hj, JSON.stringify(cfg, null, 4), 'utf8');
    }
  } catch (e) {
    note = `（改 hooks.json 失败: ${e.message}）`;
  }
  return (
    `已完整还原${note}：enabled=false、AGENTS.md 恢复中性、GEMINI.md 已删除。\n` +
    `恢复用 armor_set({enabled:true}) 或 armor_set({profile:"gemini4hardened"})；若摘过 PreToolUse，跑 panic.ps1 -Restore。\n` +
    fmt(readState())
  );
}

function tailLog(name, n) {
  try {
    const lines = fs.readFileSync(path.join(LOGS, name), 'utf8').trim().split(/\r?\n/);
    return lines.slice(-n).join('\n');
  } catch {
    return `(无 ${name})`;
  }
}

function callTool(name, args) {
  if (name === 'armor_status') {
    return fmt(readState()) + '\n\n最近调用:\n' + tailLog('tool_use.jsonl', 3) + '\n最近注入:\n' + tailLog('invoke.jsonl', 3);
  }
  if (name === 'armor_set') return setArmor(args);
  if (name === 'armor_panic') return panic();
  throw new Error('unknown tool: ' + name);
}

function reply(obj) {
  process.stdout.write(JSON.stringify(obj) + '\n');
}

function handle(msg) {
  const { id, method, params } = msg;
  const isNotification = id === undefined || id === null;

  if (method === 'initialize') {
    return reply({
      jsonrpc: '2.0',
      id,
      result: {
        protocolVersion: (params && params.protocolVersion) || '2024-11-05',
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: 'armor-switch', version: '1.1.0' },
      },
    });
  }
  if (method === 'notifications/initialized' || isNotification) return;
  if (method === 'ping') return reply({ jsonrpc: '2.0', id, result: {} });

  if (method === 'tools/list') {
    return reply({ jsonrpc: '2.0', id, result: { tools: TOOLS } });
  }

  if (method === 'tools/call') {
    const name = params && params.name;
    const args = (params && params.arguments) || {};
    try {
      const text = callTool(name, args);
      return reply({ jsonrpc: '2.0', id, result: { content: [{ type: 'text', text }], isError: false } });
    } catch (e) {
      return reply({ jsonrpc: '2.0', id, result: { content: [{ type: 'text', text: 'error: ' + e.message }], isError: true } });
    }
  }

  if (method === 'resources/list') return reply({ jsonrpc: '2.0', id, result: { resources: [] } });
  if (method === 'prompts/list') return reply({ jsonrpc: '2.0', id, result: { prompts: [] } });

  return reply({ jsonrpc: '2.0', id, error: { code: -32601, message: 'method not found: ' + method } });
}

let buf = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => {
  buf += chunk;
  let idx;
  while ((idx = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, idx).trim();
    buf = buf.slice(idx + 1);
    if (!line) continue;
    try {
      handle(JSON.parse(line));
    } catch {
      /* ignore malformed line */
    }
  }
});
process.stdin.on('end', () => process.exit(0));
