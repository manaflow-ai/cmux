// l10n-allow-file: synthetic file names and host errors for a behavioral regression.
// Leo, 2026-11-17, after dropping a video into a chat: "STOP FUCKING BLOCKING ON SOME RANDOM BULLSHIT
// WHAT THE FUCK COULD TAKE SO LONG ABOUT LINKING A FUCKING VIDEO", "I DRAG AND DROP IT IN WTF ARE YOU
// FUCKING ENCODING", "I CAN'T EVEN FUCKING SEND A MESSAGE WHILE THE FUCKING THING LOADS ... JUST MAKE
// IT LOOK LIKE IT'S SENT OR JUST SEND IT". A dropped file is its tile in the drop's own frame, and a
// Send made while it still attaches goes at once, with no read of the file before it: the prompt
// takes the file as a stand-in that settles once the file is its chip (composer/sendBehind.ts), and
// the chat shows the prompt as sent while the transfer runs behind it (direct.ts `send`).
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, useImperativeHandle, type Ref } from "react";
import { createRoot, type Root } from "react-dom/client";
import type { ComposerAttachment, LinkItem, PromptBlock } from "../src/agent-session/acpmux/attachments";
import type { UploadResult } from "../src/agent-session/acpmux/cloudUploads";
import {
  useAttachmentIntake,
  useSendWhenAttached,
  type AttachmentIntakeOptions,
} from "../src/agent-session/acpmux/composer/attachmentIntakeModel";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "FileReader",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;
/// Every FileReader read in the page: a base64 encode of the file before Send is the bug.
const encoded: number[] = [];

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  const { window } = dom;
  class CountingReader {
    onload: (() => void) | null = null;
    onerror: (() => void) | null = null;
    result: string | null = null;
    error: Error | null = null;
    readAsDataURL(blob: Blob) {
      encoded.push(blob.size);
    }
  }
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
    Element: window.Element,
    FileReader: CountingReader,
  });
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  encoded.length = 0;
});

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

const GIB = 1024 * 1024 * 1024;
const HEADER_BYTES = 64 * 1024;

/// A 3 GB screen recording as WebKit hands a drop: its name, type and size, its bytes read only on
/// demand. `whole` counts reads of the whole file; `sliced` the size of every partial read.
function hugeVideo() {
  const reads = { whole: 0, sliced: [] as number[] };
  const size = 3 * GIB;
  const file = {
    name: "Screen Recording 2026-11-17.mov",
    type: "video/quicktime",
    size,
    lastModified: 0,
    webkitRelativePath: "",
    slice(start = 0, end = size) {
      const length = Math.max(0, Math.min(end, size) - start);
      reads.sliced.push(length);
      return new Blob([new Uint8Array(Math.min(length, 16))]);
    },
    arrayBuffer() {
      reads.whole += 1;
      return Promise.reject(new Error("read the whole 3 GB file"));
    },
    bytes() {
      reads.whole += 1;
      return Promise.reject(new Error("read the whole 3 GB file"));
    },
    text() {
      reads.whole += 1;
      return Promise.reject(new Error("read the whole 3 GB file"));
    },
    stream() {
      reads.whole += 1;
      throw new Error("read the whole 3 GB file");
    },
  } as unknown as File;
  return { file, reads };
}

type Probe = ReturnType<typeof useAttachmentIntake> & { hold: ReturnType<typeof useSendWhenAttached> };
function Harness({ options, handle }: { options: AttachmentIntakeOptions; handle: Ref<Probe> }) {
  const intake = useAttachmentIntake(options);
  // As Composer.tsx holds its send.
  const hold = useSendWhenAttached(intake.loading, options.scope, intake.unsettled);
  useImperativeHandle(handle, () => ({ ...intake, hold }));
  return null;
}

const turn = () => new Promise((resolve) => setTimeout(resolve, 0));

async function until(check: () => boolean, within = 2_000) {
  const deadline = Date.now() + within;
  while (!check() && Date.now() < deadline) await act(turn);
  expect(check()).toBe(true);
}

function mount(options: Partial<AttachmentIntakeOptions>) {
  const full: AttachmentIntakeOptions = { allowImages: true, scope: "chat", pasteTarget: () => undefined, ...options };
  const handle: { current: Probe | null } = { current: null };
  root = createRoot(host);
  act(() => root!.render(<Harness options={full} handle={handle} />));
  return handle;
}

