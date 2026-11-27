// l10n-allow-file: test fixtures (made-up prompts).
// Held prompts across a host that went away (Leo, 2026-11-25: "ugh our queuing of batching user
// messages is awkward as shit. we need to improve them"; "wait that message got split up and
// queued"). The record: the host was gone 90 s, prompts typed meanwhile waited in the page's hold,
// the host came back and they went in order, then the first two went AGAIN, joined into one
// message with the first one's image, under fresh ids. The hold had given back a prompt the
// connection lost, with every prompt behind it, while the host's journal sent it again under its
// own id; the composer's joined copy was the second send.
//
// Here the host is gone, then back: each prompt must reach acpmux exactly once, with its images,
// in order, and none goes back into the composer.
import { afterEach, expect, test } from "bun:test";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { settleReact } from "../../../test/support/domTeardown";
import type { ComposerAttachment } from "./attachments";
import { clientWaiter, lostPrompt, resentAfterLoss, type LostPrompt, type ResendWaiter } from "./lostPrompt";
import { keptInChat } from "./pane/sendHost";
import { noteHandedBack, onHandedBackRecorded, promptRecorded, wasRecorded } from "./handedBack";
import { useTrustHeldPrompts, type TrustHeldPrompt } from "./trustHeld";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const KEYS = ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"];

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved)
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  saved.clear();
});

function mountDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main></main></body></html>", { url: "http://localhost/" });
  for (const key of KEYS) saved.set(key, scope[key]);
  const w = dom.window;
  Object.assign(scope, {
    window: w,
    document: w.document,
    navigator: w.navigator,
    Node: w.Node,
    HTMLElement: w.HTMLElement,
    Element: w.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return w.document.querySelector("main")!;
}

const image = (id: string): ComposerAttachment => ({ id, kind: "image", name: `${id}.png` }) as ComposerAttachment;

type Took = { promptId: string; text: string; images: string[]; from: "page" | "journal" };

/// acpmux behind a host that goes away: a send while it is gone is lost (the connection drops
/// before acpmux answers), and the host's journal sends it again, under its promptId, once it is
/// back. acpmux runs a promptId at most once and records each prompt it takes.
function fakeHost() {
  const took: Took[] = [];
  const journal: { entry: TrustHeldPrompt; resent: () => void }[] = [];
  let up = true;
  const take = (entry: TrustHeldPrompt, from: Took["from"]) => {
    if (took.some((one) => one.promptId === entry.id)) return;
    took.push({
      promptId: entry.id,
      text: entry.text,
      images: entry.attachments.filter((chip) => chip.kind === "image").map((chip) => chip.id),
      from,
    });
    promptRecorded(entry.id);
  };
  return {
    took,
    down: () => (up = false),
    /// The host is back: its journal sends what the connection lost, then the page's sends go.
    back: () => {
      up = true;
      for (const lost of journal.splice(0)) {
        take(lost.entry, "journal");
        lost.resent();
      }
    },
    send: (entry: TrustHeldPrompt): Promise<string | undefined> => {
      if (up) {
        take(entry, "page");
        return Promise.resolve("chat-1");
      }
      // Lost before acpmux answered: direct.ts tags it `lostPrompt`.
      const error = Object.assign(new Error("connection closed"), {
        code: "native.connection_closed",
        lostPrompt: { sessionId: "chat-1", promptId: entry.id } satisfies LostPrompt,
      });
      journal.push({ entry, resent: () => undefined });
      return new Promise<string | undefined>((_, reject) => setTimeout(() => reject(error), 0));
    },
    /// lostPrompt.ts `resentAfterLoss`, as App wires it: true once the lost prompt shows on the
    /// next connection (the journal's resend), here once the host is back.
    resent: async (error: unknown): Promise<string | undefined> => {
      const lost = lostPrompt(error);
      if (!lost) return undefined;
      const waiting = journal.find((one) => one.entry.id === lost.promptId);
      if (waiting) await new Promise<void>((resolve) => (waiting.resent = resolve));
      return took.some((one) => one.promptId === lost.promptId) ? lost.sessionId : undefined;
    },
  };
}

type Hold = ReturnType<typeof useTrustHeldPrompts>;

/// Yield to queued macrotasks (the fake host's lost-send rejects, the flush's next send): no wall
/// clock, so a loaded runner cannot outrun it.
async function macrotasks(turns = 8) {
  for (let turn = 0; turn < turns; turn++) await new Promise((resolve) => setTimeout(resolve, 0));
}

async function scenario(withResendWait: boolean) {
  const main = mountDom();
  const host = fakeHost();
  const givenBack: TrustHeldPrompt[][] = [];
  let hold: Hold | undefined;
  let setHolds: (holds: boolean) => void = () => undefined;
  function Pane() {
    const [holds, set] = useState(false);
    setHolds = set;
    hold = useTrustHeldPrompts({
      chat: "chat-1",
      cwd: "/repo",
      holds,
      send: host.send,
      reserve: () => Promise.resolve(undefined),
      putBack: (entries) => givenBack.push(entries),
      refusedForTrust: () => false,
      ...(withResendWait ? { resent: host.resent } : {}),
    });
    return null;
  }
  await act(async () => {
    root = createRoot(main);
    root.render(<Pane />);
  });
  // The host goes away; the folder holds what is typed meanwhile (trustGate), in order.
  host.down();
  await act(async () => {
    setHolds(true);
  });
  await act(async () => {
    hold!.hold("like the save as prompt is still here. i told you all to remove it.", [image("1ea4f73b")]);
    hold!.hold("", [image("07da9c7e")]);
    hold!.hold("and the branch symbol switch.", []);
    hold!.hold("move this back to the center", []);
  });
  // The hold lets go while the connection is still gone (90 s of outage, the reconnect racing):
  // the first send is lost before acpmux answers.
  await act(async () => {
    setHolds(false);
  });
  await act(async () => {
    await macrotasks();
  });
  // The host is back: its journal sends the lost one again under its own id.
  await act(async () => {
    host.back();
    await macrotasks();
  });
  await act(async () => {
    await macrotasks();
  });
  return { host, givenBack };
}

test("host gone, prompts held, host back: each prompt reaches acpmux exactly once, with its images", async () => {
  const { host, givenBack } = await scenario(true);
  expect(host.took.map((one) => [one.text, one.images])).toEqual([
    ["like the save as prompt is still here. i told you all to remove it.", ["1ea4f73b"]],
    ["", ["07da9c7e"]],
    ["and the branch symbol switch.", []],
    ["move this back to the center", []],
  ]);
  expect(new Set(host.took.map((one) => one.promptId)).size).toBe(4);
  // Nothing went back into the composer, so nothing is sent a second time under a fresh id.
  expect(givenBack).toEqual([]);
});

test("without the resend wait the hold gave the lost prompt and the rest back (the double-send)", async () => {
  const { host, givenBack } = await scenario(false);
  // The journal still sent the lost one...
  expect(host.took.map((one) => one.from)).toEqual(["journal"]);
  // ...and the composer got it back with the rest: its next Send carried the first one again.
  expect(givenBack.flat().map((entry) => entry.text)[0]).toBe(host.took[0]!.text);
  // The give-back side now refuses a copy acpmux recorded (App `giveBackTrustHeld`).
  expect(wasRecorded(host.took[0]!.promptId)).toBe(true);
});

test("a copy handed back before its record comes leaves the composer when it does", () => {
  const heard: string[] = [];
  const stop = onHandedBackRecorded((back) => heard.push(back.text));
  noteHandedBack("late-1", { text: "and the branch symbol switch.", attachments: [] });
  expect(wasRecorded("late-1")).toBe(false);
  promptRecorded("late-1");
  expect(heard).toEqual(["and the branch symbol switch."]);
  expect(wasRecorded("late-1")).toBe(true);
  stop();
});

/// The person moves to another chat while a lost held prompt waits for the host's resend. The pane's
/// wait says no at once (direct.ts `awaitResent`: another chat shows), while the host's outbox still
/// sends the prompt to its own chat. `keeps`: the host's store keeps the prompt for its chat
/// (direct.ts `keepsUnsentPrompt`), as the app host's does.
async function switchScenario(keeps: boolean) {
  const main = mountDom();
  const took: string[] = [];
  const stored = new Set<string>();
  const givenBack: TrustHeldPrompt[][] = [];
  const clients = clientWaiter<ResendWaiter>();
  // The connection the prompts went on: it dropped before acpmux answered the first.
  const from: ResendWaiter = {
    isClosed: true,
    awaitResent: async () => false,
    ...(keeps ? { keepsUnsentPrompt: (promptId: string) => stored.has(promptId) } : {}),
  };
  const lostOn = new WeakMap<object, ResendWaiter>();
  let up = false;
  let hold: Hold | undefined;
  let setHolds: (holds: boolean) => void = () => undefined;
  let setChat: (chat: string) => void = () => undefined;
  function Pane() {
    const [holds, set] = useState(true);
    const [chat, choose] = useState("chat-1");
    setHolds = set;
    setChat = choose;
    hold = useTrustHeldPrompts({
      chat,
      cwd: "/repo",
      holds,
      send: (entry) => {
        // On disk before it goes (direct.ts `keepUnsent`), until acpmux records it.
        stored.add(entry.id);
        if (up) {
          took.push(entry.text);
          stored.delete(entry.id);
          return Promise.resolve("chat-1");
        }
        const error = Object.assign(new Error("connection closed"), {
          code: "native.connection_closed",
          lostPrompt: { sessionId: "chat-1", promptId: entry.id } satisfies LostPrompt,
        });
        lostOn.set(error, from);
        return new Promise<string | undefined>((_, reject) => setTimeout(() => reject(error), 0));
      },
      reserve: () => Promise.resolve(undefined),
      putBack: (entries) => givenBack.push(entries),
      refusedForTrust: () => false,
      keptElsewhere: keptInChat,
      // As App wires it.
      resent: async (error) => {
        const lost = lostPrompt(error);
        if (!lost || !error || typeof error !== "object") return undefined;
        return (await resentAfterLoss(error, clients, lostOn.get(error))) ? lost.sessionId : undefined;
      },
    });
    return null;
  }
  await act(async () => {
    root = createRoot(main);
    root.render(<Pane />);
  });
  await act(async () => {
    hold!.hold("like the save as prompt is still here. i told you all to remove it.", [image("1ea4f73b")]);
    hold!.hold("and the branch symbol switch.", []);
  });
  // The hold lets go while the connection is gone: the first send is lost.
  await act(async () => {
    setHolds(false);
    await macrotasks();
  });
  const lostId = [...stored][0]!;
  // The person picks another chat; the next connection shows it, so its resend wait says no.
  await act(async () => {
    setChat("chat-2");
    clients.connected({ isClosed: false, selectedSession: "chat-2", awaitResent: async () => false });
    await macrotasks();
  });
  // The host's outbox sends the lost prompt to its chat all the same.
  took.push("like the save as prompt is still here. i told you all to remove it.");
  up = true;
  await act(async () => {
    await macrotasks();
  });
  return { took, givenBack, stored, lostId };
}

test("a chat switch while a lost held prompt waits: the host's store keeps it in its chat, never its draft", async () => {
  const { took, givenBack, stored, lostId } = await switchScenario(true);
  const back = givenBack.flat().map((entry) => entry.text);
  // Only the one behind it, which never left, goes back (into its chat's draft).
  expect(back).toEqual(["and the branch symbol switch."]);
  // The outbox's send is the only one: no copy waits in the draft for the next Send.
  expect(took.filter((text) => text.startsWith("like the save as"))).toHaveLength(1);
  // The store still has it: the chat, shown again, drops it as acpmux has it, or draws it as not
  // sent with Retry if the outbox never got it there (direct.ts `restoreUnsentPrompts`).
  expect(stored.has(lostId)).toBe(true);
});

test("without the host's store the switch still gives the lost prompt back (nothing else keeps it)", async () => {
  const { givenBack } = await switchScenario(false);
  // The old path, and the double-send the store now prevents: the delivered prompt went back too.
  expect(givenBack.flat().map((entry) => entry.text)).toEqual([
    "like the save as prompt is still here. i told you all to remove it.",
    "and the branch symbol switch.",
  ]);
});
