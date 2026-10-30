// l10n-allow-file: test fixture words, not shipped UI.
// Voice input through the selected harness: a chat whose harness takes audio (ACP
// `promptCapabilities.audio`, Codex 0.145+ through acpmux) gets the session's recording with the
// prompt, beside its transcript; any other chat keeps plain dictation.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import React, { act, useRef } from "react";
import type { Root } from "react-dom/client";
import {
  MAX_AUDIO_BYTES,
  audioAttachment,
  promptBlocks,
  recordingAttachment,
  recordingLeftOutNotice,
  remoteRecordingAttachment,
  takesAudio,
} from "../src/agent-session/acpmux/attachments";
import type { DictationAudio, DictationField } from "../src/agent-session/acpmux/dictation";
import type { DictationRecording } from "../src/agent-session/acpmux/dictationText";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT", "Node"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const clip = { mimeType: "audio/wav", data: "UklGRg==" };

/// A composer field and the dictation hook on it; returns what the host was asked, what was
/// attached, and the field's text at each attach.
async function mount(accepts: boolean, chat?: () => string | undefined) {
  const { createRoot } = await import("react-dom/client");
  const { useDictation } = await import("../src/agent-session/acpmux/dictation");
  const calls: [string, unknown][] = [];
  const attached: { audio: DictationRecording; textThen: string }[] = [];
  const omitted: string[] = [];
  let elsewhere = 0;
  let submitted = 0;
  let text = "";
  const field: DictationField = {
    focus() {},
    submit() {
      submitted += 1;
    },
    focused: () => true,
    text: () => ({ value: text, selectionStart: text.length, selectionEnd: text.length }),
    writeText(value: string) {
      text = value;
    },
    element: () => host,
  };
  const call = async (method: string, params?: Record<string, unknown>) => {
    calls.push([method, params]);
    return null;
  };
  function Pane({ audio }: { audio: DictationAudio }) {
    const prompt = useRef<DictationField | null>(field);
    useDictation(prompt, call, audio);
    return null;
  }
  const audio: DictationAudio = {
    accepts,
    chat,
    elsewhere: () => {
      elsewhere += 1;
    },
    attach: (a) => attached.push({ audio: a, textThen: text }),
    omitted: (reason) => omitted.push(reason),
  };
  const container = document.createElement("div");
  host.append(container);
  root = createRoot(container);
  await act(async () => root!.render(<Pane audio={audio} />));
  return {
    calls,
    elsewhere: () => elsewhere,
    submitted: () => submitted,
    attached,
    omitted,
    text: () => text,
    rerender: (next: boolean) => act(async () => root!.render(<Pane audio={{ ...audio, accepts: next }} />)),
  };
}

test("a harness that takes audio gets the recording before the words, and the host records for it", async () => {
  const { deliverDictation } = await import("../src/agent-session/acpmux/dictation");
  const pane = await mount(true);
  expect(pane.calls).toContainEqual(["dictation.audio", { enabled: true }]);
  await act(async () => {
    deliverDictation({ state: "listening", text: "fix the", level: 0.4, cancelled: false });
    deliverDictation({ state: "idle", text: "fix the build", level: 0, cancelled: false, audio: clip });
  });
  expect(pane.attached).toEqual([{ audio: clip, textThen: "fix the" }]);
  expect(pane.text()).toBe("fix the build");
  // Switching to a harness without audio tells the host, so the next start records nothing.
  await pane.rerender(false);
  expect(pane.calls.at(-1)).toEqual(["dictation.audio", { enabled: false }]);
  act(() => root?.unmount());
  root = undefined;
});

test("a cancelled session attaches nothing", async () => {
  const { deliverDictation } = await import("../src/agent-session/acpmux/dictation");
  const pane = await mount(true);
  await act(async () => {
    deliverDictation({ state: "listening", text: "never mind", level: 0.4, cancelled: false });
    deliverDictation({ state: "idle", text: "", level: 0, cancelled: true, audio: clip });
  });
  expect(pane.attached).toEqual([]);
  act(() => root?.unmount());
  root = undefined;
});

test("a chat without audio keeps plain dictation", async () => {
  const pane = await mount(false);
  expect(pane.calls).toContainEqual(["dictation.audio", { enabled: false }]);
  act(() => root?.unmount());
  root = undefined;
});

test("the recording goes to the agent as an ACP audio block after the transcript", () => {
  const recording = audioAttachment(clip, "Voice recording")!;
  expect(recording).toMatchObject({ kind: "audio", mimeType: "audio/wav", size: 4, data: clip.data });
  expect(promptBlocks("fix the build", [recording])).toEqual([
    { type: "text", text: "fix the build" },
    { type: "audio", mimeType: "audio/wav", data: clip.data },
  ]);
});

