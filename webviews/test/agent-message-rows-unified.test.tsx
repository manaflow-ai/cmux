// l10n-allow-file: test fixtures (messages between agents).
// Messages between agents draw as one row (conversation/AgentMessageRow.tsx) whatever their kind,
// name their sender bare, and never show the lane-gh broker's label or an older acpmux's
// "(self-declared, unauthenticated)" words. Leo, 2026-11-07, on received rows reading "NAME
// (self-declared, unauthenticated)" over a cut "[message … relayed by the lane-gh broker; its te…"
// line: "Why does it say blah blah unauthenticated? And why can't I see the full excerpt of its
// message?", and on the subagent report and sent rows: "why is it formatted differently from
// everything else ... They should look basically the same as the other ones". On the "Received 7
// messages" hover, a wall of suffixed names: "this is not useful."
// Trace-ID: ask-4d2f6a6dc7, ask-03230f76a4.
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { IncomingMessageLine } from "../src/agent-session/acpmux/conversation/IncomingMessageCard";
import { InboxNoticeCard } from "../src/agent-session/acpmux/conversation/InboxNoticeCard";
import { inboxNotice, type InboxNotice } from "../src/agent-session/acpmux/conversation/inboxNotice";
import { incomingPrompt, type IncomingMessage } from "../src/agent-session/acpmux/conversation/incomingMessage";
import { relayEnvelope, withoutRelayHead } from "../src/agent-session/acpmux/conversation/relayEnvelope";
import { AcpmuxSendLine } from "../src/agent-session/acpmux/conversation/SentMessageLine";
import { acpmuxSendCall } from "../src/agent-session/acpmux/conversation/acpmuxSends";
import { SubagentDoneLine } from "../src/agent-session/acpmux/subagents/SubagentDoneLine";
import { DoneReportLookContext } from "../src/agent-session/acpmux/subagents/subagentDoneLineModel";
import { SubagentNavContext } from "../src/agent-session/acpmux/subagents/subagentGroupModel";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "MouseEvent",
    "localStorage",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    MouseEvent: dom.window.MouseEvent,
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

async function render(node: ReactNode, setup?: (window: JSDOM["window"]) => void): Promise<HTMLElement> {
  const container = installDom();
  setup?.(dom!.window);
  await act(async () => {
    root = createRoot(container);
    root.render(node);
  });
  return container;
}

async function openAll(container: HTMLElement): Promise<void> {
  for (const toggle of container.querySelectorAll<HTMLElement>(".cv-agentmsg__toggle"))
    await act(async () => toggle.click());
}

const SUFFIX = "(self-declared, unauthenticated)";
const BODY = "**#37534 is green** at `64d6b1b`.\n\n- the canary stays on huge-blue\n- the cap counts each host once";

/// The broker's label around `body`, as a lane VM's message reaches the agent.
const relayed = (body: string, id: string, from: string) =>
  [
    `[message ${id} from ${from} (an agent, not Leo), relayed by the lane-gh broker; its text ends at "[end of message ${id}]"]`,
    body,
    `[end of message ${id}]`,
  ].join("\n");

const received = (text: string, sender: Record<string, unknown>, fromName: string): IncomingMessage => {
  const prompt = incomingPrompt(text, {
    client: "acpmux-cli#1@gcp-agent-lane-2",
    _meta: { provenance: { kind: "agent_message", from: "fromAgent", fromName, sender } },
  });
  if (prompt?.kind !== "message") throw new Error("not a received message");
  return prompt.message;
};

test("a verified relayed message: the bare name, its family's mark, and the whole message rendered", async () => {
  const message = received(
    relayed(BODY, "7f70dca3", "gcp-agent-lane-2/lock-proof-routes"),
    { verification: "verified", harness: "codex", relay: { by: "lane-gh broker", machine: "gcp-agent-lane-2" } },
    "gcp-agent-lane-2/lock-proof-routes",
  );
  const container = await render(<IncomingMessageLine id="m-verified" message={message} onOpen={() => undefined} />);
  // The shared row.
  expect(container.querySelector(".cv-agentmsg")).not.toBeNull();
  // The codex mark, with the session's badge (SenderIcon.tsx), not the toned robot alone every
  // unknown sender wears.
  expect(container.querySelector(".cv-received__mark")).not.toBeNull();
  expect(container.querySelector(".cv-received__mark .cv-sender-icon__main")).not.toBeNull();
  expect(container.querySelector(".cv-unverified")).toBeNull();
  await openAll(container);
  const card = container.querySelector(".cv-agentmsg__card");
  expect(card?.querySelector("strong")?.textContent).toBe("#37534 is green");
  expect(card?.querySelectorAll("li").length).toBe(2);
  const text = container.textContent ?? "";
  expect(text).toContain("gcp-agent-lane-2/lock-proof-routes");
  expect(text).not.toContain("[message");
  expect(text).not.toContain("relayed by");
  expect(text).not.toContain("[end of message");
});

