# KrewOS

Self-hosted multi-agent runtime. Run and coordinate a team of specialized AI agents on your own infrastructure, using your own LLM API keys.

## Overview

KrewOS packages an agent runtime, persistent SQLite storage, automatic TLS reverse proxy, and an interactive browser observatory into a single Distroless/Hardened container (`ghcr.io/krewos/krewos`):

- **Multi-agent coordination** — Work 1:1 with individual agents or in multi-agent group threads where a lead agent delegates tasks, coordinates specialists, and consolidates results.
- **Sandboxed execution & browser** — Agents run shell commands, persistent terminals, and scheduled jobs inside isolated Linux workspaces, with dedicated per-agent Chromium profiles and live browser inspection.
- **Extensibility via MCP** — Connect external tools and services over the Model Context Protocol (`mcp.json`, supporting isolated `stdio` processes and Streamable HTTP).
- **Memory & secret vault** — Conversation history and long-term agent memory are stored locally in SQLite. Sensitive credentials are stored in an encrypted vault (`ChaCha20-Poly1305`), injected at runtime, and redacted from outputs.

---

## Quickstart (Docker Compose)

**Prerequisites:** Docker (≥ 23.x) with Compose v2 and an OpenAI-compatible LLM API key.

### 1. Clone & configure

```bash
git clone https://github.com/krewos/krewos.git
cd krewos
cp .env.example .env
```

Generate your Argon2id sign-in password hash:

```bash
docker run --rm -it ghcr.io/krewos/krewos:latest /usr/local/bin/krewos --hash-password
```

Set the required values in `.env`:

- `KREWOS_AUTH_PASSWORD_HASH='$argon2id$...'` *(single-quoted)*
- `KREWOS_LLM_BASE_URL` and `KREWOS_LLM_API_KEY`
- *(Optional)* `KREWOS_AUTH_ORIGIN` — defaults to `https://krewos.localhost` out of the box (change to `https://<your-domain-or-lan-ip>` when deploying on a remote host).

### 2. Start & open `https://krewos.localhost`

```bash
docker compose pull
docker compose up -d
```

On first start, KrewOS automatically provisions a local Root CA and TLS server certificate inside `krewos-data` matching `KREWOS_AUTH_ORIGIN` (and automatically re-signs the server certificate if you change `KREWOS_AUTH_ORIGIN` later).

To trust the local CA on your machine so your browser shows a green lock without certificate warnings (or download `http://krewos.localhost/ca.crt` directly):

- **macOS:**
  ```bash
  curl -fsSL http://127.0.0.1/ca.crt -o krewos-ca.crt && sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain krewos-ca.crt && rm krewos-ca.crt
  ```
- **Linux (Debian / Ubuntu):**
  ```bash
  sudo curl -fsSL http://127.0.0.1/ca.crt -o /usr/local/share/ca-certificates/krewos-ca.crt && sudo update-ca-certificates
  ```
- **Windows (PowerShell as Administrator):**
  ```powershell
  curl.exe -fsSL http://127.0.0.1/ca.crt -o krewos-ca.crt; certutil -addstore -f "ROOT" krewos-ca.crt; Remove-Item krewos-ca.crt
  ```