test("voice input follows the picked model", () => {
  const picker = (current: string) => [
    {
      id: "model",
      category: "model",
      currentValue: current,
      options: [
        { value: "hears", _meta: { inputModalities: ["text", "audio"] } },
        { value: "reads", _meta: { inputModalities: ["text", "image"] } },
        { value: "unknown" },
      ],
    },
  ];
  expect(takesAudio({ audio: true }, picker("hears"))).toBe(true);
  expect(takesAudio({ audio: true }, picker("reads"))).toBe(false);
  // A model without a list, beside models with one, takes none (as cmux-codex-acp rules).
  expect(takesAudio({ audio: true }, picker("unknown"))).toBe(false);
  // A harness that names no modalities at all is taken at its word.
  expect(takesAudio({ audio: true }, [{ category: "model", currentValue: "x", options: [{ value: "x" }] }])).toBe(true);
  expect(takesAudio({ audio: true }, undefined)).toBe(true);
  expect(takesAudio({ audio: false }, picker("hears"))).toBe(false);
  expect(takesAudio(undefined, picker("hears"))).toBe(false);
});

test("a recording left out says why, and only to a harness that takes audio", async () => {
  const { deliverDictation } = await import("../src/agent-session/acpmux/dictation");
  const pane = await mount(true);
  await act(async () => {
    deliverDictation({ state: "listening", text: "a long one", level: 0.4, cancelled: false });
    deliverDictation({ state: "idle", text: "a long one", level: 0, cancelled: false, audioOmitted: "tooLong" });
  });
  expect(pane.omitted).toEqual(["tooLong"]);
  expect(pane.attached).toEqual([]);
  expect(pane.text()).toBe("a long one");
  act(() => root?.unmount());
  root = undefined;
  const plain = await mount(false);
  await act(async () => {
    deliverDictation({ state: "listening", text: "words", level: 0.4, cancelled: false });
    deliverDictation({ state: "idle", text: "words", level: 0, cancelled: false, audioOmitted: "narrowband" });
  });
  expect(plain.omitted).toEqual([]);
  act(() => root?.unmount());
  root = undefined;
});

test("a recording past the byte cap is no attachment", () => {
  // Two minutes of 16 kHz 16-bit mono plus its header fits under the cap.
  const twoMinutes = "A".repeat(Math.ceil(((44 + 16_000 * 2 * 120) * 4) / 3));
  expect(audioAttachment({ mimeType: "audio/wav", data: twoMinutes }, "Voice recording")).toBeDefined();
  const over = "A".repeat(Math.ceil(((MAX_AUDIO_BYTES + 1) * 4) / 3) + 4);
  expect(audioAttachment({ mimeType: "audio/wav", data: over }, "Voice recording")).toBeUndefined();
});

test("a recording kept out by the byte cap gets a notice that does not claim two minutes", async () => {
  const { translate } = await import("../src/agent-session/acpmux/i18n");
  const { recordingLeftOutNotice } = await import("../src/agent-session/acpmux/attachments");
  // The byte cap's path, as App.tsx's `attach` takes it: no attachment, then the notice.
  const over = "A".repeat(Math.ceil(((MAX_AUDIO_BYTES + 1) * 4) / 3) + 4);
  expect(audioAttachment({ mimeType: "audio/wav", data: over }, "Voice recording")).toBeUndefined();
  const capped = translate(recordingLeftOutNotice("tooLarge"), {}, "en");
  expect(capped).toBe("The voice recording is too long to attach, so the prompt gets the transcript only.");
  // The host's two-minute stop reads the same; a narrowband mic keeps its own reason.
  expect(translate(recordingLeftOutNotice("tooLong"), {}, "en")).toBe(capped);
  expect(translate(recordingLeftOutNotice("narrowband"), {}, "en")).not.toBe(capped);
});

// Review of #27012 (P2): a recording the host could not write (a full disk, a folder that is not
// writable) came back as no audio and no reason, so auto-send sent the transcript alone without a
// word. The host now says `writeFailed`, and the notice says the recording was lost.
test("a recording the host could not save gets a notice that says the audio was lost", async () => {
  const { translate } = await import("../src/agent-session/acpmux/i18n");
  const { recordingLeftOutNotice } = await import("../src/agent-session/acpmux/attachments");
  const lost = translate(recordingLeftOutNotice("writeFailed"), {}, "en");
  expect(lost).toBe("The voice recording couldn't be saved on this Mac, so the prompt gets the transcript only.");
  expect(lost).not.toBe(translate(recordingLeftOutNotice("tooLong"), {}, "en"));
  expect(lost).not.toBe(translate(recordingLeftOutNotice("narrowband"), {}, "en"));
});