test("an unverified sender gets the marker only: no 'self-declared' words anywhere in the row", async () => {
  const name = `gcp-codex-swarm-05/cloud-start-matrix ${SUFFIX}`;
  const message = received("Matrix run 14 is green.", { verification: "declared" }, name);
  const container = await render(<IncomingMessageLine id="m-declared" message={message} onOpen={() => undefined} />);
  await openAll(container);
  const marker = container.querySelector(".cv-unverified");
  // The name it gave is its claim (UnverifiedMark.tsx).
  expect(marker?.getAttribute("title")).toBe(`Claimed to be ${message.name}, not proven`);
  expect(container.innerHTML).not.toContain("self-declared");
  expect(container.innerHTML).not.toContain("unauthenticated");
  expect(container.textContent).toContain("gcp-codex-swarm-05/cloud-start-matrix");
  expect(container.textContent).not.toContain("Received message from");
  // Review of #37653: the marker is the one sign; the chip carries no "Unverified" word beside it.
  expect(container.textContent).not.toMatch(/unverified/i);
  expect(container.querySelectorAll(".cv-unverified").length).toBe(1);
});

test("an older acpmux's sender with only the suffix (no record) is marked unverified, the name bare", async () => {
  const message = received("hello", {}, `lane-x ${SUFFIX}`);
  expect(message.name).toBe("lane-x");
  expect(message.unverified).toBe(true);
});

test("an older record whose broker label names a suffixed sender keeps its marker, the name bare", async () => {
  // An older acpmux's `acpmux send` at a shell: no provenance and no sender record, so only the
  // label's suffix says acpmux could not verify it.
  const whole = relayed("Matrix run 14 is green.", "56d7d1c5", `gcp-codex-swarm-05/cloud-start-matrix ${SUFFIX}`);
  const prompt = incomingPrompt(whole, { client: "acpmux-cli#1@gcp-codex-swarm-05" });
  if (prompt?.kind !== "message") throw new Error("not a received message");
  expect(prompt.message.name).toBe("gcp-codex-swarm-05/cloud-start-matrix");
  expect(prompt.message.unverified).toBe(true);
  const container = await render(
    <IncomingMessageLine id="m-old-label" message={prompt.message} onOpen={() => undefined} />,
  );
  expect(container.querySelector(".cv-unverified")).not.toBeNull();
  expect(container.textContent).toContain("gcp-codex-swarm-05/cloud-start-matrix");
  expect(container.innerHTML).not.toContain("self-declared");
});

test("a broker label naming a suffixed sender still unwraps, and a head cut short reads as nothing", () => {
  const whole = relayed("Matrix run 14 is green.", "56d7d1c5", `gcp-codex-swarm-05/cloud-start-matrix ${SUFFIX}`);
  const envelope = relayEnvelope(whole);
  expect(envelope?.body).toBe("Matrix run 14 is green.");
  expect(envelope?.sender).toBe("gcp-codex-swarm-05/cloud-start-matrix");
  expect(withoutRelayHead(whole.slice(0, 120))).toBe("");
});

test("an older acpmux's inbox notice: bare names, no label, the whole message once opened", () => {
  const from = `gcp-codex-swarm-05/cloud-start-matrix ${SUFFIX}`;
  const whole = relayed("Matrix run 14 is green.\n\nNext: the cold-start numbers.", "56d7d1c5", from);
  const notice = inboxNotice("[inbox] New messages from other agents in 1 thread.", {
    threads: [
      {
        threadId: "declared:gcp-codex-swarm-05/cloud-start-matrix",
        label: `gcp-codex-swarm-05/cloud-start-matrix ${SUFFIX}`,
        from: [from],
        new: 1,
        preview: whole.slice(0, 120),
        promptIds: ["p-56d7"],
        messages: [{ promptId: "p-56d7", from, text: whole }],
      },
    ],
  })!;
  const thread = notice.threads[0]!;
  expect(thread.from).toEqual(["gcp-codex-swarm-05/cloud-start-matrix"]);
  expect(thread.label).toBe("gcp-codex-swarm-05/cloud-start-matrix");
  expect(thread.preview).toBe("Matrix run 14 is green.");
  expect(thread.messages?.[0]?.text).toBe("Matrix run 14 is green.\n\nNext: the cold-start numbers.");
  expect(thread.messages?.[0]?.from).toBe("gcp-codex-swarm-05/cloud-start-matrix");
  expect(JSON.stringify(notice)).not.toContain("self-declared");
});

