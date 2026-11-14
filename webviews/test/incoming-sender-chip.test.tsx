// Another agent's message line (conversation/IncomingMessageCard.tsx, the shared DisclosureRow's
// `.cv-disclosure__open`) goes to the sender's chat (Leo, ask-7325396234: "I THINK I WANNA BE ABLE TO
// CLICK ON THESE TO ACTUALLY GO TO THEM"): a click on the line opens the sender by its acpmux id, a
// lane on a peer found by its bare name too, and its chevron alone opens the message. No "Open chat"
// word sits beside it (Leo, 2026-10-29: "Nobody asked for open chat. We can just click."). The
// sender's name is plain text on the line, never a button of its own; a sender no list names has a
// line that only opens the message.
import { afterAll, afterEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { IncomingRelation } from "../src/agent-session/acpmux/conversation/incomingMessage";
import { translatorFor } from "../src/agent-session/acpmux/i18n";
import type { AcpmuxSessionEntry } from "../src/agent-session/acpmux/sessionList";
import { teardownDom } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  Range: dom.window.Range,
  customElements: dom.window.customElements,
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
const host = dom.window.document.getElementById("root")!;
let root: Root | undefined;

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
});
afterAll(async () => {
  await teardownDom(saved, { scope });
});

const { createRoot } = await import("react-dom/client");
const { IncomingMessageLine } = await import("../src/agent-session/acpmux/conversation/IncomingMessageCard");
const { SubsessionContext, SubsessionStore } = await import("../src/agent-session/acpmux/subagents/subsessions");
const { setChiefFaceHost } = await import("../src/agent-session/acpmux/chiefFace");
const { incomingPrompt } = await import("../src/agent-session/acpmux/conversation/incomingMessage");

const t = translatorFor("en");
const entry = (fields: Partial<AcpmuxSessionEntry> & { sessionId: string }) =>
  ({ displayTitle: fields.name ?? "", pendingPermissions: 0, ...fields }) as AcpmuxSessionEntry;
// A lane on huge-blue, listed here through the peer as `huge-blue/chief-ui`, and a chat on this Mac.
const sessions = [
  entry({ sessionId: "mux-chief-ui", name: "huge-blue/chief-ui", peer: "huge-blue" }),
  entry({ sessionId: "mux-deputy", name: "coord-deputy", hostKind: "local" }),
];

async function line(
  message: { name: string; sessionId?: string; chief?: string; relation?: IncomingRelation },
  entries = sessions,
) {
  const store = new SubsessionStore();
  store.set(entries);
  const opened: string[] = [];
  const text = "Rebased; ready for review.";
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <SubsessionContext.Provider value={{ store, open: () => undefined }}>
        <IncomingMessageLine
          id="row-1"
          message={{ ...message, text, raw: text }}
          onOpen={(id) => void opened.push(id)}
        />
      </SubsessionContext.Provider>,
    ),
  );
  return {
    // The sender's name is the link to its chat (Leo, 2026-10-29: "just make the left side
    // identifier like it was before and you can click it to go to that session"); no Open chat.
    open: host.querySelector<HTMLButtonElement>("button.cv-received__from--open"),
    from: host.querySelector<HTMLElement>(".cv-received__from"),
    toggle: host.querySelector<HTMLButtonElement>("button.cv-agentmsg__toggle")!,
    opened,
  };
}

test("a peer lane, found by its bare name, opens from its name; no Open chat, the toggle apart", async () => {
  const { open, from, toggle, opened } = await line({ name: "chief-ui" });
  expect(host.querySelector(".cv-disclosure__open")).toBeNull();
  expect(host.textContent).not.toContain(t("subsession.openChat"));
  expect(from?.textContent).toBe("chief-ui");
  expect(from).toBe(open);
  expect(from?.closest("button.cv-agentmsg__toggle")).toBeNull();
  await act(async () => open!.click());
  expect(opened).toEqual(["mux-chief-ui"]);
  // The name leaves the message closed.
  expect(toggle.getAttribute("aria-expanded")).toBe("false");
});

