// The chat front's first interaction at launch (src/agent-session/acpmux/launchInputEcho.ts): while a launch harness
// reads the marks, the first change of the composer's prompt after a key reports `pane.inputEchoed` once, after
// the frame that draws it, for the launch mark `agent_pane.input_echoed`. A change with no key before it (a restored
// draft) reports nothing, and with no harness reading nothing runs.
import { afterEach, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import {
  composerChanged,
  resetLaunchInputEchoForTest,
  watchLaunchInputEcho,
} from "../src/agent-session/acpmux/launchInputEcho";

describe("watchLaunchInputEcho", () => {
  afterEach(() => resetLaunchInputEchoForTest());

  function page(measured = true) {
    const dom = new JSDOM(`<!doctype html><main id="root"></main>`, { pretendToBeVisual: true });
    // What the host's `__snapshot/chat.js` sets while a launch harness reads the marks.
    if (measured) Object.assign(dom.window, { __cmuxLaunchMeasured: true });
    const sent: [string, Record<string, unknown>][] = [];
    const report = (method: string, params: Record<string, unknown>) => {
      sent.push([method, params]);
      return Promise.resolve(null);
    };
    const view = dom.window as unknown as Window;
    const drawn = () => new Promise((resolve) => view.requestAnimationFrame(() => view.setTimeout(resolve, 5)));
    return { dom, view, sent, report, drawn };
  }

  test("the first change after a key reports once, after its frame", async () => {
    const { dom, view, sent, report, drawn } = page();
    watchLaunchInputEcho(report, dom.window.document);
    // A restored draft before any key is no echo.
    composerChanged(view);
    await drawn();
    expect(sent).toEqual([]);
    view.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "x" }));
    const before = Date.now();
    composerChanged(view);
    expect(sent).toEqual([]);
    await drawn();
    expect(sent.map(([method]) => method)).toEqual(["pane.inputEchoed"]);
    expect(sent[0][1].echoedEpochMs as number).toBeGreaterThanOrEqual(before);
    composerChanged(view);
    await drawn();
    expect(sent.length).toBe(1);
  });

  test("with no launch harness reading, nothing is watched or sent", async () => {
    const { dom, view, sent, report, drawn } = page(false);
    watchLaunchInputEcho(report, dom.window.document);
    view.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "x" }));
    composerChanged(view);
    await drawn();
    expect(sent).toEqual([]);
  });
});