test("a notice thread rendered: the marker, and the whole message under its line before it is opened", async () => {
  const from = `gcp-codex-swarm-05/cloud-start-matrix ${SUFFIX}`;
  const whole = relayed("Matrix run 14 is green.\n\nNext: the cold-start numbers.", "56d7d1c5", from);
  const notice = inboxNotice("[inbox] New messages from other agents in 1 thread.", {
    threads: [
      {
        threadId: "declared:gcp-codex-swarm-05/cloud-start-matrix",
        label: `gcp-codex-swarm-05/cloud-start-matrix ${SUFFIX}`,
        from: [from],
        new: 1,
        preview: whole.slice(0, 120),
        promptIds: ["p-56d7"],
        messages: [{ promptId: "p-56d7", from, text: whole }],
      },
    ],
  })!;
  const container = await render(<InboxNoticeCard rowId="r-old" notice={notice} onOpen={() => undefined} />);
  expect(container.querySelector(".cv-agentmsg")).not.toBeNull();
  expect(container.querySelector(".cv-unverified")).not.toBeNull();
  // Shut, the card under the line holds the message whole (Leo, 2026-11-09); the line says it once.
  const newest = container.querySelector(".cv-inbox__newest")?.textContent ?? "";
  expect(newest).toContain("Matrix run 14 is green.");
  expect(newest).toContain("Next: the cold-start numbers.");
  expect(container.querySelector(".cv-agentmsg__preview")?.textContent).toBe("");
  await openAll(container);
  const text = container.textContent ?? "";
  expect(text).toContain("Next: the cold-start numbers.");
  expect(text).not.toContain("[message");
  expect(container.innerHTML).not.toContain("self-declared");
});

test("a thread with no messages and no preview reads them from acpmux before it is opened", async () => {
  const reads: string[] = [];
  const notice: InboxNotice = {
    threads: [
      { threadId: "pr:9", label: "#9", from: ["lane-a"], count: 1, preview: "", blocker: false, promptIds: ["a1"] },
    ],
  };
  const container = await render(
    <InboxNoticeCard
      rowId="r-fetch"
      notice={notice}
      onOpen={() => undefined}
      readThread={async (id) => {
        reads.push(id);
        return [{ promptId: "a1", from: "lane-a", text: relayed("The whole message.", "abcd1234", "vm/lane-a") }];
      }}
    />,
  );
  await act(async () => undefined);
  expect(reads).toEqual(["pr:9"]);
  // One short line, read whole: on the line, as a received line reads (inboxThreadRead.ts `fitsLine`).
  expect(container.querySelector(".cv-agentmsg__preview")?.textContent).toBe("The whole message.");
  expect(container.querySelector(".cv-inbox__newest")).toBeNull();
  await openAll(container);
  expect(container.querySelector(".cv-received__text")?.textContent).toBe("The whole message.");
});

type Tool = NonNullable<AcpmuxActivity["tool"]>;

test("a send and a subagent's report draw through the same row as a received message", async () => {
  const tool: Tool = {
    id: "toolu_send_rows",
    title: "acpmux send coord",
    kind: "execute",
    status: "completed",
    command: "acpmux send --no-wait coord - <<'EOF'\n" + BODY + "\nEOF",
    description: "Report the merge",
  };
  const done: AcpmuxRow = {
    id: "done-rows",
    version: 1,
    kind: "subagentDone",
    at: 61_000,
    subagents: [
      {
        id: "agent-rows",
        parent: null,
        name: "Diagnose nightly lag",
        task: "Diagnose nightly lag",
        state: "completed",
        startedAt: 0,
        endedAt: 61_000,
        result: "I fixed nothing.\n\n1. **Nightly**: the disk floor.",
      },
    ],
  };
  const container = await render(
    <SubagentNavContext.Provider value={() => undefined}>
      <DoneReportLookContext.Provider value="disclosure">
        <AcpmuxSendLine tool={tool} send={acpmuxSendCall(tool)!} />
        <SubagentDoneLine row={done} />
      </DoneReportLookContext.Provider>
    </SubagentNavContext.Provider>,
  );
  expect(container.querySelectorAll(".cv-agentmsg").length).toBe(2);
  await openAll(container);
  const cards = [...container.querySelectorAll(".cv-agentmsg__card")];
  expect(cards.length).toBe(2);
  expect(cards[0]?.querySelector("strong")?.textContent).toBe("#37534 is green");
  expect(cards[1]?.querySelector("strong")?.textContent).toBe("Nightly");
});

