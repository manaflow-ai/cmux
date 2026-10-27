// l10n-allow-file: test fixture words, not shipped UI.
// Voice input through the selected harness: a chat whose harness takes audio (ACP
// `promptCapabilities.audio`, Codex 0.145+ through acpmux) gets the session's recording with the
// prompt, beside its transcript; any other chat keeps plain dictation.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import React, { act, useRef } from "react";
import type { Root } from "react-dom/client";
import {
  INLINE_AUDIO_BYTES_LIMIT,
  audioAttachment,
  promptBlocks,
  takesAudio,
} from "../src/agent-session/acpmux/attachments";
import type { DictationAudio, DictationField } from "../src/agent-session/acpmux/dictation";

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
async function mount(accepts: boolean) {
  const { createRoot } = await import("react-dom/client");
  const { useDictation } = await import("../src/agent-session/acpmux/dictation");
  const calls: [string, unknown][] = [];
  const attached: { audio: typeof clip; textThen: string }[] = [];
  const omitted: string[] = [];
  let text = "";
  const field: DictationField = {
    focus() {},
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
    attach: (a) => attached.push({ audio: a, textThen: text }),
    omitted: (reason) => omitted.push(reason),
  };
  const container = document.createElement("div");
  host.append(container);
  root = createRoot(container);
  await act(async () => root!.render(<Pane audio={audio} />));
  return {
    calls,
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

test("recordings past the inline transport budget stay on the transcript path", () => {
  const twoMinutes = "A".repeat(Math.ceil(((44 + 16_000 * 2 * 120) * 4) / 3));
  expect(audioAttachment({ mimeType: "audio/wav", data: twoMinutes }, "Voice recording")).toBeDefined();
  const over = "A".repeat(Math.ceil(((INLINE_AUDIO_BYTES_LIMIT + 1) * 4) / 3) + 4);
  expect(audioAttachment({ mimeType: "audio/wav", data: over }, "Voice recording")).toBeUndefined();
});

test("inline transport omission notices keep their reason", async () => {
  const { translate } = await import("../src/agent-session/acpmux/i18n");
  const { recordingLeftOutNotice } = await import("../src/agent-session/acpmux/attachments");
  const capped = translate(recordingLeftOutNotice("tooLarge"), {}, "en");
  const tooLong = translate(recordingLeftOutNotice("tooLong"), {}, "en");
  expect(capped).toBe(tooLong);
  expect(translate(recordingLeftOutNotice("narrowband"), {}, "en")).not.toBe(capped);
});
