// A Chief's backend (its brain's starting engine): Claude by default, Codex, or UniiChat. A new
// Chief names a non-default engine in `chief.profile.create` (`harness`), the page reads the
// record's `engine`, and a Chief's row shows a chip only when its engine is not the default.
import { expect, test } from "bun:test";
import { chief } from "../src/pages/home-channels/daemonPeople";
import { HomeSheets } from "../src/pages/home-channels/sheets";
import { chiefBackendChip, chiefBackendLabel, HomeOps, type HomeChief } from "../src/pages/home-channels/types";

const LABELS: Record<string, string> = {
  "chief.backend.claude": "Claude",
  "chief.backend.codex": "Codex",
  "chief.backend.unii": "UniiChat",
};
const t = (key: string) => LABELS[key] ?? key;

const existing = {
  id: "agent_1",
  display_name: "Ada",
  role: "",
  rev: 1,
  created_at: "2026-10-19T00:00:00Z",
};

/** A page client and a host relay over one registry; the host records each create it relays. */
function sheetsWithHost() {
  const created: Array<Record<string, unknown>> = [];
  const client = {
    call: async (op: string) => {
      if (op === HomeOps.capabilities) return { start: true, invite: true, chiefs: true };
      if (op === HomeOps.chiefs) return { chiefs: [chief(existing)] };
      if (op === HomeOps.startConversation) return { conversation: "conv_1" };
      return {};
    },
  };
  const host = {
    call: async (op: string, params: Record<string, unknown>) => {
      if (op === "cmux.chief.profile.list") return { chiefs: [existing] };
      if (op === "cmux.chief.profile.create") {
        created.push(params);
        return { value: { id: "agent_2", display_name: params.display_name, rev: 1 } };
      }
      return {};
    },
  };
  const sheets = new HomeSheets(client as never, host as never, { open: async () => {}, fail: () => {} });
  return { sheets, created };
}

async function ready(sheets: HomeSheets) {
  await sheets.start();
  // The host probe runs after the list; wait until it marks the relay usable.
  for (let i = 0; i < 20 && !sheets.getSnapshot().chiefGrants; i++) await Promise.resolve();
  expect(sheets.getSnapshot().chiefGrants).toBe(true);
}

const profile = { name: "Uni", role: "", personality: "", instructions: "" };

test("a new Chief on UniiChat names `harness: unii`; on Claude it names no harness", async () => {
  const { sheets, created } = sheetsWithHost();
  await ready(sheets);
  await sheets.createChief(profile, undefined, undefined, "unii");
  expect(created[0]).toMatchObject({ display_name: "Uni", harness: "unii" });
  await sheets.createChief(profile, undefined, undefined, "claude");
  expect("harness" in created[1]!).toBe(false);
  await sheets.createChief(profile, undefined, undefined);
  expect("harness" in created[2]!).toBe(false);
  await sheets.createChief(profile, undefined, undefined, "codex");
  expect(created[3]).toMatchObject({ harness: "codex" });
});

test("the record parser reads the engine, and only the fields it names", () => {
  expect(chief({ ...existing, engine: { harness: "unii", model: "u-1", effort: "high" } }).engine).toEqual({
    harness: "unii",
    model: "u-1",
    effort: "high",
  });
  expect(chief({ ...existing, engine: { harness: "codex" } }).engine).toEqual({ harness: "codex" });
  expect(chief({ ...existing, engine: {} }).engine).toBeUndefined();
  expect(chief(existing).engine).toBeUndefined();
});

test("a Chief's row chip names a non-default engine; the default shows none", () => {
  const record = (engine?: HomeChief["engine"]): HomeChief => ({ ...chief(existing), ...(engine ? { engine } : {}) });
  expect(chiefBackendChip(t, record({ harness: "unii" }))).toBe("UniiChat");
  expect(chiefBackendChip(t, record({ harness: "codex" }))).toBe("Codex");
  expect(chiefBackendChip(t, record({ harness: "claude" }))).toBeUndefined();
  expect(chiefBackendChip(t, record({ harness: "default" }))).toBeUndefined();
  expect(chiefBackendChip(t, record())).toBeUndefined();
  expect(chiefBackendChip(t, undefined)).toBeUndefined();
  // An engine this page does not know shows its id as it is.
  expect(chiefBackendChip(t, record({ harness: "opencode" }))).toBe("opencode");
  expect(chiefBackendLabel(t, undefined)).toBe("Claude");
});
