/**
 * Built-in slash commands for cmux101 TUI.
 *
 * Commands are dispatched BEFORE the user input reaches the model,
 * allowing them to manipulate session state or display info in-place.
 */

import * as fs from "node:fs/promises";
import * as path from "node:path";
import * as os from "node:os";
import type { SessionHandle, ToolRegistry, Permissions } from "../core/types.js";
import { listSessions } from "../core/session.js";
import { createPowerCommands } from "./power_commands.js";

// ---------------------------------------------------------------------------
// Interfaces
// ---------------------------------------------------------------------------

export interface SlashContext {
  session: SessionHandle;
  toolRegistry: ToolRegistry;
  permissions: Permissions;
  cwd: string;
  abort: () => void;
  exit: () => void;
  appendSystemMessage: (text: string) => Promise<void>;
  refreshSession: (newSessionId?: string) => Promise<void>;
  getMemoryStore: () => any;
}

export interface SlashResult {
  /** Text to display as a system message in the TUI. */
  display?: string;
  /**
   * When true, the runner MUST NOT forward this input to the model.
   * When false, the input was not recognised and should be forwarded normally.
   */
  consumed: boolean;
  /**
   * When set, the TUI sends THIS text to the model instead of the original
   * user input. Only meaningful when consumed is true.
   */
  transformedPrompt?: string;
}

export interface SlashCommand {
  name: string;
  description: string;
  aliases?: string[];
  run(ctx: SlashContext, args: string): Promise<SlashResult>;
}

// ---------------------------------------------------------------------------
// SlashRegistry
// ---------------------------------------------------------------------------

export class SlashRegistry {
  private readonly _commands: Map<string, SlashCommand> = new Map();

  register(cmd: SlashCommand): void {
    this._commands.set(cmd.name, cmd);
    for (const alias of cmd.aliases ?? []) {
      this._commands.set(alias, cmd);
    }
  }

  get(name: string): SlashCommand | undefined {
    return this._commands.get(name);
  }

  list(): SlashCommand[] {
    // Return unique commands (deduplicate aliases)
    const seen = new Set<SlashCommand>();
    const out: SlashCommand[] = [];
    for (const cmd of this._commands.values()) {
      if (!seen.has(cmd)) {
        seen.add(cmd);
        out.push(cmd);
      }
    }
    return out;
  }

  isSlashInput(text: string): boolean {
    return text.startsWith("/");
  }

  async dispatch(input: string, ctx: SlashContext): Promise<SlashResult> {
    if (!this.isSlashInput(input)) {
      return { consumed: false };
    }
    const trimmed = input.slice(1); // strip leading "/"
    const spaceIdx = trimmed.indexOf(" ");
    const name = spaceIdx === -1 ? trimmed : trimmed.slice(0, spaceIdx);
    const args = spaceIdx === -1 ? "" : trimmed.slice(spaceIdx + 1).trim();

    const cmd = this._commands.get(name);
    if (!cmd) {
      // Unknown command — let the model handle it
      return { consumed: false };
    }
    return cmd.run(ctx, args);
  }
}

// ---------------------------------------------------------------------------
// Built-in command implementations
// ---------------------------------------------------------------------------

function makeHelp(registry: SlashRegistry): SlashCommand {
  return {
    name: "help",
    description: "List all slash commands with descriptions.",
    async run(ctx: SlashContext, _args: string): Promise<SlashResult> {
      const commands = registry.list().sort((a, b) => a.name.localeCompare(b.name));
      const lines: string[] = [
        "Available slash commands:",
        "─".repeat(40),
      ];
      for (const cmd of commands) {
        const aliases = cmd.aliases && cmd.aliases.length > 0
          ? ` (aliases: ${cmd.aliases.map((a) => "/" + a).join(", ")})`
          : "";
        lines.push(`  /${cmd.name}${aliases}`);
        lines.push(`      ${cmd.description}`);
      }
      lines.push("─".repeat(40));
      lines.push("Type /<command> [args] and press Enter.");
      return { display: lines.join("\n"), consumed: true };
    },
  };
}

const quitCommand: SlashCommand = {
  name: "quit",
  description: "Exit cmux101.",
  aliases: ["exit"],
  async run(ctx: SlashContext, _args: string): Promise<SlashResult> {
    ctx.exit();
    return { consumed: true };
  },
};

