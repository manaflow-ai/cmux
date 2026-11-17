// A prompt sent while its files are still being read or uploaded leaves the composer at once and
// shows as sent; its files follow it (Leo, 2026-11-17: "I CAN'T EVEN SEND A MESSAGE WHILE THE
// THING LOADS ... IT SHOULD JUST BE SENT THERE FAST ... JUST MAKE IT LOOK LIKE IT'S SENT OR JUST
// SEND IT"). Before, the composer held the prompt (useSendWhenAttached) until a dropped screen
// recording had streamed whole to the chat's machine.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { ComposerAttachment } from "../attachments";
import type { UploadResult } from "../cloudUploads";
import { emptySnapshot } from "../snapshotCache";
import { StartingSends, withStartingPrompt, type StartingSend } from "../startingSends";
import { acpmuxSendsReady, untilAcpmuxTakesSends } from "../sendWhenReady";
import { useAttachmentIntake } from "./attachmentIntakeModel";
import { settleReact } from "../../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "IS_REACT_ACT_ENVIRONMENT"]) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
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

const MB = 1 << 20;

/// A 500 MB screen recording as the page gets it from a drop: its size is declared, and nothing on
/// the send's path reads its bytes (a read of them would throw here).
function recording(size = 500 * MB): File {
  const file = new File([], "Screen Recording.mov", { type: "video/quicktime" });
  Object.defineProperty(file, "size", { value: size });
  for (const read of ["arrayBuffer", "text", "stream", "bytes"] as const)
    Object.defineProperty(file, read, {
      value: () => {
        throw new Error(`the send read the file (${read})`);
      },
    });
  return file;
}

/// The composer's intake for a chat on another machine: each file streams there (`upload`), and
/// the upload ends only when the test says.
async function mountIntake() {
  root = createRoot(installDom());
  let finish!: (result: UploadResult) => void;
  const uploads: File[][] = [];
  const upload = (files: File[]) => {
    uploads.push(files);
    return new Promise<UploadResult>((resolve) => (finish = resolve));
  };
  let intake!: ReturnType<typeof useAttachmentIntake>;
  function Probe() {
    intake = useAttachmentIntake({ allowImages: true, pasteTarget: () => undefined, upload, scope: "chat" });
    return null;
  }
  await act(async () => root!.render(<Probe />));
  return { intake: () => intake, uploads, finish: (result: UploadResult) => finish(result) };
}

const settle = async () => {
  for (let i = 0; i < 20; i++) await act(async () => await Promise.resolve());
};

test("a 500 MB file still uploading: the send leaves the composer within 50 ms and its file follows it", async () => {
  const h = await mountIntake();
  await act(async () => void h.intake().attach([recording()], true, "drop"));
  await settle();
  // The recording streams to the chat's machine: before, every send waited here for all 500 MB.
  expect(h.intake().loading).toBe(1);
  expect(h.uploads.length).toBe(1);

  const pressed = performance.now();
  let ready!: Promise<ComposerAttachment[]>;
  await act(async () => {
    const handed = h.intake().sendWith()!;
    expect(handed.standIns.map((chip) => chip.name)).toEqual(["Screen Recording.mov"]);
    ready = handed.take();
  });
  const sendMs = performance.now() - pressed;
  expect(sendMs).toBeLessThan(50);
  // The composer holds nothing for it now: its tile went with the prompt, and the next send is free.
  expect(h.intake().pending).toEqual([]);
  expect(h.intake().loading).toBe(0);

  let made: ComposerAttachment[] | undefined;
  void ready.then((chips) => (made = chips));
  await settle();
  expect(made).toBeUndefined();
  // The upload ends: the prompt gets the chip, a link to the copy; the composer gets nothing.
  await act(async () => h.finish({ paths: ["/home/agent/.acpmux/uploads/chat/1/Screen Recording.mov"] }));
  await settle();
  expect(made?.map((chip) => chip.path)).toEqual(["/home/agent/.acpmux/uploads/chat/1/Screen Recording.mov"]);
  expect(h.intake().attachments).toEqual([]);
});

test("a send the chat could not take gives its files back to the composer, still uploading", async () => {
  const h = await mountIntake();
  await act(async () => void h.intake().attach([recording()], true, "drop"));
  await settle();
  await act(async () => {
    const handed = h.intake().sendWith()!;
    void handed.take();
    handed.giveBack();
  });
  expect(h.intake().pending.map((chip) => chip.name)).toEqual(["Screen Recording.mov"]);
  expect(h.intake().loading).toBe(1);
  await act(async () => h.finish({ paths: ["/up/Screen Recording.mov"] }));
  await settle();
  expect(h.intake().attachments.map((chip) => chip.path)).toEqual(["/up/Screen Recording.mov"]);
});

