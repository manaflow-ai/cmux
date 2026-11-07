// Review round 6 of cmux#37736, New Message and its sheets: a first send the owner refused keeps
// New Message, one with no answer comes to the page Not Delivered with Retry (F2); the Invite sheet
// lists pending invites (G2) and validates in its own status line (G4); Requests (G5) and Group Info
// (G1) follow the host while they show; the To: list's Chief look (G6); an agent member's sparkle
// (G7); no compose button over New Message (M); closing New Message goes back (N); the composer's
// spell checking follows Settings (O).
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { pretendToBeVisual: true });
  Object.assign(dom.window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  for (const key of [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "Element",
    "Node",
    "CSS",
    "MouseEvent",
    "KeyboardEvent",
    "getComputedStyle",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "ResizeObserver",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    CSS: { escape: (value: string) => value },
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    ResizeObserver: (dom.window as unknown as { ResizeObserver: unknown }).ResizeObserver,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(() => {
  if (root) act(() => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const { useSyncExternalStore } = await import("react");
const { NewMessage } = await import("../src/pages/home-messages/sheets/NewMessage");
const { firstSendOutcome } = await import("../src/pages/home-messages/sheets/actions");
const { EMPTY_DRAFT, contactLook } = await import("../src/pages/home-messages/sheets/recipients");
const { parseContactsAnswer, isGone, MessagesDataOps } = await import("../src/pages/home-messages/sheets/wire");
const { InviteSheet } = await import("../src/pages/home-messages/sheets/InviteSheets");
const { MemberAvatar } = await import("../src/pages/home-messages/sheets/GroupInfoSheet");
const { MessagesNav, newMessageHasKeyboard } = await import("../src/pages/home-messages/nav");
const { closeNewMessage } = await import("../src/pages/home-messages/pageCommands");
const { parseAppearance } = await import("../src/pages/home-messages/detail/detailHost");
const { MessageComposer } = await import("../src/pages/home-messages/transcript/MessageComposer");
const { createTranscriptStrings } = await import("../src/pages/home-messages/transcript/strings");
const { MessagesDetail } = await import("../src/pages/home-messages/detail/MessagesDetail");
const { noMessagesHost } = await import("../src/pages/home-messages/host");
const { HomeChannelsStore } = await import("../src/pages/home-channels/store");
const { HomeOps } = await import("../src/pages/home-channels/types");
const { createStrings } = await import("../src/pages/shared/i18n");
const sheetsTable = (await import("../src/pages/home-messages/sheets/generated/strings.json")).default;
type ComposeActions = import("../src/pages/home-messages/sheets/actions").ComposeActions;
type ComposeOutcome = import("../src/pages/home-messages/sheets/model").ComposeOutcome;
type PendingSend = import("../src/pages/home-channels/store").PendingSend;
type HomeConversation = import("../src/pages/home-channels/types").HomeConversation;

const sheetStrings = createStrings(sheetsTable, ["en"]);
const transcriptStrings = createTranscriptStrings(["en"]);
const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
const ada = { id: "ada", name: "Ada", source: "team" as const };
const withAda = { ...EMPTY_DRAFT, tokens: [{ text: "Ada", recipient: { kind: "contact" as const, contact: ada } }] };

function row(key: string, conversation = "dm"): PendingSend {
  return { key, conversation, text: "hello", createdAt: 1, failed: true };
}

function composeActions(start: () => Promise<ComposeOutcome>): ComposeActions {
  return {
    createChief: async () => ({ kind: "refused", reason: "" }),
    invite: async () => ({ kind: "refused", reason: "" }),
    seatImpact: async () => ({ kind: "unknown" }),
    inviteToTeam: async () => ({ kind: "refused", reason: "" }),
    start,
    newChief: () => {},
    openInvite: () => {},
    openTeamInvite: () => {},
  };
}

/** New Message over `start`; resolves the composer's `send`, and what `onSent` heard. */
async function renderNewMessage(start: () => Promise<ComposeOutcome>) {
  const container = installDom();
  const sent: { conversation: string; pending?: readonly PendingSend[] }[] = [];
  let send: ((text: string) => Promise<boolean>) | undefined;
  await act(async () => {
    root = createRoot(container);
    root.render(
      <NewMessage
        strings={sheetStrings}
        draft={withAda}
        onDraft={() => {}}
        contacts={[ada]}
        rows={[]}
        actions={composeActions(start)}
        onSent={(conversation, pending) => sent.push({ conversation, ...(pending ? { pending } : {}) })}
        onEscape={() => {}}
        onFocusMessage={() => {}}
        renderConversation={() => null}
        renderComposer={(go) => {
          send = go;
          return null;
        }}
      />,
    );
  });
  return { container, sent, send: send! };
}

test("F2: a refused first send keeps New Message and says why under To:", async () => {
  const { container, sent, send } = await renderNewMessage(async () => ({ kind: "refused", reason: "Too long" }));
  let went = true;
  await act(async () => {
    went = await send("hello");
  });
  expect(went).toBe(false);
  expect(sent).toEqual([]);
  expect(container.querySelector('[data-testid="cmux.home.newMessage.notice"]')?.textContent).toContain("Too long");
});

test("F2: a first send with no answer opens the conversation with the send, not sent, under its key", async () => {
  const { sent, send } = await renderNewMessage(async () =>
    firstSendOutcome({ kind: "opened", conversation: "dm", pending: [row("k1"), { key: 1 } as never] }),
  );
  await act(async () => {
    await send("hello");
  });
  expect(sent).toEqual([{ conversation: "dm", pending: [row("k1")] }]);
  // A malformed or foreign row never shows; an opened outcome without one stays as it was.
  expect(firstSendOutcome({ kind: "opened", conversation: "dm", pending: [row("k2", "other")] })).toEqual({
    kind: "opened",
    conversation: "dm",
  });
  // The page's store shows it as its own: not sent, with Retry under the same key.
  const store = new HomeChannelsStore(null);
  store.adoptPending([{ ...row("k1"), failed: false }]);
  expect(store.getSnapshot().pending.map((entry) => [entry.key, entry.failed])).toEqual([["k1", true]]);
});

test("G2: contacts' pending invites reach the Invite sheet", async () => {
  const read = parseContactsAnswer({ contacts: [], inviteTeam: null, pendingInvites: ["a@b.co", 3, ""] });
  expect(read.pendingInvites).toEqual(["a@b.co"]);
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(
      <InviteSheet
        strings={sheetStrings}
        actions={composeActions(async () => ({ kind: "refused", reason: "" }))}
        pending={read.pendingInvites}
        onFinish={() => {}}
      />,
    );
  });
  expect(document.querySelector('[data-testid="cmux.home.invite.pending"]')?.textContent).toBe("a@b.co");
  // G4: the form validates in its own status line; the browser's bubble would stop the submit first.
  expect(document.querySelector<HTMLFormElement>("form")?.noValidate).toBe(true);
});

test("G6: a Chief's To: look comes from the host's contacts", () => {
  const read = parseContactsAnswer({
    contacts: [
      { id: "chief", name: "Chief", source: "agent", look: { tag: "Main · Cloud", activity: "Active now" } },
      { id: "ada", name: "Ada", source: "team", look: { tag: 3 } },
    ],
  });
  expect(contactLook({ kind: "contact", contact: read.contacts[0]! })).toEqual({
    tag: "Main · Cloud",
    activity: "Active now",
  });
  expect(contactLook({ kind: "contact", contact: read.contacts[1]! })).toEqual({});
});

test("G7: an agent member shows a sparkle, a person their initials", async () => {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(
      <>
        <MemberAvatar member={{ id: "ada", name: "Ada", isAgent: false }} />
        <MemberAvatar member={{ id: "chief", name: "Chief", isAgent: true }} />
      </>,
    );
  });
  expect(container.querySelectorAll('[data-testid="cmux.home.groupInfo.agentAvatar"]').length).toBe(1);
  expect(container.textContent).toBe("AD");
});

test("N: closing New Message goes back to what showed, with the keyboard only if New Message had it", () => {
  const nav = new MessagesNav();
  nav.lastShown = "dm";
  const back: string[] = [];
  nav.openCompose();
  let focus = nav.getSnapshot().focusEpoch;
  expect(nav.endCompose(false, (id) => back.push(id))).toBe(true);
  expect(back).toEqual(["dm"]);
  expect(nav.getSnapshot().focusEpoch).toBe(focus);
  nav.openCompose();
  focus = nav.getSnapshot().focusEpoch;
  nav.endCompose(true, (id) => back.push(id));
  expect(nav.getSnapshot().focusEpoch).toBe(focus + 1);
  expect(nav.endCompose(true, (id) => back.push(id))).toBe(false);

  // The page's close selects the conversation New Message's people had moved off.
  const selects: string[] = [];
  const store = {
    getSnapshot: () => ({ selected: "other", conversations: new Map([["dm", {}]]) }),
    select: async (id: string) => void selects.push(id),
  };
  nav.openCompose();
  expect(closeNewMessage({ nav, store: store as never })).toBe(true);
  expect(selects).toEqual(["dm"]);

  // Who holds the keyboard: an input inside New Message.
  installDom();
  document.body.innerHTML = '<section class="hm-new-message"><input id="to"></section><input id="out">';
  document.getElementById("to")!.focus();
  expect(newMessageHasKeyboard(document)).toBe(true);
  document.getElementById("out")!.focus();
  expect(newMessageHasKeyboard(document)).toBe(false);
});

test("O: the composer's spell checking follows the host's setting", async () => {
  expect(parseAppearance({}).spellChecking).toBe(false);
  expect(parseAppearance({ spellChecking: true }).spellChecking).toBe(true);
  const container = installDom();
  const render = (spellChecking: boolean) =>
    act(async () => {
      root ??= createRoot(container);
      root.render(
        <MessageComposer
          strings={transcriptStrings}
          sendEnabled
          onSend={async () => true}
          spellChecking={spellChecking}
        />,
      );
    });
  await render(true);
  await settle();
  expect(container.querySelector("[spellcheck]")?.getAttribute("spellcheck")).toBe("true");
  await render(false);
  await settle();
  expect(container.querySelector("[spellcheck]")?.getAttribute("spellcheck")).toBe("false");
});

// ---------- The detail over a host that follows (G1, G5) ----------

function conversation(id: string, patch: Partial<HomeConversation> = {}): HomeConversation {
  return {
    id,
    owner: "local",
    title: id,
    kind: "group",
    participants: [],
    lastSeq: 0,
    rev: 1,
    updatedAt: 1,
    unread: 0,
    mentions: 0,
    muted: false,
    pinned: false,
    ...patch,
  };
}

function followingHost() {
  const streams = new Map<string, { onEvent: (data: unknown) => void; filter?: Record<string, unknown> }>();
  const stopped: string[] = [];
  const host = {
    call: async () => ({}),
    subscribe: async (stream: string, onEvent: (data: unknown) => void, filter?: Record<string, unknown>) => {
      streams.set(stream, { onEvent, ...(filter ? { filter } : {}) });
      return () => void stopped.push(stream);
    },
    handle: () => () => {},
  };
  return { host, streams, stopped };
}

function homeClient() {
  const me = { id: "me", kind: "human", name: "Me", chief: false };
  const group = conversation("g", { participants: [me] as never });
  return {
    call: async (op: string) => {
      if (op === HomeOps.inbox) return { me, conversations: [group], rev: 1 };
      if (op === HomeOps.page) return { conversation: group, messages: [], hasOlder: false };
      return {};
    },
    subscribe: async () => () => {},
    handle: () => () => {},
  };
}

async function renderDetail(host: unknown) {
  const container = installDom();
  const store = new HomeChannelsStore(homeClient() as never);
  await store.reloadInbox();
  await store.select("g");
  const nav = new MessagesNav();
  function Detail() {
    const snapshot = useSyncExternalStore(store.subscribe, store.getSnapshot);
    const open = snapshot.selected ? snapshot.conversations.get(snapshot.selected) : undefined;
    return (
      <MessagesDetail
        store={store}
        snapshot={snapshot}
        conversation={open}
        me={snapshot.me}
        strings={transcriptStrings}
        host={host as never}
        messages={noMessagesHost}
        chrome={{ windowControls: null }}
        nav={nav}
      />
    );
  }
  await act(async () => {
    root = createRoot(container);
    root.render(<Detail />);
  });
  await settle();
  return { container, nav };
}

test("G1: Group Info follows the conversation and closes once it is gone", async () => {
  const { host, streams, stopped } = followingHost();
  const { nav } = await renderDetail(host);
  await act(async () => nav.present({ kind: "groupInfo", conversation: "g" }));
  await settle();
  const follow = streams.get(MessagesDataOps.groupFollow);
  expect(follow?.filter).toEqual({ conversation: "g" });
  const info = (title: string) => ({
    info: { conversation: "g", isGroup: false, title, displayTitle: title, members: [], canMute: true, muted: false },
    addable: [],
  });
  await act(async () => follow!.onEvent(info("Lisbon")));
  expect(document.body.textContent).toContain("Lisbon");
  await act(async () => follow!.onEvent(info("Porto")));
  expect(document.body.textContent).toContain("Porto");
  expect(isGone({ gone: true })).toBe(true);
  await act(async () => follow!.onEvent({ gone: true }));
  await settle();
  expect(nav.getSnapshot().sheet).toBeUndefined();
  expect(stopped).toContain(MessagesDataOps.groupFollow);
});

test("G5: Requests follows the host's requests while it shows", async () => {
  const { host, streams, stopped } = followingHost();
  const { nav } = await renderDetail(host);
  expect(streams.has(MessagesDataOps.requestsFollow)).toBe(false);
  await act(async () => nav.present({ kind: "requests" }));
  await settle();
  const follow = streams.get(MessagesDataOps.requestsFollow);
  expect(follow).toBeDefined();
  await act(async () =>
    follow!.onEvent({
      requests: [{ conversation: "r1", inviter: "Ada", isGroup: false, preview: "hi", trusted: true }],
    }),
  );
  expect(nav.getSnapshot().requests.map((request) => request.conversation)).toEqual(["r1"]);
  await act(async () => nav.dismiss());
  await settle();
  expect(stopped).toContain(MessagesDataOps.requestsFollow);
});

test("M: no compose button over New Message", async () => {
  const { MessagesApp } = await import("../src/pages/home-messages/App");
  const container = installDom();
  const store = new HomeChannelsStore(homeClient() as never);
  await store.reloadInbox();
  const nav = new MessagesNav();
  await act(async () => {
    root = createRoot(container);
    root.render(
      <MessagesApp
        store={store}
        strings={transcriptStrings}
        host={null}
        messages={noMessagesHost}
        nav={nav}
        widthStorage={null}
      />,
    );
  });
  await settle();
  expect(container.querySelector(".hm-compose")).not.toBeNull();
  await act(async () => nav.openCompose());
  expect(container.querySelector(".hm-compose")).toBeNull();
  await act(async () => void nav.closeCompose());
  expect(container.querySelector(".hm-compose")).not.toBeNull();
});