const clearCommand: SlashCommand = {
  name: "clear",
  description: "Start a new session (same provider/model/cwd).",
  async run(ctx: SlashContext, _args: string): Promise<SlashResult> {
    await ctx.refreshSession();
    return {
      display: `Started a new session: ${ctx.session.meta.id}`,
      consumed: true,
    };
  },
};

const modelCommand: SlashCommand = {
  name: "model",
  description: "Display or switch the active model. Usage: /model [name]",
  async run(ctx: SlashContext, args: string): Promise<SlashResult> {
    const currentModel = ctx.session.meta.model;
    if (!args) {
      return {
        display: [
          `Current model: ${currentModel}`,
          "(Pass a model name to switch: /model <name>)",
        ].join("\n"),
        consumed: true,
      };
    }
    // Switch model
    (ctx.session.meta as { model: string }).model = args.trim();
    return {
      display: `Model switched to: ${args.trim()} (takes effect on next message)`,
      consumed: true,
    };
  },
};

const resumeCommand: SlashCommand = {
  name: "resume",
  description: "List recent sessions or resume one. Usage: /resume [session-id]",
  async run(ctx: SlashContext, args: string): Promise<SlashResult> {
    if (args) {
      await ctx.refreshSession(args.trim());
      return {
        display: `Resumed session: ${args.trim()}`,
        consumed: true,
      };
    }
    // List 10 most recent sessions
    let sessions: Awaited<ReturnType<typeof listSessions>>;
    try {
      sessions = await listSessions();
    } catch {
      return {
        display: "Could not list sessions.",
        consumed: true,
      };
    }
    const recent = sessions.slice(0, 10);
    if (recent.length === 0) {
      return { display: "No sessions found.", consumed: true };
    }
    const lines = [
      "Recent sessions (newest first):",
      "─".repeat(60),
      ...recent.map(
        (s, i) =>
          `  ${i + 1}. ${s.id.slice(0, 8)}...  model:${s.model}  started:${s.startedAt.slice(0, 19)}  cwd:${s.cwd}`
      ),
      "─".repeat(60),
      "Use /resume <id> to switch to a session.",
    ];
    return { display: lines.join("\n"), consumed: true };
  },
};

const skillsCommand: SlashCommand = {
  name: "skills",
  description: "List loaded skills.",
  async run(ctx: SlashContext, _args: string): Promise<SlashResult> {
    const memoryStore = ctx.getMemoryStore();
    // SkillRegistry is passed via getMemoryStore returning the ctx's skill registry
    // when it has a list() method. We check for toolRegistry's list() as a fallback.
    // The actual SkillRegistry must be surfaced through getMemoryStore() or another ctx field.
    // Since the spec says "use SkillRegistry passed via ctx", and ctx only exposes getMemoryStore(),
    // we treat getMemoryStore() as an opaque store that may have a listSkills() or be a SkillRegistry.
    let lines: string[];

    if (memoryStore && typeof memoryStore.list === "function") {
      // Could be SkillRegistry or MemoryStore — check for skill-specific shape
      let items: any[];
      try {
        items = memoryStore.list();
      } catch {
        items = [];
      }
      if (items.length === 0) {
        lines = ["No skills loaded."];
      } else {
        lines = [
          "Loaded skills:",
          "─".repeat(40),
          ...items.map((s: any) => `  /${s.name}  — ${s.description ?? "(no description)"}`),
          "─".repeat(40),
        ];
      }
    } else {
      lines = ["No skill registry available."];
    }
    return { display: lines.join("\n"), consumed: true };
  },
};

