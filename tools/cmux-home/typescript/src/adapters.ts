export const adapterOrder = ["claude", "codex", "opencode", "pi"] as const;

export type AdapterId = (typeof adapterOrder)[number];

export interface ResumeInput {
  adapter: AdapterId;
  sessionId?: string;
  cwd?: string;
  model?: string;
  permissionMode?: string;
  approvalPolicy?: string;
  sandboxMode?: string;
  effort?: string;
  agentName?: string;
  thinking?: string;
}

export interface AgentAdapter {
  id: AdapterId;
  displayName: string;
  executable: string;
  resumeTemplate: string;
  featureGaps: string[];
  resumeCommand(input: ResumeInput): string | undefined;
}

export const adapters: Record<AdapterId, AgentAdapter> = {
  claude: {
    id: "claude",
    displayName: "Claude Code",
    executable: "claude",
    resumeTemplate: "claude --resume <session-id>",
    featureGaps: [
      "permission-mode and model flags need captured launch metadata",
      "MCP and auth environment preservation stays in the cmux runtime",
    ],
    resumeCommand(input) {
      return commandWithCwd(input.cwd, [
        "claude",
        "--resume",
        requiredSessionId(input),
        ...optionalFlag("--model", input.model),
        ...optionalFlag("--permission-mode", input.permissionMode),
      ]);
    },
  },
  codex: {
    id: "codex",
    displayName: "Codex",
    executable: "codex",
    resumeTemplate: "codex resume <session-id>",
    featureGaps: [
      "approval policy, sandbox, and reasoning effort require captured launch metadata",
      "live permission and plan feed integration is not wired in this prototype",
    ],
    resumeCommand(input) {
      return commandWithCwd(input.cwd, [
        "codex",
        "resume",
        ...optionalFlag("--model", input.model),
        ...optionalFlag("--ask-for-approval", input.approvalPolicy),
        ...optionalFlag("--sandbox", input.sandboxMode),
        ...optionalFlag("-c", input.effort ? `model_reasoning_effort=${input.effort}` : undefined),
        requiredSessionId(input),
      ]);
    },
  },
  opencode: {
    id: "opencode",
    displayName: "OpenCode",
    executable: "opencode",
    resumeTemplate: "opencode --session <session-id>",
    featureGaps: [
      "run/pr one-shot sessions are not resumable",
      "SQLite history lookup is external to this package",
    ],
    resumeCommand(input) {
      return commandWithCwd(input.cwd, [
        "opencode",
        "--session",
        requiredSessionId(input),
        ...optionalFlag("-m", input.model),
        ...optionalFlag("--agent", input.agentName),
      ]);
    },
  },
  pi: {
    id: "pi",
    displayName: "Pi",
    executable: "pi",
    resumeTemplate: "pi --session <session-id>",
    featureGaps: [
      "Vault registry discovery is not connected yet",
      "session path, model, and thinking flags require launch metadata",
    ],
    resumeCommand(input) {
      return commandWithCwd(input.cwd, [
        "pi",
        "--session",
        requiredSessionId(input),
        ...optionalFlag("--model", input.model),
        ...optionalFlag("--thinking", input.thinking),
      ]);
    },
  },
};

export function normalizeAdapterId(value: unknown): AdapterId | undefined {
  if (typeof value !== "string") {
    return undefined;
  }
  const normalized = value.trim().toLowerCase().replace(/[\s_-]+/g, "");
  switch (normalized) {
    case "claude":
    case "claudecode":
      return "claude";
    case "codex":
    case "openaicodex":
      return "codex";
    case "opencode":
    case "openkode":
      return "opencode";
    case "pi":
    case "picodingagent":
      return "pi";
    default:
      return undefined;
  }
}

export function compareAdapters(left: AdapterId, right: AdapterId): number {
  return adapterOrder.indexOf(left) - adapterOrder.indexOf(right);
}

export function buildResumeCommand(input: ResumeInput): string | undefined {
  return adapters[input.adapter].resumeCommand(input);
}

export function shellQuote(value: string): string {
  if (/^[A-Za-z0-9_./:=+-]+$/.test(value)) {
    return value;
  }
  return "'" + value.replaceAll("'", "'\\''") + "'";
}

function requiredSessionId(input: ResumeInput): string {
  const sessionId = input.sessionId?.trim();
  return sessionId || "<session-id>";
}

function optionalFlag(flag: string, value: string | undefined): string[] {
  const normalized = value?.trim();
  return normalized ? [flag, normalized] : [];
}

function commandWithCwd(cwd: string | undefined, parts: string[]): string {
  const command = parts.map(shellQuote).join(" ");
  const normalizedCwd = cwd?.trim();
  return normalizedCwd ? `cd ${shellQuote(normalizedCwd)} && ${command}` : command;
}
