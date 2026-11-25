// l10n-allow-file: test fixture prompts, commands and messages, not shipped UI.
// Every row whose drawn height follows a line the reader opened or closed is estimated as they left
// it (model.ts `measuredRowHeight`, `fallbackRowHeight`, `activityStepHeight`), closed and open,
// within the 4px spacing token of what Chrome draws. The estimate places a row whenever its drawn
// height is gone (another width, a "Worked for" closed and opened again, history paged out and back),
// so an estimate of the closed row under an opened one placed every row below it too high, and they
// moved down when it mounted (openedRunEstimate.test.tsx is the folded runs' case).
//
// The drawn heights are Chrome's, at 1100x800 (an 800px column), for these rows as the transcript
// drew them in the papercut pane (test/support/papercutChat.ts) from the same fixture, the reader's
// clicks made in the page (an untracked bench script, bench/reader-state-heights.ts, that reads each
// `article.acpmux-row`'s box). Before this change: the long prompt opened estimated 499 (drawn 958),
// the opened thought 26 (86), the opened commands 22 (269, 207, and 289 for 1,000 lines of output), the opened message 22 (139.5), and
// the edited-files card 150 and 78 whatever the reader had opened (drawn 70 shut, 142 open, 70).
// Those were drawn at the 22 one-line pitch; a row that opens under its one line adds the row air
// (transcriptGrid.ts ROW_AIR_LOOKS, conversation.css `--cv-row-air`) once, as `AIR` below.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { layoutConversation, type AcpmuxActivity, type AcpmuxRow } from "./model";
import { TRANSCRIPT_LINE_ROW as LINE, TRANSCRIPT_LINE_WORDS } from "./transcriptGrid";
import { TranscriptDisclosureProvider } from "./conversation/transcriptDisclosure";
import {
  callDisclosureKey,
  resetTranscriptDisclosure,
  useTranscriptDisclosure,
  type DisclosureSetter,
} from "./conversation/transcriptDisclosureModel";
import { thoughtChoices } from "./conversation/thoughtChoices";
import { setCardOpen } from "./turnChanges/openStore";
import { setEditedFilesSettings } from "./turnChanges/settings";
import { settleReact } from "../../../test/support/domTeardown";

const CHAT = "reader-state";
const SPACING = 4;
/// The air a one-line row adds over its 22 line of words.
const AIR = LINE - TRANSCRIPT_LINE_WORDS;

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  resetTranscriptDisclosure();
  thoughtChoices.clear();
  setCardOpen("edits-2", false);
  setEditedFilesSettings({});
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

