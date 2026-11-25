// The pane's redraw of a snapshot leaves room for a key (Leo, 2026-11-17: "man the difference typing on
// terminal vs gui is def noticeable rn"). While a reply streams, a snapshot that is not a streamed chunk
// (a tool call, its result, a new row) redraws the whole pane. As a default-lane update that render ran in
// one piece, and a key typed while it ran waited for all of it before the page's keydown listener: 24% of
// the renderer main-thread time keys waited behind (bench/shared-renderer-typing.bench.ts --trace).
//
// The redraw is a transition now (paneSnapshotLane.ts): React renders it in 5 ms slices with input between
// them. These check, with React's real scheduler (no act()):
// - a key that comes in while the pane renders a snapshot reaches its listener before that render ends;
// - a sent prompt and a chat switch still render at once, in one piece: the key waits for them;
// - snapshots apply in order, none lost, none stale, when urgent draws overtake pending ones;
// - nothing torn while a redraw is pending: each commit shows one snapshot whole with its own fold set and
//   follow, and the streaming row's last text never goes back.
import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { Root } from "react-dom/client";
import type { AcpmuxRow, AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "KeyboardEvent",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;
let field: HTMLInputElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><input id=field><div id=root></div>", { url: "https://cmux.test/" });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    KeyboardEvent: window.KeyboardEvent,
    // Real scheduling, not act()'s queue: the test reads when React renders.
    IS_REACT_ACT_ENVIRONMENT: false,
    Node: window.Node,
    Element: window.Element,
  });
  host = window.document.getElementById("root")!;
  field = window.document.getElementById("field") as HTMLInputElement;
});

beforeEach(() => {
  root?.unmount();
  root = undefined;
});

afterAll(async () => {
  root?.unmount();
  await teardownDom(saved, { scope });
});

const task = () => new Promise<void>((resolve) => setTimeout(resolve, 0));
const until = async (done: () => boolean) => {
  for (let i = 0; i < 2000 && !done(); i += 1) await task();
  expect(done()).toBe(true);
};

const SESSION = "chat-a";
const row = (id: string, kind: string, text: string, extra: Partial<AcpmuxRow> = {}) =>
  ({ id, kind, text, version: 1, ...extra }) as unknown as AcpmuxRow;
/// A chat of `count` turns, then `tail` (the reply that streams, a tool call, ...).
const chat = (count: number, tail: AcpmuxRow[], extra: Partial<AcpmuxSnapshot> = {}): AcpmuxSnapshot =>
  ({
    type: "snapshot",
    protocolVersion: 1,
    connection: "connected",
    sessionId: SESSION,
    isWorking: true,
    sessions: [],
    queue: [],
    rows: [
      ...Array.from({ length: count }, (_, index) =>
        row(`turn-${index}`, index % 2 ? "assistant" : "user", `line ${index}`),
      ),
      ...tail,
    ],
    ...extra,
  }) as AcpmuxSnapshot;

/// What a row's render costs: a pane of a few hundred rows takes tens of ms, as the real one does on a
/// throttled renderer.
const busy = (ms: number) => {
  const end = performance.now() + ms;
  while (performance.now() < end);
};

type Commit = { seq: number; rows: number; folded: string[]; follow: boolean; liveText?: string; shown?: string };

