// Toggle Terminal and Chat's approval (Leo, 2026-11-12: the terminal and GUI toggle is "the
// sauce", two live views of one session, instant both ways). While the terminal drives the
// session, this chat is a View Only watch and acpmux sends it no permission: the harness asks in
// the terminal (Claude Code's "Do you want to proceed?", Codex's "Would you like to run the
// following command?"). The host reads that dialog off the terminal's screen (cmux-window-rules
// `tabs::approval`) and pushes it here (`terminalApproval`, CmuxNextAgentPane
// AgentPaneTerminalApproval); the chat draws it as its own permission card, and a click asks the
// host to pick that option in the terminal (`chat.terminalApproval.answer {key, label, id}`).
// A module store like toolCards/toolCardStore.ts, so a push that arrives before the
// dock mounts is kept.
import { useSyncExternalStore } from "react";
import type { AcpmuxPermission } from "../model";

export type TerminalApprovalOption = {
  /// The number the dialog draws before the option: what the host picks.
  key: number;
  label: string;
  /// As an ACP option reads: allow_once, allow_always, reject_once or other.
  kind: string;
};

export type TerminalApproval = {
  /// What the dialog asks, whole (cmux-window-rules `TerminalApproval::id`): a click names it, so it
  /// answers only this dialog, never another asking the same question about another command.
  id: string;
  question: string;
  /// The dialog's heading ("Bash command", "Edit file").
  header?: string;
  command?: string;
  detail: string[];
  options: TerminalApprovalOption[];
  /// The terminal's harness (claude, codex), for the card's look.
  harness?: string;
};

/// The host op a click on the card calls.
export const TERMINAL_APPROVAL_ANSWER_OP = "chat.terminalApproval.answer";

const MAX_TEXT = 2048;
const MAX_OPTIONS = 9;
const MAX_DETAIL = 12;
const text = (value: unknown) => (typeof value === "string" ? value.slice(0, MAX_TEXT) : "");

/// The pushed dialog, or null for none or anything malformed.
export function parseTerminalApproval(value: unknown): TerminalApproval | null {
  if (!value || typeof value !== "object") return null;
  const raw = value as Record<string, unknown>;
  const id = text(raw.id).trim();
  const question = text(raw.question).trim();
  if (!id || !question || !Array.isArray(raw.options)) return null;
  const options: TerminalApprovalOption[] = [];
  for (const entry of raw.options as unknown[]) {
    if (!entry || typeof entry !== "object") continue;
    const option = entry as Record<string, unknown>;
    const key = option.key;
    const label = text(option.label).trim();
    if (typeof key !== "number" || !Number.isSafeInteger(key) || key < 1 || !label) continue;
    options.push({ key, label, kind: text(option.kind) || "other" });
  }
  if (options.length < 2 || options.length > MAX_OPTIONS) return null;
  const detail = Array.isArray(raw.detail)
    ? (raw.detail as unknown[])
        .map(text)
        .filter((line) => line.trim())
        .slice(0, MAX_DETAIL)
    : [];
  const header = text(raw.header).trim();
  const command = text(raw.command).trim();
  const harness = text(raw.harness).trim();
  return {
    id,
    question,
    ...(header ? { header } : {}),
    ...(command ? { command } : {}),
    detail,
    options,
    ...(harness ? { harness } : {}),
  };
}

/// The dialog as the chat's permission card reads an ask: its heading as the tool's title, its
/// first detail row (Claude Code's description, Codex's reason) as what the call does, else the
/// question; each option by its number. The id changes with the dialog, so a new one is a new card.
export function terminalApprovalPermission(approval: TerminalApproval): AcpmuxPermission {
  const reason = approval.detail[0]?.replace(/^Reason:\s*/i, "").trim();
  const kind = toolKind(approval);
  return {
    permissionId: `terminal:${approval.id}`,
    title: approval.header ?? approval.question,
    description: reason || approval.question,
    ...(approval.command ? { command: approval.command } : {}),
    ...(kind ? { kind } : {}),
    pending: true,
    options: approval.options.map((option) => ({
      id: String(option.key),
      name: option.label,
      allow: option.kind.startsWith("allow"),
      ...(option.kind === "other" ? {} : { kind: option.kind }),
    })),
  };
}

/// The tool kind the card's icon shows: a command runs, else what the dialog's heading names.
function toolKind(approval: TerminalApproval): string | undefined {
  if (approval.command) return "execute";
  const header = approval.header?.toLowerCase() ?? "";
  if (/edit|write|create/.test(header)) return "edit";
  if (/read/.test(header)) return "read";
  if (/fetch|web/.test(header)) return "fetch";
  return undefined;
}

/// What a click on option `optionId` sends the host: the option and the dialog the card showed, so the
/// host types nothing when the terminal shows another dialog by then.
export function terminalApprovalAnswer(approval: TerminalApproval, optionId: string) {
  const option = approval.options.find((o) => String(o.key) === optionId);
  if (!option) return null;
  return { key: option.key, label: option.label, id: approval.id };
}

let current: TerminalApproval | null = null;
const listeners = new Set<() => void>();

/// Replaces the dialog from a host push; null or anything malformed clears it.
export function setTerminalApproval(value: unknown): void {
  const next = parseTerminalApproval(value);
  if (next === null && current === null) return;
  current = next;
  for (const listener of listeners) listener();
}

export function terminalApproval(): TerminalApproval | null {
  return current;
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function useTerminalApproval(): TerminalApproval | null {
  return useSyncExternalStore(subscribe, terminalApproval, terminalApproval);
}

// The old page host's push (`window.cmuxAcpmuxTerminalApproval?.(value)`); the page host's is the
// `terminalApproval` event (pageHost.ts).
declare global {
  interface Window {
    cmuxAcpmuxTerminalApproval?: (value: unknown) => void;
  }
}
if (typeof window !== "undefined") window.cmuxAcpmuxTerminalApproval = setTerminalApproval;