const memoryCommand: SlashCommand = {
  name: "memory",
  description: "Manage persistent memory. Usage: /memory [list|save <name> <body>|remove <name>]",
  async run(ctx: SlashContext, args: string): Promise<SlashResult> {
    const store = ctx.getMemoryStore();
    if (!store) {
      return { display: "No memory store available.", consumed: true };
    }

    const parts = args.trim().split(/\s+/);
    const subcommand = parts[0] || "list";

    if (subcommand === "list" || !subcommand) {
      let records: any[];
      try {
        records = await store.list();
      } catch (e: any) {
        return { display: `Error listing memories: ${e?.message ?? String(e)}`, consumed: true };
      }
      if (records.length === 0) {
        return { display: "No memories stored.", consumed: true };
      }
      const lines = [
        "Stored memories:",
        "─".repeat(40),
        ...records.map(
          (r: any) => `  [${r.scope ?? "global"}] ${r.name} (${r.type ?? "?"}): ${r.description ?? ""}`
        ),
        "─".repeat(40),
      ];
      return { display: lines.join("\n"), consumed: true };
    }

    if (subcommand === "save") {
      const name = parts[1];
      const body = parts.slice(2).join(" ");
      if (!name || !body) {
        return {
          display: "Usage: /memory save <name> <body>",
          consumed: true,
        };
      }
      try {
        await store.save({
          name,
          description: `Saved via /memory save`,
          type: "user",
          body,
          scope: "global",
        });
        return { display: `Saved memory '${name}'.`, consumed: true };
      } catch (e: any) {
        return { display: `Error saving memory: ${e?.message ?? String(e)}`, consumed: true };
      }
    }

    if (subcommand === "remove") {
      const name = parts[1];
      if (!name) {
        return { display: "Usage: /memory remove <name>", consumed: true };
      }
      try {
        const removed = await store.remove(name);
        return {
          display: removed ? `Removed memory '${name}'.` : `Memory '${name}' not found.`,
          consumed: true,
        };
      } catch (e: any) {
        return { display: `Error removing memory: ${e?.message ?? String(e)}`, consumed: true };
      }
    }

    return {
      display: `Unknown memory subcommand: ${subcommand}. Use list, save, or remove.`,
      consumed: true,
    };
  },
};

const toolsCommand: SlashCommand = {
  name: "tools",
  description: "List registered tools with descriptions.",
  async run(ctx: SlashContext, _args: string): Promise<SlashResult> {
    const tools = ctx.toolRegistry.list();
    if (tools.length === 0) {
      return { display: "No tools registered.", consumed: true };
    }
    const lines = [
      "Registered tools:",
      "─".repeat(50),
      ...tools.map((t) => `  ${t.name}\n      ${t.description}`),
      "─".repeat(50),
    ];
    return { display: lines.join("\n"), consumed: true };
  },
};

const statusCommand: SlashCommand = {
  name: "status",
  description: "Show session info: id, model, provider, cwd, messages, tools, permissions.",
  async run(ctx: SlashContext, _args: string): Promise<SlashResult> {
    const meta = ctx.session.meta;
    const msgCount = ctx.session.messages.length;
    const toolCount = ctx.toolRegistry.list().length;
    const lines = [
      "Session status:",
      "─".repeat(40),
      `  Session ID : ${meta.id}`,
      `  Model      : ${meta.model}`,
      `  Provider   : ${meta.providerId}`,
      `  CWD        : ${meta.cwd}`,
      `  Messages   : ${msgCount}`,
      `  Tools      : ${toolCount}`,
      "─".repeat(40),
    ];
    return { display: lines.join("\n"), consumed: true };
  },
};

const costCommand: SlashCommand = {
  name: "cost",
  description: "Display cumulative token usage and estimated cost.",
  async run(_ctx: SlashContext, _args: string): Promise<SlashResult> {
    return {
      display: "(cost tracking not yet implemented)",
      consumed: true,
    };
  },
};

const permissionsCommand: SlashCommand = {
  name: "permissions",
  description: "Display current permission rules.",
  async run(ctx: SlashContext, _args: string): Promise<SlashResult> {
    // Permissions is an interface — we inspect what we can
    const perm = ctx.permissions as any;
    const lines: string[] = ["Permission rules:", "─".repeat(40)];

    const allow: string[] = perm._allow ?? [];
    const ask: string[] = perm._ask ?? [];
    const deny: string[] = perm._deny ?? [];

    if (allow.length > 0) {
      lines.push("  Allow:");
      for (const p of allow) lines.push(`    - ${p}`);
    } else {
      lines.push("  Allow: (none)");
    }

    if (ask.length > 0) {
      lines.push("  Ask:");
      for (const p of ask) lines.push(`    - ${p}`);
    } else {
      lines.push("  Ask: (none)");
    }

    if (deny.length > 0) {
      lines.push("  Deny:");
      for (const p of deny) lines.push(`    - ${p}`);
    } else {
      lines.push("  Deny: (none)");
    }

    lines.push("─".repeat(40));
    return { display: lines.join("\n"), consumed: true };
  },
};

