// Round 6 package "cards" (cmux#37736 F3 and its area): a Chief's question and permission parts,
// link previews, places, work parts and mentions are what the native Home drew, not the part's type
// name or a session id. The permission card answers through the app on a click and shows the native
// notes; Copy copies a link's address and a place's coordinates.
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

const { message: wireMessage } = await import("../src/pages/home-channels/daemonHome");
const { partText } = await import("../src/pages/home-channels/model");
const { transcriptRows } = await import("../src/pages/home-messages/transcript/rows");
const { TranscriptRowView, bubbleCopyText } = await import("../src/pages/home-messages/transcript/TranscriptRows");
const { createTranscriptStrings } = await import("../src/pages/home-messages/transcript/strings");
const { ApprovalDecisions, approvalDigest } = await import("../src/pages/home-messages/cards/approval/approval");
type HomeConversation = import("../src/pages/home-channels/types").HomeConversation;
type HomeMessage = import("../src/pages/home-channels/types").HomeMessage;
type HomeParticipant = import("../src/pages/home-channels/types").HomeParticipant;
type Row = import("../src/pages/home-messages/transcript/rows").TranscriptRow;

const DIGEST = "a".repeat(64);
const REQUEST = JSON.stringify({
  toolCall: { title: "Bash", rawInput: { command: "printf approval-test" } },
  options: [
    { optionId: "yes", kind: "allow_once" },
    { optionId: "no", kind: "reject_once" },
  ],
});
const approvalWire = (state: Record<string, unknown> = { kind: "pending" }) => ({
  type: "question",
  harness: "chief",
  session: "local/test-subagent",
  permission: "perm-1",
  items: [
    {
      id: `approval:${DIGEST}`,
      prompt: "a1 needs permission to run Bash",
      options: [
        { id: "allow", label: "Allow once", preview: { text: REQUEST, format: "monospace" } },
        { id: "deny", label: "Deny" },
      ],
      multi_select: false,
      allows_other: false,
    },
  ],
  state,
});
const wire = (parts: unknown[], author = "agent_mux", seq = 7) =>
  wireMessage({
    id: `m${seq}`,
    conversation: "c1",
    seq,
    author,
    created_at: "2026-11-07T10:00:00.000Z",
    client_msg_id: `k${seq}`,
    parts,
    reactions: [],
  });

const chief = { id: "agent_mux", kind: "agent" as const, name: "Chief", chief: true };
const me = { id: "user_local", kind: "human" as const, name: "Me", chief: false };
const ana = { id: "ana", kind: "human" as const, name: "Ana", chief: false };
function conversation(owner: "local" | "cloud" = "local"): HomeConversation {
  return {
    id: "c1",
    owner,
    title: "",
    kind: "chief",
    participants: [me, chief, ana],
    lastSeq: 7,
    rev: 1,
    updatedAt: 0,
    unread: 0,
    mentions: 0,
    muted: false,
    pinned: false,
  };
}
const bubbles = (messages: HomeMessage[], owner: "local" | "cloud" = "local") =>
  transcriptRows({ me: me.id, conversation: conversation(owner), messages }, Date.parse("2026-11-07T12:00:00Z")).filter(
    (row): row is Extract<Row, { kind: "bubble" }> => row.kind === "bubble",
  );

test("the daemon's question, link preview and place parts keep their fields", () => {
  const message = wire([
    approvalWire(),
    {
      type: "link_preview",
      url: "https://example.com/a",
      title: "Example",
      site: "example.com",
      image: { hash: "h1", mime_type: "image/jpeg", byte_count: 9 },
    },
    { type: "location", latitude: 37.33, longitude: -122.01, label: "Apple Park" },
  ]);
  const [question, link, place] = message.parts;
  expect(question?.type).toBe("question");
  if (question?.type !== "question") throw new Error("question");
  expect(question.permission).toBe("perm-1");
  expect(question.items[0]?.options.map((option) => option.id)).toEqual(["allow", "deny"]);
  expect(question.items[0]?.allowsOther).toBe(false);
  expect(approvalDigest(question)).toBe(DIGEST);
  expect(link).toEqual({
    type: "link_preview",
    url: "https://example.com/a",
    title: "Example",
    site: "example.com",
    image: { hash: "h1", mimeType: "image/jpeg", byteCount: 9 },
  });
  expect(place).toEqual({ type: "location", latitude: 37.33, longitude: -122.01, label: "Apple Park" });
  // Plain text as the native `plainText`: never the part's type name.
  expect(message.parts.map(partText)).toEqual([
    "a1 needs permission to run Bash\n1. Allow once\n2. Deny",
    "Example",
    "Apple Park",
  ]);
});

