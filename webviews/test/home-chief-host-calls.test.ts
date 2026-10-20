// The Chief editor's wire (u2586, docs/chiefs-create-byo-backend.md): Home's sheets and Settings'
// Chiefs card send the backend (`harness`, `model`, `effort`) and `locked` to the host's page
// relay with the gesture fields in one `chief.profile.update`; Undo and Restore are
// `chief.profile.undo {chief, expected_rev, to_rev?}`; History reads `chief.profile.history`; a
// brought backend is `cmux.chief.backend.add`, its check `cmux.chief.backend.doctor {id, prompt}`.
import { expect, test } from "bun:test";
import { ChiefHost, HostChiefEditor, parseBackends, parseHistory } from "../src/pages/home-channels/chiefEditing";
import { chief } from "../src/pages/home-channels/daemonPeople";
import { HomeSheets } from "../src/pages/home-channels/sheets";
import { HomeOps, type HomeChief } from "../src/pages/home-channels/types";
import type { PageClient } from "../src/pages/shared/pageClient";

type Sent = { op: string; params: Record<string, unknown> };

const RAW = {
  id: "agent_chief",
  display_name: "Chief",
  role: "Runs the team's agents",
  personality: "Brief.",
  instructions: "",
  tools: ["chiefs", "spawn", "tell", "workspaces"],
  harnesses: [],
  self_edit: ["avatar"],
  is_default: true,
  rev: 3,
  created_at: "2026-10-10T09:00:00Z",
  avatar: null,
  engine: { harness: "claude", model: "claude-opus-5-5" },
  locked: false,
};

/** A page client that answers what the sheets read and records every call. */
function client(answers: Record<string, unknown> = {}): { client: PageClient; sent: Sent[] } {
  const sent: Sent[] = [];
  return {
    sent,
    client: {
      call: async <R>(op: string, params: unknown) => {
        sent.push({ op, params: params as Record<string, unknown> });
        if (op in answers) return answers[op] as R;
        if (op === HomeOps.capabilities) return { start: true, invite: true, chiefs: true } as R;
        if (op === HomeOps.chiefs) return { chiefs: [chief(RAW)] } as R;
        if (op === "cmux.chief.profile.list") return { chiefs: [RAW] } as R;
        if (op === "cmux.chief.profile.update" || op === "cmux.chief.profile.undo") return { value: RAW } as R;
        return {} as R;
      },
      subscribe: async () => () => {},
      handle: () => () => {},
    },
  };
}

async function homeSheets() {
  const page = client();
  const host = client();
  const sheets = new HomeSheets(page.client, host.client, {
    open: async () => {},
    fail: (message) => {
      throw new Error(message);
    },
  });
  await sheets.start();
  // The relay's list matches the page's: the host relays the person's gesture.
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(sheets.getSnapshot().chiefGrants).toBe(true);
  return { sheets, page, host };
}

test("a Chief record reads its backend and lock", () => {
  const record = chief({ ...RAW, locked: true, engine: { harness: "codex", model: "gpt-6-astra", effort: "high" } });
  expect([record.engine, record.locked]).toEqual([{ harness: "codex", model: "gpt-6-astra", effort: "high" }, true]);
  expect(chief({ ...RAW, engine: {} }).engine).toBeUndefined();
});

test("Home's Save sends the backend and the lock with the gesture fields in one host update", async () => {
  const { sheets, page, host } = await homeSheets();
  const before = sheets.getSnapshot().chiefs.get("agent_chief")!;
  const ok = await sheets.updateChief(before, {
    profile: { name: "Chief", role: before.role, personality: before.personality, instructions: before.instructions },
    engine: { harness: "codex", model: "gpt-6-astra", effort: "high" },
    locked: true,
    picture: undefined,
  });
  expect(ok).toBe(true);
  const updates = host.sent.filter((call) => call.op === "cmux.chief.profile.update");
  expect(updates).toHaveLength(1);
  expect(updates[0]!.params).toMatchObject({
    chief: "agent_chief",
    harness: "codex",
    model: "gpt-6-astra",
    effort: "high",
    locked: true,
  });
  expect(typeof updates[0]!.params.idempotency_key).toBe("string");
  // Nothing of the backend or the lock goes on the page's own connection.
  expect(page.sent.some((call) => call.op === HomeOps.chiefUpdate)).toBe(false);
});