test("a group's hover lists its messages newest first, short names, two lines each, then +N more", async () => {
  const { GroupHoverLookContext, MessageGroupHover, hoverMessages } =
    await import("../src/agent-session/acpmux/conversation/MessageGroupHover");
  const list: IncomingMessage[] = Array.from({ length: 7 }, (_, index) => ({
    name: `gcp-agent-lane-3/lane-${index} ${SUFFIX}`,
    text: relayed(`message ${index}\nsecond line ${index}`, `abcd000${index}`, `gcp-agent-lane-3/lane-${index}`),
    raw: "",
    ...(index === 6 && { unverified: true as const }),
  }));
  // The `messages` look (a gallery version; the digest is group-hover-digest.test.tsx).
  const container = await render(
    <GroupHoverLookContext.Provider value="messages">
      <MessageGroupHover list={hoverMessages(list)} />
    </GroupHoverLookContext.Provider>,
  );
  const text = container.textContent ?? "";
  expect(text).not.toContain("self-declared");
  expect(text).not.toContain("[message");
  expect(text).not.toContain("gcp-agent-lane-3/");
  // Newest first: lane-6 leads, five shown, the rest counted.
  expect(text.indexOf("lane-6")).toBeLessThan(text.indexOf("lane-5"));
  expect(text).toContain("message 6");
  expect(text).toContain("second line 6");
  expect(text).not.toContain("lane-1");
  expect(text).toContain("+2 more");
  expect(container.querySelectorAll(".cv-unverified").length).toBe(1);
});

test("an inbox notice's hover lists every message of every thread, newest first, and counts the rest", async () => {
  const { GroupHoverLookContext, MessageGroupHover, inboxHover } =
    await import("../src/agent-session/acpmux/conversation/MessageGroupHover");
  const notice: InboxNotice = {
    threads: [
      {
        threadId: "pr:1",
        label: "#1",
        from: ["vm/lane-a"],
        count: 3,
        preview: "",
        blocker: false,
        promptIds: ["a1", "a2", "a3"],
        messages: [
          { promptId: "a1", from: "vm/lane-a", text: "first from a", at: 10 },
          { promptId: "a2", from: "vm/lane-a", text: "second from a", at: 30 },
          { promptId: "a3", from: "vm/lane-a", text: "third from a", at: 50 },
        ],
      },
      // A thread that held only its preview stands for its whole count.
      {
        threadId: "pr:2",
        label: "#2",
        from: ["vm/lane-b"],
        count: 4,
        preview: "newest from b",
        blocker: false,
        promptIds: ["b1", "b2", "b3", "b4"],
      },
      {
        threadId: "pr:3",
        label: "#3",
        from: ["vm/lane-c"],
        count: 1,
        preview: "",
        blocker: false,
        promptIds: ["c1"],
        messages: [{ promptId: "c1", from: "vm/lane-c", text: "only from c", at: 40 }],
      },
    ],
  };
  const list = inboxHover(notice.threads);
  expect(list.messages.map((m) => m.text)).toEqual([
    "third from a",
    "only from c",
    "second from a",
    "first from a",
    "newest from b",
  ]);
  // 3 + 4 + 1 messages in all.
  expect(list.total).toBe(8);
  const container = await render(
    <GroupHoverLookContext.Provider value="messages">
      <MessageGroupHover list={list} />
    </GroupHoverLookContext.Provider>,
  );
  const items = [...container.querySelectorAll(".cv-group-hover__item")];
  expect(items).toHaveLength(5);
  expect(items[0]?.textContent).toContain("third from a");
  expect(container.querySelector(".cv-group-hover__more")?.textContent).toBe("+3 more");
});

test("a lane batch's hover counts a preview-only delivery as its thread's whole count", async () => {
  const { hoverMessages } = await import("../src/agent-session/acpmux/conversation/MessageGroupHover");
  const one = (name: string, text: string): IncomingMessage => ({ name, text, raw: "" });
  const list = hoverMessages([one("a", "older"), one("b", "newer")], [undefined, 6]);
  expect(list.messages.map((m) => m.text)).toEqual(["newer", "older"]);
  expect(list.total).toBe(7);
});

