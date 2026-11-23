// A subagent pane's read of its own records fails before the chat's link is up (review of #37697,
// F2): it stays loading and reads again once the link is up, never settling as empty.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { useOwnLog, type OwnLogRecord } from "./subagentOwnLog";
import { settleReact } from "../../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

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

function mount(): Root {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "IS_REACT_ACT_ENVIRONMENT"]) saved.set(key, scope[key]);
  Object.assign(scope, { window: dom.window, document: dom.window.document, IS_REACT_ACT_ENVIRONMENT: true });
  return (root = createRoot(dom.window.document.getElementById("root")!));
}

test("a read that fails before the link is up stays loading and reads again once it is up", async () => {
  const spawn: OwnLogRecord = {
    seq: 1,
    at: 1,
    dir: "in",
    kind: "subagent_spawned",
    msg: {
      method: "session/update",
      params: {
        _meta: { acpmux: { subagents: [{ id: "a1", parent: null, name: "Audit", state: "completed" }] } },
        update: { sessionUpdate: "subagent_spawned" },
      },
    },
  };
  let calls = 0;
  let up = false;
  const read = async () => {
    calls += 1;
    if (!up) throw new Error("Not connected");
    return [spawn];
  };
  const seen: { loading: boolean; state?: string }[] = [];
  function Probe({ connected }: { connected: boolean }) {
    const own = useOwnLog("a1", { session: "chat" }, read, connected);
    seen.push({ loading: own.loading, state: own.log?.agent?.state });
    return null;
  }
  const view = mount();
  await act(async () => view.render(<Probe connected={true} />));
  expect(calls).toBe(1);
  expect(seen.at(-1)).toEqual({ loading: true, state: undefined });

  // The link drops and comes back: the read runs again and settles with the subagent's own state.
  up = true;
  await act(async () => view.render(<Probe connected={false} />));
  await act(async () => view.render(<Probe connected={true} />));
  expect(calls).toBe(2);
  expect(seen.at(-1)).toEqual({ loading: false, state: "completed" });

  // Settled: another reconnect reads nothing more.
  await act(async () => view.render(<Probe connected={false} />));
  await act(async () => view.render(<Probe connected={true} />));
  expect(calls).toBe(2);
});