test("a work part with no preview is no bubble; with one it shows the preview, never the session", () => {
  const marker = wire([{ type: "work", session: "optchat-2e448bc2-8525", status: "done" }], "agent_mux", 1);
  const preview = wire(
    [{ type: "work", session: "optchat-2e448bc2-8525", status: "done", preview: "Landed 3 commits" }],
    "agent_mux",
    2,
  );
  expect(partText(marker.parts[0]!)).toBe("");
  const rows = bubbles([marker, preview]);
  expect(rows.map((row) => row.message.id)).toEqual(["m2"]);
  expect(bubbleCopyText(rows[0]!)).toBe("Landed 3 commits");
});

test("only a local Chief's permission question is a card", () => {
  const local = bubbles([wire([approvalWire()])]);
  expect(local[0]?.approval).toBe(true);
  expect(bubbles([wire([approvalWire()])], "cloud")[0]?.approval).toBeUndefined();
  expect(bubbles([wire([approvalWire()], "ana")])[0]?.approval).toBeUndefined();
  expect(bubbleCopyText(local[0]!), "a permission card copies nothing").toBe("");
});

function render(
  row: Extract<Row, { kind: "bubble" }>,
  decisions?: InstanceType<typeof ApprovalDecisions>,
  onOpen = (_: string) => {},
) {
  const host = installDom();
  const strings = createTranscriptStrings(["en"]);
  root = createRoot(host);
  act(() =>
    root!.render(
      <TranscriptRowView
        row={row}
        me={me.id}
        strings={strings}
        now={0}
        people={
          new Map<string, HomeParticipant>([
            [chief.id, chief],
            [ana.id, ana],
          ])
        }
        actions={{
          ...(decisions ? { approvals: decisions } : {}),
          links: { fetchPreview: async () => undefined, onOpen },
        }}
      />,
    ),
  );
  return host;
}

const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
const buttons = (host: HTMLElement) => [...host.querySelectorAll("button")].map((button) => button.textContent);

test("Allow sends the decision for this card and shows the app's note", async () => {
  const calls: unknown[] = [];
  let answer!: (value: unknown) => void;
  const decisions = new ApprovalDecisions((params) => {
    calls.push(params);
    return new Promise((resolve) => (answer = resolve));
  });
  const row = bubbles([wire([approvalWire()])])[0]!;
  const host = render(row, decisions);
  expect(host.textContent).toContain("a1 needs permission to run Bash");
  expect(host.textContent).toContain('"command": "printf approval-test"');
  expect(buttons(host)).toEqual(["Deny", "Allow"]);
  const allow = [...host.querySelectorAll("button")].find((button) => button.textContent === "Allow")!;
  await act(async () => allow.click());
  expect(calls).toEqual([{ conversation: "c1", message: "m7", seq: 7, partIndex: 0, allow: true }]);
  expect(
    [...host.querySelectorAll("button")].every((button) => button.disabled),
    "busy: no second decision",
  ).toBe(true);
  await act(async () => allow.click());
  expect(calls.length).toBe(1);
  await act(async () => answer({ note: "allowed", ended: true }));
  await settle();
  expect(host.textContent).toContain("Allowed");
  expect(buttons(host)).toEqual([]);
});

test("a refused or failed decision says so and keeps the card answerable", async () => {
  const decisions = new ApprovalDecisions(async () => {
    throw new Error("cmux.page.user_only");
  });
  const host = render(bubbles([wire([approvalWire()])])[0]!, decisions);
  const deny = [...host.querySelectorAll("button")].find((button) => button.textContent === "Deny")!;
  await act(async () => deny.click());
  await settle();
  expect(host.textContent).toContain("Could not answer. Try again.");
  expect(buttons(host)).toEqual(["Deny", "Allow"]);
  expect([...host.querySelectorAll("button")].some((button) => button.disabled)).toBe(false);
});

