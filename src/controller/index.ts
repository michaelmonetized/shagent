import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

async function run() {
    const transport = new StdioClientTransport({
        command: "npx",
        args: ["-y", "chrome-devtools-mcp"],
    });

    const client = new Client({
        name: "shagent-client",
        version: "1.0.0"
    }, {
        capabilities: {}
    });

    await client.connect(transport);
    
    const tools = await client.listTools();
    console.log("Available tools:", tools);

    await client.close();
}

run().catch(console.error);
