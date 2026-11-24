// A send held while a pasted image is still being read keeps the person's own Enter or click
// (Leo, 2026-11-06: "why is this still happening"; a reply quoting a message, with a pasted
// terminal screenshot, came back "Not sent: it needs your own key press or click.").
// The host keeps one grant per key press or click (AgentPaneUserGestures.swift): the pasted
// image's `chat.upload.begin` spends it, and so does the send's `transport.gesture`. The image's
// upload begins only after the host answered where the pasted files are (intakeFiles.ts), so an
// Enter pressed before that is the gesture the upload spent. The send, held until the image's chip
// was ready (useSendWhenAttached), asked for its ticket only then, and the host had none left.
// The hold now binds the send's gesture at the Enter itself, and the held send goes with it.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { useSendWhenAttached, useSendWhenOriginals } from "./attachmentIntakeModel";
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

/// The host's gesture record, as AgentPaneUserGestures keeps it: one grant per key press or click,
/// however old for a prompt (`consumeForSend`); an upload's begin spends it too (`consume`).
function host() {
  let grant = false;
  let issued = 0;
  const tickets = new Map<string, string>();
  return {
    /// A real key press or click in the pane (the paste's ⌘V, the Enter, a click on Send).
    press: () => {
      grant = true;
    },
    /// `chat.upload.begin` of the pasted image's original (AgentPaneModel.swift `.uploadStage`).
    uploadBegin: () => {
      const had = grant;
      grant = false;
      return had;
    },
    /// `transport.gesture` for one prompt: a ticket while a grant is left, else none.
    reserve: (promptId: string) => {
      if (!grant) return undefined;
      grant = false;
      const ticket = `ticket-${(issued += 1)}`;
      tickets.set(ticket, promptId);
      return ticket;
    },
    /// The relay's check of a `session/prompt` frame: its ticket for its own prompt, or a grant left.
    accepts: (promptId: string, ticket: string | undefined) => {
      if (ticket !== undefined) return tickets.get(ticket) === promptId;
      const had = grant;
      grant = false;
      return had;
    },
  };
}

type Gesture = { promptId: string; ticket: string | undefined };

/// The composer's two holds, as Composer.tsx wires them: each binds a held send's gesture through
/// `bind` (the pane's `transport.gesture` for a new prompt id).
async function mount(bind: () => Gesture) {
  root = createRoot(installDom());
  let attached!: ReturnType<typeof useSendWhenAttached<Gesture>>;
  let originals!: ReturnType<typeof useSendWhenOriginals<Gesture>>;
  function Probe({ reading, uploading }: { reading: number; uploading: number }) {
    attached = useSendWhenAttached<Gesture>(reading, "chat", reading, bind);
    originals = useSendWhenOriginals<Gesture>(uploading, "chat", bind);
    return null;
  }
  const render = (reading: number, uploading = 0) =>
    act(async () => root!.render(<Probe reading={reading} uploading={uploading} />));
  await render(0);
  return { render, attached: () => attached, originals: () => originals };
}

/// The send, as App.tsx's goes: with the gesture the hold kept, else it binds the person's
/// gesture now (`client.bindSendGesture`), and the relay checks the frame.
function sender(model: ReturnType<typeof host>) {
  const frames: { promptId: string; accepted: boolean }[] = [];
  const send = (kept?: Gesture) => {
    const gesture = kept ?? { promptId: `p-${frames.length + 1}`, ticket: undefined };
    const ticket = kept ? kept.ticket : model.reserve(gesture.promptId);
    frames.push({ promptId: gesture.promptId, accepted: model.accepts(gesture.promptId, ticket) });
  };
  return { frames, send };
}

test("Enter on a reply with a pasted image still being read sends it with that Enter", async () => {
  const model = host();
  const { frames, send } = sender(model);
  let bound = 0;
  const probe = await mount(() => {
    bound += 1;
    const promptId = `held-${bound}`;
    return { promptId, ticket: model.reserve(promptId) };
  });
  // ⌘V: the screenshot's chip draws, still being read.
  model.press();
  await probe.render(1);
  // Enter (or a click on Send): the prompt waits for the chip.
  model.press();
  expect(probe.attached()((gesture) => send(gesture))).toBe(true);
  // The host answered where the pasted files are: the image's original begins to upload, and its
  // begin takes the one grant the host has left.
  model.uploadBegin();
  // The chip is ready: the held prompt goes, with the Enter's own proof.
  await probe.render(0);
  expect(frames).toEqual([{ promptId: "held-1", accepted: true }]);
  expect(bound).toBe(1);
});

test("a held send that then waits for its originals goes once, with the gesture of its Enter", async () => {
  const model = host();
  const { frames, send } = sender(model);
  let bound = 0;
  const probe = await mount(() => {
    bound += 1;
    const promptId = `held-${bound}`;
    return { promptId, ticket: model.reserve(promptId) };
  });
  model.press();
  await probe.render(1, 1);
  model.press();
  // The chip is still read, then the prompt is too large until the original is saved: the second
  // hold keeps the gesture the first one bound, and binds none of its own.
  expect(
    probe.attached()((gesture) => {
      expect(probe.originals()(true, (again) => send(again), gesture)).toBe(true);
    }),
  ).toBe(true);
  model.uploadBegin();
  await probe.render(0, 1);
  expect(frames).toEqual([]);
  await probe.render(0, 0);
  expect(frames).toEqual([{ promptId: "held-1", accepted: true }]);
  expect(bound).toBe(1);
});

test("a send with nothing to wait for binds no gesture early, and one without a person's gesture is refused", async () => {
  const model = host();
  const { frames, send } = sender(model);
  let bound = 0;
  const probe = await mount(() => {
    bound += 1;
    return { promptId: `held-${bound}`, ticket: model.reserve(`held-${bound}`) };
  });
  // Nothing pending: the hold does nothing, and the send binds its own gesture as before.
  model.press();
  expect(probe.attached()((gesture) => send(gesture))).toBe(false);
  send();
  // A script's send while a chip is read: no key press or click, so the hold binds no ticket and
  // the relay still refuses the frame.
  await probe.render(1);
  expect(probe.attached()((gesture) => send(gesture))).toBe(true);
  await probe.render(0);
  expect(frames).toEqual([
    { promptId: "p-1", accepted: true },
    { promptId: "held-1", accepted: false },
  ]);
});
