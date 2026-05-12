/**
 * MCP client manager — connects to external MCP servers and exposes their tools.
 */

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { SSEClientTransport } from "@modelcontextprotocol/sdk/client/sse.js";
import type { McpServerConfig } from "../core/types.js";

// ----------------------------------------------------------------------------
// Public types
// ----------------------------------------------------------------------------

export interface McpToolInfo {
  name: string;
  description?: string;
  inputSchema: Record<string, unknown>;
}

export interface McpConnection {
  name: string;
  tools: McpToolInfo[];
  callTool(name: string, args: Record<string, unknown>): Promise<unknown>;
  close(): Promise<void>;
}

type LogFn = (level: "debug" | "info" | "warn" | "error", msg: string) => void;

// ----------------------------------------------------------------------------
// Constants
// ----------------------------------------------------------------------------

const CONNECT_TIMEOUT_MS = 10_000;
const CALL_TIMEOUT_MS = 60_000;

// ----------------------------------------------------------------------------
// McpClientManager
// ----------------------------------------------------------------------------

export class McpClientManager {
  private _connections: McpConnection[] = [];
  private readonly _log: LogFn;

  constructor(log: LogFn) {
    this._log = log;
  }

  connections(): McpConnection[] {
    return [...this._connections];
  }

  async connect(config: McpServerConfig): Promise<McpConnection> {
    this._log("info", `[MCP] Connecting to server: ${config.name}`);

    let transport: StdioClientTransport | SSEClientTransport;

    if (config.transport === "stdio") {
      if (!config.command) {
        throw new Error(
          `[MCP] Server "${config.name}" has transport=stdio but no command specified`,
        );
      }
      transport = new StdioClientTransport({
        command: config.command,
        args: config.args ?? [],
        env: config.env,
      });
    } else if (config.transport === "sse" || config.transport === "http") {
      if (!config.url) {
        throw new Error(
          `[MCP] Server "${config.name}" has transport=${config.transport} but no url specified`,
        );
      }
      transport = new SSEClientTransport(new URL(config.url));
    } else {
      throw new Error(
        `[MCP] Server "${config.name}" has unknown transport: ${(config as McpServerConfig).transport}`,
      );
    }

    const client = new Client(
      { name: "cmux101", version: "0.1.0" },
      { capabilities: {} },
    );

    // Connect with timeout
    await withTimeout(
      client.connect(transport),
      CONNECT_TIMEOUT_MS,
      `Timed out connecting to MCP server "${config.name}" after ${CONNECT_TIMEOUT_MS}ms`,
    );

    // List tools
    let toolList: McpToolInfo[];
    try {
      const result = await client.listTools();
      toolList = result.tools.map((t) => ({
        name: t.name,
        description: t.description,
        inputSchema: t.inputSchema as Record<string, unknown>,
      }));
    } catch (err) {
      await client.close();
      throw new Error(
        `[MCP] Failed to list tools for server "${config.name}": ${err}`,
      );
    }

    this._log(
      "info",
      `[MCP] Connected to "${config.name}" — ${toolList.length} tool(s): ${toolList.map((t) => t.name).join(", ")}`,
    );

    const conn: McpConnection = {
      name: config.name,
      tools: toolList,
      async callTool(
        toolName: string,
        args: Record<string, unknown>,
      ): Promise<unknown> {
        const result = await withTimeout(
          client.callTool({ name: toolName, arguments: args }),
          CALL_TIMEOUT_MS,
          `MCP tool call "${toolName}" timed out after ${CALL_TIMEOUT_MS}ms`,
        );
        return result;
      },
      async close(): Promise<void> {
        await client.close();
      },
    };

    this._connections.push(conn);
    return conn;
  }

  async disconnectAll(): Promise<void> {
    const conns = this._connections.splice(0);
    await Promise.allSettled(conns.map((c) => c.close()));
  }
}

// ----------------------------------------------------------------------------
// Helpers
// ----------------------------------------------------------------------------

function withTimeout<T>(
  promise: Promise<T>,
  ms: number,
  message: string,
): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(message)), ms);
    promise.then(
      (v) => {
        clearTimeout(timer);
        resolve(v);
      },
      (e) => {
        clearTimeout(timer);
        reject(e);
      },
    );
  });
}
