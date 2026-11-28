import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { PendingSteer } from "./PendingSteer";
import { markSentNow, NewestSteerContext, SteerChatContext, takesSteersBack } from "./pendingSteerModel";
import { TurnActionsContext } from "./turnActions";
import type { AcpmuxRow } from "../model";
import { settleReact } from "../../../../test/support/domTeardown";

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
  await settleReact();
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

// Leo, 2026-11-03: "this looks kinda weird when i send now and there was a previously steered
// message". Send now on the newest steer stops the agent's step, and the agent then reads every
// waiting steer, so the earlier steers it covered drop their X and Copy line with it; left behind,
// the earlier one looked held back while the newer one looked sent.
test("Send now on the newest steer clears the earlier steers it covers", async () => {
  const container = installDom();
  root = createRoot(container);
  const rows: AcpmuxRow[] = [1, 2].map((n) => ({
    ...waiting,
    id: `user-cover-${n}`,
    at: n,
    steerPromptId: `p-cover-${n}`,
  }));
  const draw = (list: AcpmuxRow[], newest: string) =>
    act(async () =>
      root!.render(
        <TurnActionsContext.Provider value={{ unsteer: async () => "back" as const }}>
          <NewestSteerContext.Provider value={newest}>
            {list.map((row) => (
              <div key={row.id} data-row={row.id}>
                <PendingSteer row={row} send={async () => true} />
              </div>
            ))}
          </NewestSteerContext.Provider>
        </TurnActionsContext.Provider>,
      ),
    );
  await draw(rows, "user-cover-2");
  expect(container.querySelectorAll(".cv-user__pending").length).toBe(2);
  await act(async () => container.querySelector<HTMLButtonElement>(".cv-user__send-now")!.click());
  // acpmux still says both wait until the agent reads them.
  expect(container.querySelectorAll(".cv-user__pending").length).toBe(0);
  // A steer sent after that one waits on its own: it offers Send now, and the covered ones stay clear.
  const later: AcpmuxRow = { ...waiting, id: "user-cover-3", at: 3, steerPromptId: "p-cover-3" };
  await draw([...rows, later], "user-cover-3");
  const pending = [...container.querySelectorAll(".cv-user__pending")];
  expect(pending.map((node) => node.closest("[data-row]")?.getAttribute("data-row"))).toEqual(["user-cover-3"]);
  expect(container.querySelectorAll(".cv-user__send-now").length).toBe(1);
});

// cmux#32846: the page switches chats in place, so a Send now in one chat must not clear the earlier
// steers of another. Chat B's steers were sent at the same times as chat A's (two hosts' clocks).
test("Send now in one chat leaves another chat's earlier steers their X", async () => {
  const container = installDom();
  root = createRoot(container);
  const pair = (chat: string): AcpmuxRow[] =>
    [1, 2].map((n) => ({ ...waiting, id: `user-${n}`, at: 100 + n, steerPromptId: `p-${chat}-${n}` }));
  const draw = (chat: string) =>
    act(async () =>
      root!.render(
        <TurnActionsContext.Provider value={{ unsteer: async () => "back" as const }}>
          <SteerChatContext.Provider value={chat}>
            <NewestSteerContext.Provider value="user-2">
              {pair(chat).map((row) => (
                <div key={row.id} data-row={row.id}>
                  <PendingSteer row={row} send={async () => true} />
                </div>
              ))}
            </NewestSteerContext.Provider>
          </SteerChatContext.Provider>
        </TurnActionsContext.Provider>,
      ),
    );
  await draw("chat-a");
  await act(async () => container.querySelector<HTMLButtonElement>(".cv-user__send-now")!.click());
  expect(container.querySelectorAll(".cv-user__pending").length).toBe(0);
  await draw("chat-b");
  expect(container.querySelectorAll(".cv-user__take-back").length).toBe(2);
  expect(container.querySelectorAll(".cv-user__send-now").length).toBe(1);
});

// The same from the composer: a queued prompt sent now (its row's Send now, ComposerQueue.tsx)
// becomes a steer under the same promptId while an earlier steer still waits. Its row must not offer
// Send now again, and the earlier steer goes with it.
test("a queued prompt sent now from the composer shows no Send now again, nor the earlier steer's X", async () => {
  const container = installDom();
  root = createRoot(container);
  markSentNow("p-queued-now");
  const rows: AcpmuxRow[] = [
    { ...waiting, id: "user-queue-1", at: 10, steerPromptId: "p-earlier-steer" },
    { ...waiting, id: "user-queue-2", at: 11, text: "Then add a test", steerPromptId: "p-queued-now" },
  ];
  await act(async () =>
    root!.render(
      <TurnActionsContext.Provider value={{ unsteer: async () => "back" as const }}>
        <NewestSteerContext.Provider value="user-queue-2">
          {rows.map((row) => (
            <PendingSteer key={row.id} row={row} send={async () => true} />
          ))}
        </NewestSteerContext.Provider>
      </TurnActionsContext.Provider>,
    ),
  );
  expect(container.querySelectorAll(".cv-user__pending").length).toBe(0);
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
