// The plain attach says on screen apart from the reader's hand on it, and asks acpmux to leave the
// agent's stream out while the page is not on screen (CMUX-571: about 5 MB/s reached the app's panes
// with chats open, hidden panes included). The host lets exactly these params through.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { plainAttach } from "./attachParams";

/// The params the host lets through for `method`: the one contract, schemas/agent-pane/methods.json,
/// which AcpmuxPaneMethodContractsTests holds knownParams equal to. Read there, never a list copied
/// here: a copy went stale each time base added a param (seenSeq, then cutoverSeq).
const CONTRACT = JSON.parse(readFileSync(`${import.meta.dir}/../../../../schemas/agent-pane/methods.json`, "utf8")) as {
  methods: Record<string, { params: string[] }>;
};

function hostParams(method: string): string[] {
  const entry = CONTRACT.methods[method];
  if (!entry) throw new Error(`no contract entry for ${method}`);
  return entry.params;
}

test("a hidden page's attach asks for no stream while hidden and keeps attending apart", () => {
  const params = plainAttach("chat-1", { settled: false, visible: false, attending: true, local: true, maxBytes: 1 });
  expect(params.visible).toBe(false);
  expect(params.attending).toBe(true);
  expect(params.quietHidden).toBe(true);
});

test("a shown page whose reader is away is still on screen", () => {
  const params = plainAttach("chat-1", { settled: true, visible: true, attending: false, local: false, maxBytes: 1 });
  expect(params.visible).toBe(true);
  expect(params.attending).toBe(false);
});

test("the host lets every param of the plain attach through", () => {
  const params = plainAttach("chat-1", { settled: true, visible: true, attending: true, local: true, maxBytes: 1 });
  const allowed = new Set(hostParams("_acpmux/attach"));
  for (const key of Object.keys(params)) expect(allowed.has(key)).toBe(true);
});
