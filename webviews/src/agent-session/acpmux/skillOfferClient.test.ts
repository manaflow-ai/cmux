// l10n-allow-file: test fixtures.
// The skill distiller through the client (direct.ts): a `skill_offer` record draws one row on its
// turn, a `skill_resolved` record settles it, and Save or Not now go to the daemon as
// `_acpmux/skill_resolve` (the mock's, mock.ts). A refused save leaves the offer open with the
// daemon's message; a daemon without the `skill-distill-v1` feature draws no card.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { SkillOffer } from "./conversation/skillOffer";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = {
  window: "window" in scope,
  document: "document" in scope,
  values: { window: scope.window, document: scope.document },
};

beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(() => {
  for (const key of ["window", "document"] as const)
    if (saved[key]) scope[key] = saved.values[key];
    else delete scope[key];
});
afterEach(() => {
  delete scope.cmuxAcpmuxMockSkillError;
  delete scope.cmuxAcpmuxMockNoSkillDistill;
});

type Daemon = { record: (target: string, step: unknown, at?: number) => unknown };
type Row = { id: string; kind: string; skill?: SkillOffer };

const DRAFT = {
  name: "run-webview-tests",
  description: "Use when asked to run the webview tests.",
  body: "## Steps\n\n1. Run bun test.",
};
const OFFER = {
  offerId: "s1",
  ...DRAFT,
  count: 3,
  chats: [{ sessionId: "a", prompt: "Run the tests." }],
  drafted: "harness",
};

async function open(extra: unknown[] = []) {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const daemon = socket as unknown as Daemon;
  const steps = [
    { mux: "user_message", msg: { text: "Run the webview tests." } },
    { mux: "turn_started", msg: {} },
    { mux: "turn_result", msg: { status: "completed" } },
    { mux: "skill_offer", msg: OFFER },
    // A turn after it, so a test can wait until every record above was read.
    { mux: "user_message", msg: { text: "Thanks." } },
    ...extra,
  ];
  for (const step of steps) daemon.record(mockHost.sessionId!, step);
  let rows: Row[] = [];
  const wakes: Array<() => void> = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      rows = snapshot.rows as Row[];
      for (const wake of wakes.splice(0)) wake();
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  const skill = () => rows.find((row) => row.kind === "skillOffer")?.skill;
  const until = async (ready: () => boolean) => {
    while (!ready()) await new Promise<void>((resolve) => wakes.push(resolve));
  };
  return { client, skill, until, rows: () => rows };
}

test("an offer record draws one card; a resolution record settles it", async () => {
  const { client, skill, until, rows } = await open([
    { mux: "skill_resolved", msg: { offerId: "s1", action: "save", name: "run-webview-tests", path: "p/SKILL.md" } },
  ]);
  try {
    await until(() => skill()?.outcome !== undefined);
    expect(rows().filter((row) => row.kind === "skillOffer")).toHaveLength(1);
    expect(skill()).toMatchObject({ offerId: "s1", name: "run-webview-tests", count: 3 });
    expect(skill()?.outcome).toEqual({ action: "save", name: "run-webview-tests", path: "p/SKILL.md" });
  } finally {
    client.close?.();
  }
});

test("Save sends the draft, or the edits, and the daemon's answer settles the card", async () => {
  const { client, skill, until } = await open();
  try {
    await until(() => skill() !== undefined);
    await client.resolveSkill("s1", "save", { ...DRAFT, name: "run-tests" });
    expect(skill()?.outcome).toEqual({ action: "save", name: "run-tests", path: ".claude/skills/run-tests/SKILL.md" });
    expect(skill()?.busy).toBeUndefined();
    // A second answer (the daemon's own record) settles nothing twice.
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(skill()?.outcome?.name).toBe("run-tests");
  } finally {
    client.close?.();
  }
});

test("Not now sends a dismissal", async () => {
  const { client, skill, until } = await open();
  try {
    await until(() => skill() !== undefined);
    await client.resolveSkill("s1", "dismiss");
    expect(skill()?.outcome).toEqual({ action: "dismiss" });
  } finally {
    client.close?.();
  }
});

test("a refused save shows the daemon's message and leaves the offer open", async () => {
  const { client, skill, until } = await open();
  try {
    await until(() => skill() !== undefined);
    scope.cmuxAcpmuxMockSkillError = "a skill named run-webview-tests already exists";
    await client.resolveSkill("s1", "save");
    expect(skill()?.error).toBe("a skill named run-webview-tests already exists");
    expect(skill()?.outcome).toBeUndefined();
    expect(skill()?.busy).toBeUndefined();
    delete scope.cmuxAcpmuxMockSkillError;
    await client.resolveSkill("s1", "save");
    expect(skill()).toMatchObject({ outcome: { action: "save", name: "run-webview-tests" }, error: undefined });
  } finally {
    client.close?.();
  }
});

test("a daemon without skill-distill-v1 draws no card", async () => {
  scope.cmuxAcpmuxMockNoSkillDistill = true;
  const { client, rows, until } = await open();
  try {
    await until(() => rows().some((row) => row.kind === "user"));
    await until(() => rows().filter((row) => row.kind === "user").length >= 2);
    expect(rows().some((row) => row.kind === "skillOffer")).toBe(false);
  } finally {
    client.close?.();
  }
});
