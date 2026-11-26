// l10n-allow-file: synthetic file names and host errors for a behavioral regression.
// Leo, 2026-11-01: he pasted a 17 s mp4 into a chat on another machine and sent "here"; the agent
// answered "Nothing came through", the chip showed Retry, and "i had to retry to get it to load???".
// A send made while a file uploads waits for it and goes with it (composer/attachmentIntake.tsx),
// and a failed upload is asked again on its own, with no Retry and no key or click (Leo, 2026-11-22:
// "vacuous decisions like that should be just done"; composer/uploadRetry.ts).
import { afterAll, afterEach, beforeAll, expect, jest, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, useImperativeHandle, type Ref } from "react";
import { createRoot, type Root } from "react-dom/client";
import type { KnownPaths } from "../src/agent-session/acpmux/attachments";
import type { UploadResult } from "../src/agent-session/acpmux/cloudUploads";
import { setExperimentSwitches } from "../src/experiments/switches";
import {
  useAttachmentIntake,
  useSendWhenAttached,
  type AttachmentIntakeOptions,
} from "../src/agent-session/acpmux/composer/attachmentIntakeModel";
import { ChipRetries } from "../src/agent-session/acpmux/composer/uploadRetry";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT", "Node", "Element"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  const { window } = dom;
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
    Element: window.Element,
  });
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  jest.useRealTimers();
  setExperimentSwitches({});
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

const mp4 = () => new File(["video bytes"], "Sunbringer Menu Animation.mp4", { type: "video/mp4" });

type Probe = ReturnType<typeof useAttachmentIntake> & { hold: ReturnType<typeof useSendWhenAttached> };
function Harness({ options, handle }: { options: AttachmentIntakeOptions; handle: Ref<Probe> }) {
  const intake = useAttachmentIntake(options);
  // As Composer.tsx holds its send.
  const hold = useSendWhenAttached(intake.loading, options.scope, intake.unsettled);
  useImperativeHandle(handle, () => ({ ...intake, hold }));
  return null;
}

/// Yields to the next macrotask, so timers and the hook's state updates run.
const turn = () => new Promise((resolve) => setTimeout(resolve, 0));

/// Waits until `check` holds, giving up after `within` ms: the asks again back off from 0.5-1 s, then
/// 1-2 s (autoRetry.ts), so two of them land within 3 s.
async function until(check: () => boolean, within = 4_000) {
  const deadline = Date.now() + within;
  while (!check() && Date.now() < deadline) await act(turn);
  expect(check()).toBe(true);
}

function mount(upload: AttachmentIntakeOptions["upload"], localPaths?: AttachmentIntakeOptions["localPaths"]) {
  const options: AttachmentIntakeOptions = {
    allowImages: true,
    scope: "chat",
    pasteTarget: () => undefined,
    upload,
    localPaths,
  };
  const handle: { current: Probe | null } = { current: null };
  root = createRoot(host);
  act(() => root!.render(<Harness options={options} handle={handle} />));
  return handle;
}

test("a delayed native lookup keeps the loading mark while Attachment Type Icons is off (the default)", async () => {
  const lookup = Promise.withResolvers<KnownPaths>();
  const handle = mount(
    () => Promise.resolve({ paths: [] }),
    () => lookup.promise,
  );
  await act(() => void handle.current!.attach([new File(["bytes"], "local.txt")], true, "drop"));
  expect(handle.current!.pending.map((chip) => chip.resolvingPath)).toEqual([undefined]);
  await act(async () => lookup.resolve([{ path: "/tmp/local.txt", folder: false }]));
  expect(handle.current!.attachments.map((chip) => chip.path)).toEqual(["/tmp/local.txt"]);
});