test("an answered or cancelled card shows where it stands, without buttons", () => {
  const answered = render(
    bubbles([
      wire([
        approvalWire({
          kind: "answered",
          answer: { selections: { [`approval:${DIGEST}`]: { option_ids: ["deny"] } } },
        }),
      ]),
    ])[0]!,
    new ApprovalDecisions(async () => ({})),
  );
  expect(answered.textContent).toContain("Denied");
  expect(answered.textContent).not.toContain("printf approval-test");
  expect(buttons(answered)).toEqual([]);
  act(() => root!.unmount());
  root = undefined;
  const cancelled = render(
    bubbles([wire([approvalWire({ kind: "cancelled" })])])[0]!,
    new ApprovalDecisions(async () => ({})),
  );
  expect(cancelled.textContent).toContain("This approval is no longer open");
});

test("a link preview draws its card and Copy copies its address; a place its coordinates", () => {
  const opened: string[] = [];
  const [link, place] = bubbles([
    wire([{ type: "link_preview", url: "https://example.com/a", title: "Example", site: "example.com" }], "ana", 1),
    wire([{ type: "location", latitude: 37.33, longitude: -122.01, label: "Apple Park" }], "ana", 2),
  ]);
  const host = render(link!, undefined, (href) => opened.push(href));
  const anchor = host.querySelector<HTMLAnchorElement>(".hm-part-link")!;
  expect(anchor.textContent).toBe("Exampleexample.com");
  act(() => anchor.click());
  expect(opened).toEqual(["https://example.com/a"]);
  expect(bubbleCopyText(link!)).toBe("https://example.com/a");
  act(() => root!.unmount());
  root = undefined;
  const placed = render(place!);
  expect(placed.querySelector(".hm-part-location")?.textContent).toBe("Apple Park37.33, -122.01");
  expect(bubbleCopyText(place!)).toBe("Apple Park\n37.33, -122.01");
});

test("a mention is drawn as a highlighted run of the text it names", () => {
  const message = wire(
    [{ type: "text", text: "hey @Ana look", runs: [{ start: 4, length: 4, mention: "ana" }] }],
    "user_local",
    3,
  );
  const host = render(bubbles([message])[0]!);
  const mention = host.querySelector(".mt-mention");
  expect(mention?.textContent).toBe("@Ana");
  expect(host.querySelector(".mt-text")?.textContent).toBe("hey @Ana look");
});

test("a plain question shows its prompt and numbered options", () => {
  const question = approvalWire();
  (question.items[0] as Record<string, unknown>).id = "q1";
  const host = render(bubbles([wire([{ ...question, harness: "claude" }], "agent_mux", 4)])[0]!);
  expect(host.querySelector(".mt-text")?.textContent).toBe("a1 needs permission to run Bash\n1. Allow once\n2. Deny");
  expect(buttons(host)).toEqual([]);
});

test("a part the page does not draw shows what native did: a widget's fallback, else its link, else its type", () => {
  const texts = wire([
    { type: "widget", app: "com.example.weather", fallback: "Sunny, 21°C", props: {} },
    { type: "widget", fallback: "no app" },
    { type: "poll", url: "https://example.com/poll/1" },
    { type: "poll" },
  ]).parts.map((part) => partText(part));
  // Chat widgets are gone: a stored widget part reads as its fallback (Swift HomeWireMapping).
  expect(texts).toEqual(["Sunny, 21°C", "no app", "https://example.com/poll/1", "poll"]);
});

test("a stored chat widget draws as a plain text bubble, never a widget card", () => {
  // Chat widgets are gone (Nov 9: "remove widgets completely").
  const host = render(
    bubbles([wire([{ type: "widget", app: "cmux/pr-card", widget: "cmux.chat.widget/1", fallback: "PR #7: open", props: { number: 7 } }], "agent_mux", 4)])[0]!,
  );
  expect(host.querySelector(".hm-widget, [data-widget]")).toBeNull();
  expect(host.querySelector(".mt-text")?.textContent).toBe("PR #7: open");
});