// Leo, 2026-10-26: "I ALREADY SAID WE NEED ARBITARRILY LARGE FILES OF ANY TYPE". A recording too
// long to go inline is the WAV the host wrote on this Mac: a local chat's agent gets that file.
test("a long recording goes to a local chat as its saved file, of any size", () => {
  const long = { mimeType: "audio/wav", path: "/tmp/cmux-dictation/Recording-a.wav", byteCount: 96_000_044 };
  const chip = recordingAttachment(long, "Voice recording", true)!;
  expect(chip).toMatchObject({
    kind: "link",
    saved: true,
    path: long.path,
    name: "Voice recording.wav",
    size: 96_000_044,
  });
  const blocks = promptBlocks("hello", [chip]);
  expect(blocks).toContainEqual(expect.objectContaining({ type: "resource_link", uri: `file://${long.path}` }));
  // A chat on another computer cannot open this Mac's file: the transcript goes, with a notice.
  expect(recordingAttachment(long, "Voice recording", false)).toBeUndefined();
  expect(recordingLeftOutNotice("elsewhere")).toBe("dictation.recordingElsewhere");
  // One that fits a prompt still goes as an audio block, local or not.
  expect(recordingAttachment(clip, "Voice recording", false)).toMatchObject({ kind: "audio", data: clip.data });
});

// A slow writer lets the pane navigate before its last recording update arrives.
test("a recording that finishes in another chat never attaches, splices or auto-sends there", async () => {
  const { deliverDictation, configureDictation } = await import("../src/agent-session/acpmux/dictation");
  configureDictation({ dictation: { autoSend: true } });
  for (const [origin, writeFails] of [
    ["chat-a", false],
    ["", false],
    ["chat-a", true],
    ["", true],
  ] as const) {
    let shown: string = origin;
    const pane = await mount(true, () => shown || undefined);
    await act(async () => deliverDictation({ state: "starting", text: "", level: 0, cancelled: false }));
    shown = "chat-b";
    await act(async () =>
      deliverDictation({
        state: "idle",
        text: "private words",
        level: 0,
        cancelled: false,
        session: origin,
        audio: writeFails
          ? undefined
          : { mimeType: "audio/wav", path: "/private/chat-a/Recording.wav", byteCount: 9_600_080 },
        audioOmitted: writeFails ? "writeFailed" : undefined,
      }),
    );
    expect(pane.attached).toEqual([]);
    expect(pane.text()).toBe("");
    expect(pane.submitted()).toBe(0);
    expect(pane.elsewhere()).toBe(1);
    await act(async () => root?.unmount());
    root = undefined;
  }
  configureDictation(undefined);
});

// A chat on another computer: the host sends the WAV it wrote, from its own disk, to the chat's
// machine (`dictation.recording.upload` with the host's own path), and the chip links the copy
// there, so the remote agent opens it. The page never reads the recording's bytes.
test("a long recording for a chat elsewhere goes as the copy the host sent to that machine", async () => {
  const long = { mimeType: "audio/wav", path: "/Users/me/cmux/Chat Uploads/u/Recording.wav", byteCount: 96_000_044 };
  const calls: [string, Record<string, unknown>][] = [];
  const remote = "/home/me/.acpmux/uploads/chat-a/Recording.wav";
  const chip = await remoteRecordingAttachment(long, "Voice recording", async (method, params) => {
    calls.push([method, params]);
    return { path: remote };
  });
  expect(calls).toEqual([["dictation.recording.upload", { path: long.path }]]);
  expect(chip).toMatchObject({
    kind: "link",
    saved: true,
    path: remote,
    name: "Voice recording.wav",
    size: 96_000_044,
  });
  const blocks = promptBlocks("hello", [chip!]);
  expect(blocks).toContainEqual(expect.objectContaining({ type: "resource_link", uri: `file://${remote}` }));
  expect(JSON.stringify(blocks)).not.toContain(long.path);
});

test("a long recording the host could not send elsewhere goes as the transcript alone", async () => {
  const long = { mimeType: "audio/wav", path: "/Users/me/cmux/Chat Uploads/u/Recording.wav", byteCount: 96_000_044 };
  const refused = async () => {
    throw Object.assign(new Error("Couldn't send the file to huge-blue."), { code: "upload_failed" });
  };
  expect(await remoteRecordingAttachment(long, "Voice recording", refused)).toBeUndefined();
  // An older host, or an answer that is not a path there.
  expect(await remoteRecordingAttachment(long, "Voice recording", async () => ({}))).toBeUndefined();
  expect(
    await remoteRecordingAttachment(long, "Voice recording", async () => ({ path: "relative.wav" })),
  ).toBeUndefined();
  // A recording that went inline has no file to send: nothing is asked.
  let asked = false;
  const inline = await remoteRecordingAttachment(clip, "Voice recording", async () => {
    asked = true;
    return { path: "/x" };
  });
  expect(inline).toBeUndefined();
  expect(asked).toBe(false);
});