/// The person's Send, as Composer.tsx makes it: the files still attaching go with the prompt as
/// stand-ins (`goAhead`), and only what cannot is held for.
function press(handle: { current: Probe | null }) {
  const sent: ComposerAttachment[][] = [];
  const probe = handle.current!;
  const standIns = (probe as { goAhead?: () => ComposerAttachment[] | undefined }).goAhead?.();
  if (standIns) {
    sent.push([...probe.attachments, ...standIns]);
    return { sent, held: false };
  }
  const held = probe.hold(() => sent.push(handle.current!.attachments));
  return { sent, held };
}

test("a dropped 3 GB video is its tile in the drop's frame, and Send goes at once with no read of the file", async () => {
  const { file, reads } = hugeVideo();
  let finish: (result: UploadResult) => void = () => {};
  let uploads = 0;
  // A chat on another machine: the file's bytes truly must go there.
  const handle = mount({
    upload: () => {
      uploads += 1;
      return new Promise<UploadResult>((resolve) => (finish = resolve));
    },
  });
  // The drop: its tile is in the same frame.
  act(() => void handle.current!.attach([file], true, "drop"));
  expect(handle.current!.pending.map((chip) => chip.name)).toEqual([file.name]);
  // Send, at once: it goes, never held for the transfer.
  const { sent, held } = press(handle);
  expect(held).toBe(false);
  expect(sent).toHaveLength(1);
  expect(sent[0]!.map((chip) => [chip.name, chip.size])).toEqual([[file.name, file.size]]);
  // Nothing read the file or encoded it before the Send: at most its header.
  expect(reads.whole).toBe(0);
  expect(Math.max(0, ...reads.sliced)).toBeLessThanOrEqual(HEADER_BYTES);
  expect(encoded).toEqual([]);
  // The tile went with the prompt: the composer holds nothing for it.
  await act(turn);
  expect(handle.current!.pending).toEqual([]);
  expect(handle.current!.loading).toBe(0);
  expect(handle.current!.hold(() => {})).toBe(false);
  // The transfer goes on behind the sent prompt, and its stand-in settles to the saved file's link.
  await until(() => uploads === 1);
  const { settleBehindSend } = await import("../src/agent-session/acpmux/composer/sendBehind");
  const settled = settleBehindSend(sent[0]![0]!);
  await act(async () => finish({ paths: [`/remote/uploads/${file.name}`] }));
  const result = await settled;
  expect("chip" in result && result.chip.path).toBe(`/remote/uploads/${file.name}`);
  expect("chip" in result && result.chip.id).toBe(sent[0]![0]!.id);
  // It never came back to the strip.
  expect(handle.current!.attachments).toEqual([]);
});

test("a video dropped in a chat on this Mac goes as its path, with Send never held for it", async () => {
  const { file, reads } = hugeVideo();
  let answer: (items: LinkItem[]) => void = () => {};
  let uploads = 0;
  const handle = mount({
    localPaths: () => new Promise<LinkItem[]>((resolve) => (answer = resolve)),
    upload: async () => {
      uploads += 1;
      return undefined;
    },
  });
  act(() => void handle.current!.attach([file], true, "drop"));
  expect(handle.current!.pending).toHaveLength(1);
  const { sent, held } = press(handle);
  expect(held).toBe(false);
  expect(sent).toHaveLength(1);
  const { settleBehindSend } = await import("../src/agent-session/acpmux/composer/sendBehind");
  const settled = settleBehindSend(sent[0]![0]!);
  await act(async () => answer([{ path: `/Users/me/Desktop/${file.name}`, folder: false }]));
  const result = await settled;
  expect("chip" in result && result.chip.path).toBe(`/Users/me/Desktop/${file.name}`);
  // Its path, never a copy: no upload, no read, no encode.
  expect(uploads).toBe(0);
  expect(reads.whole).toBe(0);
  expect(encoded).toEqual([]);
});

