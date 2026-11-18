// The started-agent pills, ported from Swift `HomeAgentPills`: each state draws its own mark and
// status, and a report is unread until the person opens it.
import { afterEach, describe, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { cardStrings } from "../strings";
import { AgentPills } from "./AgentPills";
import { agentPills } from "./agentModel";

const strings = cardStrings(["en"]);

describe("agentPills", () => {
  test("each state keeps its state; unknown states work; a report is unread by default", () => {
    const pills = agentPills({
      peers: ["a1", "a2", "a3", "a4", "a5"],
      titles: ["Fix", "Build", "Audit", "Scroll", "Odd"],
      states: ["told", "reported", "stopped", "queued", "mystery"],
    });
    expect(pills.map((pill) => pill.state)).toEqual(["told", "reported", "stopped", "queued", "told"]);
    expect(pills.map((pill) => pill.unread)).toEqual([false, true, false, false, false]);
  });

  test("a seen report has no dot; titles that do not match the peers show the ids", () => {
    const pills = agentPills({ peers: ["a1", "a2"], titles: ["only one"], states: ["reported"], unread: [false] });
    expect(pills.map((pill) => [pill.title, pill.state, pill.unread])).toEqual([
      ["a1", "reported", false],
      ["a2", "told", false],
    ]);
  });
});

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) scope[key] = value;
  saved.clear();
});

function render(node: React.ReactNode): HTMLElement {
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
  const host = dom.window.document.getElementById("root")!;
  root = createRoot(host);
  act(() => root!.render(node));
  return host;
}

describe("AgentPills", () => {
  test("draws one pill per agent with its state, status and dot, and a click opens it", () => {
    const opened: [string, boolean][] = [];
    const host = render(
      <AgentPills
        row={{
          peers: ["a1", "a2", "a3", "a4"],
          titles: ["Fix", "Build", "Audit", "Scroll"],
          states: ["told", "reported", "stopped", "queued"],
        }}
        strings={strings}
        onOpen={(peer, command) => opened.push([peer, command])}
      />,
    );
    const pills = [...host.querySelectorAll<HTMLButtonElement>(".hm-pill")];
    expect(pills.map((pill) => pill.dataset.state)).toEqual(["told", "reported", "stopped", "queued"]);
    expect(pills.map((pill) => pill.getAttribute("aria-label"))).toEqual([
      "Fix, Working",
      "Build, Reported",
      "Audit, Stopped without a report",
      "Scroll, Queued",
    ]);
    expect(pills.map((pill) => pill.querySelector(".hm-pill__dot") !== null)).toEqual([false, true, false, false]);
    act(() => {
      pills[1]!.dispatchEvent(new dom!.window.MouseEvent("click", { bubbles: true, metaKey: true }));
    });
    expect(opened).toEqual([["a2", true]]);
  });

  test("the two-line shape adds the status line", () => {
    const host = render(
      <AgentPills
        row={{ peers: ["a1"], titles: ["Fix"], states: ["reported"] }}
        shape="twoLine"
        strings={strings}
        onOpen={() => {}}
      />,
    );
    expect(host.querySelector(".hm-pill__status")?.textContent).toBe("Reported · a1");
  });
});