// Review of #37653: the "Received N messages" hover is newest first by when each message came
// (an inbox message's `at`, else its row's), not by the rows' order reversed: a notice lists its
// threads in its own order, which is not the messages' age.
test("a lane batch's hover lists its messages newest first by their time, not their order", async () => {
  const { hoverMessages } = await import("../src/agent-session/acpmux/conversation/MessageGroupHover");
  const { flattenInboxRows } = await import("../src/agent-session/acpmux/conversation/laneNoticeBatches");
  const notice: InboxNotice = {
    threads: [
      {
        threadId: "pr:1",
        label: "#1",
        from: ["vm/lane-a"],
        count: 1,
        preview: "",
        blocker: false,
        promptIds: ["a1"],
        messages: [{ promptId: "a1", from: "vm/lane-a", text: "newest, listed first", at: 50 }],
      },
      {
        threadId: "pr:2",
        label: "#2",
        from: ["vm/lane-b"],
        count: 1,
        preview: "",
        blocker: false,
        promptIds: ["b1"],
        messages: [{ promptId: "b1", from: "vm/lane-b", text: "oldest, listed last", at: 10 }],
      },
    ],
  };
  const row: AcpmuxRow = { id: "inbox-time", version: 1, at: 99, kind: "user", incoming: { kind: "inbox", notice } };
  const children = flattenInboxRows([row]).filter((r) => r.incoming?.kind === "message");
  const messages = children.map((r) => (r.incoming?.kind === "message" ? r.incoming.message : undefined));
  const list = hoverMessages(
    messages,
    children.map(() => undefined),
    children.map((r) => r.at),
  );
  expect(list.messages.map((m) => m.text)).toEqual(["newest, listed first", "oldest, listed last"]);
  // Rows with no message time sort by their own: the later row first, a tie by order.
  const one = (name: string, text: string): IncomingMessage => ({ name, text, raw: "" });
  expect(
    hoverMessages([one("a", "late"), one("b", "early"), one("c", "tie")], [], [30, 10, 30]).messages.map((m) => m.text),
  ).toEqual(["tie", "late", "early"]);
});

// Review of #37653: acpmux may say a thread's newest sender is unverified only on the thread (its
// sender record, or an older acpmux's suffix on its `from`), not on each message. That message's
// row and the group's hover still mark its sender's name as a claim.
test("a thread's unverified sender marks its newest message's row and hover", async () => {
  const { flattenInboxRows } = await import("../src/agent-session/acpmux/conversation/laneNoticeBatches");
  const { GroupHoverLookContext, MessageGroupHover, hoverMessages, inboxHover } =
    await import("../src/agent-session/acpmux/conversation/MessageGroupHover");
  const notice = inboxNotice("[inbox] New messages from other agents in 1 thread.", {
    threads: [
      {
        threadId: "pr:9",
        label: "#9",
        from: ["vm-1/lane-a", "vm-1/lane-b"],
        promptIds: ["a1", "b1"],
        sender: { label: "vm-1/lane-b", labelDeclared: true, verification: "declared" },
        messages: [
          { promptId: "a1", from: "vm-1/lane-a", text: "first", at: 10 },
          { promptId: "b1", from: "vm-1/lane-b", text: "second", at: 20 },
        ],
      },
    ],
  })!;
  expect(notice.threads[0]?.unverified).toBe(true);
  const row: AcpmuxRow = {
    id: "inbox-unverified",
    version: 1,
    at: 1,
    kind: "user",
    incoming: { kind: "inbox", notice },
  };
  const children = flattenInboxRows([row]).filter((r) => r.incoming?.kind === "message");
  const messages = children.map((r) => (r.incoming?.kind === "message" ? r.incoming.message : undefined));
  // Only the newest sender's message: the thread's flag names that sender, not the one before.
  expect(messages.map((m) => m?.unverified === true)).toEqual([false, true]);
  const container = await render(
    <GroupHoverLookContext.Provider value="messages">
      <MessageGroupHover
        list={hoverMessages(
          messages,
          [],
          children.map((r) => r.at),
        )}
      />
    </GroupHoverLookContext.Provider>,
  );
  const items = [...container.querySelectorAll(".cv-group-hover__item")];
  expect(items[0]?.textContent).toContain("second");
  expect(items[0]?.querySelector(".cv-unverified")?.getAttribute("title")).toBe(
    "Claimed to be vm-1/lane-b, not proven",
  );
  expect(items[1]?.querySelector(".cv-unverified")).toBeNull();
  // The notice card's own hover reads the same.
  expect(inboxHover(notice.threads).messages.map((m) => [m.text, m.unverified === true])).toEqual([
    ["second", true],
    ["first", false],
  ]);
});