Then open **[https://krewos.localhost](https://krewos.localhost)** and sign in at `/login` (default username: `owner`).

<details>
<summary><strong>Advanced Configuration Reference (<code>.env</code>)</strong></summary>

All variables below are optional and have production-ready defaults:

| Variable | Default | Description |
|---|---|---|
| `KREWOS_AUTH_USERNAME` | `owner` | Single-user sign-in username |
| `KREWOS_AUTH_PASSWORD_HASH` | *(required)* | Single-quoted Argon2id PHC password hash |
| `KREWOS_AUTH_ORIGIN` | `https://krewos.localhost` | Exact browser origin; drives automatic TLS certificate SANs |
| `KREWOS_VAULT_KEY` | *(derived)* | Optional master passphrase (`≥ 16` chars) for Agent Vault (`ChaCha20-Poly1305`); derived via HKDF when unset |
| `KREWOS_LLM_BASE_URL` | *(required)* | Provider API origin ending in `/v1` or `/v1beta` (no trailing slash) |
| `KREWOS_LLM_API_KEY` | *(required)* | Provider API key (server-side only) |
| `KREWOS_LLM_MODEL` | `gpt-6-luna` | Chat completion model identifier |
| `KREWOS_LLM_WIRE_API` | `chat_completions` | Wire protocol: `chat_completions`, `responses`, or `gemini` |
| `KREWOS_LLM_REASONING_EFFORT` | *(provider default)* | Optional reasoning effort (`none`, `low`, `medium`, `high`, or numeric budget on Gemini 2.5) |
| `KREWOS_DREAM_MODEL` | `KREWOS_LLM_MODEL` | Optional model override for background memory dream consolidation |
| `KREWOS_DREAM_WIRE_API` | `KREWOS_LLM_WIRE_API` | Optional wire protocol override for memory dreams |
| `KREWOS_DREAM_REASONING_EFFORT` | `KREWOS_LLM_REASONING_EFFORT` | Optional reasoning effort override for memory dreams |
| `KREWOS_BROWSER_ENABLED` | `1` | Start embedded browser stack (`0` to disable on headless servers) |
| `KREWOS_BROWSER_MAX_INSTANCES` | `4` | Max warm per-agent Chromium processes in the LRU pool |
| `KREWOS_SHELL_EXEC_TIMEOUT_SECS` | `600` | Per-command `shell_exec` wall-clock timeout in seconds (`1..=3600`) |
| `KREWOS_SHELL_EXEC_OUTPUT_MAX_CHARS` | `16000` | Max combined stdout/stderr characters per `shell_exec` call (`256..=200000`) |
| `KREWOS_SHELL_EXEC_NPROC_MAX` | `2048` | `RLIMIT_NPROC` per agent sandbox UID (`1..=65536`) |
| `HOMEBREW_NO_AUTO_UPDATE` | `1` | Skip Homebrew formula index auto-update on agent `brew` calls (`0` to enable) |
| `KREWOS_AGENT_TOOL_LOOP_MAX` | `50` | Max LLM↔tool round-trips per agent wake (`1..=500`) |
| `KREWOS_AGENT_TOOL_TIME_BUDGET_SECS` | `600` | Cumulative wall-clock tool budget per turn across wakes (`30..=3600`) |
| `KREWOS_TURN_TOOL_CALLS_MAX` | `200` | Max individual tool invocations per turn (`1..=5000`) |
| `KREWOS_GROUP_WAKES_PER_MEMBER_MAX` | `10` | Max group wakes per active circle member per turn (`1..=100`) |
| `KREWOS_PEER_PM_MAX_HOP_DEPTH` | `5` | Max priority `send_to_agent` hop chain depth (`0..=16`) |
| `KREWOS_GROUP_QUEUE_MAX` | `64` | Max queued turns per circle thread (`1..=1000`) |
| `KREWOS_MAX_CONCURRENT_TURNS` | `8` | Max concurrent active turns across all threads (`1..=256`) |
| `KREWOS_MAX_CONCURRENT_TOOL_CALLS` | `8` | Max concurrent tool executions across active wakes (`1..=256`) |
| `KREWOS_MCP_CONNECT_TIMEOUT_SECS` | `60` | Per-server MCP startup handshake timeout in seconds |
| `KREWOS_MCP_CALL_TIMEOUT_SECS` | `120` | Per-call MCP `tools/call` timeout in seconds |
| `KREWOS_MCP_TOOL_RESULT_MAX_CHARS` | `48000` | Max characters per MCP tool result injected into context (`256..=100000`) |
| `KREWOS_DEBUG` | off | Set to `1` / `true` for structured turn/wake/tool/dream terminal logs |

</details>

---

## Volumes

| Volume | Mount | Purpose |
|--------|-------|---------|
| `krewos-data` | `/var/lib/krewos` | SQLite database (`krewos.sqlite`), encrypted vault, attachments, `MEMORY.md` exports, and auto-generated TLS certificates |
| `krewos-workspace` | `/workspace` | Per-agent workspaces (`/workspace/<agent_id>`) and shared downloads |
| `krewos-browser-profile` | `/var/lib/krewos-browser` | Persistent per-agent Chromium profiles and VNC Unix socket |
| `krewos-mcp-cache` | `/var/cache/krewos-mcp` | Isolated `uv` and `bun` caches for `stdio` MCP servers |
| `krewos-linuxbrew` | `/home/linuxbrew` | Homebrew prefix and packages installed for agent use |

---

## License

KrewOS is proprietary software governed by the **[KrewOS End-User License Agreement (EULA) 1.0](LICENSE)**:

- **Free Direct Use:** Free to download, install, and run for personal, educational, and internal professional productivity.
- **No Commercial Resale or SaaS:** Selling, sublicensing, offering KrewOS as a managed service / SaaS / cloud hosting offering, or bundling it into a paid commercial offering requires prior written authorization (`krewos.team@gmail.com` / [https://github.com/krewos/krewos](https://github.com/krewos/krewos)).
- **Restrictions:** Execution of the unmodified container images and binaries only ("As-Is"; plain-text configuration files such as `compose.yaml` and `mcp.json` may be adapted for your environment). Modification, reverse engineering, and redistribution/re-hosting are prohibited.

See [NOTICE](NOTICE) for third-party attributions. Report security vulnerabilities privately to `krewos.team@gmail.com` or via [GitHub Security Advisories](https://github.com/krewos/krewos/security/advisories/new).
