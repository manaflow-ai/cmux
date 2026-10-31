// l10n-allow-file: test fixtures (command lines, session names and messages).
// Several messages from one call (acpmuxSends.ts `acpmuxSendBatch`, acpmuxMcpSends.ts): a shell
// function a coordinator batch-sends with, a `for` loop, a `;`/`&&` chain and the acpmux MCP
// send's `messages`, each read as one sent-message row per recipient. Anything else stays a
// command row. The reading is memoized per call snapshot (`acpmuxSendCalls`).
import { beforeEach, describe, expect, test } from "bun:test";
import type { AcpmuxActivity } from "../model";
import { acpmuxMcpSends } from "./acpmuxMcpSends";
import {
  acpmuxSend,
  acpmuxSendBatch,
  acpmuxSendCalls,
  acpmuxSendCallsParseCountForTests,
  resetAcpmuxSendCallsCacheForTests,
} from "./acpmuxSends";
import { toolGroups } from "./toolGroups";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

const bash = (command: string, fields: Partial<Tool> = {}): Tool => ({
  id: `toolu_${command.length}`,
  title: command.slice(0, 120),
  kind: "execute",
  status: "completed",
  command,
  ...fields,
});

/// The coordinator's shape from Leo's screenshot (2026-10-30), names made up.
const FUNCTION_BATCH =
  'cd /tmp/coord; s(){ acpmux send --no-wait --from coord "$1" "$(cat "$2")" 2>&1 | tail -1; }; s build-box/nightly escalate-nightly.md; s gcp-lane/acpmux-owner relay-owner.md';

beforeEach(() => resetAcpmuxSendCallsCacheForTests());

describe("acpmuxSendBatch", () => {
  test("a single send reads as before: one message, its words", () => {
    expect(acpmuxSendBatch("acpmux send --no-wait coord-deputy 'Merged #4182.'")).toEqual({
      sends: [{ target: "coord-deputy", text: "Merged #4182.", noWait: true }],
    });
    const calls = acpmuxSendCalls(bash("acpmux send --no-wait coord-deputy 'Merged #4182.'", { output: "queued" }));
    expect(calls?.map(({ target, text, state }) => ({ target, text, state }))).toEqual([
      { target: "coord-deputy", text: "Merged #4182.", state: "sent" },
    ]);
    // A single send is no batch member: no index, so its row keeps its first key.
    expect(calls?.[0]?.index).toBeUndefined();
  });

  test("a shell function: each call's $1 the target, the file its $(cat \"$2\") reads named", () => {
    // The single-send reader refuses it (two sends); the batch reads both.
    expect(acpmuxSend(FUNCTION_BATCH)).toBeUndefined();
    expect(acpmuxSendBatch(FUNCTION_BATCH)).toEqual({
      sends: [
        { target: "build-box/nightly", file: "escalate-nightly.md", noWait: true },
        { target: "gcp-lane/acpmux-owner", file: "relay-owner.md", noWait: true },
      ],
    });
    // `function name { … }` and literal prompt arguments.
    expect(acpmuxSendBatch('function tell { acpmux send "$1" "$2"; }\ntell a "hello there"\ntell b bye')?.sends).toEqual([
      { target: "a", text: "hello there", noWait: false },
      { target: "b", text: "bye", noWait: false },
    ]);
  });

  test("each message takes its own line of the output: queued, steered, or acpmux's error", () => {
    const calls = acpmuxSendCalls(
      bash(FUNCTION_BATCH, {
        output: 'queued\nacpmux: no_session: no session matches "gcp-lane/acpmux-owner"',
        exitCode: 0,
      }),
    );
    expect(calls?.map(({ target, state, delivery, index, count }) => ({ target, state, delivery, index, count }))).toEqual([
      { target: "build-box/nightly", state: "sent", delivery: "queued", index: 0, count: 2 },
      { target: "gcp-lane/acpmux-owner", state: "failed", delivery: undefined, index: 1, count: 2 },
    ]);
    // While the call runs, every message is going out.
    expect(acpmuxSendCalls(bash(FUNCTION_BATCH, { id: "running", status: "in_progress" }))?.map((c) => c.state)).toEqual([
      "sending",
      "sending",
    ]);
    // A failed call whose output no line can be matched to: not known whether each went.
    expect(
      acpmuxSendCalls(bash(FUNCTION_BATCH, { id: "failed", status: "failed", output: "Exit code 1\nboom" }))?.map(
        (c) => c.state,
      ),
    ).toEqual(["ended", "ended"]);
  });

  test("a for loop: its variable takes each word, in the target and the file's path", () => {
    expect(
      acpmuxSendBatch('for lane in tests docs; do acpmux send --no-wait "$lane" "$(cat "/tmp/briefs/${lane}.md")"; done')
        ?.sends,
    ).toEqual([
      { target: "tests", file: "/tmp/briefs/tests.md", noWait: true },
      { target: "docs", file: "/tmp/briefs/docs.md", noWait: true },
    ]);
    // Over several lines, with bash's `$(<file)`.
    expect(acpmuxSendBatch('for x in p q\ndo\n  acpmux send $x "$(<$x.md)"\ndone')?.sends).toEqual([
      { target: "p", file: "p.md", noWait: false },
      { target: "q", file: "q.md", noWait: false },
    ]);
  });

  test("a ; or && chain of sends", () => {
    expect(
      acpmuxSendBatch("acpmux send a 'one' && acpmux send b 'two'; acpmux send c - <<'EOF'\nthree\nEOF")?.sends.at(-1),
    ).toEqual({ target: "c", text: "three\n", noWait: false });
    expect(acpmuxSendBatch("acpmux send a 'one' && acpmux send b 'two'; acpmux send c three")?.sends.map((s) => s.target)).toEqual([
      "a",
      "b",
      "c",
    ]);
    // Other work in the chain is counted, never hidden: it stays behind Raw.
    expect(acpmuxSendBatch("git push && acpmux send a 'pushed' && acpmux send b 'pushed'")?.others).toBe(1);
  });

  test("what is not known stays a command row: nothing is guessed", () => {
    for (const line of [
      "git status && ls -la",
      'echo "acpmux send x y"',
      'while read lane; do acpmux send "$lane" hi; done < lanes',
      'for lane in $(cat lanes); do acpmux send "$lane" hi; done',
      'acpmux send "$LANE" hi; acpmux send b hi',
      's(){ acpmux send "$1" hi; }; s "$NEXT"',
      "bash -c 'acpmux send a one; acpmux send b two'",
      "acpmux send a \"$(acpmux send b x)\"",
      "for x in a b; do acpmux send $x hi",
      "s(){ acpmux send a hi",
    ])
      expect(acpmuxSendBatch(line)).toBeUndefined();
    expect(acpmuxSendCalls(bash("git status && ls -la"))).toBeUndefined();
    expect(acpmuxSendCalls(bash('for f in *.md; do wc -l "$f"; done'))).toBeUndefined();
  });

  test("a batch draws as one group of sent-message rows, one per recipient", () => {
    const call = bash(FUNCTION_BATCH, { output: "queued\nsteered" });
    const groups = toolGroups([{ kind: "tool", text: call.title, tool: call }]);
    expect(groups.length).toBe(1);
    const group = groups[0]!;
    expect(group.type).toBe("messages");
    if (group.type !== "messages") return;
    expect(group.members.map((member) => (member.type === "send" ? member.send.target : ""))).toEqual([
      "build-box/nightly",
      "gcp-lane/acpmux-owner",
    ]);
  });
});