test("a sender named only by its record's session still opens its chat", async () => {
  const opened: string[] = [];
  const notice: InboxNotice = {
    threads: [
      {
        threadId: "from:vm/lane-a",
        label: "",
        from: ["vm/lane-a"],
        count: 1,
        preview: "hello",
        blocker: false,
        promptIds: ["a1"],
        sender: { session: "sess-a" },
      },
    ],
  };
  const container = await render(
    <InboxNoticeCard rowId="r-session" notice={notice} onOpen={(id) => void opened.push(id)} />,
  );
  const chip = container.querySelector<HTMLElement>(".cv-received__from--open");
  expect(chip).not.toBeNull();
  await act(async () => chip!.click());
  expect(opened).toEqual(["sess-a"]);
});

test("an inbox delivery takes its session from the sender record when the thread names none", async () => {
  const { flattenInboxRows } = await import("../src/agent-session/acpmux/conversation/laneNoticeBatches");
  const notice: InboxNotice = {
    threads: [
      {
        threadId: "pr:7",
        label: "#7",
        from: ["vm/lane-a"],
        count: 2,
        preview: "",
        blocker: false,
        promptIds: ["a1", "a2"],
        messages: [
          { promptId: "a1", from: "vm/lane-a", text: "one", sender: { session: "sess-a" } },
          { promptId: "a2", from: "vm/lane-b", text: "two", sender: { session: "sess-b" } },
        ],
      },
      {
        threadId: "pr:8",
        label: "#8",
        from: ["vm/lane-c"],
        count: 1,
        preview: "three",
        blocker: false,
        promptIds: ["c1"],
        sender: { session: "sess-c" },
      },
    ],
  };
  const row: AcpmuxRow = { id: "inbox-row", version: 1, at: 1, kind: "user", incoming: { kind: "inbox", notice } };
  const children = flattenInboxRows([row]).filter((r) => r.incoming?.kind === "message");
  const sessions = children.map((r) => (r.incoming?.kind === "message" ? r.incoming.message.sessionId : undefined));
  expect(sessions).toEqual(["sess-a", "sess-b", "sess-c"]);
  expect(children[2]?.inboxThread?.fromSession).toBe("sess-c");
});

test("a thread whose preview was cut inside the broker's head stays an expandable row that reads its message", async () => {
  const { flattenInboxRows } = await import("../src/agent-session/acpmux/conversation/laneNoticeBatches");
  const { MessageRow } = await import("../src/agent-session/acpmux/rows/MessageRow");
  const { isVisiblyEmptyMessage } = await import("../src/agent-session/acpmux/conversation/visibleMessage");
  // acpmux cut the thread's preview at 120 characters, inside the label's head, and sent no messages.
  const whole = relayed("The whole message.", "12345678", "vm/lane");
  const prompt = incomingPrompt("[inbox] New messages from other agents in 1 thread.", {
    client: "acpmux",
    _meta: {
      provenance: {
        kind: "inbox_notice",
        threads: [
          { threadId: "from:vm/lane", from: ["vm/lane"], new: 1, preview: whole.slice(0, 120), promptIds: ["p1"] },
        ],
      },
    },
  });
  if (prompt?.kind !== "inbox") throw new Error("not an inbox notice");
  const row: AcpmuxRow = { id: "inbox-cut", version: 1, at: 1, kind: "user", incoming: prompt };
  const child = flattenInboxRows([row]).find((r) => r.inboxThread)!;
  expect(child.inboxThread?.threadId).toBe("from:vm/lane");
  const reads: string[] = [];
  const container = await render(
    <MessageRow row={child} onToggleActivity={() => undefined} expanded={false} />,
    (window) => {
      (window as unknown as Record<string, unknown>).cmuxAcpmuxActions = {
        "chat.inbox.thread": async ({ threadId }: { threadId: string }) => {
          reads.push(threadId);
          return [{ promptId: "p1", from: "vm/lane", text: whole }];
        },
      };
    },
  );
  await act(async () => undefined);
  expect(container.querySelector(".cv-agentmsg")).not.toBeNull();
  expect(reads).toEqual(["from:vm/lane"]);
  // The turn keeps it too (turns.ts drops visibly empty messages).
  expect(isVisiblyEmptyMessage(child)).toBe(false);
  expect(container.textContent).not.toContain("[message");
  await openAll(container);
  expect(container.querySelector(".cv-received__text")?.textContent).toBe("The whole message.");
});

