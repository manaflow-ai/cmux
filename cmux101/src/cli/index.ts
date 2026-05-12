/**
 * CLI entry point for cmux101.
 *
 * Wires args -> config -> providers/tools/session/runner -> TUI or print.
 */

import { parseArgs } from "./args.ts";
import { login, logout, getApiKey } from "./auth.ts";
import { loadConfig } from "./config.ts";
import { resolveModel } from "./model_router.ts";
import { createDefaultRegistry } from "../providers/index.ts";
import { createDefaultToolRegistry } from "../tools/index.ts";
import { subagentTools } from "../tools/subagent.ts";
import { createSession, resumeSession, listSessions } from "../core/session.ts";
import { createPermissionResolver, PermissionResolver } from "../core/permissions.ts";
import { buildDefaultSystemPrompt } from "../core/system_prompt.ts";
import { discoverProjectContext, renderProjectContext } from "./context.ts";
import { runInit } from "./init.ts";
import { Runner, type RunnerEvent } from "../core/runner.ts";
import { estimateCost } from "../core/cost.ts";
import { runPrint } from "../headless/print.ts";
import { createSubagentDispatcher } from "../core/subagent_dispatcher.ts";
import { cmuxAvailable } from "../tools/cmux/index.ts";
import type { Provider, PermissionLevel, Message, Tool } from "../core/types.ts";
import { runDoctor, renderDoctorReport } from "./doctor.ts";
import { emit } from "./output.ts";

// ---------------------------------------------------------------------------
// Usage text
// ---------------------------------------------------------------------------

const USAGE = `
cmux101 — an agentic coding CLI with first-class cmux integration

Usage:
  cmux101 [flags] [prompt]        Launch TUI (or print mode with -p)
  cmux101 auth login <provider>   Save API key for a provider
  cmux101 auth logout <provider>  Remove saved API key
  cmux101 models [provider]       List available models
  cmux101 init [--force]          Bootstrap project CLAUDE.md + .cmux101/ config
  cmux101 sessions                List recent sessions

Flags:
  -p, --print               Print mode (non-interactive output)
  -m, --model <id>          Override the model
  --provider <id>           Override the provider (anthropic, openai, gemini, ...)
  --cwd <path>              Set working directory
  --resume <session-id>     Resume an existing session
  --show-thinking           Show model thinking/reasoning blocks
  --auto                    Auto-approve all permissions (use with care)
  --plan                    Plan mode (read-only, no side-effects)
  -v, --version             Print version and exit
  -h, --help                Show this help text

Providers (configured via env or 'cmux101 auth login'):
  anthropic   ANTHROPIC_API_KEY
  openai      OPENAI_API_KEY
  gemini      GEMINI_API_KEY | GOOGLE_API_KEY
  openrouter  OPENROUTER_API_KEY
  bedrock     AWS_REGION + AWS credentials
  vertex      GOOGLE_CLOUD_PROJECT + ADC
  ollama      (auto) http://localhost:11434
  lmstudio    (auto) http://localhost:1234
`.trimStart();

// ---------------------------------------------------------------------------
// Version
// ---------------------------------------------------------------------------

async function getVersion(): Promise<string> {
  try {
    const pkgPath = new URL("../../package.json", import.meta.url).pathname;
    const file = Bun.file(pkgPath);
    const pkg = (await file.json()) as { version?: string };
    return pkg.version ?? "0.0.0";
  } catch {
    return "0.0.0";
  }
}

// ---------------------------------------------------------------------------
// Provider selection
// ---------------------------------------------------------------------------

async function pickProvider(
  preferred: string | undefined,
  configDefault: string,
): Promise<Provider> {
  const registry = await createDefaultRegistry();
  registry.loadFromEnv(process.env);

  const targetId = preferred ?? configDefault;
  const provider = registry.get(targetId);
  if (provider) return provider;

  // Fall back to anything configured.
  const available = registry.list();
  if (available.length > 0) {
    console.error(
      `Warning: provider "${targetId}" is not configured. Falling back to "${available[0]!.id}". ` +
        `Run \`cmux101 auth login ${targetId}\` to configure.`,
    );
    return available[0]!;
  }

  console.error(
    `No providers configured. Run \`cmux101 auth login <provider>\` ` +
      `or set an API key env var (ANTHROPIC_API_KEY, OPENAI_API_KEY, ...).`,
  );
  process.exit(1);
}

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

