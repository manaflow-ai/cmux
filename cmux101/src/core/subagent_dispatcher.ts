/**
 * Real implementation of SubagentDispatcher. Constructs a child Session,
 * child Runner with narrowed permissions/tools, and runs to completion.
 *
 * Worktree isolation: when isolation === "worktree", we shell out to
 * `git worktree add` into a temp dir, point the child runner's cwd at it,
 * and clean up on success.
 */

import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type {
  Provider,
  SubagentDispatcher,
  SubagentRequest,
  SubagentResult,
  Tool,
  Permissions,
  HookEvent,
  HookResponse,
} from "./types.ts";
import type { BuiltinToolRegistry } from "../tools/index.ts";
import { Runner } from "./runner.ts";
import { createSession } from "./session.ts";

export interface DispatcherDeps {
  provider: Provider;
  /** Parent tool registry. Subagent will see a filtered subset. */
  toolRegistry: BuiltinToolRegistry;
  /** Parent permissions. Subagent gets a narrowed copy. */
  parentPermissions: Permissions;
  /** Default cwd if the request doesn't isolate. */
  cwd: string;
  /** Default model if the request doesn't override. */
  defaultModel: string;
  /** Optional hook bridge. */
  emitHook?: (event: HookEvent) => Promise<HookResponse>;
  log?: (level: "debug" | "info" | "warn" | "error", text: string) => void;
}

export function createSubagentDispatcher(deps: DispatcherDeps): SubagentDispatcher {
  return async (req: SubagentRequest): Promise<SubagentResult> => {
    const log = deps.log ?? (() => {});

    // Set up cwd: isolate via worktree if requested.
    let childCwd = deps.cwd;
    let worktreeCleanup: (() => void) | null = null;
    if (req.isolation === "worktree") {
      const wt = setupWorktree(deps.cwd, log);
      if (wt) {
        childCwd = wt.path;
        worktreeCleanup = wt.cleanup;
      } else {
        log("warn", "worktree isolation requested but not available; running in parent cwd");
      }
    }

    // Build a child registry with optional tool subset.
    const allTools = deps.toolRegistry.list();
    const allowed = req.tools ? new Set(req.tools) : null;
    const childTools: Tool[] = allowed ? allTools.filter((t) => allowed.has(t.name)) : allTools;
    const childRegistry = new (deps.toolRegistry.constructor as { new (): BuiltinToolRegistry })();
    for (const t of childTools) childRegistry.register(t);

    // Narrow permissions: child sees only its allowed tool names as "allow",
    // everything else "deny".
    const childPermissions = req.tools
      ? deps.parentPermissions.narrow(req.tools)
      : deps.parentPermissions;

    // Create a child session.
    const session = await createSession({
      cwd: childCwd,
      providerId: deps.provider.id,
      model: req.model ?? deps.defaultModel,
      system: req.system,
    });

    const abortController = new AbortController();
    let totalIn = 0;
    let totalOut = 0;
    const finalTexts: string[] = [];

    const runner = new Runner({
      session,
      provider: deps.provider,
      toolRegistry: childRegistry,
      permissions: childPermissions,
      abortController,
      cwd: childCwd,
      // Subagents can't spawn further subagents by default.
      spawnSubagent: undefined,
      emitHook: deps.emitHook,
      log,
      system: req.system,
      onEvent: (event) => {
        if (event.kind === "stream" && event.event.kind === "usage") {
          totalIn += event.event.inputTokens;
          totalOut += event.event.outputTokens;
        }
        if (event.kind === "assistant_message") {
          for (const block of event.message.content) {
            if (block.type === "text") finalTexts.push(block.text);
          }
        }
      },
    });

    let ok = true;
    try {
      await runner.run(req.prompt);
    } catch (err) {
      ok = false;
      log("error", `subagent ${req.label} failed: ${err instanceof Error ? err.message : String(err)}`);
    } finally {
      if (worktreeCleanup) worktreeCleanup();
    }

    return {
      text: finalTexts.join("\n").trim() || "(no output)",
      usage: { inputTokens: totalIn, outputTokens: totalOut },
      transcriptPath: join(process.env.HOME ?? "", ".cmux101", "sessions", session.meta.id, "transcript.jsonl"),
      ok,
    };
  };
}

function setupWorktree(parentCwd: string, log: (level: "debug" | "info" | "warn" | "error", text: string) => void): { path: string; cleanup: () => void } | null {
  // Verify parent is a git repo.
  const check = spawnSync("git", ["rev-parse", "--show-toplevel"], { cwd: parentCwd, encoding: "utf-8" });
  if (check.status !== 0) return null;
  const top = check.stdout.trim();

  const wtDir = mkdtempSync(join(tmpdir(), "cmux101-wt-"));
  const branchName = `cmux101-subagent-${Date.now()}-${Math.floor(Math.random() * 10000)}`;
  const addRes = spawnSync(
    "git",
    ["worktree", "add", "-b", branchName, wtDir, "HEAD"],
    { cwd: top, encoding: "utf-8" },
  );
  if (addRes.status !== 0) {
    log("warn", `git worktree add failed: ${addRes.stderr}`);
    try { rmSync(wtDir, { recursive: true, force: true }); } catch {}
    return null;
  }

  return {
    path: wtDir,
    cleanup: () => {
      try {
        spawnSync("git", ["worktree", "remove", "--force", wtDir], { cwd: top });
      } catch {}
      if (existsSync(wtDir)) {
        try { rmSync(wtDir, { recursive: true, force: true }); } catch {}
      }
    },
  };
}
