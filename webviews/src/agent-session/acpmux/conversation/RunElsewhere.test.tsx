// l10n-allow-file: test fixture commands, paths and machine names, not shipped UI.
// "Run on a bigger machine": the chip shows on a running shell row from 20 s on and never on a
// finished one or a non-shell; a click shows exactly what goes (secret-looking files left out
// until ticked, untracked files staying) and starts the run with the plan's digest; the run's
// output streams in under the row in order, and the reads stop when it ends.
import { afterEach, expect, jest, test } from "bun:test";
import { act } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { translate } from "../i18n";
import type { AcpmuxActivity } from "../model";
import { CommandRow } from "./CommandRow";
import { ToolRow } from "./ToolRow";
import {
  RUN_ELSEWHERE_AFTER_MS,
  RunElsewhereContext,
  RunElsewhereStore,
  appendOutput,
  chipDueAt,
  firstMachine,
  nextReadDelay,
  RUN_OUTPUT_KEEP,
  type RunElsewhere,
  type RunOutput,
  type RunPlan,
} from "./runElsewhereModel";
import { resetTranscriptDisclosure } from "./transcriptDisclosureModel";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    if (!saved.has(key)) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  jest.useRealTimers();
  resetTranscriptDisclosure();
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const call = (status: string, startedAt: number, command = "cargo test", kind = "execute"): AcpmuxActivity => ({
  kind: "tool",
  text: command,
  tool: { id: "t1", title: command, kind, status, command, startedAt },
});

const PLAN: RunPlan = {
  eligible: true,
  machines: [
    { name: "laptop", ok: false, why: "not connected now" },
    { name: "build-box", ok: true },
  ],
  tree: {
    origin: "https://github.com/acme/app.git",
    base: "4f1c2a9be03d7e51a2c6f0b8d9e4a7c3b1f05e62",
    prefix: "",
    files: [
      { path: "src/lib.rs", status: "M", secret: false },
      { path: ".env", status: "A", secret: true },
    ],
    untracked: ["scratch.txt"],
    untrackedTotal: 1,
    patchBytes: 900,
    digest: "d1",
  },
};

/** Lets the client's resolved promises and their `.then`s run, with no wall-clock wait. */
const flush = () =>
  act(async () => {
    for (let i = 0; i < 8; i++) await Promise.resolve();
  });

/** Moves the reader's fake clock on, then lets the read it starts settle. */
async function advance(ms: number) {
  await act(async () => void jest.advanceTimersByTime(ms));
  await flush();
}

function harness(outputs: RunOutput[] = []) {
  const calls: { started?: unknown[]; reads: number[]; stopped: string[] } = { reads: [], stopped: [] };
  const runs: RunElsewhere = {
    store: new RunElsewhereStore(),
    client: {
      plan: async () => PLAN,
      start: async (...args) => {
        calls.started = args;
        return { id: "bg-7" };
      },
      output: async (_task, from) => {
        calls.reads.push(from);
        return outputs.shift() ?? { data: "", nextByte: from, state: "running" };
      },
      stop: async (id) => void calls.stopped.push(id),
    },
  };
  return { runs, calls };
}

async function render(item: AcpmuxActivity, runs: RunElsewhere, Row: typeof CommandRow = CommandRow) {
  const host = installDom();
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <RunElsewhereContext.Provider value={runs}>
        <div className="cv-tools">
          <Row item={item} />
        </div>
      </RunElsewhereContext.Provider>,
    ),
  );
  return host;
}

const b64 = (text: string) => Buffer.from(text, "utf8").toString("base64");

test("a row renders to a string, with or without the store, as the transcript's server renders do", () => {
  // useSyncExternalStore throws under renderToString without a server snapshot.
  const { runs } = harness();
  for (const Row of [CommandRow, ToolRow]) {
    expect(renderToStaticMarkup(<Row item={call("in_progress", Date.now())} />)).toContain("cargo test");
    expect(
      renderToStaticMarkup(
        <RunElsewhereContext.Provider value={runs}>
          <Row item={call("in_progress", Date.now())} />
        </RunElsewhereContext.Provider>,
      ),
    ).toContain("cargo test");
  }
});

test("the chip is due 20 s into a running shell command and never otherwise", () => {
  const base = { kind: "execute", command: "make", startedAt: 1000, running: true };
  expect(chipDueAt(base)).toBe(1000 + RUN_ELSEWHERE_AFTER_MS);
  expect(chipDueAt({ ...base, running: false })).toBeUndefined();
  expect(chipDueAt({ ...base, kind: "read" })).toBeUndefined();
  expect(chipDueAt({ ...base, command: "  " })).toBeUndefined();
  expect(chipDueAt({ ...base, startedAt: undefined })).toBeUndefined();
});

