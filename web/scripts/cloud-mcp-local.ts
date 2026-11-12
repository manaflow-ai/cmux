// Local demo of the cmux Cloud MCP tools against a cmux-tui session on this
// computer, for MCP Inspector or any MCP client. No auth and no Cloud: one fake
// machine, `local`, whose guest commands run `cmux-tui` here. Binds 127.0.0.1.
//
//   cmux-tui server ensure --session cloud
//   bun scripts/cloud-mcp-local.ts            # prints the URL
//   npx @modelcontextprotocol/inspector --cli http://127.0.0.1:8765/mcp --transport http --method tools/list

import { spawnSync } from "node:child_process";
import { CloudMcpToolError, handleCloudMcpBody, type CloudMcpGateway } from "../services/mcp/cloudMcp";

// The web package's tsconfig does not load Bun's ambient types; this script is
// Bun-only, so type the one global it needs here.
declare const Bun: {
  serve(options: {
    hostname: string;
    port: number;
    fetch(request: Request): Response | Promise<Response>;
  }): unknown;
};

const port = Number(process.env.CMUX_MCP_DEMO_PORT ?? 8765);
const cmuxTui = process.env.CMUX_TUI_BIN ?? "cmux-tui";
const MACHINE_ID = "local";

const gateway: CloudMcpGateway = {
  listMachines: async () => [{ id: MACHINE_ID, name: "this computer", status: "running" }],
  runCmuxTui: async (machineId, args, timeoutMs) => {
    if (machineId !== MACHINE_ID) {
      throw new CloudMcpToolError("vm_not_found", `Cloud VM ${machineId} was not found.`);
    }
    // `args` is quoted for a POSIX shell, exactly as it reaches the machine's shell.
    const result = spawnSync("sh", ["-c", `exec "$0" ${args}`, cmuxTui], { encoding: "utf8", timeout: timeoutMs });
    return { exitCode: result.status ?? 124, stdout: result.stdout ?? "", stderr: result.stderr ?? "" };
  },
};

Bun.serve({
  hostname: "127.0.0.1",
  port,
  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname !== "/mcp") return new Response("not found", { status: 404 });
    if (request.method !== "POST") return new Response(null, { status: 405, headers: { allow: "POST" } });
    let message: unknown;
    try {
      message = await request.json();
    } catch {
      return Response.json({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } }, { status: 400 });
    }
    const reply = await handleCloudMcpBody(gateway, message, (error) => console.error(error));
    return reply ? Response.json(reply) : new Response(null, { status: 202 });
  },
});

console.log(`cmux Cloud MCP demo at http://127.0.0.1:${port}/mcp (machine id: ${MACHINE_ID})`);
