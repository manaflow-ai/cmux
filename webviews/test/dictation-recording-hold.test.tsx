// l10n-allow-file: test fixture words, not shipped UI.
// A long recording sent to the machine of a chat that runs elsewhere (attachments.ts
// remoteRecordingAttachment) is a pending chip while it uploads, the same loading tile a streaming
// drop shows (composer/attachmentIntake.tsx attachLater). A send made meanwhile (Return, the Send
// button, dictation's auto-send) waits for it, as it waits for a file still being read, so the
// recording is never lost from the prompt; its × lets the send go without it, and a failed upload
// leaves the chip with its note and Retry. Leo, 2026-10-25: "Attachments take arbitrarily large
// files of any type".
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, useRef } from "react";
import type { Root } from "react-dom/client";
import { type ComposerAttachment, remoteRecordingAttachment } from "../src/agent-session/acpmux/attachments";
import { useAttachmentIntake, useSendWhenAttached } from "../src/agent-session/acpmux/composer/attachmentIntake";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT", "Node"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root;

beforeAll(async () => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { url: "https://cmux.test/" });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: dom.window.Node,
  });
  const { createRoot } = await import("react-dom/client");
  root = createRoot(dom.window.document.getElementById("root")!);
});

afterAll(() => {
  act(() => root.unmount());
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const long = { mimeType: "audio/wav", path: "/Users/me/cmux/Chat Uploads/u/Recording.wav", byteCount: 96_000_044 };
const remote = "/home/me/.acpmux/uploads/chat-a/Recording.wav";
const FAILED = "The recording could not be sent.";

type Intake = ReturnType<typeof useAttachmentIntake>;
let intake: Intake;
/// What each send carried: the paths (or names) of its chips.
let sent: string[][] = [];
let send: () => void = () => {};

/// A composer's intake and its send hold, as Composer.tsx wires them; a send reads the chips after
/// the render that has them (a ref), as the composer's does.
function Probe() {
  intake = useAttachmentIntake({ allowImages: true, pasteTarget: () => undefined, scope: "chat-a" });
  const hold = useSendWhenAttached(intake.loading, "chat-a", intake.unsettled);
  const staged = useRef<readonly ComposerAttachment[]>([]);
  staged.current = intake.attachments;
  const go = () => {
    sent.push(staged.current.map((chip) => chip.path ?? chip.name));
    intake.setAttachments([]);
  };
  send = () => {
    if (!hold(go)) go();
  };
  return null;
}

/// The host's `dictation.recording.upload`, answered when the test says.
function upload() {
  let answer: (value: unknown) => void = () => {};
  let refuse: (error: Error) => void = () => {};
  const asked: string[] = [];
  const call = (method: string, params: Record<string, unknown>) => {
    asked.push(`${method} ${String(params.path)}`);
    return new Promise<unknown>((resolve, reject) => {
      answer = resolve;
      refuse = reject;
    });
  };
  return {
    asked,
    answer: (value: unknown) => answer(value),
    refuse: (error: Error) => refuse(error),
    make: () => remoteRecordingAttachment(long, "Recording", call),
  };
}

async function fresh() {
  sent = [];
  await act(async () => root.render(<Probe />));
  await act(async () => intake.setAttachments([]));
}

test("a send made while a long recording uploads waits for it and carries the remote copy", async () => {
  await fresh();
  const host = upload();
  // Dictation's auto-send runs right after the recording is handed over, before any other render.
  await act(async () => {
    intake.attachLater("Recording.wav", host.make, FAILED);
    send();
  });
  expect(host.asked).toEqual([`dictation.recording.upload ${long.path}`]);
  expect(intake.pending).toMatchObject([{ name: "Recording.wav" }]);
  expect(intake.pending[0]?.failed).toBeUndefined();
  expect(sent).toEqual([]);
  // A second press while it waits does not send twice.
  await act(async () => send());
  expect(sent).toEqual([]);
  await act(async () => host.answer({ path: remote }));
  expect(intake.pending).toEqual([]);
  expect(sent).toEqual([[remote]]);
});

test("the pending recording's x lets the waiting send go without it", async () => {
  await fresh();
  const host = upload();
  await act(async () => intake.attachLater("Recording.wav", host.make, FAILED));
  await act(async () => send());
  expect(sent).toEqual([]);
  await act(async () => intake.cancel(intake.pending[0]!.id));
  expect(sent).toEqual([[]]);
  // The upload's late answer stages nothing.
  await act(async () => host.answer({ path: remote }));
  expect(intake.attachments).toEqual([]);
  expect(intake.pending).toEqual([]);
});

test("a failed upload keeps the waiting send blocked with the failed chip; Retry's answer lets it go with the audio", async () => {
  await fresh();
  const host = upload();
  await act(async () => intake.attachLater("Recording.wav", host.make, FAILED));
  await act(async () => send());
  // The stager refuses the recording (Cloud's `upload_refused` at begin, a peer's `too_large`).
  await act(async () => host.refuse(Object.assign(new Error("refused"), { code: "upload_refused" })));
  // The send does not go without its audio: it waits, and the chip says why, with Retry.
  expect(sent).toEqual([]);
  expect(intake.pending).toMatchObject([{ name: "Recording.wav", failed: FAILED }]);
  // A send pressed again while the chip shows its failure waits too.
  await act(async () => send());
  expect(sent).toEqual([]);
  // Retry asks the host again; its answer becomes the chip, and the waiting send goes with it, once.
  await act(async () => intake.retry(intake.pending[0]!.id));
  expect(host.asked).toHaveLength(2);
  expect(intake.pending[0]?.failed).toBeUndefined();
  expect(sent).toEqual([]);
  await act(async () => host.answer({ path: remote }));
  expect(intake.pending).toEqual([]);
  expect(sent).toEqual([[remote]]);
});

test("the failed recording's x lets the waiting send go with the text alone", async () => {
  await fresh();
  const host = upload();
  await act(async () => intake.attachLater("Recording.wav", host.make, FAILED));
  await act(async () => send());
  await act(async () => host.answer(null));
  expect(sent).toEqual([]);
  expect(intake.pending).toMatchObject([{ name: "Recording.wav", failed: FAILED }]);
  await act(async () => intake.cancel(intake.pending[0]!.id));
  expect(sent).toEqual([[]]);
  expect(intake.pending).toEqual([]);
});
