import codexRecording from "./fixtures/agent-session-events.ndjson?raw";
import claudeRecording from "./fixtures/claude-live-notifications.ndjson?raw";
import type { AcpmuxRow, AcpmuxSnapshot } from "../acpmux/model";
import { commandsFromUpdate } from "../acpmux/slashCommands";
import { sessionEntry } from "../acpmux/sessionList";

const catalog = [
  {
    id: "codex",
    name: "Codex",
    models: [
      { id: "gpt-6-astra", name: "GPT-6-Astra" },
      { id: "gpt-5.6-sol", name: "GPT-5.6-Sol" },
    ],
  },
  { id: "claude", name: "Claude", models: [{ id: "claude-sonnet", name: "Claude Sonnet" }] },
];

export type PreviewFixture = { id: string; label: string; snapshot: AcpmuxSnapshot; replay?: AcpmuxRow[] };

const previewStartedAt = Date.now() - 5 * 60_000;

function baseSnapshot(title: string, harness = "codex"): AcpmuxSnapshot {
  return {
    type: "snapshot",
    protocolVersion: 1,
    rows: [],
    sessions: [sessionEntry({ sessionId: "preview-session", title, harness })],
    summary: {
      sessionId: "preview-session",
      title,
      harness,
      model: harness === "claude" ? "claude-sonnet" : "gpt-6-astra",
      effort: "high",
    },
    connection: "connected",
    sessionId: "preview-session",
    isWorking: false,
    queue: [],
    catalog,
    canLoadOlder: false,
  };
}

function recordingRows(raw: string, title: string, harness: string): { snapshot: AcpmuxSnapshot; replay: AcpmuxRow[] } {
  const snapshot = baseSnapshot(title, harness);
  const rows: AcpmuxRow[] = [];
  const replay: AcpmuxRow[] = [];
  let assistant: AcpmuxRow | undefined;
  let sequence = 0;
  const append = (row: AcpmuxRow) => {
    rows.push(row);
    replay.push(structuredClone(row));
  };
  for (const line of raw.split(/\r?\n/)) {
    if (!line.trim()) continue;
    let event: Record<string, unknown>;
    try {
      event = JSON.parse(line) as Record<string, unknown>;
    } catch {
      continue;
    }
    const eventKind = String(event.kind ?? (event.update as Record<string, unknown> | undefined)?.sessionUpdate ?? "");
    const msg = (event.msg ?? event.update ?? {}) as Record<string, unknown>;
    const commands = commandsFromUpdate((msg.params as Record<string, unknown> | undefined)?.update ?? event.update);
    if (commands) {
      snapshot.commands = commands;
      continue;
    }
    const content = (msg.content ?? {}) as Record<string, unknown>;
    const text = String(msg.text ?? content.text ?? "");
    if (eventKind === "user_message" || eventKind === "session/prompt") {
      append({
        id: `user-${sequence++}`,
        version: 1,
        at: Number(event.at ?? Date.now()),
        kind: "user",
        text: String(msg.text ?? msg.prompt ?? ""),
      });
    } else if (eventKind === "agent_message_chunk") {
      if (!assistant) {
        assistant = {
          id: `assistant-${sequence++}`,
          version: 1,
          at: Number(event.at ?? Date.now()),
          kind: "assistant",
          text: "",
          streaming: true,
        };
        append(assistant);
      }
      assistant.text = `${assistant.text ?? ""}${text}`;
      assistant.version += 1;
      const last = rows[rows.length - 1];
      if (last?.id === assistant.id) rows[rows.length - 1] = structuredClone(assistant);
      else append(structuredClone(assistant));
    } else if (eventKind === "agent_thought_chunk" || eventKind === "think") {
      append({
        id: `thought-${sequence++}`,
        version: 1,
        at: Number(event.at ?? Date.now()),
        kind: "plan",
        text: text || "Thinking…",
      });
    } else if (
      eventKind === "tool_call" ||
      eventKind === "tool_call_update" ||
      eventKind === "execute" ||
      eventKind === "read"
    ) {
      append({
        id: `activity-${sequence++}`,
        version: 1,
        at: Number(event.at ?? Date.now()),
        kind: "activity",
        toolCount: 1,
        items: [
          {
            kind: "tool",
            text: String(msg.title ?? msg.name ?? eventKind),
            tool: {
              id: `tool-${sequence}`,
              title: String(msg.title ?? eventKind),
              kind: eventKind,
              status: "completed",
              inputSummary: String(msg.input ?? msg.path ?? ""),
            },
          },
        ],
      });
    } else if (eventKind === "turn_end" || eventKind === "status") {
      if (eventKind === "turn_end") {
        if (assistant) assistant.streaming = false;
        append({
          id: `summary-${sequence++}`,
          version: 1,
          at: Number(event.at ?? Date.now()),
          kind: "turnSummary",
          durationMs: 4200,
          toolCount: rows.filter((row) => row.kind === "activity").length,
        });
      }
    }
  }
  snapshot.rows = rows;
  snapshot.isWorking = false;
  return { snapshot, replay };
}

function syntheticSnapshot(): AcpmuxSnapshot {
  const snapshot = baseSnapshot("5,000 row fling", "codex");
  snapshot.rows = Array.from({ length: 5000 }, (_, index) => {
    const kind = index % 9 === 0 ? "user" : index % 7 === 0 ? "activity" : index % 11 === 0 ? "plan" : "assistant";
    return {
      id: `seed-${index}`,
      version: 1,
      at: previewStartedAt + index,
      kind,
      text:
        kind === "activity"
          ? undefined
          : `${kind === "user" ? "Prompt" : "Result"} ${index}: The quick brown fox crosses a markdown paragraph with **bold text** and a code sample.`,
      toolCount: kind === "activity" ? 2 : undefined,
      items:
        kind === "activity"
          ? [
              {
                kind: "tool",
                text: "Read package metadata",
                tool: {
                  id: `seed-tool-${index}`,
                  title: "Read",
                  kind: "read",
                  status: "completed",
                  inputSummary: "Packages/macOS/CmuxAcpmux",
                },
              },
            ]
          : undefined,
    };
  });
  return snapshot;
}

