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
/// The chat the composer shows, and whether a switch now carries its prompt (a harness switch).
let chat = "chat-a";
let carry = false;
/// The chips the intake handed to another chat than the one shown.
let handedOff: [string, string[]][] = [];

/// A composer's intake and its send hold, as Composer.tsx wires them; a send reads the chips after
/// the render that has them (a ref), as the composer's does.
function Probe() {
  intake = useAttachmentIntake({
    allowImages: true,
    pasteTarget: () => undefined,
    scope: chat,
    carries: () => carry,
    elsewhere: (session, chips) => handedOff.push([session, chips.map((chip) => chip.path ?? chip.name)]),
  });
  const hold = useSendWhenAttached(intake.loading, chat, intake.unsettled);
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
  chat = "chat-a";
  carry = false;
  handedOff = [];
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
  let stopped = 0;
  await act(async () => intake.attachLater("Recording.wav", host.make, FAILED, () => stopped++));
  await act(async () => send());
  expect(sent).toEqual([]);
  await act(async () => intake.cancel(intake.pending[0]!.id));
  expect(sent).toEqual([[]]);
  // The × stops the host's upload too (dictation.recording.cancel), once.
  expect(stopped).toBe(1);
  // The upload's late answer stages nothing.
  await act(async () => host.answer({ path: remote }));
  expect(intake.attachments).toEqual([]);
  expect(intake.pending).toEqual([]);
});

test("a failed upload leaves the chip with its note and Retry; the waiting send goes without it", async () => {
  await fresh();
  const host = upload();
  await act(async () => intake.attachLater("Recording.wav", host.make, FAILED));
  await act(async () => send());
  await act(async () => host.refuse(Object.assign(new Error("no route"), { code: "upload_failed" })));
  expect(sent).toEqual([[]]);
  expect(intake.pending).toMatchObject([{ name: "Recording.wav", failed: FAILED }]);
  // Retry asks the host again; its answer becomes the saved chip, for the next prompt.
  await act(async () => intake.retry(intake.pending[0]!.id));
  expect(host.asked).toHaveLength(2);
  expect(intake.pending[0]?.failed).toBeUndefined();
  await act(async () => host.answer({ path: remote }));
  expect(intake.pending).toEqual([]);
  expect(intake.attachments).toMatchObject([{ kind: "link", saved: true, path: remote }]);
  await act(async () => send());
  expect(sent).toEqual([[], [remote]]);
});

// Review of #26953 at 06aa3fc4: a switch that carries the prompt (a harness switch) moved the
// pending recording to the new chat with it, so its copy on chat A's machine was staged in chat B.
// The host's chip stays with the chat it was made for, and lands in that chat's kept chips.
test("a switch that carries the prompt leaves the uploading recording with its own chat", async () => {
  await fresh();
  const host = upload();
  await act(async () => intake.attachLater("Recording.wav", host.make, FAILED));
  chat = "chat-b";
  carry = true;
  await act(async () => root.render(<Probe />));
  // Chat B neither shows it nor waits for it: a send there goes at once, without it.
  expect(intake.pending).toEqual([]);
  await act(async () => send());
  expect(sent).toEqual([[]]);
  await act(async () => host.answer({ path: remote }));
  expect(intake.attachments).toEqual([]);
  expect(handedOff).toEqual([["chat-a", [remote]]]);
});