test("a machine that can take the run is picked first, the last one used before others", () => {
  const machines = [
    { name: "a", ok: false },
    { name: "b", ok: true },
    { name: "c", ok: true },
  ];
  expect(firstMachine(machines)).toBe("b");
  expect(firstMachine(machines, "c")).toBe("c");
  expect(firstMachine(machines, "a")).toBe("b");
  expect(firstMachine([{ name: "a", ok: false }])).toBeUndefined();
});

test("output keeps its newest bytes from a line start, and quiet reads back off to 2 s", () => {
  const long = "x".repeat(RUN_OUTPUT_KEEP - 2) + "\nnext line\n";
  const kept = appendOutput(long, "more\n");
  expect(kept.length).toBeLessThanOrEqual(RUN_OUTPUT_KEEP);
  expect(kept).toBe("next line\nmore\n");
  let delay = 250;
  for (let i = 0; i < 6; i++) delay = nextReadDelay(delay, false);
  expect(delay).toBe(2000);
  expect(nextReadDelay(delay, true)).toBe(250);
});

test("a command running under 20 s, a finished one and a non-shell show no chip", async () => {
  const { runs } = harness();
  let host = await render(call("in_progress", Date.now() - 5_000), runs);
  expect(host.querySelector(".cv-run-elsewhere-chip")).toBeNull();
  await act(async () => root!.unmount());
  root = undefined;
  host = await render(call("completed", Date.now() - 60_000), runs);
  expect(host.querySelector(".cv-run-elsewhere-chip")).toBeNull();
  await act(async () => root!.unmount());
  root = undefined;
  host = await render(call("in_progress", Date.now() - 60_000, "Read src/lib.rs", "read"), runs, ToolRow);
  expect(host.querySelector(".cv-run-elsewhere-chip")).toBeNull();
});

test("a click shows what goes, leaves the secret out, and starts with the plan's digest", async () => {
  const { runs, calls } = harness();
  const host = await render(call("in_progress", Date.now() - 30_000), runs);
  const chip = host.querySelector<HTMLElement>(".cv-run-elsewhere-chip");
  expect(chip?.textContent).toBe(translate("runElsewhere.chip"));
  const row = host.querySelector<HTMLButtonElement>(".cv-command")!;
  await act(async () => chip!.click());
  await flush();
  expect(row.getAttribute("aria-expanded")).toBe("false");
  const panel = host.querySelector(".cv-run-elsewhere")!;
  expect(panel.textContent).toContain("src/lib.rs");
  expect(panel.textContent).toContain(".env");
  expect(panel.textContent).toContain("scratch.txt");
  expect(panel.textContent).toContain("4f1c2a9be");
  const radios = [...panel.querySelectorAll<HTMLInputElement>("input[type=radio]")];
  expect(radios.map((r) => [r.value, r.checked, r.disabled])).toEqual([
    ["laptop", false, true],
    ["build-box", true, false],
  ]);
  // The focus is in the panel, on the machine picked, so Return runs and Escape closes.
  expect(host.ownerDocument.activeElement).toBe(radios[1]);
  const run = panel.querySelector<HTMLButtonElement>(".cv-run-elsewhere__run")!;
  expect(run.textContent).toContain(translate("runElsewhere.run", { machine: "build-box" }));
  await act(async () => run.click());
  await flush();
  expect(calls.started).toEqual(["cargo test", "build-box", "d1", []]);
  expect(host.querySelector(".cv-run-elsewhere-chip")).toBeNull();
});

test("ticking a secret-looking file sends it", async () => {
  const { runs, calls } = harness();
  const host = await render(call("in_progress", Date.now() - 30_000), runs);
  await act(async () => host.querySelector<HTMLElement>(".cv-run-elsewhere-chip")!.click());
  await flush();
  const box = host.querySelector<HTMLInputElement>(".cv-run-elsewhere input[type=checkbox]")!;
  await act(async () => box.click());
  await act(async () => host.querySelector<HTMLButtonElement>(".cv-run-elsewhere__run")!.click());
  await flush();
  expect(calls.started).toEqual(["cargo test", "build-box", "d1", [".env"]]);
});