const exportCommand: SlashCommand = {
  name: "export",
  description: "Export transcript as markdown. Usage: /export [path]",
  async run(ctx: SlashContext, args: string): Promise<SlashResult> {
    const sessionId = ctx.session.meta.id;
    const defaultName = `cmux101-session-${sessionId}.md`;
    const outputPath = args.trim() || path.join(ctx.cwd, defaultName);

    const messages = ctx.session.messages;
    const lines: string[] = [
      `# cmux101 Session Transcript`,
      ``,
      `Session ID: ${sessionId}`,
      `Model: ${ctx.session.meta.model}`,
      `Provider: ${ctx.session.meta.providerId}`,
      `Started: ${ctx.session.meta.startedAt}`,
      `CWD: ${ctx.session.meta.cwd}`,
      ``,
      `---`,
      ``,
    ];

    for (const msg of messages) {
      const roleLabel = msg.role.charAt(0).toUpperCase() + msg.role.slice(1);
      lines.push(`## ${roleLabel}`);
      lines.push(``);
      for (const block of msg.content) {
        if (block.type === "text") {
          lines.push(block.text);
        } else if (block.type === "tool_use") {
          lines.push(`**Tool call:** \`${block.name}\``);
          lines.push("```json");
          lines.push(JSON.stringify(block.input, null, 2));
          lines.push("```");
        } else if (block.type === "tool_result") {
          lines.push(`**Tool result** (id: ${block.tool_use_id})`);
          if (typeof block.content === "string") {
            lines.push(block.content);
          }
        } else if (block.type === "thinking") {
          lines.push(`*Thinking: ${block.thinking}*`);
        }
      }
      lines.push(``);
    }

    try {
      await fs.mkdir(path.dirname(outputPath), { recursive: true });
      await Bun.write(outputPath, lines.join("\n"));
    } catch (e: any) {
      return {
        display: `Error writing export: ${e?.message ?? String(e)}`,
        consumed: true,
      };
    }

    return { display: `Transcript exported to: ${outputPath}`, consumed: true };
  },
};

const initCommand: SlashCommand = {
  name: "init",
  description: "Run the init subcommand to bootstrap project config.",
  async run(_ctx: SlashContext, _args: string): Promise<SlashResult> {
    try {
      await import("../cli/init.js");
      return { display: "Init complete.", consumed: true };
    } catch {
      return {
        display: "Run `cmux101 init` in your shell instead.",
        consumed: true,
      };
    }
  },
};

const doctorCommand: SlashCommand = {
  name: "doctor",
  description: "Run preflight checks: providers, disk write, tools.",
  async run(ctx: SlashContext, _args: string): Promise<SlashResult> {
    const checks: Array<{ label: string; pass: boolean; detail?: string }> = [];

    // 1. Check provider configured
    {
      const providerId = ctx.session.meta.providerId;
      checks.push({
        label: "Provider configured",
        pass: !!providerId && providerId.length > 0,
        detail: providerId ? `Provider: ${providerId}` : "No provider found",
      });
    }

    // 2. Check disk write to ~/.cmux101
    {
      const cmuxDir = path.join(os.homedir(), ".cmux101");
      const testFile = path.join(cmuxDir, ".doctor-write-test");
      let pass = false;
      let detail = "";
      try {
        await fs.mkdir(cmuxDir, { recursive: true });
        await Bun.write(testFile, "ok");
        await fs.unlink(testFile);
        pass = true;
        detail = `Wrote to ${cmuxDir}`;
      } catch (e: any) {
        detail = `Write failed: ${e?.message ?? String(e)}`;
      }
      checks.push({ label: "Disk write (~/.cmux101)", pass, detail });
    }

    // 3. Check at least one tool registered
    {
      const toolCount = ctx.toolRegistry.list().length;
      checks.push({
        label: "Tools registered",
        pass: toolCount > 0,
        detail: `${toolCount} tool(s)`,
      });
    }

    const lines = ["Doctor checks:", "─".repeat(50)];
    for (const check of checks) {
      const status = check.pass ? "PASS" : "FAIL";
      const detail = check.detail ? `  (${check.detail})` : "";
      lines.push(`  [${status}] ${check.label}${detail}`);
    }
    lines.push("─".repeat(50));

    const allPass = checks.every((c) => c.pass);
    lines.push(allPass ? "All checks passed." : "Some checks failed.");

    return { display: lines.join("\n"), consumed: true };
  },
};

/** Build a short programmatic summary of messages (no model call). */
function buildConversationSummary(messages: ReadonlyArray<import("../core/types.js").Message>): string {
  const parts: string[] = [];
  for (const msg of messages) {
    const role = msg.role;
    for (const block of msg.content) {
      if (block.type === "text" && block.text.trim()) {
        const snippet = block.text.trim().slice(0, 120).replace(/\n+/g, " ");
        parts.push(`[${role}] ${snippet}`);
      } else if (block.type === "tool_use") {
        parts.push(`[tool_call] ${block.name}`);
      } else if (block.type === "tool_result") {
        const content = typeof block.content === "string" ? block.content : "(image/multi)";
        const snippet = content.trim().slice(0, 60).replace(/\n+/g, " ");
        parts.push(`[tool_result:${block.tool_use_id?.slice(0, 8) ?? "?"}] ${snippet}`);
      }
    }
  }
  const joined = parts.join("\n");
  return joined.length > 2000 ? joined.slice(0, 1997) + "..." : joined;
}

