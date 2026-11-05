// l10n-allow-file: test fixtures.
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxActivity } from "../model";
import { translatorFor } from "../i18n";
import { SubsessionContext, SubsessionStore } from "../subagents/subsessions";
import { toolGroups } from "./toolGroups";
import { resetTranscriptDisclosure } from "./transcriptDisclosure";
import { WhoElseCard, whatText } from "./WhoElseCard";
import { whoElseCall, WHO_ELSE_SCHEMA } from "./whoElseCalls";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

const ANSWER = {
  schema: WHO_ELSE_SCHEMA,
  query: { files: ["cmux-tui/crates/acpmux/src/hub/mod.rs"], fileCount: 1 },
  sessions: [
    {
      sessionId: "s-codex",
      name: "crate-split",
      ref: "crate-split",
      harness: "codex",
      status: "running",
      live: true,
      branch: "lane/crate-split",
      pullRequests: ["https://github.com/manaflow-ai/cmux/pull/36001"],
      agoMs: 4 * 60_000,
      filesInCommon: 5,
      editedInCommon: 2,
      files: [
        { path: "cmux-tui/crates/acpmux/src/hub/mod.rs", edited: true },
        { path: "cmux-tui/crates/acpmux/src/store.rs", edited: true },
        { path: "cmux-tui/crates/acpmux/src/rpc.rs", edited: false },
      ],
      sameWorktree: false,
      sameBranch: false,
      topicWords: [],
    },
    {
      sessionId: "s-oc",
      name: "mux-rs",
      ref: "big-red/mux-rs",
      host: "big-red",
      harness: "opencode",
      status: "idle",
      live: true,
      agoMs: 3 * 3_600_000,
      filesInCommon: 1,
      editedInCommon: 0,
      files: [{ path: "cmux-tui/crates/acpmux/src/hub/mod.rs", edited: false }],
      pullRequests: [],
      sameWorktree: false,
      sameBranch: false,
      topicWords: [],
    },
  ],
  more: 0,
  unreached: [{ host: "cosmic-gray", error: "no answer in 5 s" }],
};

const activity = (tool: Partial<Tool> & { title: string }): AcpmuxActivity => ({
  kind: "tool",
  text: tool.title,
  tool: { id: tool.title, status: "completed", ...tool } as Tool,
});

test("the acpmux MCP tool's answer is one who-else card, in Claude's and Codex's shapes", () => {
  const claude = activity({
    title: "mcp__acpmux__who_else",
    inputSummary: JSON.stringify({ files: ["src/hub/mod.rs"] }),
    output: JSON.stringify({ content: [{ type: "text", text: "crate-split ..." }], structuredContent: ANSWER }),
  });
  const codex = activity({
    title: "acpmux.who_else",
    inputSummary: JSON.stringify({ server: "acpmux", tool: "who_else", arguments: {} }),
    output: JSON.stringify(ANSWER),
  });
  for (const item of [claude, codex]) {
    const call = whoElseCall(item);
    expect(call?.answer?.sessions.map((s) => s.name)).toEqual(["crate-split", "mux-rs"]);
    expect(call?.answer?.unreached).toEqual(["cosmic-gray"]);
    expect(toolGroups([item]).map((g) => g.type)).toEqual(["whoElse"]);
  }
});

test("a shell `acpmux who-else --json` is the card; a text answer stays shell output", () => {
  const json = activity({
    title: "acpmux who-else --json src/a.rs",
    kind: "execute",
    command: "cd /w && acpmux --json who-else src/a.rs",
    output: JSON.stringify(ANSWER),
  });
  expect(toolGroups([json]).map((g) => g.type)).toEqual(["whoElse"]);
  const text = activity({
    title: "acpmux who-else",
    kind: "execute",
    command: "acpmux who-else",
    output: "crate-split (codex, lane/crate-split, #36001): edited mod.rs; 4m ago",
  });
  expect(whoElseCall(text)).toBeUndefined();
  // Another command that prints JSON with no such schema is not one.
  const other = activity({ title: "acpmux ls", kind: "execute", command: "acpmux ls --json", output: "{}" });
  expect(whoElseCall(other)).toBeUndefined();
});

test("a row says what the session edited and read in common, by file name", () => {
  const t = translatorFor("en");
  const call = whoElseCall(activity({ title: "mcp__acpmux__who_else", output: JSON.stringify(ANSWER) }))!;
  expect(whatText(t, call.answer!.sessions[0]!)).toBe("edited mod.rs, store.rs · read rpc.rs · +2 more");
  expect(whatText(t, call.answer!.sessions[1]!)).toBe("read mod.rs");
});

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  resetTranscriptDisclosure();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

async function render(node: ReactNode): Promise<HTMLElement> {
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
  const container = dom.window.document.getElementById("root")!;
  await act(async () => {
    root = createRoot(container);
    root.render(node);
  });
  return container;
}

test("the card names each session as a chip that opens its chat, with its branch, PR and age", async () => {
  const item = activity({ title: "mcp__acpmux__who_else", output: JSON.stringify(ANSWER) });
  const opened: string[] = [];
  const page = await render(
    <SubsessionContext.Provider value={{ store: new SubsessionStore(), open: (id) => opened.push(id) }}>
      <WhoElseCard item={item} call={whoElseCall(item)!} />
    </SubsessionContext.Provider>,
  );
  expect(page.querySelector(".cv-who-else__line")?.textContent).toBe("2 other sessions work on these files");
  const chips = [...page.querySelectorAll<HTMLButtonElement>(".cv-agent-tag.is-open")];
  expect(chips.map((c) => c.textContent)).toEqual(["crate-split", "big-red/mux-rs"]);
  expect(page.querySelector(".cv-who-else__where")?.textContent).toBe("codex · lane/crate-split");
  expect(page.querySelector(".cv-who-else__pr")?.textContent).toBe("#36001");
  expect([...page.querySelectorAll(".cv-who-else__ago")].map((a) => a.textContent)).toEqual(["4m ago", "3h ago"]);
  expect(page.querySelector(".cv-who-else__note")?.textContent).toBe("Not asked: cosmic-gray");
  await act(async () => chips[0]!.click());
  expect(opened).toEqual(["s-codex"]);
});

test("an answer with nobody says so in one line", async () => {
  const empty = { ...ANSWER, sessions: [], unreached: [] };
  const item = activity({ title: "mcp__acpmux__who_else", output: JSON.stringify(empty) });
  const page = await render(<WhoElseCard item={item} call={whoElseCall(item)!} />);
  expect(page.textContent).toBe("No other session works on these files");
});
