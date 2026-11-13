// A new chat that will start on another of the person's machines checks that the agent it shows is
// set up there (Austin, 2026-11-12): the machine's default is picked for it when the machine names
// one, Send is held with a notice otherwise, and a machine that does not answer holds nothing.
import { afterEach, expect, test } from "bun:test";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import {
  type MachineHarnessCheck,
  type MachineHarnesses,
  machineHarnessVerdict,
  readMachineHarnesses,
  useMachineHarnessCheck,
  withMachineHarnesses,
} from "./machineHarnesses";
import { useMachineHarnesses } from "./catalog";
import type { AcpmuxSnapshot } from "./model";

/// A peer's `_acpmux/harnesses` as acpmux forwards it (requests.rs adds `peer`).
const STUDIO_REPLY = {
  harnesses: {
    claude: { kind: "acp", family: "claude" },
    codex: { kind: "acp", family: "codex", unavailable: "codex-acp not found" },
    shell: { kind: "terminal" },
    router: { kind: "cmux-router" },
    hidden: { kind: "acp", pickerHidden: true },
    opencode: { kind: "acp" },
  },
  defaultHarness: "claude",
  peer: "studio",
};

test("a machine's reply lists the agents a chat there can start on, and its default", () => {
  const machine = readMachineHarnesses(STUDIO_REPLY)!;
  expect([...machine.ids].sort()).toEqual(["claude", "opencode"]);
  expect(machine.defaultHarness).toBe("claude");
  // A default the machine cannot start is no default.
  expect(readMachineHarnesses({ ...STUDIO_REPLY, defaultHarness: "codex" })!.defaultHarness).toBeUndefined();
  expect(readMachineHarnesses({ error: "no" })).toBeUndefined();
  expect(readMachineHarnesses(undefined)).toBeUndefined();
});

test("an agent the machine has is fine; one it lacks switches to its one default, else holds Send", () => {
  const machine = readMachineHarnesses(STUDIO_REPLY)!;
  expect(machineHarnessVerdict("claude", machine)).toEqual({ kind: "ok" });
  expect(machineHarnessVerdict("codex", machine)).toEqual({ kind: "switch", to: "claude" });
  // No default, but only one agent: that one.
  expect(machineHarnessVerdict("codex", { ids: new Set(["opencode"]) })).toEqual({ kind: "switch", to: "opencode" });
  // No default and several agents: no one sensible pick, so Send waits for the person's.
  expect(machineHarnessVerdict("codex", { ids: new Set(["opencode", "claude"]) })).toEqual({ kind: "missing" });
  expect(machineHarnessVerdict("codex", { ids: new Set() })).toEqual({ kind: "missing" });
});

test("a machine that did not answer, or no agent shown yet, never holds Send", () => {
  expect(machineHarnessVerdict("codex", undefined)).toEqual({ kind: "ok" });
  expect(machineHarnessVerdict(undefined, readMachineHarnesses(STUDIO_REPLY))).toEqual({ kind: "ok" });
});

const entry = (id: string, extra: Partial<AcpmuxSnapshot["catalog"][number]> = {}) => ({
  id,
  name: id,
  models: [{ id: `${id}-model`, name: `${id} model` }],
  ...extra,
});

test("the model picker keeps an agent the machine lacks listed, its models greyed with why", () => {
  const catalog = [entry("claude"), entry("codex"), entry("terminal", { pickable: false })];
  const machine: MachineHarnesses = { ids: new Set(["claude"]) };
  const shown = withMachineHarnesses(catalog, machine, "Not set up on studio");
  expect(shown[0]).toBe(catalog[0]!);
  expect(shown[1]).toMatchObject({ id: "codex", unavailable: "Not set up on studio", probeFailed: true });
  expect(shown[1]!.models.every((model) => model.unavailable === "Not set up on studio")).toBe(true);
  // Not a chat agent anyway: left as it is.
  expect(shown[2]).toBe(catalog[2]!);
  // Nothing missing, or no answer: the same array.
  const onlyClaude = catalog.slice(0, 1);
  expect(withMachineHarnesses(onlyClaude, machine, "x")).toBe(onlyClaude);
  expect(withMachineHarnesses(catalog, undefined, "x")).toBe(catalog);
});

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>");
  for (const key of ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const settle = () =>
  act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });

/// The pane's wiring in small: the machine's agents (useMachineHarnesses), the verdict for the
/// selected agent, and the check that switches it or holds Send. A switch lands as the pane's does:
/// the selection becomes the agent asked for.
function Pane({
  reply,
  start,
  switches,
  out,
}: {
  reply: () => Promise<unknown>;
  start: string;
  switches: string[];
  out: { check?: MachineHarnessCheck };
}) {
  const [selected, setSelected] = useState(start);
  const machine = useMachineHarnesses(
    { id: 1, client: { harnesses: async () => [], peerHarnesses: reply } },
    "studio",
    true,
  );
  out.check = useMachineHarnessCheck({
    peer: "studio",
    selected,
    verdict: machineHarnessVerdict(selected, machine),
    switching: false,
    switchTo: (harness) => {
      switches.push(harness);
      setSelected(harness);
    },
  });
  return <span data-selected={selected} />;
}

async function renderPane(reply: () => Promise<unknown>, start: string) {
  const container = installDom();
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const switches: string[] = [];
  const out: { check?: MachineHarnessCheck } = {};
  await act(async () => {
    root = createRoot(container);
    root.render(
      <QueryClientProvider client={client}>
        <Pane reply={reply} start={start} switches={switches} out={out} />
      </QueryClientProvider>,
    );
  });
  await settle();
  await settle();
  return { container, switches, out };
}

test("an agent the machine lacks becomes the machine's default before Send, once", async () => {
  const { container, switches, out } = await renderPane(async () => STUDIO_REPLY, "codex");
  expect(switches).toEqual(["claude"]);
  expect(container.querySelector("span")?.getAttribute("data-selected")).toBe("claude");
  expect(out.check).toEqual({ blocked: false, notice: false });
});

test("with no one default the selection stays, Send is held and the notice shows", async () => {
  const reply = { harnesses: { claude: {}, opencode: {} }, peer: "studio" };
  const { container, switches, out } = await renderPane(async () => reply, "codex");
  expect(switches).toEqual([]);
  expect(container.querySelector("span")?.getAttribute("data-selected")).toBe("codex");
  expect(out.check).toEqual({ blocked: true, notice: true });
});

test("a refused or failed read of the machine holds nothing", async () => {
  const { switches, out } = await renderPane(
    () => Promise.reject(new Error("peer did not report harnesses in 5 s")),
    "codex",
  );
  expect(switches).toEqual([]);
  expect(out.check).toEqual({ blocked: false, notice: false });
});
