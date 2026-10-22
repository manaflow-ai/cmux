// l10n-allow-file: test fixture replies, not shipped UI.
// Leo 2026-10-22: "in a nother chat it kept only linking to leo-workspace and not the cmux repo".
// A coordinator chat whose folder is leo-workspace writes cmux pull request numbers; each bare #N
// linked to leo-workspace, the folder's repository. A bare #N now takes the repository the
// transcript's evidence names (conversation/bareReferences.ts), and the App's pull request cache
// says which of the chat's repositories has it.
import { afterAll, afterEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
class Observer {
  observe() {}
  unobserve() {}
  disconnect() {}
}
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  MutationObserver: dom.window.MutationObserver,
  getComputedStyle: dom.window.getComputedStyle,
  IntersectionObserver: Observer,
  ResizeObserver: Observer,
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
// jsdom has no layout. A tall viewport mounts every row of these small conversations.
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => 10_000 });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { UiProvider } = await import("../src/ui/UiProvider");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
const { resetLinkStore } = await import("../src/agent-session/acpmux/chips/linkStore");
const { resetPullRequestStore } = await import("../src/agent-session/acpmux/chips/pullRequestStore");
const { resetReferenceExistence } = await import("../src/agent-session/acpmux/chips/referenceExistence");

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const FOLDER = "teamleaderleo/leo-workspace";
const CMUX = "manaflow-ai/cmux";
const NUMBERS = [24175, 23959, 24197, 23880, 23027];
const pr = (repo: string, number: number) => `https://github.com/${repo}/pull/${number}`;

type Row = import("../src/agent-session/acpmux/model").AcpmuxRow;
let at = 0;
const row = (kind: string, fields: Partial<Row> = {}): Row => ({ id: `r${++at}`, version: 1, at, kind, ...fields });
const user = (text: string) => row("user", { text });
const assistant = (text: string) => row("assistant", { text });
const shell = (command: string, output: string, exitCode = 0) =>
  row("activity", {
    items: [
      {
        kind: "tool",
        text: "",
        tool: { id: `t${at}`, title: command, kind: "execute", status: "completed", command, output, exitCode },
      },
    ],
  });

let unmount: (() => Promise<void>) | undefined;
afterEach(async () => {
  await unmount?.();
  unmount = undefined;
});

/// Renders `rows` in a chat whose folder's repository is leo-workspace. The host's pull request
/// cache has `existing` (by address); every other address has no pull request.
async function render(rows: Row[], existing: readonly string[]) {
  resetLinkStore();
  resetPullRequestStore();
  resetReferenceExistence();
  const calls: { method: string; params: Record<string, unknown> }[] = [];
  setChipHost(async (method, params) => {
    calls.push({ method, params });
    if (method !== "pr.inspect") return {};
    const url = String(params.url);
    const match = /\/pull\/(\d+)$/.exec(url);
    return existing.includes(url)
      ? { pullRequest: { url, number: Number(match![1]), title: `PR ${match![1]}`, state: "merged" }, reading: false }
      : { pullRequest: null, reading: false };
  });
  const element = dom.window.document.getElementById("root")!;
  const root = createRoot(element);
  await act(async () =>
    root.render(
      <UiProvider container={element}>
        <VirtualTranscript rows={rows} onToggleActivity={() => {}} expanded={new Set()} githubRepository={FOLDER} />
      </UiProvider>,
    ),
  );
  // The host's answers are promises (no timers): a few turns of the event loop settle every
  // link.inspect and pr.inspect and the renders after them.
  for (let pass = 0; pass < 10; pass++) await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  unmount = async () => {
    await act(async () => root.unmount());
    setChipHost(undefined);
  };
  const chips = () =>
    [...element.querySelectorAll<HTMLAnchorElement>("a.cv-chip.is-ref")].map((chip) => [
      chip.textContent,
      chip.getAttribute("href"),
    ]);
  return { element, calls, chips };
}