describe("acpmuxSendCalls is memoized per call snapshot", () => {
  test("a streamed update elsewhere never reads this call's line again", () => {
    const call = bash(FUNCTION_BATCH, { output: "queued\nqueued" });
    const other = bash("bun test", { id: "other", status: "in_progress", output: "" });
    const items = (o: Tool): AcpmuxActivity[] => [
      { kind: "tool", text: call.title, tool: call },
      { kind: "tool", text: o.title, tool: o },
    ];
    toolGroups(items(other));
    const after = acpmuxSendCallsParseCountForTests();
    // Fifty tokens of output on the other call, each a new snapshot of it and of the turn.
    let next = other;
    for (let token = 0; token < 50; token++) {
      next = { ...next, output: `${next.output}x` };
      toolGroups(items(next));
    }
    // Only the changing call is read again, once per token; the batch never.
    expect(acpmuxSendCallsParseCountForTests() - after).toBe(50);
    // A new snapshot of the batch itself (its output changed) is read once.
    acpmuxSendCalls({ ...call, output: "queued\nsteered" });
    expect(acpmuxSendCallsParseCountForTests() - after).toBe(51);
  });
});

describe("acpmuxMcpSends", () => {
  const mcp = (args: unknown, fields: Partial<Tool> = {}): Tool => ({
    id: "toolu_mcp",
    title: "mcp__cmux__acpmux_send",
    kind: "other",
    status: "completed",
    inputSummary: JSON.stringify(args),
    ...fields,
  });

  test("messages merge over the top-level defaults; a file names its path", () => {
    const parts = acpmuxMcpSends(
      mcp({ text: "Rebase on #4182.", messages: [{ to: "tests" }, { to: "docs", file: "/tmp/docs.md" }] }),
    );
    expect(parts?.map(({ target, text, file, state }) => ({ target, text, file, state }))).toEqual([
      { target: "tests", text: "Rebase on #4182.", file: undefined, state: "sent" },
      { target: "docs", text: undefined, file: "/tmp/docs.md", state: "sent" },
    ]);
  });

  test("the result's rows: one per recipient, a tag item one per session it reached", () => {
    const output = JSON.stringify({
      results: [
        { index: 0, to: "tests", target: "tests", ok: true, status: "queued" },
        { index: 1, tag: "area=docs", target: "docs-a", ok: true, status: "delivered" },
        { index: 1, tag: "area=docs", target: "docs-b", ok: false, status: "failed", error: "Not sent" },
      ],
      sent: 2,
      failed: 1,
    });
    const parts = acpmuxMcpSends(mcp({ messages: [{ to: "tests", text: "a" }, { tag: "area=docs", text: "b" }] }, { output }));
    expect(parts?.map(({ target, text, state, delivery, index }) => ({ target, text, state, delivery, index }))).toEqual([
      { target: "tests", text: "a", state: "sent", delivery: "queued", index: 0 },
      { target: "docs-a", text: "b", state: "sent", delivery: "delivered", index: 1 },
      { target: "docs-b", text: "b", state: "failed", delivery: undefined, index: 1 },
    ]);
  });

  test("the first shape stays agentMessages.ts's card; other tools are not sends", () => {
    expect(acpmuxMcpSends(mcp({ to: "tests", text: "hi" }))).toBeUndefined();
    expect(acpmuxMcpSends({ ...mcp({ messages: [{ to: "a", text: "b" }] }), title: "mcp__gmail__send" })).toBeUndefined();
    // A file alone (the first shape with `file`) is a send row naming it.
    expect(acpmuxMcpSends(mcp({ to: "tests", file: "/tmp/b.md" }))?.[0]).toMatchObject({ target: "tests", file: "/tmp/b.md" });
  });
});