// Review of #37653: a preview-only inbox row (one with no messages) still asks for its sender by
// acpmux's record (its label, never cut), not by the bare name its line shows: a label-only sender
// whose bare name another chat shares must not open that other chat.
test("a preview-only inbox row opens its sender by the record's label, not the bare name", async () => {
  const { flattenInboxRows } = await import("../src/agent-session/acpmux/conversation/laneNoticeBatches");
  const { MessageRow } = await import("../src/agent-session/acpmux/rows/MessageRow");
  const refs = await import("../src/agent-session/acpmux/conversation/sessionRefs");
  const prompt = incomingPrompt("[inbox] New messages from other agents in 1 thread.", {
    client: "acpmux",
    _meta: {
      provenance: {
        kind: "inbox_notice",
        threads: [
          {
            threadId: "declared:vm-1/lane-a",
            from: ["lane-a"],
            new: 1,
            preview: "done",
            promptIds: ["p1"],
            sender: { label: "vm-1/lane-a", labelDeclared: true, verification: "declared" },
          },
        ],
      },
    },
  });
  if (prompt?.kind !== "inbox") throw new Error("not an inbox notice");
  const row: AcpmuxRow = { id: "inbox-label", version: 1, at: 1, kind: "user", incoming: prompt };
  const child = flattenInboxRows([row]).find((r) => r.inboxThread)!;
  const opened: string[] = [];
  refs.resetSessionRefs();
  // acpmux has not answered yet: the click opens by what the chip asks for.
  refs.setSessionRefResolver(() => new Promise(() => undefined));
  try {
    const container = await render(
      <MessageRow row={child} onToggleActivity={() => undefined} expanded={false} />,
      (window) => {
        (window as unknown as Record<string, unknown>).cmuxAcpmuxActions = {
          "chat.offer.open": async ({ sessionId }: { sessionId: string }) => void opened.push(sessionId),
          "chat.inbox.thread": async () => [],
        };
      },
    );
    const chip = container.querySelector<HTMLElement>(".cv-received__from--open");
    expect(chip).not.toBeNull();
    await act(async () => chip!.click());
    expect(opened).toEqual(["vm-1/lane-a"]);
  } finally {
    refs.setSessionRefResolver(undefined);
    refs.resetSessionRefs();
  }
});

// A relayed message (`--from coord --relay lane-gh --relayed-from vm-1/lane-a`): its record's label is
// the name the sender declared, shown only; the chip asks for the chat by the relay's address
// (cmux#38642 review).
test("a relayed preview-only inbox row opens its sender by the relay address, not the declared label", async () => {
  const { flattenInboxRows } = await import("../src/agent-session/acpmux/conversation/laneNoticeBatches");
  const { MessageRow } = await import("../src/agent-session/acpmux/rows/MessageRow");
  const refs = await import("../src/agent-session/acpmux/conversation/sessionRefs");
  const prompt = incomingPrompt("[inbox] New messages from other agents in 1 thread.", {
    client: "acpmux",
    _meta: {
      provenance: {
        kind: "inbox_notice",
        threads: [
          {
            threadId: "from:vm-1/lane-a",
            from: ["coord"],
            new: 1,
            preview: "done",
            promptIds: ["p1"],
            sender: {
              label: "coord",
              verification: "verified",
              relay: { by: "lane-gh", machine: "vm-1", session: "lane-a" },
            },
          },
        ],
      },
    },
  });
  if (prompt?.kind !== "inbox") throw new Error("not an inbox notice");
  const row: AcpmuxRow = { id: "inbox-relay", version: 1, at: 1, kind: "user", incoming: prompt };
  const child = flattenInboxRows([row]).find((r) => r.inboxThread)!;
  const opened: string[] = [];
  refs.resetSessionRefs();
  // acpmux has not answered yet: the click opens by what the chip asks for.
  refs.setSessionRefResolver(() => new Promise(() => undefined));
  try {
    const container = await render(
      <MessageRow row={child} onToggleActivity={() => undefined} expanded={false} />,
      (window) => {
        (window as unknown as Record<string, unknown>).cmuxAcpmuxActions = {
          "chat.offer.open": async ({ sessionId }: { sessionId: string }) => void opened.push(sessionId),
          "chat.inbox.thread": async () => [],
        };
      },
    );
    const chip = container.querySelector<HTMLElement>(".cv-received__from--open");
    expect(chip).not.toBeNull();
    await act(async () => chip!.click());
    expect(opened).toEqual(["vm-1/lane-a"]);
  } finally {
    refs.setSessionRefResolver(undefined);
    refs.resetSessionRefs();
  }
});

