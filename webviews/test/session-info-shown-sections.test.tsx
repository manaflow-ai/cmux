// l10n-allow-file: test fixture rows, not shipped UI.
// Settings > Agent Chat > Chat Layout > Session Info: <section> (agentPane.display.sessionInfo.sections.*):
// which of the chat's thread details Session Info shows. Every one is on by default (the panel as it
// was); one turned off is not drawn, in the web panel or the native one, and comes back where it was.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { setChatDisplay } from "../src/agent-session/acpmux/chatDisplay";
import { SessionInfo } from "../src/agent-session/acpmux/session-info/SessionInfo";
import { DEFAULT_ORDER } from "../src/agent-session/acpmux/session-info/sectionOrder";
import {
  hiddenSessionInfoSections,
  PICKABLE_SESSION_INFO_SECTIONS,
  sessionInfoSectionKey,
  withoutHiddenSections,
} from "../src/agent-session/acpmux/session-info/shownSections";
import { orderSections } from "../src/agent-session/acpmux/session-info/native/nativeSessionInfoModel";
import type { NativeInfoSection } from "../src/agent-session/acpmux/session-info/native/model";
import { translate } from "../src/agent-session/acpmux/i18n";
import {
  DEFAULT_SECTIONS,
  resetSessionInfoState,
  setSessionInfoMore,
} from "../src/agent-session/acpmux/session-info/sessionInfoState";
import { assistant, chat } from "../src/gallery/fixtures/acpmux";
import { settleReact } from "./support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  const replacements: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    MutationObserver: dom.window.MutationObserver,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.keys(replacements)) saved.set(key, scope[key]);
  Object.assign(scope, replacements);
  return dom.window.document.getElementById("root")!;
}

beforeEach(() => {
  resetSessionInfoState();
  setSessionInfoMore(true);
  setChatDisplay({});
});

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
  setChatDisplay({});
});

const SOURCE = join(import.meta.dir, "../../schemas/settings/source");

test("one Settings row per section: a toggle, on by default, on the Chat Layout card and agent-settable", () => {
  const rows = (
    JSON.parse(readFileSync(join(SOURCE, "agent-pane-display.json"), "utf8")) as {
      lists: { rows: { key: string; kind: string; default: unknown }[] }[];
    }
  ).lists.flatMap((list) => list.rows);
  const prefix = "agentPane.display.sessionInfo.sections.";
  const picked = rows.filter((row) => row.key.startsWith(prefix));
  expect(picked.map((row) => row.key)).toEqual(PICKABLE_SESSION_INFO_SECTIONS.map(sessionInfoSectionKey));
  for (const row of picked) expect([row.kind, row.default]).toEqual(["toggle", true]);
  const layout = readFileSync(join(SOURCE, "page-layout.json"), "utf8");
  for (const row of picked) {
    expect(layout).toContain(`"${row.key}"`);
    // One policy file per key (schemas/settings/source/agent-policy/_refusals.json).
    const policy = JSON.parse(readFileSync(join(SOURCE, "agent-policy", `${row.key}.json`), "utf8"));
    expect(policy.agent).toBe("settable");
  }
  // Every built-in section the panel draws has a row (the Show more line is no section).
  const pickable: string[] = [...PICKABLE_SESSION_INFO_SECTIONS].sort();
  expect(pickable).toEqual(DEFAULT_ORDER.filter((id) => id !== "more").sort());
});

test("only false turns a section off; nothing set hides nothing", () => {
  expect(hiddenSessionInfoSections({})).toEqual([]);
  expect(
    hiddenSessionInfoSections({
      [sessionInfoSectionKey("usage")]: false,
      [sessionInfoSectionKey("context")]: false,
      [sessionInfoSectionKey("outputs")]: true,
      [sessionInfoSectionKey("sources")]: "false",
      [sessionInfoSectionKey("tasks")]: null,
    }),
  ).toEqual(["context", "usage"]);
  const nodes = { environment: 1, usage: 2 };
  expect(withoutHiddenSections(nodes, [])).toBe(nodes);
  expect(withoutHiddenSections(nodes, ["usage"])).toEqual({ environment: 1 });
});

test("the native panel leaves out the sections turned off, in the person's order", () => {
  const section = (id: string) => ({ id, title: id, rows: [] }) as unknown as NativeInfoSection;
  const all = ["environment", "context", "usage"].map(section);
  expect(orderSections(all, translate).map((entry) => entry.id)).toEqual(["environment", "context", "usage"]);
  expect(orderSections(all, translate, ["context"]).map((entry) => entry.id)).toEqual(["environment", "usage"]);
});

test("the open panel follows the setting at once: a section turned off goes, turned on comes back", async () => {
  const container = installDom();
  const rows = [assistant("Wrote [notes.pdf](/tmp/notes/notes.pdf).", 0)];
  const base = chat(rows);
  await act(async () => {
    root = createRoot(container);
    root.render(
      <SessionInfo
        summary={base.summary}
        machineName="cosmic-gray"
        rows={rows}
        sections={{ ...DEFAULT_SECTIONS, outputs: true }}
      />,
    );
  });
  const has = (id: string) => container.querySelector(`[data-section="${id}"]`) !== null;
  expect(has("environment")).toBe(true);
  expect(has("outputs")).toBe(true);

  await act(async () => setChatDisplay({ [sessionInfoSectionKey("outputs")]: false }));
  expect(has("outputs")).toBe(false);
  expect(has("environment")).toBe(true);

  await act(async () => setChatDisplay({ [sessionInfoSectionKey("environment")]: false }));
  expect(has("environment")).toBe(false);
  expect(has("outputs")).toBe(true);

  await act(async () => setChatDisplay({ [sessionInfoSectionKey("environment")]: true }));
  expect(has("environment")).toBe(true);
  expect(has("outputs")).toBe(true);
});