test("a delayed native lookup keeps its chips local until one file actually needs bytes", async () => {
  setExperimentSwitches({ attachmentTypeIcons: true });
  const lookup = Promise.withResolvers<KnownPaths>();
  const upload = Promise.withResolvers<UploadResult>();
  const batches: string[][] = [];
  const handle = mount(
    (files, _, progress) => {
      batches.push(files.map((file) => file.name));
      progress?.(0, 0.5);
      return upload.promise;
    },
    () => lookup.promise,
  );
  const files = ["local.txt", "clipboard.bin"].map((name) => new File(["bytes"], name));
  await act(() => void handle.current!.attach(files, true, "drop"));
  expect(handle.current!.pending.map((chip) => chip.resolvingPath)).toEqual([true, true]);
  expect(batches).toEqual([]);
  await act(async () => lookup.resolve([{ path: "/tmp/local.txt", folder: false }, undefined]));
  expect(handle.current!.attachments.map((chip) => chip.path)).toEqual(["/tmp/local.txt"]);
  expect(batches).toEqual([["clipboard.bin"]]);
  expect(handle.current!.pending).toMatchObject([{ name: "clipboard.bin", resolvingPath: false, progress: 0.5 }]);
  await act(async () => upload.resolve({ paths: ["/saved/clipboard.bin"] }));
  expect(handle.current!.pending).toEqual([]);
});

test("a send made while a pasted video uploads waits for it, then goes once with it", async () => {
  let finish: (result: UploadResult) => void = () => {};
  const handle = mount(() => new Promise<UploadResult>((resolve) => (finish = resolve)));
  await act(() => void handle.current!.attach([mp4()], true));
  await until(() => handle.current!.pending[0]?.uploading === true);
  // Before: an upload never held a send, so "here" went at once without the video.
  const sent: string[][] = [];
  const send = () => sent.push(handle.current!.attachments.map((chip) => chip.name));
  expect(handle.current!.hold(send)).toBe(true);
  expect(sent).toEqual([]);
  await act(() => finish({ paths: ["/home/cmux/.acpmux/uploads/s/u/Sunbringer Menu Animation.mp4"] }));
  await until(() => sent.length > 0);
  expect(sent).toEqual([["Sunbringer Menu Animation.mp4"]]);
});

test("a failed upload is asked again on its own, with no key or click; its chip never shows a failure", async () => {
  const answers: UploadResult[] = [
    { error: "Couldn't send the file to gcp-codex-lane-2." },
    { paths: ["/remote/clip.mp4"] },
  ];
  let calls = 0;
  const handle = mount(async () => {
    calls += 1;
    return answers.shift();
  });
  let shownFailed = false;
  await act(() => void handle.current!.attach([mp4()], true));
  await until(() => {
    if (handle.current!.pending.some((chip) => chip.failed)) shownFailed = true;
    return handle.current!.attachments.length === 1;
  });
  expect(calls).toBe(2);
  expect(shownFailed).toBe(false);
  expect(handle.current!.pending).toEqual([]);
  expect(handle.current!.loading).toBe(0);
});

test("a failed upload that keeps failing keeps loading and holds a send; its x ends the asks", async () => {
  let calls = 0;
  const handle = mount(async () => {
    calls += 1;
    return { error: "The upload timed out: the app did not answer." };
  });
  await act(() => void handle.current!.attach([mp4()], true));
  await until(() => calls >= 2);
  const chip = handle.current!.pending[0]!;
  // Still loading, with the host's words for its tile's "Still trying" once that lasts; never failed.
  expect(chip.failed).toBeUndefined();
  expect(chip.retrying).toContain("The upload timed out");
  expect(handle.current!.loading).toBe(1);
  expect(handle.current!.hold(() => {})).toBe(true);
  act(() => handle.current!.cancel(chip.id));
  await until(() => handle.current!.pending.length === 0);
  expect(handle.current!.loading).toBe(0);
  const after = calls;
  // fixed-wait: longer than the next backoff step, to see that no ask comes after the x.
  await act(() => new Promise((resolve) => setTimeout(resolve, 2_500)));
  expect(calls).toBe(after);
});

