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
import { SubagentDoneLine, DoneReportLookContext } from "../src/agent-session/acpmux/subagents/SubagentDoneLine";
import { SubagentNavContext } from "../src/agent-session/acpmux/subagents/SubagentGroup";
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

async function render(node: ReactNode): Promise<HTMLElement> {
  const container = installDom();
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
  // The codex mark, not the neutral robot every unknown sender wears.
  expect(container.querySelector(".cv-received__mark")).not.toBeNull();
  expect(container.querySelector(".cv-received__mark [data-agent-tone]")).toBeNull();
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
  expect(marker?.getAttribute("title")).toBe("Sender not verified");
  expect(container.innerHTML).not.toContain("self-declared");
  expect(container.innerHTML).not.toContain("unauthenticated");
  expect(container.textContent).toContain("gcp-codex-swarm-05/cloud-start-matrix");
  expect(container.textContent).not.toContain("Received message from");
});

test("an older acpmux's sender with only the suffix (no record) is marked unverified, the name bare", async () => {
  const message = received("hello", {}, `lane-x ${SUFFIX}`);
  expect(message.name).toBe("lane-x");
  expect(message.unverified).toBe(true);
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

test("a notice thread rendered: the marker, the first line as its preview, the whole message opened", async () => {
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
  expect(container.querySelector(".cv-agentmsg__preview")?.textContent).toContain("Matrix run 14 is green.");
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
  expect(container.querySelector(".cv-agentmsg__preview")?.textContent).toContain("The whole message.");
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
  const { MessageGroupHover, hoverMessages } =
    await import("../src/agent-session/acpmux/conversation/MessageGroupHover");
  const list: IncomingMessage[] = Array.from({ length: 7 }, (_, index) => ({
    name: `gcp-agent-lane-3/lane-${index} ${SUFFIX}`,
    text: relayed(`message ${index}\nsecond line ${index}`, `abcd000${index}`, `gcp-agent-lane-3/lane-${index}`),
    raw: "",
    ...(index === 6 && { unverified: true as const }),
  }));
  const container = await render(<MessageGroupHover messages={hoverMessages(list)} />);
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
