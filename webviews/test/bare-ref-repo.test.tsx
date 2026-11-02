// l10n-allow-file: test fixture replies, not shipped UI.
// Leo 2026-10-22: "in a nother chat it kept only linking to leo-workspace and not the cmux repo".
// A coordinator chat whose folder is leo-workspace writes cmux pull request numbers; each bare #N
// linked to leo-workspace, the folder's repository. A bare #N now takes the repository the
// transcript's evidence names (conversation/bareReferences.ts), and the App's pull request cache
// says which of the chat's repositories has it.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { act } from "react";
import { UiProvider } from "../src/ui/UiProvider";
import { VirtualTranscript } from "../src/agent-session/acpmux/App";
import { setChipHost } from "../src/agent-session/acpmux/chips/host";
import { resetLinkStore } from "../src/agent-session/acpmux/chips/linkStore";
import { resetPullRequestStore } from "../src/agent-session/acpmux/chips/pullRequestStore";
import { resetReferenceExistence } from "../src/agent-session/acpmux/chips/referenceExistence";
import { newReferenceScopeCache, referenceScopes } from "../src/agent-session/acpmux/conversation/bareReferences";
import { setMessageOpened } from "../src/agent-session/acpmux/conversation/incomingOpened";
import { useDom } from "./support/unknownWrite";

const dom = useDom();
beforeAll(() => {
  // jsdom has no layout. A tall viewport mounts every row of these small conversations.
  Object.assign(globalThis, { getComputedStyle: window.getComputedStyle.bind(window) });
  Object.defineProperty(window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => 10_000 });
  Object.defineProperty(window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });
});
afterEach(() => setChipHost(undefined));
afterAll(() => void delete (globalThis as { getComputedStyle?: unknown }).getComputedStyle);

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

/// Renders `rows` in a chat whose folder's repository is leo-workspace. The host's pull request
/// cache has `existing` (by address); every other address has no pull request.
async function render(
  rows: Row[],
  existing: readonly string[],
  { source, reading = 0, folder = FOLDER }: { source?: Row[]; reading?: number; folder?: string } = {},
) {
  resetLinkStore();
  resetPullRequestStore();
  resetReferenceExistence();
  const calls: { method: string; params: Record<string, unknown> }[] = [];
  setChipHost(async (method, params) => {
    calls.push({ method, params });
    if (method !== "pr.inspect") return {};
    // The host's read is still running for the first `reading` asks.
    if (calls.filter((call) => call.method === "pr.inspect").length <= reading)
      return { pullRequest: null, reading: true };
    const url = String(params.url);
    const match = /\/pull\/(\d+)$/.exec(url);
    return existing.includes(url)
      ? { pullRequest: { url, number: Number(match![1]), title: `PR ${match![1]}`, state: "merged" }, reading: false }
      : { pullRequest: null, reading: false };
  });
  const element = dom.host();
  await dom.render(
    <UiProvider container={element}>
      <VirtualTranscript
        rows={rows}
        sourceRows={source}
        onToggleActivity={() => {}}
        expanded={new Set()}
        githubRepository={folder || undefined}
      />
    </UiProvider>,
  );
  // The host's answers are promises (no timers): a few turns of the event loop settle every
  // link.inspect and pr.inspect and the renders after them.
  for (let pass = 0; pass < 10; pass++) await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  // The replies' chips: a prompt's explicit `owner/repo#N` draws as its own chip too (sent prompts
  // render Markdown, user-prompt-markdown.test.ts), which these rules about replies do not read.
  const chips = () =>
    [...element.querySelectorAll<HTMLAnchorElement>("a.cv-chip.is-ref")]
      .filter((chip) => !chip.closest(".cv-user"))
      .map((chip) => [chip.textContent, chip.getAttribute("href")]);
  return { element, calls, chips };
}