/// The pane as App.tsx draws the direct client's snapshots: one `setSnapshot` per non-streamed snapshot
/// through `drawPaneSnapshot(drawn, next, pending)`, the streaming row through `useStreamingRow`, a
/// fold set and a follow flag as urgent state of their own. Each commit records what it showed.
async function mountPane(first: AcpmuxSnapshot, rowCost: number) {
  const React = await import("react");
  const { createRoot } = await import("react-dom/client");
  const { drawPaneSnapshot, PendingPaneDraw } = await import("../src/agent-session/acpmux/paneSnapshotLane");
  const { streamingRow, useStreamingRow } = await import("../src/agent-session/acpmux/streamingRow");
  const commits: Commit[] = [];
  const api: {
    receive?: (next: AcpmuxSnapshot) => void;
    fold?: (id: string) => void;
    unfollow?: () => void;
    rendering?: () => void;
  } = {};
  let drawn: AcpmuxSnapshot | undefined;
  const pending = new PendingPaneDraw();
  function Row({ value }: { value: AcpmuxRow }) {
    busy(rowCost);
    api.rendering?.();
    return <p data-id={value.id}>{value.text}</p>;
  }
  const MemoRow = React.memo(Row);
  function Pane() {
    const [snapshot, setSnapshot] = React.useState(first);
    const [folded, setFolded] = React.useState<string[]>([]);
    const [follow, setFollow] = React.useState(true);
    const live = useStreamingRow(true);
    api.receive = (next) => {
      streamingRow.clear();
      const before = drawn;
      drawn = next;
      drawPaneSnapshot(before, next, pending, () => setSnapshot(next));
    };
    api.fold = (id) => setFolded((current) => [...current, id]);
    api.unfollow = () => setFollow(false);
    // The reply row, wherever it is: a tool call may land under it.
    const last = snapshot.rows.find((value) => value.id === "reply") ?? snapshot.rows.at(-1)!;
    // The transcript reads the live row only while its row still shows what the live row drew over.
    const shown = live && live.row.id === last.id && live.drawnText === last.text ? live.row.text : last.text;
    React.useLayoutEffect(() => pending.committed(snapshot), [snapshot]);
    React.useLayoutEffect(() => {
      commits.push({
        seq: Number((snapshot as { seq?: number }).seq ?? 0),
        rows: snapshot.rows.length,
        folded,
        follow,
        liveText: live?.row.text,
        shown,
      });
    });
    return (
      <div data-follow={follow}>
        {snapshot.rows.map((value) =>
          folded.includes(value.id) ? <hr key={value.id} /> : <MemoRow key={value.id} value={value} />,
        )}
      </div>
    );
  }
  drawn = first;
  root = createRoot(host);
  root.render(<Pane />);
  await until(() => commits.length > 0);
  return { commits, api, streamingRow, pending };
}

const withSeq = (snapshot: AcpmuxSnapshot, seq: number) => ({ ...snapshot, seq }) as AcpmuxSnapshot;

/// Sends `next` as the direct client's socket does (a task of its own), and queues a key the moment the
/// pane's render of it starts, as a key typed then is. Answers whether the pane had committed `next`
/// when the key's listener ran.
async function keyDuringRender(pane: Awaited<ReturnType<typeof mountPane>>, next: AcpmuxSnapshot) {
  const seq = Number((next as { seq?: number }).seq);
  const committedAtKey: boolean[] = [];
  const pendingAtKey: boolean[] = [];
  const listener = () => {
    committedAtKey.push(pane.commits.some((commit) => commit.seq === seq));
    pendingAtKey.push(pane.pending.pending);
  };
  field.addEventListener("keydown", listener);
  let queued = false;
  pane.api.rendering = () => {
    if (queued) return;
    queued = true;
    setTimeout(() => field.dispatchEvent(new KeyboardEvent("keydown", { key: "a" })), 0);
  };
  setTimeout(() => pane.api.receive!(next), 0);
  await until(() => committedAtKey.length > 0 && pane.commits.some((commit) => commit.seq === seq));
  field.removeEventListener("keydown", listener);
  pane.api.rendering = undefined;
  // The pane says its draw is pending until it commits: a running command's output goes through the
  // pane meanwhile (liveToolOutput.ts reads in sync renders, so an entry told from the pending rows
  // would take the committed row's newer output away).
  expect(pendingAtKey[0]).toBe(!committedAtKey[0]);
  expect(pane.pending.pending, "pending after its commit").toBe(false);
  return committedAtKey[0]!;
}

test("a key that comes in while the pane renders a snapshot reaches its listener before that render ends", async () => {
  const reply = (text: string) => row("reply", "assistant", text, { streaming: true } as Partial<AcpmuxRow>);
  const first = withSeq(chat(300, [reply("Hello")]), 1);
  const pane = await mountPane(first, 0.15);
  // A tool call lands under the reply: not a streamed chunk, so the whole pane redraws.
  const next = withSeq(chat(300, [reply("Hello"), row("tool-1", "tool", "Read file.ts")]), 2);
  const committedAtKey = [await keyDuringRender(pane, next)];
  // Base: the snapshot's default-lane render ran in one piece; the key's listener ran after its commit.
  expect(committedAtKey[0], "the pane had committed the snapshot before the key's listener ran").toBe(false);
  expect(pane.commits.at(-1)!.seq).toBe(2);
  expect(pane.commits.at(-1)!.rows).toBe(302);
});