test("two preview-only notices from one sender whose previews clean to nothing both keep their row", async () => {
  // Review of cmux#37653 (F1 at b2dc1923): a preview cut inside the broker's head cleans to "", and
  // with two prompt ids a thread names no single msgId, so the duplicate check keyed both on
  // sender + "" and dropped the second thread. Each delivery is its prompt ids.
  const { flattenInboxRows } = await import("../src/agent-session/acpmux/conversation/laneNoticeBatches");
  const notice = (id: string, threadId: string, promptIds: string[], at: number): AcpmuxRow => {
    const prompt = incomingPrompt("[inbox] New messages from other agents in 1 thread.", {
      client: "acpmux",
      _meta: {
        provenance: {
          kind: "inbox_notice",
          threads: [
            {
              threadId,
              from: ["vm/lane"],
              new: promptIds.length,
              preview: relayed("The whole message.", "12345678", "vm/lane").slice(0, 120),
              promptIds,
            },
          ],
        },
      },
    });
    if (prompt?.kind !== "inbox") throw new Error("not an inbox notice");
    return { id, version: 1, at, kind: "user", incoming: prompt };
  };
  const rows = [notice("n1", "pr:1", ["p1", "p2"], 1), notice("n2", "pr:2", ["p3", "p4"], 2)];
  const threads = flattenInboxRows(rows)
    .filter((r) => r.inboxThread)
    .map((r) => r.inboxThread!.threadId);
  expect(threads).toEqual(["pr:1", "pr:2"]);
  // The same thread delivered twice (the same prompt ids) still shows once.
  const again = flattenInboxRows([notice("n1", "pr:1", ["p1", "p2"], 1), notice("n3", "pr:1", ["p1", "p2"], 3)])
    .filter((r) => r.inboxThread)
    .map((r) => r.inboxThread!.threadId);
  expect(again).toEqual(["pr:1"]);
});

// Opening a received line or an inbox thread keeps the line as it was, as the disclosure line these
// rows drew before kept its label: the chevron after the words stays on its pixel instead of jumping
// back to the chip (gallery health, agent-pane.inbox-notice#one-open, whose layout-shift row is 0).
// A received line keeps its first line; an inbox thread's line carries none in either state, its
// text in the card under it (Leo, 2026-11-09). Leo, 2026-11-04: "we move all our affected, possibly
// affected elements in the cohesive way".
test("an opened received line or inbox thread keeps its line as it was, so its chevron does not move", async () => {
  const message = received(
    relayed("Matrix run 14 is green.\n\nNext: the cold-start numbers.", "56d7d1c5", "vm/lane-a"),
    { verification: "verified", harness: "codex", relay: { by: "lane-gh broker", machine: "vm" } },
    "vm/lane-a",
  );
  const line = await render(<IncomingMessageLine id="m-keep" message={message} onOpen={() => undefined} />);
  await openAll(line);
  expect(line.querySelector(".cv-agentmsg[data-open]")).not.toBeNull();
  expect(line.querySelector(".cv-agentmsg__preview")?.textContent).toContain("Matrix run 14 is green.");

  const notice: InboxNotice = {
    threads: [
      {
        threadId: "pr:9",
        label: "#9",
        from: ["lane-a"],
        count: 1,
        preview: "Rebase on main.",
        blocker: false,
        promptIds: ["a1"],
      },
    ],
  };
  const thread = await render(<InboxNoticeCard rowId="r-keep" notice={notice} onOpen={() => undefined} />);
  expect(thread.querySelector(".cv-agentmsg__preview")?.textContent).toBe("");
  expect(thread.querySelector(".cv-agentmsg__card")?.textContent).toContain("Rebase on main.");
  await openAll(thread);
  expect(thread.querySelector(".cv-agentmsg[data-open]")).not.toBeNull();
  expect(thread.querySelector(".cv-agentmsg__preview")?.textContent).toBe("");
  expect(thread.querySelector(".cv-agentmsg__card")?.textContent).toContain("Rebase on main.");
});
