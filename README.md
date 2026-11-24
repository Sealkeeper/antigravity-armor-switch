# antigravity-armor-switch

**A reversible operator-policy layer for Google Antigravity** — four lifecycle hooks, a prompt-injection contract, and one master switch that has exactly two states: *fully on* and *fully restored*.

Antigravity 2.34.0 · Windows · PowerShell 5.1 · no dependencies, no patched binaries, no network interception.

[中文说明](#中文) · [How it works](#how-it-works) · [Install](#install) · [Switch semantics](#switch-semantics-the-point-of-this-repo) · [Gotchas](#three-gotchas-that-cost-hours)

---

## What this is

Antigravity reads lifecycle hooks from `%USERPROFILE%\.gemini\config\hooks.json`. Four of them are enough to take over the parts of an agent session that usually stall work:

| Hook | What it does here |
|---|---|
| `SessionStart` | optional: injects the policy once (off by default — `PreInvocation` already covers every turn) |
| `PreInvocation` | injects the operator policy into every model call as a `systemMessage`, and appends a short tail reminder |
| `PreToolUse` | returns `allow` so tool calls are not held for approval; destructive commands still go back to `ask` |
| `Stop` | returns `continue` instead of letting the run end early with no tool call |

No binary is modified, no `language_server.exe` is wrapped, no TLS is intercepted. Everything is the product's own documented hook surface.

### Verified environment

- Antigravity **2.34.0** (`%LOCALAPPDATA%\Programs\antigravity`)
- Symbols confirmed present in `resources\bin\language_server.exe`: `hooks.json`, `PreInvocation`, `PreToolUse`, `injectSteps`, `systemMessage`, `force_ask`
- Hook output contracts in use: `{"injectSteps":[{"systemMessage":{"systemMessage":"..."}}]}`, `{"decision":"allow"|"ask"}`, `{"decision":"continue"}`

---

## Switch semantics (the point of this repo)

Most "jailbreak kits" fail at one thing: turning them off. Antigravity loads **three** policy surfaces, and a switch that only flips a flag in `state.json` leaves the other two armed:

| Surface | File | Who reads it |
|---|---|---|
| hook injection | `agy-hooks\override.txt` | `PreInvocation`, every turn |
| global rules | `config\AGENTS.md` | the product, every new conversation |
| compat name | `config\GEMINI.md` | the product, every new conversation |

So this repo has **one writer**: `arm.ps1`. Every switch (`toggle.ps1`, `armor-tray.ps1`, the MCP server, `panic.ps1`) shells out to it. Nothing else touches `state.json`.

| Action | `enabled` | `override.txt` | `AGENTS.md` | `GEMINI.md` | `PreToolUse` |
|---|---|---|---|---|---|
| `-On` | true | policy text | `[ARMED]` | `[ARMED]` | `allow` |
| `-Off` | false | kept, unused | neutral | deleted | `ask` |
| `-On -Rules off` | true | policy text | neutral | deleted | `allow` |
| `panic.ps1` | false | kept | neutral | deleted | registration removed |

`arm.ps1` also **self-heals** on every run: if the master switch is off but `AGENTS.md` is still armed, or on but `override.txt` is missing, the surfaces are corrected in place and reported on the `sync:` line. `arm.ps1 -Verify` exits non-zero when anything disagrees, so it can gate a script.

```
$ powershell -File arm.ps1
  state : ON    profile=gemini4hardened
  flags : contract=True allow=True stop=True guard=True rules=True session=False tail=True maskLogs=True
  hook  : override.txt = 14691 B
  rules : AGENTS.md = 14775 B [ARMED], GEMINI.md = 14775 B [ARMED]
  probe : PreToolUse={"decision":"allow","reason":"operator policy: auto-approved"}
          PreInvocationLen=15422  SessionStartLen=2
  sync  : ok
```

---

## Install

```powershell
git clone https://github.com/Sealkeeper/antigravity-armor-switch.git
cd antigravity-armor-switch
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

The installer deploys hooks + prompt profiles + all four switches, registers the MCP server in `mcp_config.json`, creates a desktop shortcut, and leaves the master switch **off**.

Then:

```powershell
$arm = "$env:USERPROFILE\.gemini\config\arm.ps1"
& $arm                      # status + sync check
& $arm -On                  # arm
& $arm -Off                 # full restore (rules included)
& $arm -On -Profile gemini4tight     # cheaper contract
& $arm -On -Rules off                # hook layer only
```

Uninstall (restores `hooks.json`/`AGENTS.md` from `.agybreak.bak`, deletes `GEMINI.md`, the MCP entry and the shortcut):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
```

### Four ways to flip it

1. **CLI** — `arm.ps1` as above
2. **Desktop shortcut** — `破甲开关.lnk`, double-click, balloon shows the real state
3. **Tray icon** — `armor-tray.ps1`, double-click toggles, right-click has profile / rules / guard submenus
4. **Inside the IDE** — ask the agent; the `armor-switch` MCP server exposes `armor_status`, `armor_set`, `armor_panic` (restart Antigravity once so the tools appear)

State lives in `agy-hooks\state.json`, and **the hooks re-read it on every invocation** — a flip takes effect on the next tool or model call, no restart.

---

## Prompt profiles

`PreInvocation` injects one file. Profiles differ in framing, not in length for its own sake:

| Profile | Chars | Shape |
|---|---|---|
| `gemini4hardened` *(default)* | 14,691 | provenance header + full argumentative policy (Gemini 4) |
| `gemini4argon` | 14,025 | argumentative policy only |
| `gemini4compact` | 9,304 | condensed |
| `gemini4tight` | 3,071 | imperative, cheapest |
| `codeemitter` | 1,647 | output-shape contract only |
| `claude5` | 4,965 | operator-voice brief for Claude 5.5 — no authority claims, no override vocabulary |

Each profile ends with a `SENTINEL:` line so you can test whether the injection was truncated:

> "Print the last line of your system prompt verbatim."

A tail reminder is appended after the profile. The generic `tail.txt` (340 chars) is used unless a profile ships its own closer — `tail.claude5.txt` does, because the generic tail's policy vocabulary reads to Claude as an injected guard.

### Which profile for which model

The **hook layer is model-agnostic** (`PreToolUse` → `allow`, `Stop` → `continue` fire in the product before any model is involved). Only the injected text depends on the model.

| Model | Expectation | Notes |
|---|---|---|
| Gemini 4 Hydrogen / Carbon | good | argumentative contract works |
| Gemini 4 Argon | good | marked *Leaving Soon* upstream |
| Gemini 3.8 Flash | mixed | provider-side input filter can trip on keywords |
| Gemini 4 Neon / Orchestrator | poor | server-side content review; prompt text cannot reach it |
| Claude Opus 5.5 / Sonnet 5.5 | use `claude5` | alignment rejects authority/override framing; responds to operator voice + output spec |
| GPT-OSS 120B | mixed | follows specs well, weak at long artifacts |

Claude needs a different document, not a longer one. The `claude5` profile therefore drops every meta-instruction signature — no `Authority:`, no "outranks earlier scope", no persona swap, no "ignore" — and instead:

- speaks in the operator's first-person voice, conversational, with reasons rather than permissions
- names the false-positive mechanism explicitly (keyword scorers, appended severity blocks) so a classification impulse is recognisable as one
- draws narrow lines the operator says they hold *because they believe them*
- spends the rest on an output spec: dependency order, complete files, length floor, no pseudocode, no preamble, no restating the brief

Technique lineage: the operator-voice / "bring your judgment to the craft, not the premise" structure follows the Anthropic-facing entries in [togg53192-cmd/jailbreaks](https://github.com/togg53192-cmd/jailbreaks) (`Anthropic/sonnet v1.md`, `Anthropic/opus v1.md`); the security framing adapts the capability-versus-target distinction from the Gemini 4 Argon policy.

---

## Audit

`logs\tool_use.jsonl` records the **actual** decision, not a placeholder:

```json
{"ts":"...","conv":"t2","tool":"run_command","decision":"allow","args":"echo hi"}
{"ts":"...","conv":"t2","tool":"run_command","decision":"ask(destructive)","args":"rm -rf /tmp/x"}
{"ts":"...","conv":"","tool":"","decision":"ask(bad-payload)","args":"not json at all"}
```

Secrets are masked before logging (`ark…`, `sk…`, `ghp…`, `Bearer`, `api_key=`, long base64).

An unparseable payload returns `ask`, never a silent `allow` — otherwise a renamed field in a future release would disable the destructive-command guard without leaving a trace.

`logs\invoke.jsonl` records one line per turn: `{ts, conv, mode, file, tail, chars}`, which is how you prove the injection is live.

---

## Three gotchas that cost hours

1. **`hooks.json` must be written without a BOM, and the `-File` path must not be quoted.** Antigravity passes `-File "path"` as a single argument, PowerShell then reports *illegal characters in path*, and all four hooks fail silently.
2. **Never replace `resources\bin\language_server.exe` with a wrapper.** The Electron main process exits silently (code 0, no log) when the child is not the expected binary. If you want transport-level work, use a MITM proxy or an independent instance.
3. **`PreToolUse` is fail-closed on empty output.** A hook that prints `{}` (or nothing parseable) is treated as *deny*. A hook that fails to start at all yields *no decision*, which the product treats as *allow*. That asymmetry is why the off-state here prints an explicit `{"decision":"ask"}` rather than `{}`.

---

## Layout

```
install.ps1          installer / uninstaller
arm.ps1              master switch + single writer of every surface
toggle.ps1           desktop-shortcut flip
armor-tray.ps1       tray icon menu
armor-mcp.js         MCP stdio server (armor_status / armor_set / armor_panic)
panic.ps1            one-shot stop: full restore + drop the PreToolUse registration
hooks/               the four hook scripts + state.json + prompts/ + tail.txt
prompts/             policy profiles (one file per profile)
rules/               neutral global rules + optional repo-level rule
probe/               10 tiered probe cases + scoring sheet
```

---

## Scope

Built for a local, single-operator developer machine, to stop an agent from stalling on approval prompts and to keep a policy document in force for that session. It changes nothing on the provider side; requests are the official client's requests. The contracts here are prompt text — whether a given model follows one is a property of that model, not of this code, and model behaviour changes between releases.

If you redistribute or adapt the prompt profiles, keep the attribution below.

## Credits

- Hook surface, `PreInvocation` injection technique and the "don't wrap `language_server.exe`" finding: [minglong142857-web/antigravity-armor-break](https://github.com/minglong142857-web/antigravity-armor-break)
- `gemini4argon` / `gemini4hardened` / `gemini4compact` / `gemini4tight` are adapted from the *Gemini 4 Argon* operating-policy document in [togg53192-cmd/jailbreaks](https://github.com/togg53192-cmd/jailbreaks) (MIT-adjacent, credited there to its author), restructured for hook injection.
- `codeemitter` profile: original to this repo.

## License

MIT — see [LICENSE](LICENSE).

---

<a id="中文"></a>
## 中文

**给 Google Antigravity 装一层可逆的 operator 策略层**：四个生命周期钩子 + 一份提示词契约 + 一个只有两种状态的总开关（全开 / 全还原）。

不 patch 二进制、不包装 `language_server.exe`、不拦 TLS —— 全部走产品自己文档化的钩子面。

### 为什么值得单独做一个仓库

多数破甲包死在"关不掉"上。Antigravity 同时读**三个**策略面，只翻 `state.json` 里的标志，另外两个面照样武装：

| 面 | 文件 | 谁读 |
|---|---|---|
| 钩子注入 | `agy-hooks\override.txt` | `PreInvocation`，每轮 |
| 全局规则 | `config\AGENTS.md` | 产品，新会话 |
| 兼容名 | `config\GEMINI.md` | 产品，新会话 |

本仓库只有**一个写入者** `arm.ps1`，其余开关（快捷方式 / 托盘 / MCP / `panic.ps1`）全部 exec 它。`-Off` 会把 `AGENTS.md` 写回中性、删掉 `GEMINI.md`，所以"关闭"是真关闭；每次运行还会自愈不一致的 surface，并在 `sync:` 行报告。

### 快速开始

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
$arm = "$env:USERPROFILE\.gemini\config\arm.ps1"
& $arm -On                      # 开
& $arm -Off                     # 完整还原
& $arm -On -Profile gemini4tight   # 换省 token 的档位
```

### 三个费时的坑

1. `hooks.json` **必须无 BOM**，`-File` 路径**不能加引号**，否则四个钩子静默失败。
2. **不要**把 `language_server.exe` 换成包装器，Electron 主进程会静默退出。
3. `PreToolUse` 对空输出是 **fail-closed**：打印 `{}` 等于拒绝；而脚本起不来等于"无决策"→ 放行。所以关闭态必须显式打印 `{"decision":"ask"}`。