test("a sent prompt and a chat switch render at once, in one piece", async () => {
  const first = withSeq(chat(300, [row("reply", "assistant", "Done.")]), 1);
  const pane = await mountPane(first, 0.15);
  const cases: [string, AcpmuxSnapshot][] = [
    [
      "a sent prompt's row",
      withSeq(chat(300, [row("reply", "assistant", "Done."), row("sent-1", "user", "Next", { pending: true })]), 2),
    ],
    [
      "a queued prompt",
      withSeq(
        chat(300, [row("reply", "assistant", "Done."), row("sent-1", "user", "Next", { pending: true })], {
          queue: [{ id: "q-1", prompt: "after" }],
        }),
        3,
      ),
    ],
    ["another chat", withSeq({ ...chat(280, [row("other", "assistant", "Hi")]), sessionId: "chat-b" }, 4)],
  ];
  for (const [name, next] of cases)
    expect(await keyDuringRender(pane, next), `${name}: committed before the key that came in during its render`).toBe(
      true,
    );
});

test("snapshots apply in order, none lost or stale, when urgent draws overtake pending ones", async () => {
  const reply = (text: string) => row("reply", "assistant", text);
  const first = withSeq(chat(200, [reply("a")]), 1);
  const pane = await mountPane(first, 0.1);
  // Transition, transition, an urgent send, a transition, with keys' urgent state between them.
  const sequence: AcpmuxSnapshot[] = [
    withSeq(chat(200, [reply("a"), row("tool-1", "tool", "t1")]), 2),
    withSeq(chat(200, [reply("a"), row("tool-1", "tool", "t1"), row("tool-2", "tool", "t2")]), 3),
    withSeq(
      chat(200, [
        reply("a"),
        row("tool-1", "tool", "t1"),
        row("tool-2", "tool", "t2"),
        row("sent", "user", "go", { pending: true }),
      ]),
      4,
    ),
    withSeq(
      chat(200, [
        reply("a"),
        row("tool-1", "tool", "t1"),
        row("tool-2", "tool", "t2"),
        row("sent", "user", "go", { pending: true }),
        row("reply-2", "assistant", "ok"),
      ]),
      5,
    ),
  ];
  for (const next of sequence) {
    setTimeout(() => pane.api.receive!(next), 0);
    setTimeout(() => pane.api.unfollow!(), 1);
    await task();
  }
  await until(() => pane.commits.at(-1)!.seq === 5);
  // Let anything still pending land: the last commit stays the newest snapshot.
  for (let i = 0; i < 50; i += 1) await task();
  const seqs = pane.commits.map((commit) => commit.seq);
  expect(seqs.at(-1), "the newest snapshot is what the pane shows").toBe(5);
  for (let index = 1; index < seqs.length; index += 1)
    expect(seqs[index]!, `commit ${index} went back from ${seqs[index - 1]} to ${seqs[index]}`).toBeGreaterThanOrEqual(
      seqs[index - 1]!,
    );
  expect(pane.commits.at(-1)!.rows).toBe(205);
});

test("nothing torn while a redraw is pending: fold, follow and the streamed text stay whole", async () => {
  const reply = (text: string) => row("reply", "assistant", text, { streaming: true } as Partial<AcpmuxRow>);
  const first = withSeq(chat(300, [reply("Hello")]), 1);
  const pane = await mountPane(first, 0.15);
  // The reply streams ahead of the pane through the streaming row.
  pane.streamingRow.set(reply("Hello, wor"), reply("Hello"));
  await until(() => pane.commits.at(-1)!.shown === "Hello, wor");
  // A tool call's snapshot carries the reply as far as it streamed, then more streams over it.
  const next = withSeq(chat(300, [reply("Hello, world."), row("tool-1", "tool", "Read")]), 2);
  let folded = false;
  pane.api.rendering = () => {
    if (folded) return;
    folded = true;
    // The person folds a row and scrolls away while the redraw is pending: both urgent.
    setTimeout(() => {
      pane.api.fold!("turn-3");
      pane.api.unfollow!();
    }, 0);
  };
  setTimeout(() => pane.api.receive!(next), 0);
  await until(() => pane.commits.at(-1)!.seq === 2 && pane.commits.at(-1)!.folded.includes("turn-3"));
  pane.api.rendering = undefined;
  const after = pane.commits.filter((commit) => commit.folded.includes("turn-3"));
  // The fold and the follow change committed together, and every later commit keeps both.
  for (const commit of after) expect(commit.follow).toBe(false);
  expect(pane.commits.at(-1)!.folded).toEqual(["turn-3"]);
  // The reply's shown text never went back, at any commit (no frame of the old row under a new live row).
  const shown = pane.commits.map((commit) => commit.shown ?? "");
  for (let index = 1; index < shown.length; index += 1)
    expect(
      shown[index]!.length,
      `commit ${index} showed "${shown[index]}" after "${shown[index - 1]}"`,
    ).toBeGreaterThanOrEqual(shown[index - 1]!.length);
  expect(pane.commits.at(-1)!.shown).toBe("Hello, world.");
  // Each commit is one snapshot whole: its seq and its row count agree.
  for (const commit of pane.commits) expect(commit.rows).toBe(commit.seq === 2 ? 302 : 301);
});