type ModelEntry = {
  id: string;
  contextWindow: number;
  maxOutput: number;
  supportsTools: boolean;
  supportsVision: boolean;
  supportsThinking: boolean;
  error?: string;
};
type ProviderEntry = { providerId: string; displayName: string; models: ModelEntry[] };

async function handleModels(
  preferred: string | undefined,
  parsed: ReturnType<typeof parseArgs>,
): Promise<void> {
  const registry = await createDefaultRegistry();
  registry.loadFromEnv(process.env);

  const providers = preferred
    ? [registry.get(preferred)].filter((p): p is Provider => !!p)
    : registry.list();

  if (providers.length === 0) {
    console.error("No providers configured. Run `cmux101 auth login <provider>`.");
    process.exit(1);
  }

  const data: ProviderEntry[] = [];

  for (const p of providers) {
    try {
      const models = await p.listModels();
      data.push({
        providerId: p.id,
        displayName: p.displayName,
        models: models.map((m) => ({
          id: m.id,
          contextWindow: m.contextWindow,
          maxOutput: m.maxOutput,
          supportsTools: m.supportsTools,
          supportsVision: m.supportsVision,
          supportsThinking: m.supportsThinking,
        })),
      });
    } catch (err) {
      data.push({
        providerId: p.id,
        displayName: p.displayName,
        models: [
          {
            id: "(error)",
            contextWindow: 0,
            maxOutput: 0,
            supportsTools: false,
            supportsVision: false,
            supportsThinking: false,
            error: (err as Error).message,
          },
        ],
      });
    }
  }

  emit(parsed, data, (d) => {
    const rows = d as ProviderEntry[];
    const lines: string[] = [];
    for (const row of rows) {
      lines.push(`\n=== ${row.displayName} (${row.providerId}) ===`);
      for (const m of row.models) {
        if (m.error) {
          lines.push(`  (could not list models: ${m.error})`);
        } else {
          const flags = [
            m.supportsTools ? "tools" : "",
            m.supportsVision ? "vision" : "",
            m.supportsThinking ? "thinking" : "",
          ]
            .filter(Boolean)
            .join(",");
          const canonicalId = `${row.providerId}/${m.id}`;
          lines.push(
            `  ${canonicalId.padEnd(50)}  ctx=${m.contextWindow.toLocaleString().padStart(10)}  out=${m.maxOutput.toLocaleString().padStart(7)}  ${flags}`,
          );
        }
      }
    }
    return lines.join("\n") + "\n";
  });
}

// ---------------------------------------------------------------------------
// Sessions
// ---------------------------------------------------------------------------

async function handleSessions(parsed: ReturnType<typeof parseArgs>): Promise<void> {
  const sessions = await listSessions();

  emit(parsed, sessions.slice(0, 20), (d) => {
    const rows = d as typeof sessions;
    if (rows.length === 0) return "No sessions found.\n";
    const lines = ["Recent sessions:"];
    for (const s of rows) {
      lines.push(`  ${s.id.slice(0, 8)}  ${s.startedAt}  ${s.providerId}/${s.model}  ${s.cwd}`);
    }
    return lines.join("\n") + "\n";
  });
}

// ---------------------------------------------------------------------------
// Auth
// ---------------------------------------------------------------------------

async function handleAuth(
  action: "login" | "logout",
  provider: string,
  key?: string,
): Promise<void> {
  if (action === "login") {
    let apiKey = key;
    if (!apiKey) {
      const fromEnv = await getApiKey(provider);
      if (fromEnv) {
        apiKey = fromEnv;
        console.log(`Using ${provider.toUpperCase()}_API_KEY from environment.`);
      } else {
        process.stdout.write(`Enter API key for ${provider}: `);
        for await (const line of console) {
          apiKey = line.trim();
          break;
        }
      }
    }
    if (!apiKey) {
      console.error("No API key provided.");
      process.exit(1);
    }
    await login(provider, apiKey);
    console.log(`Logged in to ${provider}.`);
  } else {
    await logout(provider);
    console.log(`Logged out from ${provider}.`);
  }
}

// ---------------------------------------------------------------------------
// Session bootstrap (shared by tui and print)
// ---------------------------------------------------------------------------