test("a chat on this Mac opens by the id its message gives", async () => {
  const { open, opened } = await line({ name: "coord-deputy", sessionId: "mux-deputy" });
  await act(async () => open!.click());
  expect(opened).toEqual(["mux-deputy"]);
});

test("a sender no list names is plain text: its line only opens the message", async () => {
  const { open, from, toggle, opened } = await line({ name: "gone-lane" });
  expect(open).toBeNull();
  expect(from?.textContent).toBe("gone-lane");
  await act(async () => toggle.click());
  expect(host.querySelector(".cv-received")?.getAttribute("data-open")).toBe("true");
  expect(opened).toEqual([]);
});

const remote = entry({
  sessionId: "remote-review",
  name: "gcp-codex-lane-10/pr-row",
  peer: "gcp-codex-lane-10",
  harness: "codex",
  startedBy: "viewer",
});

test("a qualified remote sender reads by its session name in the line, its labels and the reply", async () => {
  const { open, from, toggle, opened } = await line(
    { name: remote.name!, sessionId: remote.sessionId, relation: "parent" },
    [remote],
  );
  expect(from?.textContent).toBe("Parent · pr-row");
  expect(host.querySelector(".cv-received__host-name")?.textContent).toBe("gcp-codex-lane-10");
  expect(open?.getAttribute("aria-label")).toBe("Open pr-row (gcp-codex-lane-10)");
  expect(toggle.getAttribute("aria-label")).toBe(
    t("message.collapsedLabel", { from: "Parent · pr-row", preview: "Rebased; ready for review." }),
  );
  await act(async () => open!.click());
  expect(opened).toEqual([remote.sessionId]);
});

test("a sender with no recorded name reads by its session's name, not its raw address", async () => {
  const child = entry({ sessionId: "child-3", name: "design-check", hostKind: "local" });
  const { from, toggle } = await line({ name: "acp:child-3", sessionId: "child-3" }, [child]);
  expect(from?.textContent).toBe("design-check");
  expect(toggle.getAttribute("aria-label")).toBe(
    t("message.collapsedLabel", { from: "design-check", preview: "Rebased; ready for review." }),
  );
});

test("a sender found only by its name gains no child relationship", async () => {
  const { from } = await line({ name: remote.name! }, [remote]);
  expect(from?.textContent).toBe("pr-row");
  expect(from?.textContent).not.toContain("Sub-session");
});

// manaflow-ai/cmux#27914: a Chief's turn messages a GUI agent chat, by `agents_chat_send` (the cmux
// daemon's pump: an `agent_message` from `acp:<turn>`) or by `acpmux send` from inside the turn (a
// `session_message`). acpmux names the Chief (`fromChief`, prompt_provenance.rs `stamp_chief`); the
// line names the Chief and draws its avatar as the sidebar does, not the turn's session name
// (`optchat-<home>-<n>`) and a robot, and its name never opens the turn's session.
const { setMessageOpened } = await import("../src/agent-session/acpmux/conversation/incomingOpened");
const sent = "Sidebar fix is up; CI is green.";
const chiefMessages = {
  agent_message: {
    kind: "agent_message",
    from: "acp:turn-session-1",
    fromName: "optchat-b902d10e-2991",
    to: "acp:me",
    msgId: "m-1",
    threadId: "t-1",
    fromChief: "agent_ops",
  },
  session_message: {
    kind: "session_message",
    from: "turn-session-1",
    fromName: "optchat-b902d10e-2991",
    to: "me",
    fromChief: "agent_ops",
  },
};

