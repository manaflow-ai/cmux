// The mock daemon's other sessions: a few projects on this Mac and on a cloud
// machine, in every state the sidebar draws, so mock-mode screenshots show a
// list someone actually works in rather than a single empty session.

const HOME = "/Users/lawrence";
const MINUTE = 60_000;

type Seed = { id: string; title: string; harness?: string; cwd: string; host?: string; status?: string; minutes: number; pendingPermissions?: number; unread?: boolean; pinned?: boolean };

const seeds: Seed[] = [
  { id: "pin-agent-work", title: "Set up 24/7 agent work", cwd: `${HOME}/src/cmux`, minutes: 50, pinned: true },
  { id: "pin-preflight", title: "Verify preflight GUI workflows", cwd: `${HOME}/src/cmux`, minutes: 180, pinned: true, unread: true },
  { id: "pin-storage", title: "Clean up computer storage", cwd: HOME, minutes: 600, pinned: true },
  { id: "cmux-ack", title: "Fix terminal input owner ACK", cwd: `${HOME}/src/cmux`, minutes: 2, status: "waiting", pendingPermissions: 1 },
  { id: "cmux-ci", title: "Measure cmux CI time per lane", harness: "codex", cwd: `${HOME}/src/cmux`, minutes: 4, status: "running" },
  { id: "cmux-tabs", title: "Agent chats in the tab strip", cwd: `${HOME}/src/cmux`, minutes: 12, unread: true },
  { id: "cmux-fleet", title: "Harden CI fleet reliability", harness: "codex", cwd: `${HOME}/src/cmux`, minutes: 35 },
  { id: "cmux-theme", title: "Catppuccin Mocha for the agent pane", cwd: `${HOME}/src/cmux`, minutes: 70, status: "closed" },
  { id: "cmux-socket", title: "Socket focus policy audit", harness: "codex", cwd: `${HOME}/src/cmux`, minutes: 140, status: "closed" },
  { id: "cmux-reload", title: "Stop tagged reloads by PID", cwd: `${HOME}/src/cmux`, minutes: 260, status: "closed" },
  { id: "cmux-notify", title: "Notifications panel Clear All", cwd: `${HOME}/src/cmux`, minutes: 400, status: "closed" },
  { id: "atlas-sidebar", title: "Port the Codex sidebar metrics", harness: "codex", cwd: `${HOME}/src/codex-atlas-clone`, minutes: 8, status: "running" },
  { id: "atlas-compare", title: "Score the transcript against captures", cwd: `${HOME}/src/codex-atlas-clone`, minutes: 95 },
  { id: "acpmux-tags", title: "Tags with a TTL for pin and archive", harness: "codex", cwd: "/home/lawrence/acpmux", host: "cobalt-butte", minutes: 20, status: "waiting", pendingPermissions: 2 },
  { id: "acpmux-fork", title: "session/fork keeps the parent log", cwd: "/home/lawrence/acpmux", host: "cobalt-butte", minutes: 150, status: "disconnected" },
  { id: "acpmux-rename", title: "Rename slugs from the TUI", cwd: "/home/lawrence/acpmux", host: "cobalt-butte", minutes: 320, status: "closed" },
  { id: "subrouter-quota", title: "Share one REST quota across sessions", harness: "codex", cwd: `${HOME}/src/subrouter`, minutes: 45, unread: true },
  { id: "subrouter-proxy", title: "Proxy retries on 529", cwd: `${HOME}/src/subrouter`, minutes: 500, status: "closed" },
];

/** acpmux session summaries for the seeded sessions, aged relative to `now`. */
export function mockSessions(now: number): Array<{ sessionId: string } & Record<string, unknown>> {
  return seeds.map((seed) => ({
    sessionId: `mock-${seed.id}`,
    title: seed.title,
    harness: seed.harness ?? "claude",
    model: seed.harness === "codex" ? "gpt-6-astra" : "claude-sonnet",
    cwd: seed.cwd,
    ...(seed.host ? { host: seed.host } : {}),
    status: seed.status ?? "idle",
    pendingPermissions: seed.pendingPermissions ?? 0,
    unread: seed.unread ?? false,
    tags: seed.pinned ? ["pinned"] : [],
    createdAt: now - (seed.minutes + 30) * MINUTE,
    updatedAt: now - seed.minutes * MINUTE,
  }));
}

/** Where the mock's own session lives, so it sorts into the busiest project. */
export const MOCK_SESSION_CWD = `${HOME}/src/cmux`;
