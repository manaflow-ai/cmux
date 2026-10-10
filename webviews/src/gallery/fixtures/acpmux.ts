// l10n-allow-file: gallery fixture data (sample chats and replies), not shipped UI.
// Builders for the agent pane's real data structures (model.ts AcpmuxRow, AcpmuxSnapshot,
// sessionList.ts AcpmuxSessionEntry), placed on the gallery clock (clock.ts) so relative times
// are stable. Pure data: gallery files and tests import these without a DOM.
import type { AcpmuxActivity, AcpmuxRow, AcpmuxSnapshot } from "../../agent-session/acpmux/model";
import type { AcpmuxSessionEntry } from "../../agent-session/acpmux/sessionList";
import { minutesAgo } from "../clock";

export const SESSION_ID = "gallery-session";
export const CWD = "/Users/you/src/atlas-web";

export const CATALOG: AcpmuxSnapshot["catalog"] = [
  {
    id: "claude",
    name: "Claude Code",
    models: [
      { id: "claude-opus-5-5", name: "Opus 5.5" },
      { id: "claude-sonnet-5-5", name: "Sonnet 5.5" },
      { id: "claude-haiku-4-5", name: "Haiku 4.5" },
    ],
  },
  {
    id: "codex",
    name: "Codex",
    models: [
      { id: "gpt-6-astra", name: "GPT-6-Astra" },
      { id: "gpt-5.6-sol", name: "GPT-5.6-Sol" },
    ],
  },
];

let counter = 0;
const nextId = (prefix: string) => `${prefix}-${(counter += 1)}`;

/** A row `minutes` before the gallery's now. */
export function row(kind: string, minutes: number, fields: Partial<AcpmuxRow> = {}): AcpmuxRow {
  return { id: fields.id ?? nextId(kind), version: 1, at: minutesAgo(minutes), kind, ...fields };
}

export const user = (text: string, minutes: number, fields: Partial<AcpmuxRow> = {}) =>
  row("user", minutes, { text, ...fields });

export const assistant = (text: string, minutes: number, fields: Partial<AcpmuxRow> = {}) =>
  row("assistant", minutes, { text, ...fields });

export const summary = (minutes: number, fields: Partial<AcpmuxRow> = {}) =>
  row("turnSummary", minutes, { durationMs: 42_000, toolCount: 0, ...fields });

type ToolFields = NonNullable<AcpmuxActivity["tool"]>;

export function tool(title: string, kind: string, status: string, fields: Partial<ToolFields> = {}): AcpmuxActivity {
  return { kind: "tool", text: title, tool: { id: nextId("tool"), title, kind, status, ...fields } };
}

export const thought = (text: string): AcpmuxActivity => ({ kind: "thought", text });

export const activity = (items: AcpmuxActivity[], minutes: number, fields: Partial<AcpmuxRow> = {}) =>
  row("activity", minutes, {
    items,
    toolCount: items.filter((item) => item.kind === "tool").length,
    ...fields,
  });

export function session(fields: Partial<AcpmuxSessionEntry> & { sessionId: string }): AcpmuxSessionEntry {
  return {
    displayTitle: fields.title,
    harness: "claude",
    model: "claude-opus-5-5",
    status: "idle",
    cwd: CWD,
    host: "This Mac",
    hostKind: "local",
    pendingPermissions: 0,
    updatedAt: minutesAgo(5),
    ...fields,
  };
}

/** A connected snapshot of one chat: `rows`, with its session in the list. */
export function chat(
  rows: AcpmuxRow[],
  fields: Partial<AcpmuxSnapshot> & { title?: string; harness?: string; model?: string; branch?: string } = {},
): AcpmuxSnapshot {
  const {
    title = "Add retries to the fetch helper",
    harness = "claude",
    model = "claude-opus-5-5",
    branch = "main",
    ...rest
  } = fields;
  return {
    type: "snapshot",
    protocolVersion: 1,
    rows,
    sessions: [session({ sessionId: SESSION_ID, title, harness, model })],
    summary: {
      sessionId: SESSION_ID,
      title,
      harness,
      model,
      effort: "high",
      cwd: CWD,
      host: "This Mac",
      hostKind: "local",
      branch,
      turnCount: rows.filter((candidate) => candidate.kind === "user").length,
      usage: { used: 48_000, size: 200_000 },
      promptCapabilities: { image: true },
    },
    connection: "connected",
    origin: "local",
    sessionId: SESSION_ID,
    isWorking: false,
    queue: [],
    catalog: CATALOG,
    canLoadOlder: false,
    canFork: true,
    ...rest,
  };
}

/** No chat selected: the pane's new chat or New Tab page, with `sessions` in the history. */
export function noChat(sessions: AcpmuxSessionEntry[] = [], fields: Partial<AcpmuxSnapshot> = {}): AcpmuxSnapshot {
  return {
    type: "snapshot",
    protocolVersion: 1,
    rows: [],
    sessions,
    connection: "connected",
    origin: "local",
    isWorking: false,
    queue: [],
    catalog: CATALOG,
    canLoadOlder: false,
    ...fields,
  };
}

const TITLES = [
  "Add retries to the fetch helper",
  "Fix the flaky sidebar drag test",
  "Localize the changes view",
  "Why does the build cache miss on CI?",
  "Draft the release notes for 0.42",
  "Port the settings page to React Aria",
  "Profile the transcript scroll jank",
  "Review PR 17516 route tiers",
  "Make the composer location row smaller",
  "Clean up the old maclease scripts",
  "Explain the pane protocol handshake",
  "Add a dark theme screenshot test",
];

/** `count` sessions over the last days, newest first, cycling through sample titles. */
export function manySessions(count: number): AcpmuxSessionEntry[] {
  return Array.from({ length: count }, (_, index) =>
    session({
      sessionId: `gallery-session-${index}`,
      title: TITLES[index % TITLES.length],
      harness: index % 3 === 1 ? "codex" : "claude",
      model: index % 3 === 1 ? "gpt-6-astra" : "claude-opus-5-5",
      status: index === 0 ? "running" : index === 2 ? "waiting" : "idle",
      pendingPermissions: index === 2 ? 1 : 0,
      unread: index === 1,
      updatedAt: minutesAgo(3 + index * 47),
      cwd: index % 4 === 3 ? "/Users/you/src/cmux" : CWD,
      branch: index % 2 ? `feat-${index}` : "main",
      preview: "Updated the tests and the docs; all checks pass.",
    }),
  );
}