for (const [kind, provenance] of Object.entries(chiefMessages)) {
  test(`a Chief's ${kind} shows the Chief's name and avatar, not its turn session`, async () => {
    const asked: unknown[] = [];
    const picture = "data:image/png;base64,QUJD";
    setChiefFaceHost(async (method, params) => {
      asked.push([method, params]);
      return { name: "Ops Chief", src: picture };
    });
    // Opened, so the panel shows too.
    setMessageOpened(undefined, "row-1", true);
    try {
      const parsed = incomingPrompt(sent, { _meta: { provenance } });
      const message = parsed?.kind === "message" ? parsed.message : undefined;
      expect(message).toMatchObject({ chief: "agent_ops" });
      const { open, from } = await line(message!);
      await act(async () => undefined);
      expect(asked).toEqual([["chief.face", { chief: "agent_ops" }]]);
      expect(from?.textContent).toBe("Ops Chief");
      expect(host.querySelector(".cv-received__mark img.cv-agent-avatar")?.getAttribute("src")).toBe(picture);
      expect(open).toBeNull();
      // Opened, the panel never names the sender again: the line already does.
      expect(host.querySelector(".cv-received__from-line")).toBeNull();
      expect(host.textContent).not.toContain("optchat-");
    } finally {
      setMessageOpened(undefined, "row-1", false);
      setChiefFaceHost(undefined);
    }
  });
}

test("a mounted agent identity takes a late profile icon without a parent render", async () => {
  const { AgentIdentity } = await import("../src/agent-session/acpmux/subagents/AgentIdentity");
  const { rememberHarnessIcons } = await import("../src/agent-session/shared/harnessIcons");
  // Sender Badge: None, the mark alone as before the badge (SenderIcon.test.tsx covers the badge).
  const { configureSenderIconLook, SENDER_ICON_BADGE_KEY } =
    await import("../src/agent-session/acpmux/subagents/senderIconLook");
  configureSenderIconLook({ [SENDER_ICON_BADGE_KEY]: "none" });
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <div>
        <span data-identity="unknown">
          <AgentIdentity harness="late-identity-profile" tone={2} />
        </span>
        <span data-identity="known-family">
          <AgentIdentity harness="claude-late-identity-profile" tone={3} />
        </span>
      </div>,
    ),
  );
  const unknown = host.querySelector('[data-identity="unknown"]')!;
  const known = host.querySelector('[data-identity="known-family"]')!;
  expect(unknown.querySelector('[data-agent-tone="2"]')).not.toBeNull();
  expect(known.querySelector(".agent-mark")).not.toBeNull();
  expect(known.querySelector("[data-agent-tone]")).toBeNull();
  await act(async () =>
    rememberHarnessIcons([
      { id: "late-identity-profile", iconSpec: { kind: "emoji", text: "🦊", source: "profile" } },
      { id: "claude-late-identity-profile", iconSpec: { kind: "emoji", text: "🦉", source: "profile" } },
    ]),
  );
  expect(unknown.textContent).toBe("🦊");
  expect(known.textContent).toBe("🦉");
  expect(unknown.querySelector("[data-agent-tone]")).toBeNull();
  configureSenderIconLook({});
});

// Leo, 2026-10-28 (ask-4e32bae782): "when you hover over the button, it should be able to tell you,
// like, a bit more metadata. Like, at the very least tell you what model did it, what effort level."
// The name's tooltip and the mark's name the sender's harness, model and effort: a listed chat's own,
// else the ones its message names (`fromHarness`, `fromModel`, `fromEffort`).
test("a listed sender's hover names its harness, model and effort", async () => {
  const listed = entry({
    sessionId: "mux-lane",
    name: "gcp-lane",
    hostKind: "local",
    harness: "codex",
    model: "gpt-6.1-sol",
    effort: "high",
  });
  const store = new SubsessionStore();
  store.set([...sessions, listed]);
  root = createRoot(host);
  const text = "Rebased.";
  await act(async () =>
    root!.render(
      <SubsessionContext.Provider value={{ store, open: () => undefined }}>
        <IncomingMessageLine
          id="row-1"
          message={{ name: "gcp-lane", sessionId: "mux-lane", text, raw: text }}
          onOpen={() => undefined}
        />
      </SubsessionContext.Provider>,
    ),
  );
  const open = host.querySelector<HTMLButtonElement>("button.cv-received__from--open")!;
  expect(open.getAttribute("title")).toBe(`${t("subagents.open", { name: "gcp-lane" })}\nCodex · gpt-6.1-sol high`);
  expect(open.getAttribute("aria-label")).toBe(t("subagents.open", { name: "gcp-lane" }));
  expect(host.querySelector(".cv-received__mark")?.getAttribute("title")).toBe("Codex · gpt-6.1-sol high");
});

