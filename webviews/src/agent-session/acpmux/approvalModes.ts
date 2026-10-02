/// How much an approval mode lets the agent do unasked: "ask" before acting, approve
/// what it judges safe ("auto"), or skip approvals ("full"). Agents name their modes
/// themselves (Claude's default, acceptEdits, auto and bypassPermissions; Codex's
/// read-only, auto and full-access), so the level comes from the id.
export type ApprovalLevel = "ask" | "auto" | "full";

export function approvalLevel(modeId: string): ApprovalLevel {
  if (/bypass|full|yolo|dangerous|auto[-_ ]?approve/i.test(modeId)) return "full";
  if (/^(default|manual|ask|read[-_ ]?only|untrusted|suggest)/i.test(modeId)) return "ask";
  return "auto";
}

/// Each agent's page on its approval modes, for the menu's "Learn more".
const APPROVAL_DOCS: Record<string, string> = {
  claude: "https://code.claude.com/docs/en/permission-modes",
  codex: "https://developers.openai.com/codex/agent-approvals-security",
};

export function approvalDocs(harness: string | undefined): string | undefined {
  // Variants share their agent's page ("claude-sr" is Claude).
  const key = harness
    ?.split(/[-_\s]+/)
    .find(Boolean)
    ?.toLowerCase();
  return key && Object.hasOwn(APPROVAL_DOCS, key) ? APPROVAL_DOCS[key] : undefined;
}