test("the run's output streams in under the row in order, drains its tail and stops reading when it ends", async () => {
  // A multi-byte character split across two reads arrives whole.
  const bytes = Buffer.from("line 1\nné\n", "utf8");
  const { runs, calls } = harness([
    { data: bytes.subarray(0, 9).toString("base64"), nextByte: 9, state: "running" },
    { data: bytes.subarray(9).toString("base64"), nextByte: bytes.length, state: "running" },
    // The task ended with bytes still unread: the reader takes them before it stops.
    { data: b64("done\n"), nextByte: bytes.length + 5, totalBytes: bytes.length + 11, state: "exited", exitCode: 3 },
    { data: b64("tail!\n"), nextByte: bytes.length + 11, totalBytes: bytes.length + 11, state: "exited", exitCode: 3 },
  ]);
  runs.store.set("t1", { phase: "running", machine: "build-box", taskId: "bg-7", output: "" });
  // The reader's timing is the behavior here: its clock is fake, so the reads land on the 250 ms marks.
  jest.useFakeTimers();
  const host = await render(call("in_progress", Date.now() - 30_000), runs);
  await flush();
  for (let i = 0; i < 5; i++) await advance(300);
  const out = host.querySelector(".cv-run-elsewhere__output");
  expect(out?.textContent).toBe("line 1\nné\ndone\ntail!\n");
  expect(calls.reads).toEqual([0, 9, bytes.length, bytes.length + 5]);
  const status = host.querySelector(".cv-run-elsewhere__title")!;
  expect(status.textContent).toBe(translate("runElsewhere.ended", { machine: "build-box", code: "3" }));
  await advance(5_000);
  expect(calls.reads.length).toBe(4);
});

test("a row shown again goes on reading where it stopped, without repeating output", async () => {
  // "é" is split between the two reads, with the row away in between.
  const bytes = Buffer.from("one é\n", "utf8");
  const { runs, calls } = harness([
    { data: bytes.subarray(0, 5).toString("base64"), nextByte: 5, state: "running" },
    { data: bytes.subarray(5).toString("base64"), nextByte: bytes.length, state: "running" },
  ]);
  runs.store.set("t1", { phase: "running", machine: "build-box", taskId: "bg-7", output: "" });
  jest.useFakeTimers();
  await render(call("in_progress", Date.now() - 30_000), runs);
  await flush();
  // The virtual transcript drops the row off screen, then shows it again.
  await act(async () => root!.unmount());
  const host = await render(call("in_progress", Date.now() - 30_000), runs);
  await flush();
  expect(calls.reads).toEqual([0, 5]);
  expect(host.querySelector(".cv-run-elsewhere__output")?.textContent).toBe("one é\n");
});

test("Stop stops the task on the other machine", async () => {
  const { runs, calls } = harness();
  runs.store.set("t1", { phase: "running", machine: "build-box", taskId: "bg-7", output: "" });
  const host = await render(call("in_progress", Date.now() - 30_000), runs);
  await act(async () => host.querySelector<HTMLButtonElement>(".cv-run-elsewhere__link")!.click());
  expect(calls.stopped).toEqual(["bg-7"]);
});

test("a host that refuses the plan says the build can't do it, and Cancel is the pane's own button", async () => {
  // Leo, 2026-11-11, on "Stays on this machine: Refused by the cmux host" over a grey bezel
  // "Cancel⎋": "what is this? and the weird symbol after cancel? and the weird looking cancel?"
  const { runs } = harness();
  runs.client.plan = async () => {
    throw Object.assign(new Error("Refused by the cmux host"), { code: "transport.method_refused" });
  };
  const host = await render(call("in_progress", Date.now() - 30_000), runs);
  await act(async () => host.querySelector<HTMLElement>(".cv-run-elsewhere-chip")!.click());
  await flush();
  const panel = host.querySelector(".cv-run-elsewhere")!;
  expect(panel.textContent).toContain(translate("runElsewhere.unavailable"));
  expect(panel.textContent).not.toContain("Refused by the cmux host");
  const cancel = panel.querySelector<HTMLButtonElement>(".cv-run-elsewhere__cancel")!;
  expect([...cancel.classList]).toEqual(expect.arrayContaining(["ui-button", "ui-btn"]));
  expect(cancel.dataset.variant).toBe("subtle");
  expect(panel.querySelector(".cv-run-elsewhere__run")).toBeNull();
  await act(async () => cancel.click());
  expect(host.querySelector(".cv-run-elsewhere")).toBeNull();
});

test("a dropped connection is not said as a build that can't send commands", async () => {
  const { runs } = harness();
  runs.client.plan = async () => {
    throw Object.assign(new Error("No connection to acpmux"), { code: "transport.no_connection" });
  };
  const host = await render(call("in_progress", Date.now() - 30_000), runs);
  await act(async () => host.querySelector<HTMLElement>(".cv-run-elsewhere-chip")!.click());
  await flush();
  expect(host.querySelector(".cv-run-elsewhere")!.textContent).not.toContain(translate("runElsewhere.unavailable"));
});

test("acpmux's own reason a command stays is still said", async () => {
  const { runs } = harness();
  runs.client.plan = async () => {
    throw new Error("vim needs this machine");
  };
  const host = await render(call("in_progress", Date.now() - 30_000), runs);
  await act(async () => host.querySelector<HTMLElement>(".cv-run-elsewhere-chip")!.click());
  await flush();
  expect(host.querySelector(".cv-run-elsewhere")!.textContent).toContain(
    translate("runElsewhere.stays", { why: "vim needs this machine" }),
  );
});