test("an unlisted sender's hover reads the harness, model and effort its message names", async () => {
  const parsed = incomingPrompt("Tests pass", {
    _meta: {
      provenance: {
        kind: "session_message",
        from: "peer-lane-1",
        fromName: "peer-lane",
        fromHarness: "codex",
        fromModel: "gpt-6-astra",
        fromEffort: "xhigh",
      },
    },
  });
  const message = parsed?.kind === "message" ? parsed.message : undefined;
  expect(message).toMatchObject({ harness: "codex", model: "gpt-6-astra", effort: "xhigh" });
  await line({ ...message!, sessionId: undefined });
  const from = host.querySelector<HTMLElement>(".cv-received__from")!;
  expect(from.getAttribute("title")).toBe("Codex · gpt-6-astra xhigh");
});

test("a sender nothing describes keeps no tooltip", async () => {
  await line({ name: "gone-lane" });
  expect(host.querySelector(".cv-received__from")?.getAttribute("title")).toBeNull();
  expect(host.querySelector(".cv-received__mark")?.getAttribute("title")).toBeNull();
});

// Leo, 2026-11-05, on two lanes' received lines: "i can't click to go to these for some reason". A sender the page's list cannot name was
// a plain pill a click did nothing on. Where acpmux resolves sessions (`_acpmux/resolve`, the
// `HOST/NAME` refs' resolver, sessionRefs.ts), its chip is the session link: a click opens the
// session acpmux names, on whatever machine, and a name acpmux has no chat for says so.
const refs = await import("../src/agent-session/acpmux/conversation/sessionRefs");

async function asked(
  name: string,
  answers: Record<string, { sessionId: string; name: string; host: string }>,
  lookup?: string,
) {
  const queries: string[] = [];
  refs.resetSessionRefs();
  refs.setSessionRefResolver(async (query) => {
    queries.push(query);
    const session = answers[query];
    if (!session) throw new Error("not found");
    return { session };
  });
  const store = new SubsessionStore();
  store.set(sessions);
  const opened: string[] = [];
  const missing: string[] = [];
  const text = "the hq#7125 lane is up";
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <SubsessionContext.Provider
        value={{ store, open: () => undefined, senderMissing: (who) => void missing.push(who) }}
      >
        <IncomingMessageLine
          id="row-1"
          message={{ name, ...(lookup && { lookup }), text, raw: text }}
          onOpen={(id) => void opened.push(id)}
        />
      </SubsessionContext.Provider>,
    ),
  );
  const open = host.querySelector<HTMLButtonElement>("button.cv-received__from--open");
  return { open, opened, missing, queries };
}