/// The reader's click on line `key` of this chat, through the store the rows read (`useTranscriptDisclosure`).
async function setLine(key: string, open: boolean) {
  dom ??= new JSDOM("<!doctype html><main id=root></main>", {
    url: "http://localhost/",
  });
  for (const name of ["window", "document", "navigator", "IS_REACT_ACT_ENVIRONMENT"])
    if (!saved.has(name)) saved.set(name, scope[name]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  let set: DisclosureSetter | undefined;
  function Line() {
    [, set] = useTranscriptDisclosure(key);
    return null;
  }
  await act(async () => {
    root ??= createRoot(dom!.window.document.getElementById("root")!);
    root.render(
      <TranscriptDisclosureProvider sessionId={CHAT}>
        <Line />
      </TranscriptDisclosureProvider>,
    );
  });
  await act(async () => set!(open));
}

const estimate = (row: AcpmuxRow, sessionId = CHAT) =>
  layoutConversation([row], 800, undefined, undefined, undefined, undefined, sessionId).heights[0]!;
const near = (row: AcpmuxRow, drawn: number) => expect(Math.abs(estimate(row) - drawn)).toBeLessThanOrEqual(SPACING);

/// A finished step of the papercut fixture, as turns.ts shapes it inside an opened "Worked for".
const step = (id: string, items: AcpmuxActivity[]): AcpmuxRow =>
  ({
    id,
    version: 1,
    at: 0,
    kind: "activity",
    settled: true,
    foldRun: true,
    items,
  }) as AcpmuxRow;
const shell = (id: string, command: string, output: string, exitCode = 0): AcpmuxActivity => ({
  kind: "tool",
  text: command,
  tool: {
    id,
    title: command,
    kind: "execute",
    status: "completed",
    command,
    output,
    exitCode,
  },
});
const edit = (id: string, path: string, newText: string): AcpmuxActivity => ({
  kind: "tool",
  text: `Edit ${path}`,
  tool: {
    id,
    title: `Edit ${path}`,
    kind: "edit",
    status: "completed",
    locations: [{ path }],
    diffs: [{ path, oldText: "export const a = 1;\n", newText }],
  },
});
/// The turn's edited-files card (EditedFilesRow.tsx), as turns.ts merges its edits.
const card = (id: string, items: AcpmuxActivity[]): AcpmuxRow =>
  ({
    id,
    version: 1,
    at: 0,
    kind: "activity",
    ended: true,
    merged: [id],
    items,
  }) as AcpmuxRow;

test("a long prompt the reader opened is estimated whole, over Show less (PromptText.tsx `prompt:`)", async () => {
  const text = Array.from({ length: 40 }, (_, n) => `Line ${n + 1} of the long prompt about the retry helper.`).join(
    "\n",
  );
  const row = {
    id: "user-1",
    version: 1,
    at: 0,
    kind: "user",
    text,
  } as AcpmuxRow;
  // Drawn 503 shut (its 20 lines and Show more), 958 open.
  near(row, 503);
  await setLine("prompt:user-1", true);
  near(row, 958);
  // Another chat's prompt of the same row id is not this one.
  expect(Math.abs(estimate(row, "another-chat") - 503)).toBeLessThanOrEqual(SPACING);
  await setLine("prompt:user-1", false);
  near(row, 503);
});

test("a thought the reader opened is estimated over its text (ThoughtRow.tsx, thoughtChoices.ts)", () => {
  const text =
    "Looking at the retry helper. The guard runs after the total, so the second pass lets a value past the ceiling. " +
    "I should check where the policy is read, then move the guard before the sum and run the tests again to see the failure go away.";
  const row = step("thought-row", [{ kind: "thought", text, startedAt: 1, endedAt: 1 }]);
  // Drawn LINE shut (its one line), 86 + AIR open: the line, the fold's 4px and three 20px lines.
  near(row, LINE);
  thoughtChoices.set("thought-row:thought:0", true);
  near(row, 86 + AIR);
  thoughtChoices.set("thought-row:thought:0", false);
  near(row, LINE);
});

test("a command the reader opened is estimated with its Shell card (ToolRow.tsx `row:`, ShellBlock.tsx)", async () => {
  const output = Array.from({ length: 30 }, (_, n) => `✓ case ${n + 1} keeps the cache stable`).join("\n");
  const tests = step("tests", [shell("cmd-1", "bun test src/retry", output)]);
  const lint = step("lint", [
    shell("cmd-2", "bun run lint", "src/retry.ts:4 unused import\nsrc/retry.ts:9 missing return type\n2 problems", 1),
  ]);
  near(tests, LINE);
  near(lint, LINE);
  await setLine(callDisclosureKey("cmd-1"), true);
  await setLine(callDisclosureKey("cmd-2"), true);
  // Drawn 269: 30 lines of output kept to the card's 8-line box. Drawn 207: exit 1 over 3 lines.
  near(tests, 269 + AIR);
  near(lint, 207 + AIR);
  await setLine(callDisclosureKey("cmd-1"), false);
  near(tests, LINE);
  // Past 400 lines its end is shown, with Show all under the box: drawn 289.
  const long = step("long", [
    shell("cmd-4", "bun test", Array.from({ length: 1_000 }, (_, n) => `✓ case ${n + 1}`).join("\n")),
  ]);
  await setLine(callDisclosureKey("cmd-4"), true);
  near(long, 289 + AIR);
});

test("an `acpmux send` the reader opened is estimated with its message's card (SentMessageLine.tsx `send:`)", async () => {
  const command =
    "acpmux send lane-a 'The retry guard is fixed and the suite passes on main. Please rebase your branch onto it and rerun the integration tests before you merge.'";
  const row = step("sent", [{ ...shell("send-1", command, "queued"), text: command }]);
  near(row, LINE);
  // SentMessageLine.tsx `AcpmuxSendLine`: `send:` and the call's id (`sendDisclosureKey`).
  await setLine("send:send-1", true);
  // Drawn 139.5: the line, the card's two lines of the message, and Raw under it.
  near(row, 139.5 + AIR);
});

test("the edited-files card is estimated as one row until the reader opens it, then as its stacked diffs", () => {
  const two = card("edits-2", [
    edit("e1", "/home/dev/cmux/src/retry.ts", "export const a = 2;\nexport const b = 3;\n"),
    edit("e2", "/home/dev/cmux/src/policy.ts", "export const a = 2;\nexport const b = 3;\n"),
  ]);
  const one = card("edits-1", [edit("e3", "/home/dev/cmux/src/one.ts", "export const a = 2;\n")]);
  // One row at rest, whatever agentPane.editedFiles.show says (Leo, 2026-11-25: "just having one
  // row that expands out"): the 64px row and the 6px under it.
  near(two, 70);
  near(one, 70);
  setEditedFilesSettings({ show: "collapsed" });
  near(two, 70);
  // Opened (EditedFilesCard.tsx, turnChanges/openStore.ts): each file's 32px name over about six
  // diff lines, the stack at most 60% of the view tall (EditedFilesCard.css `.acpmux-edited-stack`).
  setCardOpen("edits-2", true);
  near(two, 70 + 2 * (32 + 6 * 18));
  near(one, 70);
  const many = card(
    "edits-9",
    Array.from({ length: 9 }, (_, n) => edit(`m${n}`, `/home/dev/cmux/src/f${n}.ts`, "export const a = 2;\n")),
  );
  setCardOpen("edits-9", true);
  near(many, 70 + Math.round((typeof window === "undefined" ? 800 : window.innerHeight || 800) * 0.6));
  setEditedFilesSettings({ show: "always" });
  setCardOpen("edits-2", false);
  setCardOpen("edits-9", false);
});