test("an upload the host refused outright is asked again too: a full disk may be freed", async () => {
  let calls = 0;
  const handle = mount(async () => {
    calls += 1;
    return calls === 1 ? { error: "The disk is full.", final: true } : { paths: ["/u/clip.mp4"] };
  });
  await act(() => void handle.current!.attach([mp4()], true));
  await until(() => calls === 1);
  // It waits for its file meanwhile, as for any loading chip.
  expect(handle.current!.hold(() => {})).toBe(true);
  await until(() => handle.current!.attachments.length === 1);
  expect(calls).toBe(2);
  expect(handle.current!.pending).toEqual([]);
});

test("a failed upload is asked again only in its own chat, at once on coming back to it", async () => {
  // The composer instance survives a chat switch. Uploading A's file with B's current upload
  // handler would leak it to B's machine, even though A's pending chip stayed scoped to A.
  const handle: { current: Probe | null } = { current: null };
  let aCalls = 0;
  let bCalls = 0;
  const makeOptions = (scope: string, upload: AttachmentIntakeOptions["upload"]): AttachmentIntakeOptions => ({
    allowImages: true,
    scope,
    pasteTarget: () => undefined,
    upload,
  });
  const a = makeOptions("chat-a", async () =>
    ++aCalls === 1 ? { error: "Temporary peer disconnect" } : { paths: ["/chat-a/clip.mp4"] },
  );
  const b = makeOptions("chat-b", async () => {
    bCalls += 1;
    return { paths: ["/chat-b/clip.mp4"] };
  });
  root = createRoot(host);
  act(() => root!.render(<Harness options={a} handle={handle} />));
  await act(() => void handle.current!.attach([mp4()], true));
  await until(() => aCalls === 1 && handle.current!.pending.length === 1);
  // An ordinary chat selection, with no explicit draft/attachment carry.
  act(() => root!.render(<Harness options={b} handle={handle} />));
  expect(handle.current!.pending).toEqual([]);
  // fixed-wait: past the first asks' backoff, none of which may go through B.
  await act(() => new Promise((resolve) => setTimeout(resolve, 1_500)));
  expect(bCalls).toBe(0);
  expect(aCalls).toBe(1);
  expect(handle.current!.attachments).toEqual([]);
  // Back in chat A: it asks at once, with A's own upload. Nothing went to B's machine or prompt.
  act(() => root!.render(<Harness options={a} handle={handle} />));
  await until(() => handle.current!.attachments.some((attached) => attached.name === "Sunbringer Menu Animation.mp4"));
  expect(aCalls).toBe(2);
  expect(bCalls).toBe(0);
});

test("a paste whose twin screenshots are compared after a chat switch uploads through its own chat", async () => {
  const handle: { current: Probe | null } = { current: null };
  const calls: string[] = [];
  const makeOptions = (scope: string): AttachmentIntakeOptions => ({
    allowImages: true,
    scope,
    pasteTarget: () => ({ uploads: true }),
    upload: async () => {
      calls.push(scope);
      return { paths: [`/${scope}/shot.png`] };
    },
  });
  const [a, b] = [makeOptions("chat-a"), makeOptions("chat-b")];
  root = createRoot(host);
  act(() => root!.render(<Harness options={a} handle={handle} />));
  // One screenshot twice (attachments.ts filesOnce): its bytes are compared after the paste's task.
  const bytes = new Uint8Array(600).fill(7);
  const files = [
    new File([bytes], "shot.png", { type: "image/png" }),
    new File([bytes], "copy.png", { type: "image/png" }),
  ];
  const event = new dom.window.Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(event, "clipboardData", { value: { files, types: ["Files"], getData: () => "" } });
  act(() => {
    dom.window.document.dispatchEvent(event);
  });
  // The person moves to chat B before the compare answers, and stays there while A's file uploads.
  act(() => root!.render(<Harness options={b} handle={handle} />));
  await until(() => calls.length > 0);
  expect(calls).toEqual(["chat-a"]);
});