test("an unlisted sender on another machine opens the session acpmux resolves, by its id", async () => {
  try {
    const remote = {
      sessionId: "mock-remote-lane",
      name: "side-lane",
      host: "gcp-agent-lane-1",
    };
    const { open, opened, queries } = await asked("gcp-agent-lane-1/side-lane", {
      "gcp-agent-lane-1/side-lane": remote,
    });
    expect(open).not.toBeNull();
    // Asked once the page is idle; answered, a click opens the session by its id.
    await act(async () => void (await refs.resolveSessionRef("gcp-agent-lane-1/side-lane")));
    await act(async () => open!.click());
    expect(queries).toEqual(["gcp-agent-lane-1/side-lane"]);
    expect(opened).toEqual([remote.sessionId]);
    // Resolved, the chip names the session and its machine, and carries it for the right-click menu.
    const chip = host.querySelector<HTMLButtonElement>("button.cv-received__from--open")!;
    expect(chip.getAttribute("data-open-session")).toBe(remote.sessionId);
    expect(chip.getAttribute("aria-label")).toBe(
      t("subagents.openOnHost", { name: "gcp-agent-lane-1/side-lane", host: "gcp-agent-lane-1" }),
    );
  } finally {
    refs.setSessionRefResolver(undefined);
  }
});

// Leo, 2026-11-07: "I expect to see, okay, my right pane is going to either gain a new tab or, like,
// split ... not only do I not get that, like immediate feedback after clicking, but it also just
// fundamentally doesn't load." The click opens the tab at once, never after acpmux answers; the tab
// finds the chat or says why it can't (direct.ts `resolveMissing`, chatUnavailable.ts).
test("a click before acpmux answered opens the sender's tab at once, by what it is asked for", async () => {
  try {
    const { open, opened, queries } = await asked("gcp-agent-lane-1/side-lane", {});
    await act(async () => open!.click());
    expect(opened).toEqual(["gcp-agent-lane-1/side-lane"]);
    expect(queries).toEqual([]);
  } finally {
    refs.setSessionRefResolver(undefined);
  }
});

test("a sender acpmux has no chat for opens a tab that says so, never a silent no-op", async () => {
  try {
    const { open, opened, missing } = await asked("gone-mesh", {});
    expect(open).not.toBeNull();
    await act(async () => void (await refs.resolveSessionRef("gone-mesh")));
    await act(async () => open!.click());
    expect(opened).toEqual(["gone-mesh"]);
    expect(missing).toEqual([]);
  } finally {
    refs.setSessionRefResolver(undefined);
  }
});

// The coordinator chat showed "Can't find gcp-codex-swarm-01/ask-3f0256c58a-3 (self-declared,
// unauthenticated)'s chat": the chip asked acpmux for its line's text, note and all.
test("a self-declared sender is asked for and opened by the name it gave, never its line's text", async () => {
  try {
    const remote = { sessionId: "mock-swarm-lane", name: "ask-3f0256c58a-3", host: "gcp-codex-swarm-01" };
    const label = "gcp-codex-swarm-01/ask-3f0256c58a-3";
    const { open, opened, queries } = await asked(
      `${label} (self-declared, unauthenticated)`,
      { [label]: remote },
      label,
    );
    await act(async () => open!.click());
    expect(opened).toEqual([label]);
    await act(async () => void (await refs.resolveSessionRef(label)));
    expect(queries).toEqual([label]);
    await act(async () => host.querySelector<HTMLButtonElement>("button.cv-received__from--open")!.click());
    expect(opened).toEqual([label, remote.sessionId]);
  } finally {
    refs.setSessionRefResolver(undefined);
  }
});

test("a miss is asked again once it is old: a machine that connects later opens", async () => {
  try {
    let answer: { sessionId: string; name: string; host: string } | undefined;
    refs.resetSessionRefs();
    refs.setSessionRefResolver(async () => {
      if (!answer) throw new Error("not found");
      return { session: answer };
    });
    const now = Date.now;
    expect(await refs.resolveSessionRef("late-vm/lane")).toBeNull();
    answer = { sessionId: "mock-late", name: "lane", host: "late-vm" };
    expect(await refs.resolveSessionRef("late-vm/lane")).toBeNull();
    try {
      Date.now = () => now() + refs.MISS_KEPT_MS + 1;
      expect((await refs.resolveSessionRef("late-vm/lane"))?.sessionId).toBe("mock-late");
    } finally {
      Date.now = now;
    }
  } finally {
    refs.setSessionRefResolver(undefined);
  }
});