test("Home's Undo and Restore send chief.profile.undo with the record's revision", async () => {
  const { sheets, host } = await homeSheets();
  const editor = sheets.chiefEditor();
  const current = sheets.getSnapshot().chiefs.get("agent_chief")!;
  await editor.undo(current);
  await editor.undo(current, 1);
  const undos = host.sent.filter((call) => call.op === "cmux.chief.profile.undo").map((call) => call.params);
  expect(undos).toHaveLength(2);
  expect(undos[0]).toMatchObject({ chief: "agent_chief", expected_rev: 3 });
  expect("to_rev" in undos[0]!).toBe(false);
  expect(undos[1]).toMatchObject({ chief: "agent_chief", expected_rev: 3, to_rev: 1 });
  expect(undos[0]!.idempotency_key).not.toBe(undos[1]!.idempotency_key);
});

test("History reads chief.profile.history, newest first, who made each revision", async () => {
  const { client: host, sent } = client({
    "cmux.chief.profile.history": {
      chief: "agent_chief",
      revisions: [
        { rev: 1, at: "2026-10-10T09:00:00Z", actor: "owner", operation: "chief.profile.create", record: RAW },
        {
          rev: 2,
          at: "2026-10-11T09:00:00Z",
          actor: { kind: "chief", id: "agent_chief" },
          operation: "chief.profile.update",
          record: { ...RAW, rev: 2 },
        },
      ],
    },
  });
  const revisions = await new ChiefHost(host).history("agent_chief");
  expect(sent[0]).toMatchObject({ op: "cmux.chief.profile.history", params: { chief: "agent_chief" } });
  expect(revisions.map((r) => [r.rev, r.actor])).toEqual([
    [2, "agent_chief"],
    [1, ""],
  ]);
  expect(parseHistory({})).toEqual([]);
});

test("a brought backend is added through the host and checked with a real hello turn", async () => {
  const { client: host, sent } = client({
    "cmux.chief.backend.add": { id: "acme" },
    "cmux.chief.backend.doctor": {
      ok: false,
      steps: [{ name: "prompt", ok: false, detail: "401", fix: "Check the API key." }],
    },
  });
  const calls = new ChiefHost(host);
  const id = await calls.addBackend({
    kind: "openai-endpoint",
    name: "Acme",
    baseUrl: "https://api.acme.dev/v1",
    model: "acme-1",
    apiKey: "sk-secret",
  });
  expect(id).toBe("acme");
  expect(sent[0]).toEqual({
    op: "cmux.chief.backend.add",
    params: {
      kind: "openai-endpoint",
      name: "Acme",
      baseUrl: "https://api.acme.dev/v1",
      model: "acme-1",
      apiKey: "sk-secret",
    },
  });
  const result = await calls.checkBackend("acme");
  expect(sent[1]).toEqual({ op: "cmux.chief.backend.doctor", params: { id: "acme", prompt: true } });
  expect(result).toEqual({
    ok: false,
    steps: [{ name: "prompt", ok: false, detail: "401", fix: "Check the API key." }],
  });
});

test("the backend list is every chat harness acpmux lists, with its models' efforts", () => {
  const list = parseBackends({
    harnesses: {
      defaultHarness: "claude",
      harnesses: {
        codex: { displayName: "Codex" },
        claude: { displayName: "Claude Code" },
        muse: { kind: "terminal" },
        acme: { displayName: "Acme", unavailable: "acme-agent is not on PATH" },
      },
    },
    models: {
      harnesses: [{ harness: "codex", models: [{ id: "gpt-6-astra", name: "GPT-6 Astra", efforts: ["low", "high"] }] }],
    },
  });
  expect(list.map((backend) => backend.id)).toEqual(["claude", "acme", "codex"]);
  expect(list.find((backend) => backend.id === "codex")!.models).toEqual([
    { id: "gpt-6-astra", name: "GPT-6 Astra", efforts: ["low", "high"] },
  ]);
  expect(list.find((backend) => backend.id === "acme")!.unavailable).toBe("acme-agent is not on PATH");
});

test("Settings' editor sends every change through the host, the name and the lock included", async () => {
  const { client: host, sent } = client();
  let done: boolean | undefined;
  const editor = new HostChiefEditor(
    new ChiefHost(host),
    (saved) => (done = saved),
    (message) => {
      throw new Error(message);
    },
  );
  const before: HomeChief = chief(RAW);
  await editor.update(before, {
    profile: {
      name: "Release Chief",
      role: before.role,
      personality: before.personality,
      instructions: before.instructions,
    },
    engine: { harness: "" },
    locked: true,
    picture: undefined,
  });
  expect(done).toBe(true);
  const update = sent.find((call) => call.op === "cmux.chief.profile.update")!;
  expect(update.params).toMatchObject({
    chief: "agent_chief",
    display_name: "Release Chief",
    harness: "",
    locked: true,
  });
  expect("personality" in update.params).toBe(false);
});