test("Leo's case: a leo-workspace chat's bare cmux numbers link to manaflow-ai/cmux", async () => {
  const view = await render(
    [
      user("Land the agent pane fixes"),
      // The chat has linked cmux before (a lane's report), so cmux is a candidate.
      shell("gh pr list -R manaflow-ai/cmux --author @me", `${pr(CMUX, 24100)}\tagent pane: chips`),
      assistant(`Merged ${NUMBERS.map((number) => `#${number}`).join(", ")}.`),
    ],
    NUMBERS.map((number) => pr(CMUX, number)),
  );
  expect(view.chips()).toEqual(NUMBERS.map((number) => [`#${number}`, pr(CMUX, number)]));
});

const inspected = (calls: { method: string; params: Record<string, unknown> }[]) =>
  calls.filter((call) => call.method === "pr.inspect").map((call) => call.params.url);

test("rule 1: an explicit owner/repo#N or address keeps its own repository", async () => {
  const view = await render(
    [
      user(`Look at ${CMUX}#24175`),
      assistant(`Both: ${FOLDER}#24175 and https://github.com/${FOLDER}/pull/24197, then #24175.`),
    ],
    [],
  );
  expect(view.chips()).toEqual([
    [`${FOLDER}#24175`, pr(FOLDER, 24175)],
    // The address's chip is the address's own (LinkChips linkedText).
    [`${FOLDER}#24197`, pr(FOLDER, 24197)],
    // The bare one: its turn named the folder's last, after the prompt's cmux.
    ["#24175", pr(FOLDER, 24175)],
  ]);
});

test("rule a: the turn's own mention beats the chat's later one", async () => {
  const view = await render(
    [user("Status of o/a#5?"), assistant("#5 merged."), user("And o/b#5?"), assistant("o/b#5 is open.")],
    [],
  );
  // Prompts draw their text as written; the replies' chips:
  expect(view.chips()).toEqual([
    ["#5", pr("o/a", 5)],
    ["o/b#5", pr("o/b", 5)],
  ]);
  expect(inspected(view.calls)).toEqual([]);
});

test("rule a: a command in the turn names the number's repository (its output too)", async () => {
  const view = await render(
    [
      user("Merge it"),
      shell(`gh pr merge ${pr(CMUX, 23959)} --squash`, "✓ Squashed and merged"),
      shell("gh pr view 23880 -R x/y", `${pr(CMUX, 23880)}`),
      // A failed call is no evidence.
      shell(`gh pr view ${pr("x/z", 23027)}`, "GraphQL: Could not resolve", 1),
      assistant("Merged #23959; #23880 next; #23027 later."),
    ],
    [],
  );
  expect(view.chips()).toEqual([
    ["#23959", pr(CMUX, 23959)],
    ["#23880", pr(CMUX, 23880)],
    ["#23027", pr(FOLDER, 23027)],
  ]);
});

test("rule b: a number the chat named in an earlier turn keeps that repository", async () => {
  const view = await render(
    [user(`Watch ${pr(CMUX, 24197)}`), assistant("Watching."), user("Is it green?"), assistant("#24197 is green.")],
    [],
  );
  expect(view.chips()).toEqual([["#24197", pr(CMUX, 24197)]]);
  expect(inspected(view.calls)).toEqual([]);
});

test("rule c: the App's cache decides among the folder's and the linked repositories, asked together", async () => {
  const view = await render(
    [user(`Compare with ${CMUX}#1`), assistant("Now #900 and #901.")],
    [pr(FOLDER, 900), pr(CMUX, 901)],
  );
  expect(view.chips()).toEqual([
    ["#900", pr(FOLDER, 900)],
    ["#901", pr(CMUX, 901)],
  ]);
  // Every candidate address went to the host in one link.inspect, which reads them in one batch.
  const batch = view.calls.find(
    (call) => call.method === "link.inspect" && (call.params.urls as string[]).includes(pr(CMUX, 900)),
  );
  expect(batch?.params.urls).toEqual([pr(FOLDER, 900), pr(CMUX, 900), pr(FOLDER, 901), pr(CMUX, 901)]);
  expect(new Set(inspected(view.calls))).toEqual(
    new Set([pr(FOLDER, 900), pr(CMUX, 900), pr(FOLDER, 901), pr(CMUX, 901)]),
  );
});

test("rule d: with no evidence and one candidate, the folder's repository, asking nothing", async () => {
  const view = await render([user("What landed?"), assistant("#634 landed.")], []);
  expect(view.chips()).toEqual([["#634", pr(FOLDER, 634)]]);
  expect(inspected(view.calls)).toEqual([]);
});

test("rule d: a number no candidate has stays the folder's", async () => {
  const view = await render([user(`See ${CMUX}#1`), assistant("#77 is unknown.")], []);
  expect(view.chips().at(-1)).toEqual(["#77", pr(FOLDER, 77)]);
});

test("rule 3: a number in two candidates names its repository on the chip", async () => {
  const view = await render(
    [user(`Compare with ${CMUX}#1`), assistant("#843 is the one.")],
    [pr(FOLDER, 843), pr(CMUX, 843)],
  );
  expect(view.chips().at(-1)).toEqual(["leo-workspace#843", pr(FOLDER, 843)]);
});

test("an agent's message: its own address names the repository of its bare #N", async () => {
  const text = `[lane] #24175 merged: ${pr(CMUX, 24175)}. Next #24175 follow-up.`;
  const raw = `<agent-message from="lane">${text}</agent-message>`;
  const message = row("user", { text: raw, incoming: { kind: "message", message: { name: "lane", text, raw } } });
  const view = await render([message], []);
  const refs = view.chips().filter(([label]) => label === "#24175");
  expect(refs.length).toBeGreaterThan(0);
  expect(refs.every(([, href]) => href === pr(CMUX, 24175))).toBe(true);
});

test("a streaming reply reads only its own row again; an older row that changed is read again", async () => {
  const { referenceScopes, newReferenceScopeCache } =
    await import("../src/agent-session/acpmux/conversation/bareReferences");
  const cache = newReferenceScopeCache();
  const prompt = user(`Watch ${CMUX}#7`);
  const tool = shell("gh pr list", "");
  referenceScopes([prompt, tool, assistant("…")], cache);
  const prefix = cache.prefix;
  // The reply grew: the rows before it are the same objects, so their reading is kept.
  const scopeOf = referenceScopes([prompt, tool, assistant(`#7 and o/r#8`)], cache);
  expect(cache.prefix).not.toBe(prefix);
  expect(cache.prefix!.named).toEqual(prefix!.named);
  expect(scopeOf(prompt.id).turn).toEqual(
    new Map([
      [7, CMUX],
      [8, "o/r"],
    ]),
  );
  // An older row changed (a command finished): everything is read again.
  const done = shell("gh pr list", `${pr("x/y", 9)}`);
  const again = referenceScopes([prompt, done, assistant("#9")], cache);
  expect(again(prompt.id).evidence.named.get(9)).toBe("x/y");
});