async function buildSessionInfra(parsed: ReturnType<typeof parseArgs>) {
  const cwd = parsed.cwd ?? process.cwd();
  const config = await loadConfig({ cwd });

  // Resolve model/provider via alias + prefix routing.
  const rawModel = parsed.model ?? config.defaultModel;
  const resolved = resolveModel(rawModel, config);

  // --provider is a manual override; otherwise use what resolveModel decided.
  const providerOverride = parsed.provider ?? resolved.providerId;
  const provider = await pickProvider(providerOverride, config.defaultProvider);
  const model = resolved.modelId;

  const cmuxOk = await cmuxAvailable();
  const toolRegistry = await createDefaultToolRegistry({ includeCmux: cmuxOk });
  for (const t of subagentTools) toolRegistry.register(t);

  // Build a tool-name -> default permission map for the resolver.
  const defaults = new Map<string, PermissionLevel>();
  for (const t of toolRegistry.list()) {
    defaults.set(t.name, t.defaultPermission ?? "ask");
  }

  // Permission mode overrides
  let allow = config.permissions?.allow ?? [];
  let ask = config.permissions?.ask ?? [];
  const deny = config.permissions?.deny ?? [];

  if (parsed.permissionMode === "auto") {
    // Allow everything except hard-deny.
    allow = ["*"];
  } else if (parsed.permissionMode === "plan") {
    // Only allow read-only tools.
    allow = ["file_read", "glob", "grep", "web_fetch", "web_search", "cmux_tree", "cmux_read_screen", "cmux_list_workspaces", "cmux_current_workspace", "cmux_list_panes", "cmux_top"];
    ask = [];
  }

  const permissions: PermissionResolver = createPermissionResolver({
    allow,
    ask,
    deny,
    defaults,
    askUser: async () => "ask", // TUI will override via prompt; in print mode this means "ask" => deny by default
  });

  // Discover and render project context (CLAUDE.md / AGENTS.md files).
  const projectCtx = await discoverProjectContext(cwd);
  const projectContextStr = renderProjectContext(projectCtx);

  const session = parsed.resume
    ? await resumeSession(parsed.resume)
    : await createSession({
        cwd,
        providerId: provider.id,
        model,
        system: buildDefaultSystemPrompt({
          cwd,
          model,
          providerId: provider.id,
          cmuxAvailable: cmuxOk,
          cmuxWorkspaceId: process.env.CMUX_WORKSPACE_ID,
          projectContext: projectContextStr || undefined,
        }),
      });

  // Subagent dispatcher
  const spawnSubagent = createSubagentDispatcher({
    provider,
    toolRegistry,
    parentPermissions: permissions,
    cwd,
    defaultModel: model,
  });

  return { cwd, provider, model, toolRegistry, permissions, session, spawnSubagent, cmuxOk };
}

// ---------------------------------------------------------------------------
// Print (headless) mode
// ---------------------------------------------------------------------------

async function runHeadless(parsed: ReturnType<typeof parseArgs>): Promise<void> {
  let prompt = parsed.prompt;
  if (!prompt) {
    // Read from stdin
    if (process.stdin.isTTY) {
      console.error("No prompt provided. Pipe input or pass as argument:\n  echo 'hello' | cmux101 -p\n  cmux101 -p \"hello\"");
      process.exit(1);
    }
    const chunks: Buffer[] = [];
    for await (const chunk of process.stdin) chunks.push(chunk as Buffer);
    prompt = Buffer.concat(chunks).toString("utf-8").trim();
    if (!prompt) {
      console.error("Empty prompt on stdin.");
      process.exit(1);
    }
  }

  const infra = await buildSessionInfra(parsed);
  const showCost = parsed.showCost ?? false;
  let headlessRunner: Runner | null = null;

  await runPrint({
    session: infra.session,
    provider: infra.provider,
    toolRegistry: infra.toolRegistry,
    permissions: infra.permissions,
    cwd: infra.cwd,
    prompt,
    spawnSubagent: infra.spawnSubagent,
    verbose: parsed.showThinking,
    onRunnerCreated: (r) => { headlessRunner = r; },
  });

  if (showCost && headlessRunner) {
    const usage = (headlessRunner as Runner).getUsage();
    const { usd } = estimateCost(infra.model, usage);
    process.stderr.write(
      `[tokens in/out=${usage.inputTokens}/${usage.outputTokens}  ~$${usd.toFixed(4)}]\n`,
    );
  }
}

// ---------------------------------------------------------------------------
// TUI mode
// ---------------------------------------------------------------------------

