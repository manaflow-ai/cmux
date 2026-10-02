/// How much an approval mode lets the agent do unasked: "ask" before acting, approve
/// what it judges safe ("auto"), or skip approvals ("full"). Agents name their modes
/// themselves (Claude's default, acceptEdits, auto and bypassPermissions; Codex's
/// read-only, agent and agent-full-access). Codex also states the level in
/// `_meta.kind`, which wins; otherwise the level comes from the id.
export type ApprovalLevel = "ask" | "auto" | "full";

export type ApprovalMode = { id: string; _meta?: { [key: string]: unknown } | null };

const KINDS: Record<string, ApprovalLevel> = { standard: "ask", auto_review: "auto", full_access: "full" };

export function approvalLevel(mode: ApprovalMode | string): ApprovalLevel {
  const { id, _meta } = typeof mode === "string" ? { id: mode, _meta: undefined } : mode;
  const kind = _meta?.kind;
  if (typeof kind === "string" && Object.hasOwn(KINDS, kind)) return KINDS[kind]!;
  if (/bypass|full|yolo|dangerous|auto[-_ ]?approve/i.test(id)) return "full";
  if (/^(default|manual|ask|dont[-_ ]?ask|read[-_ ]?only|untrusted|suggest)/i.test(id)) return "ask";
  return "auto";
}

/// Each agent's page on its approval modes, for the menu's "Learn more".
const APPROVAL_DOCS: Record<string, string> = {
  claude: "https://code.claude.com/docs/en/permission-modes",
  codex: "https://learn.chatgpt.com/docs/agent-approvals-security",
};

export function approvalDocs(harness: string | undefined): string | undefined {
  // Variants share their agent's page ("claude-sr" is Claude).
  const key = harness
    ?.split(/[-_\s]+/)
    .find(Boolean)
    ?.toLowerCase();
  return key && Object.hasOwn(APPROVAL_DOCS, key) ? APPROVAL_DOCS[key] : undefined;
}
