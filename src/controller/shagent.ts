import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

interface Config {
  apiKey: string;
  model: string;
}

export class Shagent {
  private client: Client;
  private config: Config;

  constructor(config: Config) {
    this.config = config;
    this.client = new Client(
      { name: "shagent-controller", version: "1.0.0" },
      { capabilities: { tools: {} } }
    );
  }

  async initialize() {
    const transport = new StdioClientTransport({
      command: "npx",
      args: ["-y", "@modelcontextprotocol/server-filesystem", process.cwd()],
      stderr: "ignore",
    });
    await this.client.connect(transport);
  }

  async executeTask(prompt: string) {
    const toolsList = await this.client.listTools();
    const toolDescriptions = toolsList.tools.map((t) => `${t.name}: ${t.description}`).join("\n");

    const messages = [
      { role: "system", content: `You are shagent, an autonomous agent. Use tools to satisfy requests. Respond only in JSON: {"action": "tool_name", "args": {...}} or {"message": "..."}. Available tools: ${toolDescriptions}` },
      { role: "user", content: prompt }
    ];

    for (let i = 0; i < 15; i++) {
        const response = await fetch("https://openrouter.ai/api/v1/chat/completions", {
            method: "POST",
            headers: { Authorization: `Bearer ${this.config.apiKey}`, "Content-Type": "application/json" },
            body: JSON.stringify({ model: this.config.model, messages })
        });

        const data = await response.json();
        const rawContent = data.choices[0]?.message?.content;
        if (!rawContent) break;
        
        messages.push({ role: "assistant", content: rawContent });
        
        const matches = rawContent.matchAll(/\{.*?\}/gs);
        let executed = false;
        
        for (const match of Array.from(matches)) {
            try {
                // Use a standard JSON parse. Ensure LLM outputs clean JSON.
                const json = JSON.parse(match[0]);
                if (json.action) {
                    console.log(`[Executing]: ${json.action}`);
                    const res = await this.client.callTool({ name: json.action, arguments: json.args });
                    messages.push({ role: "user", content: JSON.stringify(res) });
                    executed = true;
                } else if (json.message) {
                    console.log(`[Response]: ${json.message}`);
                    return;
                }
            } catch (e) {
                console.log(`[Raw Content]: ${rawContent}`);
            }
        }
        if (!executed) break;
    }
  }

  async close() {
    await this.client.close();
  }
}