async function runInteractive(parsed: ReturnType<typeof parseArgs>): Promise<void> {
  const infra = await buildSessionInfra(parsed);

  // Lazy-load the TUI to avoid pulling React when not needed.
  const { runTui } = await import("../tui/index.ts");

  let runner: Runner | null = null;
  const abortController = new AbortController();

  const onEvent = (event: RunnerEvent): void => {
    if (!tui) return;
    if (event.kind === "stream") tui.handle.pushStreamEvent(event.event);
    else if (event.kind === "tool_pre") tui.handle.pushToolUpdate({ name: event.name, status: "tool_running" });
    else if (event.kind === "tool_output_delta") tui.handle.pushToolUpdate({ name: "(tool)", outputDelta: event.text, status: "tool_running" });
    else if (event.kind === "tool_post") tui.handle.pushToolUpdate({ name: "(tool)", status: "streaming" });
    else if (event.kind === "assistant_message") tui.handle.onMessageAppended(event.message);
    else if (event.kind === "turn_end") tui.handle.pushToolUpdate({ name: "", status: "done" });
    else if (event.kind === "usage_update" && typeof tui.handle.setUsage === "function") {
      tui.handle.setUsage(event.usage);
    }
  };

  const send = async (userText: string): Promise<void> => {
    // Reflect the user message into the TUI immediately.
    const userMsg: Message = { role: "user", content: [{ type: "text", text: userText }] };
    tui.handle.onMessageAppended(userMsg);

    if (!runner) {
      runner = new Runner({
        session: infra.session,
        provider: infra.provider,
        toolRegistry: infra.toolRegistry,
        permissions: infra.permissions,
        abortController,
        cwd: infra.cwd,
        spawnSubagent: infra.spawnSubagent,
        onEvent,
        askUser: (toolName, input) => tui.handle.promptPermission(toolName, input),
      });
    }
    try {
      await runner.run(userText);
    } catch (err) {
      tui.handle.pushStreamEvent({ kind: "error", error: err as Error & { provider?: string } } as never);
    }
  };

  const tui = runTui({
    session: infra.session,
    send,
    abort: () => abortController.abort(),
    showThinking: parsed.showThinking,
    greeting: parsed.prompt,
  });

  // If an initial prompt was passed, kick it off.
  if (parsed.prompt) {
    void send(parsed.prompt);
  }

  await tui.waitUntilExit();
}

// ---------------------------------------------------------------------------
// Main dispatch
// ---------------------------------------------------------------------------

export async function bootstrapCli(argv: string[]): Promise<void> {
  let parsed: ReturnType<typeof parseArgs>;
  try {
    parsed = parseArgs(argv);
  } catch (err) {
    console.error(`Error: ${(err as Error).message}`);
    process.exit(1);
  }

  switch (parsed.mode) {
    case "version": {
      const v = await getVersion();
      console.log(`cmux101 v${v}`);
      break;
    }
    case "help": {
      process.stdout.write(USAGE);
      break;
    }
    case "auth": {
      const sub = parsed.authSubcommand;
      if (!sub) {
        console.error("Usage: cmux101 auth login <provider> | cmux101 auth logout <provider>");
        process.exit(1);
      }
      await handleAuth(sub.action, sub.provider, sub.key);
      break;
    }
    case "models": {
      await handleModels(parsed.provider, parsed);
      break;
    }
    case "init": {
      const cwd = parsed.cwd ?? process.cwd();
      const force = parsed.initOptions?.force ?? false;
      const result = await runInit({ cwd, force });

      const isJson = parsed.outputFormat === "json";

      if (isJson) {
        console.log(JSON.stringify(result, null, 2));
      } else {
        if (result.created.length > 0) {
          console.log("Created:");
          for (const f of result.created) console.log(`  + ${f}`);
        }
        if (result.updated.length > 0) {
          console.log("Updated:");
          for (const f of result.updated) console.log(`  ~ ${f}`);
        }
        if (result.skipped.length > 0) {
          console.log("Skipped (already exists):");
          for (const f of result.skipped) console.log(`  - ${f}`);
        }
      }
      break;
    }
    case "sessions": {
      await handleSessions(parsed);
      break;
    }
    case "doctor": {
      const cwd = parsed.cwd ?? process.cwd();
      const doctorResult = await runDoctor({ cwd });
      emit(parsed, doctorResult, (d) => renderDoctorReport(d as typeof doctorResult) + "\n");
      break;
    }
    case "print": {
      await runHeadless(parsed);
      break;
    }
    case "tui":
    default: {
      await runInteractive(parsed);
      break;
    }
  }
}

if (import.meta.main) {
  const argv = Bun.argv.slice(2);
  await bootstrapCli(argv);
}