test("a prompt sent ahead of its file shows as sent at once and reaches the agent with the file's link", async () => {
  const { sendBehind } = await import("../src/agent-session/acpmux/composer/sendBehind");
  const { AcpmuxDirectClient } = await import("../src/agent-session/acpmux/direct");
  const { MockAcpmuxSocket, mockHost } = await import("../src/agent-session/acpmux/mock");
  const prompts: PromptBlock[][] = [];
  class Relay extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const self = this as unknown as { answer: (method: string, params: Record<string, any>) => Promise<unknown> };
      const original = self.answer.bind(this);
      self.answer = (method, params) => {
        if (method === "session/prompt") prompts.push(params.prompt as PromptBlock[]);
        return original(method, params);
      };
    }
  }
  type Row = { kind: string; text?: string; pending?: boolean; failed?: boolean; error?: string };
  let rows: Row[] = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => (rows = snapshot.rows as Row[]),
    undefined,
    () => new Relay() as unknown as WebSocket,
  );
  try {
    // The chat open now: its first prompt started it.
    await client.send("hello").catch(() => undefined);
    const before = prompts.length;
    let settle!: (value: { chip: ComposerAttachment }) => void;
    sendBehind("clip", new Promise((resolve) => (settle = resolve)));
    const standIn: ComposerAttachment = {
      id: "clip",
      kind: "link",
      name: "clip.mov",
      mimeType: "video/quicktime",
      size: 3 * GIB,
    };
    const going = client.send("what happens at 0:12?", [standIn]);
    await turn();
    // Shown as sent at once, while the file still goes.
    expect(
      rows.some((row) => row.kind === "user" && row.text?.startsWith("what happens at 0:12?") && row.pending),
    ).toBe(true);
    expect(prompts.length).toBe(before);
    settle({
      chip: {
        id: "clip",
        kind: "link",
        name: "clip.mov",
        mimeType: "video/quicktime",
        size: 3 * GIB,
        path: "/remote/clip.mov",
        saved: true,
      },
    });
    await going.catch(() => undefined);
    const blocks = prompts.at(-1)!;
    expect(prompts.length).toBe(before + 1);
    expect(blocks.some((block) => block.type === "resource_link" && block.uri.endsWith("/remote/clip.mov"))).toBe(true);
  } finally {
    client.close?.();
  }
});

test("a prompt whose file failed to go fails its row with the host's words, never sent without it", async () => {
  const { sendBehind } = await import("../src/agent-session/acpmux/composer/sendBehind");
  const { AcpmuxDirectClient } = await import("../src/agent-session/acpmux/direct");
  const { MockAcpmuxSocket, mockHost } = await import("../src/agent-session/acpmux/mock");
  const prompts: PromptBlock[][] = [];
  class Relay extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const self = this as unknown as { answer: (method: string, params: Record<string, any>) => Promise<unknown> };
      const original = self.answer.bind(this);
      self.answer = (method, params) => {
        if (method === "session/prompt") prompts.push(params.prompt as PromptBlock[]);
        return original(method, params);
      };
    }
  }
  type Row = { kind: string; text?: string; pending?: boolean; failed?: boolean; error?: string };
  let rows: Row[] = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => (rows = snapshot.rows as Row[]),
    undefined,
    () => new Relay() as unknown as WebSocket,
  );
  try {
    // The host's store of unsent prompts: a failed prompt is kept there, as any failed send is.
    const kept: { sessionId: string; promptId: string; error?: string }[] = [];
    client.setUnsentPromptStore({
      read: async () => [],
      put: async (sessionId, record) => void kept.push({ sessionId, promptId: record.promptId, error: record.error }),
      remove: async () => undefined,
    });
    // The chat open now: its first prompt started it.
    await client.send("hello").catch(() => undefined);
    const before = prompts.length;
    sendBehind("clip-2", Promise.resolve({ error: "The disk is full." }));
    const standIn: ComposerAttachment = {
      id: "clip-2",
      kind: "link",
      name: "clip.mov",
      mimeType: "video/quicktime",
      size: 1,
    };
    await client.send("look", [standIn]).catch(() => undefined);
    expect(prompts.length).toBe(before);
    const row = rows.find((each) => each.kind === "user" && each.text?.startsWith("look\n"));
    expect(row?.failed).toBe(true);
    expect(row?.error).toContain("The disk is full.");
    // Its delivery record gives the row Edit, Remove, Details and Retry; a reload keeps it.
    expect((row as { delivery?: { state?: string } } | undefined)?.delivery?.state).toBe("failed");
    expect(kept.some((record) => record.error?.includes("The disk is full."))).toBe(true);
  } finally {
    client.close?.();
  }
});
