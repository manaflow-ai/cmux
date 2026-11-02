import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { NewestSteerContext, PendingSteer, takesSteersBack } from "./PendingSteer";
import { TurnActionsContext } from "./turnActions";
import type { AcpmuxRow } from "../model";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

const waiting: AcpmuxRow = {
  id: "user-1",
  version: 1,
  at: 1,
  kind: "user",
  text: "Use the cache dir",
  steer: "waiting",
  steerPromptId: "p-1",
};

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
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
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

// acpmux answers send_now before the agent reads the steer: its row still says waiting then, as on
// Leo's row (2026-10-24: "after i clicked send now and it worked it should just disappear").
// Each steer has its own promptId: a Send now that worked is remembered by it for the page's life.
const steers = { count: 0 };
async function render(sendResult: boolean, row: AcpmuxRow = { ...waiting, steerPromptId: `p-${(steers.count += 1)}` }) {
  const container = dom?.window.document.getElementById("root") ?? installDom();
  const unsteer = async () => "back" as const;
  await act(async () => {
    root = createRoot(container);
    root.render(
      <TurnActionsContext.Provider value={{ unsteer }}>
        <PendingSteer row={row} send={async () => sendResult} />
      </TurnActionsContext.Provider>,
    );
  });
  return container;
}

test("Send now and the X disappear immediately once delivery is accepted", async () => {
  const container = await render(true);
  expect(container.querySelector(".cv-user__take-back")).not.toBeNull();
  const button = container.querySelector<HTMLButtonElement>(".cv-user__send-now")!;
  await act(async () => button.click());
  expect(container.querySelector(".cv-user__pending")).toBeNull();
});

test("a row drawn again after Send now worked shows no controls while the steer still waits", async () => {
  const steer: AcpmuxRow = { ...waiting, steerPromptId: "p-scrolled" };
  const container = await render(true, steer);
  await act(async () => container.querySelector<HTMLButtonElement>(".cv-user__send-now")!.click());
  // The transcript dropped the row (scrolled away) and draws it again: acpmux still says waiting.
  await act(async () => root!.unmount());
  await render(true, steer);
  expect(container.querySelector(".cv-user__pending")).toBeNull();
  // Another steer that waits still shows them.
  await act(async () => root!.unmount());
  await render(true);
  expect(container.querySelector(".cv-user__send-now")).not.toBeNull();
});

// Leo, 2026-11-01: "why are ALL of these send now???? aren't these steers???". Send now stops the
// agent's step and the agent then reads every waiting steer, so only the newest offers it; each
// keeps its X (take that one back) and its Copy.
test("with several steers waiting only the newest offers Send now; each keeps its X", async () => {
  const container = installDom();
  root = createRoot(container);
  const rows: AcpmuxRow[] = [1, 2, 3].map((n) => ({ ...waiting, id: `user-many-${n}`, steerPromptId: `p-many-${n}` }));
  await act(async () =>
    root!.render(
      <TurnActionsContext.Provider value={{ unsteer: async () => "back" as const }}>
        <NewestSteerContext.Provider value="user-many-3">
          {rows.map((row) => (
            <div key={row.id} data-row={row.id}>
              <PendingSteer row={row} send={async () => true} />
            </div>
          ))}
        </NewestSteerContext.Provider>
      </TurnActionsContext.Provider>,
    ),
  );
  const sendNows = [...container.querySelectorAll(".cv-user__send-now")];
  expect(sendNows.length).toBe(1);
  expect(sendNows[0]!.closest("[data-row]")?.getAttribute("data-row")).toBe("user-many-3");
  expect(container.querySelectorAll(".cv-user__take-back").length).toBe(3);
});

test("Send now remains available when delivery fails", async () => {
  const failed = await render(false);
  const failureButton = failed.querySelector<HTMLButtonElement>(".cv-user__send-now")!;
  await act(async () => failureButton.click());
  expect(failed.querySelector(".cv-user__send-now")).not.toBeNull();
  expect(failed.querySelector(".cv-user__pending--leaving")).toBeNull();
});

test("Send now and the X disappear when the agent reads the steer first", async () => {
  const container = installDom();
  root = createRoot(container);
  const draw = (row: AcpmuxRow) =>
    act(async () =>
      root!.render(
        <TurnActionsContext.Provider value={{ unsteer: async () => "back" as const }}>
          <PendingSteer row={row} send={() => new Promise<boolean>(() => {})} />
        </TurnActionsContext.Provider>,
      ),
    );
  const steer: AcpmuxRow = { ...waiting, steerPromptId: "p-read-first" };
  await draw(steer);
  await act(async () => container.querySelector<HTMLButtonElement>(".cv-user__send-now")!.click());
  // acpmux's snapshot says the agent read it before Send now's reply came.
  await draw({ ...steer, version: 2, steer: "landed" });
  expect(container.querySelector(".cv-user__pending")).toBeNull();
});

test("a steer read before it was drawn has no Send now or X", async () => {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(
      <TurnActionsContext.Provider value={{ unsteer: async () => "back" as const }}>
        <PendingSteer row={{ ...waiting, steer: "landed" }} send={async () => true} />
      </TurnActionsContext.Provider>,
    );
  });
  expect(container.querySelector(".cv-user__pending")).toBeNull();
});

// Leo, 2026-10-24: "where's the, like, X button? All I see is the send now". His Claude chats run
// a Claude Code profile under its own family name (claude-sr2). Only acpmux's Claude Code adapter
// takes a steer back, and `backgroundsWork` marks a chat that runs it; other agents steer too.
test("the X is offered in every Claude Code chat, whatever its family is named, and nowhere else", () => {
  const sr2 = { harness: "claude-sr2", family: "claude-sr2", steering: true, backgroundsWork: true };
  const claude = { harness: "claude", family: "claude", steering: true, backgroundsWork: true };
  const codex = { harness: "codex", family: "codex", steering: true, backgroundsWork: false };
  expect(takesSteersBack(sr2, true)).toBe(true);
  expect(takesSteersBack(claude, true)).toBe(true);
  expect(takesSteersBack(codex, true)).toBe(false);
  expect(takesSteersBack(claude, false)).toBe(false);
});
