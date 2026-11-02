// l10n-allow-file: synthetic file names and host errors for a behavioral regression.
// Leo, 2026-11-01: he pasted a 17 s mp4 into a chat on another machine and sent "here"; the agent
// answered "Nothing came through", the chip showed Retry, and "i had to retry to get it to load???".
// A send made while a file uploads waits for it and goes with it (composer/attachmentIntake.tsx),
// and a failed upload is tried again on its own before its chip shows Retry (composer/uploadRetry.ts).
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, useImperativeHandle, type Ref } from "react";
import { createRoot, type Root } from "react-dom/client";
import type { UploadResult } from "../src/agent-session/acpmux/cloudUploads";
import {
  useAttachmentIntake,
  useSendWhenAttached,
  type AttachmentIntakeOptions,
} from "../src/agent-session/acpmux/composer/attachmentIntake";
import {
  retryUploadLater,
  UPLOAD_AUTO_RETRIES,
  UPLOAD_RETRY_DELAY_MS,
} from "../src/agent-session/acpmux/composer/uploadRetry";

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
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
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

/// Waits until `check` holds, giving up after `within` ms.
async function until(check: () => boolean, within = 2_000) {
  const deadline = Date.now() + within;
  while (!check() && Date.now() < deadline) await act(turn);
  expect(check()).toBe(true);
}

function mount(upload: AttachmentIntakeOptions["upload"]) {
  const options: AttachmentIntakeOptions = { allowImages: true, scope: "chat", pasteTarget: () => undefined, upload };
  const handle: { current: Probe | null } = { current: null };
  root = createRoot(host);
  act(() => root!.render(<Harness options={options} handle={handle} />));
  return handle;
}

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

test("a failed upload is tried again on its own; its chip never shows Retry when that works", async () => {
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
  }, UPLOAD_RETRY_DELAY_MS * 3);
  expect(calls).toBe(2);
  expect(shownFailed).toBe(false);
  expect(handle.current!.pending).toEqual([]);
  // The send it held goes with the file.
  expect(handle.current!.loading).toBe(0);
});

test("a failed upload that keeps failing shows Retry, and still holds a send until Retry or x", async () => {
  // No input arrives in this page, so after its first try again the wait ends at the input wait;
  // a chip already past its tries shows Retry at once.
  let calls = 0;
  const handle = mount(async () => {
    calls += 1;
    return { error: "The upload timed out: the app did not answer." };
  });
  await act(() => void handle.current!.attach([mp4()], true));
  await until(() => handle.current!.pending[0]?.uploading === true);
  const id = handle.current!.pending[0]!.id;
  // Spend the tries: each Retry fails again.
  for (let at = 0; at < UPLOAD_AUTO_RETRIES + 1; at++) {
    const before = calls;
    await act(() => handle.current!.retry(id));
    await until(() => calls > before);
  }
  await until(() => Boolean(handle.current!.pending[0]?.failed));
  expect(handle.current!.hold(() => {})).toBe(true);
  act(() => handle.current!.cancel(id));
  await until(() => handle.current!.pending.length === 0);
  expect(handle.current!.loading).toBe(0);
});

test("an upload the host refused outright shows Retry at once, with no try again", async () => {
  let calls = 0;
  const handle = mount(async () => {
    calls += 1;
    return { error: "The disk is full.", final: true };
  });
  await act(() => void handle.current!.attach([mp4()], true));
  await until(() => Boolean(handle.current!.pending[0]?.failed));
  expect(calls).toBe(1);
  // Still the person's to Retry or remove: the send waits for it.
  expect(handle.current!.hold(() => {})).toBe(true);
});

test("an automatic retry stays in its original chat after a plain chat switch", async () => {
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
  const chip = handle.current!.pending[0]!.id;
  // An ordinary chat selection, with no explicit draft/attachment carry.
  act(() => root!.render(<Harness options={b} handle={handle} />));
  expect(handle.current!.pending).toEqual([]);
  await act(() => tick(UPLOAD_RETRY_DELAY_MS + 100));
  expect(bCalls).toBe(0);
  expect(handle.current!.attachments).toEqual([]);

  // Back in chat A, the pending upload is marked failed and can be manually retried using A's
  // upload handler. Nothing from it was put on B's machine or into B's prompt.
  act(() => root!.render(<Harness options={a} handle={handle} />));
  await until(() => handle.current!.pending[0]?.uploadFailed === true);
  await act(() => handle.current!.retry(chip));
  await until(() => handle.current!.attachments.some((attached) => attached.name === "Sunbringer Menu Animation.mp4"));
  expect(aCalls).toBe(2);
  expect(bCalls).toBe(0);
});

test("a file the composer refused never holds a send: Retry could never make it", async () => {
  const options: AttachmentIntakeOptions = { allowImages: false, scope: "chat", pasteTarget: () => undefined };
  const handle: { current: Probe | null } = { current: null };
  root = createRoot(host);
  act(() => root!.render(<Harness options={options} handle={handle} />));
  await act(() => void handle.current!.attach([new File(["png"], "shot.png", { type: "image/png" })]));
  await until(() => Boolean(handle.current!.pending[0]?.failed));
  expect(handle.current!.loading).toBe(0);
  expect(handle.current!.hold(() => {})).toBe(false);
});

/// A document stand-in whose events are the person's (`isTrusted`), which jsdom cannot dispatch.
function fakeDocument() {
  const listeners = new Map<string, Set<(event: Event) => void>>();
  return {
    doc: {
      addEventListener: (type: string, run: (event: Event) => void) => {
        if (!listeners.has(type)) listeners.set(type, new Set());
        listeners.get(type)!.add(run);
      },
      removeEventListener: (type: string, run: (event: Event) => void) => listeners.get(type)?.delete(run),
    } as unknown as Document,
    fire: (type: string, init: Record<string, unknown> = {}) => {
      for (const run of listeners.get(type) ?? []) run({ type, isTrusted: true, ...init } as unknown as Event);
    },
    count: () => [...listeners.values()].reduce((sum, set) => sum + set.size, 0),
  };
}

const tick = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

test("the first try again goes on its own; the last waits for the person's key or click, never Return", async () => {
  const { doc, fire, count } = fakeDocument();
  let again = 0;
  let gaveUp = 0;
  retryUploadLater(
    0,
    () => (again += 1),
    () => (gaveUp += 1),
    doc,
  );
  // fixed-wait: the 1 s before the first try again is the behavior under test.
  await new Promise((resolve) => setTimeout(resolve, UPLOAD_RETRY_DELAY_MS + 50));
  expect(again).toBe(1);
  retryUploadLater(
    UPLOAD_AUTO_RETRIES - 1,
    () => (again += 1),
    () => (gaveUp += 1),
    doc,
  );
  // Return is the send's own gesture: it never starts an upload.
  fire("keydown", { key: "Enter" });
  await turn();
  expect(again).toBe(1);
  fire("keydown", { key: "h" });
  await turn();
  expect(again).toBe(2);
  expect(count()).toBe(0);
  expect(gaveUp).toBe(0);
  // Its tries spent: Retry shows at once.
  retryUploadLater(
    UPLOAD_AUTO_RETRIES,
    () => (again += 1),
    () => (gaveUp += 1),
    doc,
  );
  expect(gaveUp).toBe(1);
  // A chip removed while its try waits stops listening.
  const stop = retryUploadLater(
    UPLOAD_AUTO_RETRIES - 1,
    () => (again += 1),
    () => (gaveUp += 1),
    doc,
  );
  stop();
  fire("pointerdown");
  await turn();
  expect(again).toBe(2);
  expect(count()).toBe(0);
});
