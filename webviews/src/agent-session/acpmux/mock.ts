import type { AcpmuxRow, AcpmuxSnapshot } from "./model";

// Mock transport: the host answers `ready` with `{transport: "mock"}` when no
// acpmux daemon is wanted (demos, screenshots, tests). The page then keeps a
// small in-memory transcript here and answers chat actions itself, so the
// host never has to speak the pane's action protocol.

export type MockActions = Record<string, (params: Record<string, unknown>) => Promise<unknown>>;

const sessionId = "mock-session";
const catalog = [{ id: "claude", name: "Claude", models: [{ id: "claude-sonnet", name: "Claude Sonnet" }] }, { id: "codex", name: "Codex", models: [{ id: "gpt-6-astra", name: "GPT-6-Astra" }] }];

export function mockSnapshot(rows: AcpmuxRow[], isWorking = false): AcpmuxSnapshot {
  return {
    type: "snapshot",
    protocolVersion: 1,
    rows,
    sessions: [{ sessionId, title: "Mock session" }],
    summary: { sessionId, title: "Mock session", harness: "claude", model: "claude-sonnet" },
    connection: "mock",
    sessionId,
    isWorking,
    queue: [],
    catalog,
    canLoadOlder: false,
  };
}

export function mockReply(prompt: string): string {
  return `Mock reply to **${prompt.replace(/[*_`]/g, "")}**. No acpmux daemon is attached; this pane is running in mock mode.`;
}

export function startMockHost(onSnapshot: (snapshot: AcpmuxSnapshot) => void, schedule: (run: () => void) => void = (run) => { window.setTimeout(run, 400); }): MockActions {
  let rows: AcpmuxRow[] = [{ id: "mock-welcome", version: 1, at: Date.now(), kind: "assistant", text: "Mock agent session. Type a prompt to see the pane render a turn." }];
  let next = 0;
  const publish = (isWorking = false) => onSnapshot(mockSnapshot(rows, isWorking));
  const append = (row: Omit<AcpmuxRow, "id" | "version" | "at">) => { rows = [...rows, { id: `mock-${next++}`, version: 1, at: Date.now(), ...row }]; };
  publish();
  return {
    "chat.send": async ({ text }) => {
      const prompt = String(text ?? "");
      append({ kind: "user", text: prompt });
      publish(true);
      schedule(() => { append({ kind: "assistant", text: mockReply(prompt) }); publish(); });
    },
    "chat.cancel": async () => publish(),
    "chat.permission": async () => publish(),
    "chat.model": async () => undefined,
    "chat.mode": async () => undefined,
    "chat.effort": async () => undefined,
    "chat.select": async () => undefined,
    "chat.new": async () => { rows = []; publish(); },
    "chat.history": async () => undefined,
  };
}
