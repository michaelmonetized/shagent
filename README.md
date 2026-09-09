# shagent

Small Bun CLI agent that talks to **OpenRouter** and drives tools over the **Model Context Protocol (MCP)**.

Default tool transport in the main controller is `@modelcontextprotocol/server-filesystem` for the current working directory. An alternate entry (`src/controller/index.ts`) lists tools from `chrome-devtools-mcp` instead.

`index.html` in this repo is marketing fluff, not the product.

## Requirements

- [Bun](https://bun.sh)
- Node/`npx` available (MCP servers are launched via `npx -y …`)
- `OPENROUTER_API_KEY` in the environment

Optional:

- `SHAGENT_MODEL` — defaults to `openrouter/free`

## Install

```bash
bun install
```

Dependencies (from `package.json`): `@modelcontextprotocol/sdk`, `zod`, `dotenv`.

## Run

```bash
export OPENROUTER_API_KEY=sk-or-...
# optional:
# export SHAGENT_MODEL=openrouter/free

./shagent 'list files in this directory'
# or
bun run ./shagent 'your task here'
```

Without a task argument it prints:

```text
Usage: shagent 'task description'
```

## How it works

1. `./shagent` loads `OPENROUTER_API_KEY` and constructs `Shagent` (`src/controller/shagent.ts`).
2. `initialize()` connects an MCP client over stdio to:
   `npx -y @modelcontextprotocol/server-filesystem <cwd>`
3. `executeTask(prompt)` lists MCP tools, then loops up to **15** turns:
   - Calls OpenRouter `chat/completions` with the chosen model
   - Expects JSON in the model reply: `{"action":"tool_name","args":{…}}` or `{"message":"…"}`
   - Runs matching tools via MCP and feeds results back into the message list
4. Stops when the model returns a `message`, fails to produce an executable action, or hits the turn cap

## Scripts / entrypoints

| Path | Role |
|------|------|
| `shagent` | Bun shebang CLI |
| `src/controller/shagent.ts` | Agent class (filesystem MCP + OpenRouter loop) |
| `src/controller/index.ts` | Standalone MCP client smoke test against `chrome-devtools-mcp` |
| `package.json` | name `shagent` `1.0.0`, ESM, dependencies only (no npm scripts) |

There is no `bin` field published to npm in this tree; run the local `./shagent` file with Bun.

## Notes

- Model output must be parseable JSON objects; messy replies fall through to raw logging.
- This is an early harness (few commits), not a full agent framework.