test("a turn that starts or ends, or a link that drops, draws at once; a streamed reply does not", async () => {
  const { drawsAtOnce } = await import("../src/agent-session/acpmux/paneSnapshotLane");
  const idle = chat(10, [row("reply", "assistant", "Done.")], { isWorking: false });
  const working = chat(10, [row("reply", "assistant", "Done.")], { isWorking: true });
  expect(drawsAtOnce(idle, working), "the turn starts: the composer offers Stop at once").toBe(true);
  expect(drawsAtOnce(working, idle), "the turn ends: the composer offers Send at once").toBe(true);
  expect(
    drawsAtOnce(working, { ...working, connection: "disconnected" } as AcpmuxSnapshot),
    "the link drops: the line above the composer says so at once",
  ).toBe(true);
  const grown = chat(10, [row("reply", "assistant", "Done. More")], { isWorking: true });
  expect(drawsAtOnce(working, grown), "a reply that grows mid-turn is a transition").toBe(false);
});

test("a pick coming back from the daemon (model, effort, access) draws at once; usage does not", async () => {
  const { drawsAtOnce } = await import("../src/agent-session/acpmux/paneSnapshotLane");
  const summary = {
    sessionId: "s",
    harness: "codex",
    model: "gpt-6.1-sol",
    modes: { availableModes: [{ id: "ask" }, { id: "full" }], currentModeId: "ask" },
    configOptions: [{ id: "reasoning_effort", currentValue: "default", options: [] }],
  };
  const base = chat(10, [row("reply", "assistant", "Done.")], { summary } as Partial<AcpmuxSnapshot>);
  const withSummary = (next: object) => ({ ...base, summary: { ...summary, ...next } }) as AcpmuxSnapshot;
  expect(drawsAtOnce(base, withSummary({ model: "gpt-6.1" })), "a model pick").toBe(true);
  expect(
    drawsAtOnce(base, withSummary({ configOptions: [{ id: "reasoning_effort", currentValue: "high", options: [] }] })),
    "an effort pick",
  ).toBe(true);
  expect(drawsAtOnce(base, withSummary({ modes: { ...summary.modes, currentModeId: "full" } })), "an access pick").toBe(
    true,
  );
  expect(drawsAtOnce(base, withSummary({ usage: { used: 10, size: 100 } })), "a usage update").toBe(false);
});

// Leo, 2026-11-22: "scrolling.. bit of blank screening when the content loads". A page of older history lands
// while the reader scrolls up; as a transition, each scroll frame's urgent render restarted it, and a dragged
// scroll drew none of it until it stopped (bench/transcript-scroll-up.bench.ts MODE=drag: 15 to 28 blank frames).
test("older history the reader scrolls up to draws at once; a streamed reply under it does not", async () => {
  const { drawsAtOnce } = await import("../src/agent-session/acpmux/paneSnapshotLane");
  const { PromptHeads } = await import("../src/agent-session/acpmux/promptHeads");
  const held = chat(10, [row("reply", "assistant", "Done.")], { canLoadOlder: true, historyFrom: 500 });
  const page = { ...held, rows: [row("user-1", "user", "older"), ...held.rows], historyFrom: 1 } as AcpmuxSnapshot;
  expect(drawsAtOnce(held, page), "a page lands above the first row").toBe(true);
  expect(drawsAtOnce(held, { ...held, historyFrom: 400 } as AcpmuxSnapshot), "a read that drew no row").toBe(true);
  expect(drawsAtOnce(held, { ...held, canLoadOlder: false } as AcpmuxSnapshot), "the top was reached").toBe(true);
  expect(drawsAtOnce(held, { ...held, promptCount: 900 } as AcpmuxSnapshot), "the prompt count came").toBe(true);
  const heads = PromptHeads.of([{ seq: 3, at: 0, text: "an older prompt" }]);
  expect(drawsAtOnce(held, { ...held, earlierPrompts: heads } as AcpmuxSnapshot), "the prompt index came").toBe(true);
  const grown = { ...held, rows: [...held.rows.slice(0, -1), row("reply", "assistant", "Done. More")] };
  expect(drawsAtOnce(held, grown as AcpmuxSnapshot), "a reply that grows is still a transition").toBe(false);
});