test("Leo's case: a leo-workspace chat's bare cmux numbers link to manaflow-ai/cmux", async () => {
  const view = await render(
    [
      user("Land the agent pane fixes"),
      // The chat has linked cmux before (a lane's report), so cmux is a candidate.
      shell("gh pr list -R manaflow-ai/cmux --author @me", ""),
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

test("rules a and b: a turn keeps its own mention; a later turn takes the last one before it", async () => {
  const view = await render(
    [
      user("Any news?"),
      assistant("#5 is new."),
      user("Status of o/a#5?"),
      assistant("#5 merged."),
      user("And o/b#5?"),
      assistant("o/b#5 is open."),
      user("Any news?"),
      assistant("#5 is green."),
    ],
    [],
  );
  // The first reply keeps o/a (a later turn never rewrites
  // it); the last takes o/b, the one named last before its turn (rule b).
  expect(view.chips()).toEqual([
    // Named only by later turns: rule c finds it in no candidate, so rule d stands.
    ["#5", pr(FOLDER, 5)],
    ["#5", pr("o/a", 5)],
    ["o/b#5", pr("o/b", 5)],
    ["#5", pr("o/b", 5)],
  ]);
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

test("rule a reads a message in order, and a hidden prompt still opens its turn", async () => {
  const hidden = user("o/c#6 bookkeeping");
  const rows = [
    user("Status?"),
    assistant(`Previously o/a#5; corrected: ${pr("o/b", 5)}; merged #5.`),
    assistant("#6 done."),
  ];
  // The client's rows hold a prompt the transcript does not draw; the reply after it is its turn's.
  const view = await render(rows, [], { source: [...rows.slice(0, 2), hidden, rows[2]!] });
  expect(view.chips().filter(([label]) => label?.startsWith("#"))).toEqual([
    ["#5", pr("o/b", 5)],
    ["#6", pr("o/c", 6)],
  ]);
});

test("rule c: a repository's own address makes a candidate (Leo's case: -R); a slow host read is waited for", async () => {
  const view = await render(
    [user("Tracking https://github.com/manaflow-ai/cmux now"), assistant("#24175 landed.")],
    [pr(CMUX, 24175)],
    { reading: 2 },
  );
  // The host says it is still reading at first; the next round, after it registers again, answers.
  // Waits on the answer itself (the store's first back-off is 1.5 s), giving up after 10 s.
  for (const end = Date.now() + 10_000; Date.now() < end && view.chips()[0]?.[1] !== pr(CMUX, 24175);)
    await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  expect(view.chips()).toEqual([["#24175", pr(CMUX, 24175)]]);
  expect(view.calls.filter((call) => call.method === "link.inspect").length).toBeGreaterThanOrEqual(2);
});

test("rules c, d and 3: the App's cache decides among the candidates, asked in one batch", async () => {
  const view = await render(
    [user(`Compare with ${CMUX}#1`), assistant("Now #900, #901, #77 and #843.")],
    [pr(FOLDER, 900), pr(CMUX, 901), pr(FOLDER, 843), pr(CMUX, 843)],
  );
  expect(view.chips()).toEqual([
    ["#900", pr(FOLDER, 900)],
    ["#901", pr(CMUX, 901)],
    // Rule d: no candidate has it. Rule 3: both have it, so the chip names the first.
    ["#77", pr(FOLDER, 77)],
    ["leo-workspace#843", pr(FOLDER, 843)],
  ]);
  // Every candidate address went to the host in one link.inspect, which reads them in one batch
  // (the drawn chips register their own addresses for their cards, as every chip does).
  const urls = [900, 901, 77, 843].flatMap((number) => [pr(FOLDER, number), pr(CMUX, number)]);
  const batches = view.calls.filter(
    (call) => call.method === "link.inspect" && (call.params.urls as string[]).includes(pr(CMUX, 900)),
  );
  expect(batches.map((call) => call.params.urls)).toEqual([urls]);
  expect(new Set(inspected(view.calls))).toEqual(new Set(urls));
});

test("rule c: the repositories linked last are the candidates, in a message's order too", async () => {
  const links = ["o/a", "o/b", "o/c"].map((repo) => pr(repo, 1)).join(" ");
  const view = await render([user(`See ${links}`), assistant("#9 is the fix.")], [pr("o/c", 9)]);
  expect(view.chips()).toEqual([["#9", pr("o/c", 9)]]);
});

test("with no folder repository, a bare #N links only when the transcript names its repository", async () => {
  const view = await render(
    [user("Merge it"), shell(`gh pr merge ${pr("o/r", 5)}`, ""), assistant("#5 merged; #6 is unrelated.")],
    [],
    { folder: "" },
  );
  expect(view.chips()).toEqual([["#5", pr("o/r", 5)]]);
  // A `#N` inside an address is the address's.
  const other = await render([user("Search"), assistant("See https://example.com/?q=#12 now.")], [], { folder: "" });
  expect([...other.element.querySelectorAll("a")].map((link) => link.getAttribute("href"))).toEqual([
    "https://example.com/?q=#12",
  ]);
});

test("rule d: with no evidence and one candidate, the folder's repository, asking nothing", async () => {
  const view = await render([user("What landed?"), assistant("#634 landed.")], []);
  expect(view.chips()).toEqual([["#634", pr(FOLDER, 634)]]);
  // Nothing to resolve; the drawn chip's own cache-only ask, for its mark's state colour, is all.
  expect(view.calls.filter((call) => call.method === "pr.inspect").map((call) => call.params)).toEqual([
    { url: pr(FOLDER, 634), cached: true },
  ]);
});

test("an agent's message: its own address names the repository of its bare #N", async () => {
  const text = `[lane] #24175 merged: ${pr(CMUX, 24175)}. Next #24175 follow-up.`;
  const raw = `<agent-message from="lane">${text}</agent-message>`;
  const message = row("user", { text: raw, incoming: { kind: "message", message: { name: "lane", text, raw } } });
  // Another agent's message is one line until opened, its whole text (and its chips) in the panel
  // (IncomingMessageCard.tsx, #27312): the person opened this one.
  setMessageOpened(undefined, message.id, true);
  const view = await render([message], []);
  const refs = view.chips().filter(([label]) => label === "#24175");
  expect(refs.length).toBeGreaterThan(0);
  expect(refs.every(([, href]) => href === pr(CMUX, 24175))).toBe(true);
});

test("a streaming reply reads only its own row again; an older row that changed is read again", async () => {
  const cache = newReferenceScopeCache();
  const prompt = user(`Watch ${CMUX}#7`);
  const tool = shell("gh pr list", "");
  referenceScopes([prompt, tool, assistant("…")], cache);
  const prefix = cache.prefix;
  // The reply grew: the rows before it are the same objects, so their reading is kept.
  const scopeOf = referenceScopes([prompt, tool, assistant(`#7 and o/r#8`)], cache);
  expect(cache.prefix).not.toBe(prefix);
  expect(cache.prefix!.mentions).toEqual(prefix!.mentions);
  expect(scopeOf(prompt.id).turn).toEqual(
    new Map([
      [7, CMUX],
      [8, "o/r"],
    ]),
  );
  // An older row changed (a command finished): everything is read again.
  const done = shell("gh pr list", `${pr("x/y", 9)}`);
  const again = referenceScopes([prompt, done, assistant("#9")], cache);
  expect(again(prompt.id).evidence.mentions.get(9)).toEqual([{ at: 1, repo: "x/y" }]);
});

// Leo 2026-10-29: "these auto render to the pr instead of just #1 #2...". The agent quoted his
// "what is #1 / #2", and each bare number drew as a chip for cmux's (real, unrelated) pull
// requests #1 and #2.
test("Leo's #1 / #2: a quote's bare numbers stay text; explicit references stay chips", async () => {
  const view = await render(
    [
      user("what is #1 / #2"),
      // The turn names cmux#2 itself (rule a), so only the quote keeps the quoted #2 text.
      assistant(`> what is #1 / #2\n\nThe options I listed, not pull requests (${CMUX}#2 is unrelated).`),
    ],
    [pr(CMUX, 1), pr(CMUX, 2)],
    { folder: CMUX },
  );
  expect(view.chips()).toEqual([[`${CMUX}#2`, pr(CMUX, 2)]]);
  expect(view.element.querySelector(".cv-quote")?.textContent).toContain("what is #1 / #2");
});

test("Leo's #1 / #2: a bare number far below the repository's named numbers stays text", async () => {
  const view = await render(
    [
      user(`Land ${pr(CMUX, 27262)}, then what is #1 / #2`),
      assistant('You asked "what is #1 / #2": #1 is the sidebar fix, #2 the composer one. #27262 is green.'),
    ],
    [pr(CMUX, 1), pr(CMUX, 2), pr(CMUX, 27262)],
    { folder: CMUX },
  );
  expect(view.chips().filter(([label]) => label?.startsWith("#"))).toEqual([["#27262", pr(CMUX, 27262)]]);
});

test("rule 4: with the folder's repository out of range, only the cache's answer links a number", async () => {
  const view = await render(
    [user(`Land ${pr(CMUX, 27262)} and look at ${pr("o/r", 3)}`), assistant("#5 is o/r's; #6 is nobody's.")],
    [pr("o/r", 5)],
    { folder: CMUX },
  );
  expect(view.chips().filter(([label]) => label?.startsWith("#"))).toEqual([["#5", pr("o/r", 5)]]);
  const asked = inspected(view.calls);
  expect(asked).toContain(pr("o/r", 6));
  // The folder's repository is out of range for both, so neither is asked about there.
  expect(asked.filter((url) => url === pr(CMUX, 5) || url === pr(CMUX, 6))).toEqual([]);
});