const compactCommand: SlashCommand = {
  name: "compact",
  description: "Compact the conversation to reduce context size.",
  async run(ctx: SlashContext, _args: string): Promise<SlashResult> {
    const messages = ctx.session.messages;
    const originalCount = messages.length;

    if (originalCount === 0) {
      return { display: "Nothing to compact — conversation is empty.", consumed: true };
    }

    // Keep the last 5 messages verbatim; summarize everything before.
    const KEEP = 5;
    const toSummarize = originalCount > KEEP ? messages.slice(0, originalCount - KEEP) : [];
    const tail = originalCount > KEEP ? [...messages.slice(originalCount - KEEP)] : [...messages];

    const newMessages: import("../core/types.js").Message[] = [];

    if (toSummarize.length > 0) {
      const summary = buildConversationSummary(toSummarize);
      newMessages.push({
        role: "user",
        content: [{ type: "text", text: `[compacted conversation summary]\n${summary}` }],
      });
    }

    newMessages.push(...tail);

    if (!ctx.session.replaceMessages) {
      return {
        display: "This session does not support compaction.",
        consumed: true,
      };
    }
    await ctx.session.replaceMessages(newMessages);

    const newCount = ctx.session.messages.length;
    return {
      display: `Compacted conversation. ${originalCount} messages → ${newCount} messages.`,
      consumed: true,
    };
  },
};

// ---------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------

export function createBuiltinSlashCommands(): SlashCommand[] {
  // We create a temporary registry just to pass to /help so it can list all commands.
  // The real registration happens in the caller; we return the commands and the caller
  // registers them. /help is special — we give it a reference to a registry that the
  // caller MUST set after registration.
  //
  // Pattern: use a lazy-bound registry holder.
  const registryHolder: { registry: SlashRegistry | null } = { registry: null };

  const helpCmd: SlashCommand = {
    name: "help",
    description: "List all slash commands with descriptions.",
    async run(_ctx: SlashContext, _args: string): Promise<SlashResult> {
      const registry = registryHolder.registry;
      if (!registry) {
        return { display: "Help unavailable.", consumed: true };
      }
      const commands = registry.list().sort((a, b) => a.name.localeCompare(b.name));
      const lines: string[] = [
        "Available slash commands:",
        "─".repeat(40),
      ];
      for (const cmd of commands) {
        const aliases =
          cmd.aliases && cmd.aliases.length > 0
            ? ` (aliases: ${cmd.aliases.map((a) => "/" + a).join(", ")})`
            : "";
        lines.push(`  /${cmd.name}${aliases}`);
        lines.push(`      ${cmd.description}`);
      }
      lines.push("─".repeat(40));
      lines.push("Type /<command> [args] and press Enter.");
      return { display: lines.join("\n"), consumed: true };
    },
  };

  const commands: SlashCommand[] = [
    helpCmd,
    quitCommand,
    clearCommand,
    modelCommand,
    resumeCommand,
    skillsCommand,
    memoryCommand,
    toolsCommand,
    statusCommand,
    costCommand,
    permissionsCommand,
    exportCommand,
    initCommand,
    doctorCommand,
    compactCommand,
  ];

  // Wire up the /help registry reference AFTER building the list.
  // The caller should call bindRegistry() if they want /help to list all cmds.
  (commands as any)._bindRegistry = (reg: SlashRegistry) => {
    registryHolder.registry = reg;
  };

  return commands;
}

/**
 * Create a fully wired SlashRegistry with all built-in commands.
 * Use this in production code.
 */
export function createDefaultSlashRegistry(): SlashRegistry {
  const registry = new SlashRegistry();
  const commands = createBuiltinSlashCommands();

  for (const cmd of commands) {
    registry.register(cmd);
  }

  // Register power commands
  for (const cmd of createPowerCommands()) {
    registry.register(cmd);
  }

  // Bind /help's registry reference
  const bindFn = (commands as any)._bindRegistry;
  if (typeof bindFn === "function") {
    bindFn(registry);
  }

  return registry;
}
