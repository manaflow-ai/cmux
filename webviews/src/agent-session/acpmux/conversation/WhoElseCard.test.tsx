// l10n-allow-file: test fixtures.
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxActivity } from "../model";
import { translatorFor } from "../i18n";
import { SubsessionContext, SubsessionStore } from "../subagents/subsessions";
import { staysInSight, toolGroups } from "./toolGroups";
import { resetTranscriptDisclosure } from "./transcriptDisclosureModel";
import { WhoElseCard } from "./WhoElseCard";
import { whatText } from "./whoElseCardModel";
import { whoElseCall, WHO_ELSE_SCHEMA } from "./whoElseCalls";
import { settleReact } from "../../../../test/support/domTeardown";

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
      ref: "build-box/mux-rs",
      host: "build-box",
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
  unreached: [{ host: "studio-mac", error: "no answer in 5 s" }],
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
    expect(call?.answer?.unreached).toEqual(["studio-mac"]);
    expect(toolGroups([item]).map((g) => g.type)).toEqual(["whoElse"]);
  }
});

test("another server's who_else, even titled bare, is its own tool row", () => {
  const github = activity({
    title: "who_else",
    inputSummary: JSON.stringify({ server: "github", tool: "who_else", arguments: {} }),
    output: JSON.stringify(ANSWER),
  });
  expect(whoElseCall(github)).toBeUndefined();
});

test("a pull request link is drawn only to an https URL", () => {
  const session = {
    ...ANSWER.sessions[0]!,
    pullRequests: ["javascript:alert(1)", "data:text/html,x", "http://x/pull/1", "https://github.com/o/r/pull/2"],
  };
  const call = whoElseCall(
    activity({ title: "mcp__acpmux__who_else", output: JSON.stringify({ ...ANSWER, sessions: [session] }) }),
  );
  expect(call?.answer?.sessions[0]?.pullRequests).toEqual(["https://github.com/o/r/pull/2"]);
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
  await settleReact();
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
  expect(chips.map((c) => c.textContent)).toEqual(["crate-split", "build-box/mux-rs"]);
  expect(page.querySelector(".cv-who-else__where")?.textContent).toBe("codex · lane/crate-split");
  expect(page.querySelector(".cv-who-else__pr")?.textContent).toBe("#36001");
  expect([...page.querySelectorAll(".cv-who-else__ago")].map((a) => a.textContent)).toEqual(["4m ago", "3h ago"]);
  expect(page.querySelector(".cv-who-else__note")?.textContent).toBe("Not asked: studio-mac");
  await act(async () => chips[0]!.click());
  expect(opened).toEqual(["s-codex"]);
});

test("a folded run keeps the card in sight beside its summary lines", () => {
  const item = activity({ title: "mcp__acpmux__who_else", output: JSON.stringify(ANSWER) });
  const read = activity({ title: "Read a.ts", kind: "read" });
  const card = toolGroups([item, read])[0]!;
  expect(card.type).toBe("whoElse");
  expect(staysInSight(card)).toBe(true);
});

test("sessions acpmux left out count in the line and are a note, not rows More would open", async () => {
  const capped = { ...ANSWER, more: 3, unreached: [] };
  const item = activity({ title: "mcp__acpmux__who_else", output: JSON.stringify(capped) });
  const page = await render(<WhoElseCard item={item} call={whoElseCall(item)!} />);
  expect(page.querySelector(".cv-who-else__line")?.textContent).toBe("5 other sessions work on these files");
  // Both rows the answer holds show, so there is no More to open.
  expect(page.querySelectorAll(".cv-who-else__rows li")).toHaveLength(2);
  expect(page.querySelector(".cv-who-else__more")).toBeNull();
  expect(page.querySelector(".cv-who-else__note")?.textContent).toBe("3 more not listed");
});

test("an answer with nobody says so in one line", async () => {
  const empty = { ...ANSWER, sessions: [], unreached: [] };
  const item = activity({ title: "mcp__acpmux__who_else", output: JSON.stringify(empty) });
  const page = await render(<WhoElseCard item={item} call={whoElseCall(item)!} />);
  expect(page.textContent).toBe("No other session works on these files");
});