function permissionSnapshot(): AcpmuxSnapshot {
  const snapshot = baseSnapshot("Update project dependencies", "codex");
  snapshot.rows = [
    {
      id: "permission-user",
      version: 1,
      at: previewStartedAt,
      kind: "user",
      text: "Please update the project dependencies.",
    },
    {
      id: "permission-plan",
      version: 1,
      at: previewStartedAt + 1000,
      kind: "plan",
      text: "I need to edit package files and run the test suite.",
    },
  ];
  snapshot.queue = [
    { id: "queue-1", prompt: "Then check the lockfile diff" },
    { id: "queue-2", prompt: "Summarize the changes" },
  ];
  snapshot.permission = {
    permissionId: "preview-permission",
    title: "Allow writing package files?",
    pending: true,
    options: [
      { id: "allow", name: "Allow", allow: true },
      { id: "deny", name: "Deny", allow: false },
    ],
  };
  return snapshot;
}

function groupedPermissionSnapshot(): AcpmuxSnapshot {
  const snapshot = permissionSnapshot();
  snapshot.permission = undefined;
  snapshot.permissionGroups = {
    supported: true,
    ready: true,
    loading: false,
    busy: false,
    chatAllowance: false,
    groups: [
      {
        groupId: "preview-group",
        sessionId: snapshot.sessionId!,
        turnId: "preview-turn",
        revision: 4,
        state: "pending",
        decision: null,
        decisions: ["allow_once", "allow_chat", "deny"],
        items: [
          {
            permissionId: "edit-package",
            state: "pending",
            request: {
              toolCall: {
                title: "Update package.json",
                kind: "edit",
                rawInput: { path: "package.json", dependency: "typescript" },
              },
              options: [
                { optionId: "yes", name: "Allow", kind: "allow_once" },
                { optionId: "no", name: "Deny", kind: "reject_once" },
              ],
            },
          },
          {
            permissionId: "edit-lockfile",
            state: "pending",
            request: {
              toolCall: { title: "Update bun.lock", kind: "edit", rawInput: { path: "bun.lock" } },
              options: [
                { optionId: "yes", name: "Allow", kind: "allow_once" },
                { optionId: "no", name: "Deny", kind: "reject_once" },
              ],
            },
          },
          {
            permissionId: "run-tests",
            state: "pending",
            request: {
              toolCall: { title: "Run project tests", kind: "execute", rawInput: { command: "bun test" } },
              options: [
                { optionId: "yes", name: "Allow", kind: "allow_once" },
                { optionId: "no", name: "Deny", kind: "reject_once" },
              ],
            },
          },
        ],
      },
    ],
  };
  return snapshot;
}

const codex = recordingRows(codexRecording, "Codex recorded session", "codex");
const claude = recordingRows(claudeRecording, "Claude recorded session", "claude");

function sessionListSnapshot(): AcpmuxSnapshot {
  const now = Date.now();
  const minutes = (count: number) => now - count * 60_000;
  const web = "/Users/preview/src/web";
  const sessions = [
    {
      sessionId: "web-1",
      name: "codex",
      harness: "codex",
      title: "Fix the checkout page",
      cwd: web,
      status: "waiting",
      pendingPermissions: 1,
      updatedAt: minutes(1),
    },
    {
      sessionId: "web-2",
      name: "claude",
      harness: "claude",
      title: "Port the sidebar",
      cwd: web,
      status: "running",
      updatedAt: minutes(3),
    },
    {
      sessionId: "web-3",
      name: "codex-2",
      harness: "codex",
      title: "Review the pricing copy",
      cwd: web,
      status: "idle",
      unread: true,
      updatedAt: minutes(9),
    },
    ...Array.from({ length: 6 }, (_, index) => ({
      sessionId: `web-old-${index}`,
      name: "codex",
      harness: "codex",
      title: `Older task ${index + 1}`,
      cwd: web,
      status: "closed",
      updatedAt: minutes(60 + index),
    })),
    {
      sessionId: "app-1",
      name: "release-notes",
      harness: "claude",
      title: "Draft notes",
      cwd: "/Users/preview/src/app",
      status: "disconnected",
      updatedAt: minutes(20),
    },
    {
      sessionId: "home-1",
      name: "claude",
      harness: "claude",
      title: "Clean up dotfiles",
      cwd: "/Users/preview",
      status: "idle",
      updatedAt: minutes(40),
    },
  ].map(sessionEntry);
  return { ...baseSnapshot("Port the sidebar", "claude"), sessions, sessionId: "web-2" };
}

export const previewFixtures: PreviewFixture[] = [
  { id: "codex-recording", label: "Codex recording", snapshot: codex.snapshot, replay: codex.replay },
  { id: "claude-recording", label: "Claude recording", snapshot: claude.snapshot, replay: claude.replay },
  {
    id: "streaming-replay",
    label: "Live streaming replay",
    snapshot: { ...codex.snapshot, rows: [] },
    replay: codex.replay,
  },
  { id: "synthetic-5000", label: "5,000 row fling", snapshot: syntheticSnapshot() },
  { id: "grouped-permissions", label: "Grouped tool permissions", snapshot: groupedPermissionSnapshot() },
  { id: "permission-queue", label: "Permission and queue", snapshot: permissionSnapshot() },
  { id: "session-list", label: "Session list", snapshot: sessionListSnapshot() },
];