test("a file that fails to upload after its send fails that prompt with why, never the composer", async () => {
  const h = await mountIntake();
  await act(async () => void h.intake().attach([recording()], true, "drop"));
  await settle();
  let ready!: Promise<ComposerAttachment[]>;
  await act(async () => {
    ready = h.intake().sendWith()!.take();
  });
  const failed = ready.then(
    () => "made",
    (error: Error) => error.message,
  );
  // Refused outright (final): no tries again on its own.
  await act(async () => h.finish({ error: "disk full", final: true }));
  await settle();
  expect(await failed).toContain("disk full");
  expect(h.intake().pending).toEqual([]);
});

function rows(sends: StartingSends, snapshotRows: { id: string; kind: string }[] = []) {
  const snapshot = { ...emptySnapshot(), rows: snapshotRows } as ReturnType<typeof emptySnapshot>;
  return withStartingPrompt(snapshot, sends.rows as StartingSend[]).rows.map((row) => `${row.kind}:${row.text}`);
}

test("a prompt waiting for its files is a sent row at once, and a prompt sent after it goes after it", async () => {
  const shown: string[][] = [];
  const sends = new StartingSends(
    (now) => shown.push(now.map((row) => row.text)),
    () => undefined,
    () => ({ chat: "chat", visit: 1 }),
  );
  const sent: string[] = [];
  const go = async (text: string, attachments: ComposerAttachment[]) => {
    sent.push(`${text}[${attachments.map((chip) => chip.path ?? chip.name).join(",")}]`);
  };
  let fileMade!: (chips: ComposerAttachment[]) => void;
  const ready = new Promise<ComposerAttachment[]>((resolve) => (fileMade = resolve));
  const standIn: ComposerAttachment = { id: "rec", kind: "link", name: "rec.mov", mimeType: "", size: 0 };
  const pressed = performance.now();
  sends.add("A, with two videos", [standIn], go, undefined, "prompt-a", { ready, asSent: true });
  expect(performance.now() - pressed).toBeLessThan(50);
  sends.add("B", [], go, undefined, "prompt-b", { asSent: true });
  sends.add("C", [], go, undefined, "prompt-c", { asSent: true });
  // A, B and C are the transcript's rows now, in the order they were sent.
  expect(rows(sends)).toEqual(["user:A, with two videos", "user:B", "user:C"]);
  await settle();
  // B and C never go before A, which waits for its files.
  expect(sent).toEqual([]);
  fileMade([{ ...standIn, path: "/Users/leo/Desktop/rec.mov", size: 500 * MB }]);
  await settle();
  expect(sent).toEqual(["A, with two videos[/Users/leo/Desktop/rec.mov]", "B[]", "C[]"]);
  expect(sends.busy).toBe(false);
});

test("a prompt whose file failed comes back to the composer with every prompt behind it, in order", async () => {
  const given: string[] = [];
  const sends = new StartingSends(
    () => undefined,
    (text) => given.push(text),
    () => ({ chat: "chat", visit: 1 }),
  );
  const sent: string[] = [];
  const go = async (text: string) => void sent.push(text);
  sends.add("A", [], go, undefined, "a", { ready: Promise.reject(new Error("upload failed")), asSent: true });
  sends.add("B", [], go, undefined, "b", { asSent: true });
  await settle();
  expect(sent).toEqual([]);
  // Each goes back before what the composer holds, so they read A then B.
  expect(given).toEqual(["B", "A"]);
});

test("a send made while the chat still connects to acpmux is shown at once and goes once it connects", async () => {
  installDom();
  const page = window as unknown as { cmuxAcpmuxActions?: Record<string, unknown> };
  delete page.cmuxAcpmuxActions;
  const sends = new StartingSends(
    () => undefined,
    () => undefined,
    () => ({ chat: "chat", visit: 1 }),
  );
  const sent: string[] = [];
  const go = async (text: string) => {
    await untilAcpmuxTakesSends(page);
    sent.push(text);
  };
  const pressed = performance.now();
  sends.add("sent while loading", [], go, undefined, "loading-1", { asSent: true });
  sends.add("and another", [], go, undefined, "loading-2", { asSent: true });
  expect(performance.now() - pressed).toBeLessThan(50);
  expect(rows(sends)).toEqual(["user:sent while loading", "user:and another"]);
  // Once the client draws a prompt's own row (the same id), the pane's stand-in for it goes.
  expect(rows(sends, [{ id: "local-loading-1", kind: "user" }])).toEqual(["user:undefined", "user:and another"]);
  await settle();
  expect(sent).toEqual([]);
  page.cmuxAcpmuxActions = { "chat.send": () => Promise.resolve() };
  acpmuxSendsReady();
  await settle();
  expect(sent).toEqual(["sent while loading", "and another"]);
});