test("an intentionally carried upload is asked again through its destination chat", async () => {
  const handle: { current: Probe | null } = { current: null };
  let aCalls = 0;
  let bCalls = 0;
  const makeOptions = (scope: string, upload: AttachmentIntakeOptions["upload"]): AttachmentIntakeOptions => ({
    allowImages: true,
    scope,
    pasteTarget: () => undefined,
    carries: () => true,
    upload,
  });
  const a = makeOptions("chat-a", async () => {
    aCalls += 1;
    return { error: "Temporary peer disconnect" };
  });
  const b = makeOptions("chat-b", async () => {
    bCalls += 1;
    return { paths: ["/chat-b/clip.mp4"] };
  });
  root = createRoot(host);
  act(() => root!.render(<Harness options={a} handle={handle} />));
  await act(() => void handle.current!.attach([mp4()], true));
  await until(() => aCalls === 1 && handle.current!.pending.length === 1);
  act(() => root!.render(<Harness options={b} handle={handle} />));
  await until(() => bCalls === 1 && handle.current!.attachments.length === 1);
  expect(aCalls).toBe(1);
  expect(handle.current!.pending).toEqual([]);
});

test("a file the composer refused never holds a send and is never asked again: it would fail the same way", async () => {
  const options: AttachmentIntakeOptions = { allowImages: false, scope: "chat", pasteTarget: () => undefined };
  const handle: { current: Probe | null } = { current: null };
  root = createRoot(host);
  act(() => root!.render(<Harness options={options} handle={handle} />));
  await act(() => void handle.current!.attach([new File(["png"], "shot.png", { type: "image/png" })]));
  await until(() => Boolean(handle.current!.pending[0]?.failed));
  expect(handle.current!.pending[0]!.retrying).toBeUndefined();
  expect(handle.current!.loading).toBe(0);
  expect(handle.current!.hold(() => {})).toBe(false);
});

/// A ChipRetries with no jitter and short steps, and a visible page.
function retries(ask: (id: string) => boolean) {
  return new ChipRetries(ask, { firstMs: 20, maxMs: 40, random: () => 1, visible: () => true });
}
/// Moves the fake clock on: the backoff is the behavior under test, so the steps are timed exactly.
const wait = (ms: number) => void jest.advanceTimersByTime(ms);

test("ChipRetries asks a failed chip again after its backoff, never beside an attempt still running", () => {
  jest.useFakeTimers();
  const asked: string[] = [];
  const loop = retries((id) => {
    asked.push(id);
    return true;
  });
  loop.failed("a");
  expect(loop.has("a")).toBe(true);
  expect(asked).toEqual([]);
  // Past the first 20 ms step.
  wait(35);
  expect(asked).toEqual(["a"]);
  // Its attempt still runs: a wake (the pane shown again) starts no second one.
  loop.wake();
  wait(60);
  expect(asked).toEqual(["a"]);
  // It failed again: the next ask comes after the grown step.
  loop.failed("a");
  wait(60);
  expect(asked).toEqual(["a", "a"]);
  // Made (or gone): no more asks.
  loop.end("a");
  expect(loop.has("a")).toBe(false);
  loop.failed("b");
  loop.dispose();
  wait(60);
  expect(asked).toEqual(["a", "a"]);
});

test("ChipRetries keeps asking a chip that cannot be asked now, and a wake asks it at once", () => {
  jest.useFakeTimers();
  let now = false;
  const asked: string[] = [];
  const loop = retries((id) => {
    if (!now) return false;
    asked.push(id);
    return true;
  });
  loop.failed("a");
  // Two steps pass with its chat not shown: nothing asked, still armed.
  wait(80);
  expect(asked).toEqual([]);
  now = true;
  loop.wake();
  expect(asked).toEqual(["a"]);
  loop.dispose();
});
