// l10n-allow-file: test fixture asks and chat names, not shipped UI.
// The home's inbox (HomeInbox.tsx, Leo 2026-10-26: "find the needle in the haystack"): every other
// chat's open ask, answered in place, and nothing answered that the person did not answer.
// - A row's Allow once and Deny send that ask's own option, for that ask's chat, once.
// - A refused answer says so on its row, and the row answers again.
// - ⌥⌘1 and ⌥⌘3 answer the first ask that can be answered in place, and only it, and nothing
//   while the home's own chat shows a card that takes them.
// - Two answers in one tick send one; a host that opens the chat instead keeps the row.
// - An approval shows the command it asks about.
// - A question, a held pair and another computer's chat have no answers here: the row opens the chat.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxPermission } from "../src/agent-session/acpmux/model";
import type { HomeInboxOutcome } from "../src/agent-session/acpmux/HomeInbox";
import type { NeedsYouItem, WatchedAsk } from "../src/agent-session/acpmux/needsYou/model";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const globalKeys = ["window", "document", "navigator", "HTMLElement", "Node", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = globalKeys.map((key) => [key, key in globals, globals[key]] as const);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Node: dom.window.Node,
  IS_REACT_ACT_ENVIRONMENT: true,
});
const domClasses = Object.getOwnPropertyNames(dom.window).filter(
  (key) => /^(HTML|SVG|CSS|Document|Event|KeyboardEvent)/.test(key) && !(key in globals),
);
for (const key of domClasses) globals[key] = (dom.window as unknown as Record<string, unknown>)[key];
afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) globals[key] = value;
    else delete globals[key];
  }
  for (const key of domClasses) delete globals[key];
  dom.window.close();
});

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { HomeLists } = await import("../src/agent-session/acpmux/HomeLists");
const { answerFromHome } = await import("../src/agent-session/acpmux/HomeInbox");
const { NativeError } = await import("../src/agent-session/acpmux/nativeError");
const { callPageHost } = await import("../src/agent-session/acpmux/pageHost");
const { pageError } = await import("../src/pages/shared/pageClient");
const { translate } = await import("../src/agent-session/acpmux/i18n");
const { session } = await import("../src/gallery/fixtures/acpmux");
const { minutesAgo } = await import("../src/gallery/clock");

const options = (id: string): AcpmuxPermission["options"] => [
  { id: `${id}-yes`, name: "Yes", kind: "allow_once", allow: true },
  { id: `${id}-always`, name: "Always", kind: "allow_always", allow: true },
  { id: `${id}-no`, name: "No", kind: "reject_once", allow: false },
];
const sessions = [
  session({ sessionId: "home", updatedAt: minutesAgo(0) }),
  session({ sessionId: "tests", title: "Payment tests", pendingPermissions: 1, updatedAt: minutesAgo(2) }),
  session({ sessionId: "cache", title: "Build cache", pendingPermissions: 1, updatedAt: minutesAgo(5) }),
  session({ sessionId: "auth", title: "Sign-in", pendingPermissions: 1, updatedAt: minutesAgo(1) }),
  session({
    sessionId: "remote",
    title: "Release notes",
    peer: "build-box",
    host: "build-box",
    indicator: "input",
    pendingPermissions: 1,
    updatedAt: minutesAgo(9),
  }),
];
const asks: WatchedAsk[] = [
  {
    sessionId: "tests",
    at: minutesAgo(2),
    permission: { permissionId: "p-tests", title: "Run the payment tests", pending: true, options: options("p-tests") },
  },
  {
    sessionId: "cache",
    at: minutesAgo(5),
    permission: {
      permissionId: "p-cache",
      title: "Delete the cache",
      command: "rm -rf .cache",
      pending: true,
      options: options("p-cache"),
    },
  },
  {
    sessionId: "auth",
    at: minutesAgo(1),
    permission: {
      permissionId: "p-auth",
      pending: true,
      options: options("p-auth"),
      question: {
        id: "p-auth",
        source: { harness: "claude", session: "auth", permission: "p-auth", answerOption: "p-auth-yes" },
        items: [
          {
            id: "q0",
            header: "Auth",
            prompt: "Which sign-in?",
            options: [
              { id: "OAuth", label: "OAuth" },
              { id: "Passkeys", label: "Passkeys" },
            ],
            multiSelect: false,
            allowsOther: true,
          },
        ],
        state: { kind: "pending" },
      },
    },
  },
  {
    sessionId: "home",
    at: minutesAgo(0),
    permission: { permissionId: "p-home", title: "Edit App.tsx", pending: true, options: options("p-home") },
  },
];

type Sent = {
  sessionId: string;
  permissionId?: string;
  optionId: string;
  settle(outcome: HomeInboxOutcome | "refused"): void;
};

async function mount({ shortcuts }: { shortcuts?: boolean } = {}) {
  const host = dom.window.document.createElement("div");
  dom.window.document.body.append(host);
  const root = createRoot(host);
  const sent: Sent[] = [];
  const opened: string[] = [];
  await act(async () =>
    root.render(
      <HomeLists
        sessions={sessions}
        currentId="home"
        asks={asks}
        onSelect={(id) => opened.push(id)}
        shortcuts={shortcuts}
        onAnswer={(item, choice) =>
          new Promise<HomeInboxOutcome>((resolve, reject) =>
            sent.push({
              sessionId: item.sessionId,
              permissionId: item.permissionId,
              optionId: choice.id,
              settle: (outcome) => (outcome === "refused" ? reject(new Error("refused")) : resolve(outcome)),
            }),
          )
        }
      />,
    ),
  );
  const rows = () => [...host.querySelectorAll(".acpmux-home-inbox-row")];
  const rowOf = (text: string) => rows().find((row) => row.textContent?.includes(text))!;
  const click = (row: Element, label: string) =>
    act(async () => {
      [...row.querySelectorAll("button")].find((b) => b.getAttribute("aria-label") === label)!.click();
    });
  const event = (...names: string[]) =>
    act(async () => {
      for (const name of names) dom.window.dispatchEvent(new dom.window.Event(name));
    });
  const settle = (index: number, outcome: HomeInboxOutcome | "refused") =>
    act(async () => {
      sent[index]!.settle(outcome);
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  return { host, sent, opened, rows, rowOf, click, event, settle, unmount: () => act(async () => root.unmount()) };
}

const allow = translate("permission.allowOnce");
const deny = translate("permission.deny");

test("every other chat's ask is a row, newest first, and the current chat's is not", async () => {
  const inbox = await mount();
  expect(inbox.rows().map((row) => row.getAttribute("data-kind"))).toEqual([
    "decision",
    "approval",
    "approval",
    "input",
  ]);
  expect(inbox.host.textContent).not.toContain("Edit App.tsx");
  // A question and another computer's chat have no answers here; their row opens the chat.
  expect(inbox.rowOf("Which sign-in?").querySelector(".acpmux-home-inbox-answers")).toBeNull();
  await act(async () => (inbox.rowOf("Release notes").querySelector(".acpmux-home-inbox-open") as HTMLElement).click());
  expect(inbox.opened).toEqual(["remote"]);
  await inbox.unmount();
});

test("a row's answer sends that ask's own option for its chat, once, and the row leaves", async () => {
  const inbox = await mount();
  const row = inbox.rowOf("Delete the cache");
  await inbox.click(row, deny);
  await inbox.click(row, allow);
  expect(inbox.sent.map(({ sessionId, permissionId, optionId }) => [sessionId, permissionId, optionId])).toEqual([
    ["cache", "p-cache", "p-cache-no"],
  ]);
  await inbox.settle(0, "answered");
  expect(inbox.host.textContent).not.toContain("Delete the cache");
  await inbox.unmount();
});

test("a refused answer says so on its row, and the row answers again", async () => {
  const inbox = await mount();
  await inbox.click(inbox.rowOf("Run the payment tests"), allow);
  await inbox.settle(0, "refused");
  const row = inbox.rowOf("Run the payment tests");
  expect(row.querySelector('[role="alert"]')?.textContent).toBe(translate("permission.error.refused"));
  await inbox.click(row, allow);
  expect(inbox.sent.map(({ optionId }) => optionId)).toEqual(["p-tests-yes", "p-tests-yes"]);
  await inbox.unmount();
});

test("the permission shortcuts answer the first ask answerable in place, and only it", async () => {
  const inbox = await mount();
  // The question is newest, but it has no answers here: the payment tests' row takes the keys.
  await inbox.event("cmux-acpmux-permissionDeny");
  await inbox.event("cmux-acpmux-permissionAllowOnce");
  expect(inbox.sent.map(({ optionId }) => optionId)).toEqual(["p-tests-no"]);
  // Once that ask is answered and gone, the next row takes them.
  await inbox.settle(0, "answered");
  await inbox.event("cmux-acpmux-permissionAllowOnce");
  expect(inbox.sent.at(-1)?.optionId).toBe("p-cache-yes");
  await inbox.unmount();
});

test("an approval shows the command it asks about, and its answers name it", async () => {
  const inbox = await mount();
  const row = inbox.rowOf("Delete the cache");
  const detail = row.querySelector(".acpmux-home-inbox-detail");
  expect(detail?.textContent).toBe("rm -rf .cache");
  expect(detail?.hasAttribute("data-code")).toBe(true);
  expect(row.querySelector("fieldset")?.getAttribute("aria-label")).toContain("rm -rf .cache");
  await inbox.unmount();
});

test("two answers in one tick send one", async () => {
  const inbox = await mount();
  await inbox.event("cmux-acpmux-permissionAllowOnce", "cmux-acpmux-permissionDeny");
  expect(inbox.sent.map(({ optionId }) => optionId)).toEqual(["p-tests-yes"]);
  await inbox.unmount();
});

test("an answer the host can't give here opens the chat and keeps its row", async () => {
  const inbox = await mount();
  await inbox.click(inbox.rowOf("Run the payment tests"), allow);
  await inbox.settle(0, "opened");
  const row = inbox.rowOf("Run the payment tests");
  expect(row.querySelector('[role="alert"]')).toBeNull();
  await inbox.click(row, allow);
  expect(inbox.sent).toHaveLength(2);
  await inbox.unmount();
});

test("answerFromHome: answered, opened on unsupported, and any other refusal rejects", async () => {
  const item = { sessionId: "tests", permissionId: "p-tests" } as NeedsYouItem;
  const choice = { id: "p-tests-yes", label: "Allow once", tone: "allow" } as const;
  const calls: unknown[] = [];
  const opened: string[] = [];
  const open = (id: string) => void opened.push(id);
  const answer = (fails?: string) =>
    answerFromHome(
      async (method, params) => {
        calls.push([method, params]);
        if (fails) throw new NativeError({ code: fails });
      },
      item,
      choice,
      open,
    );
  expect(await answer()).toBe("answered");
  expect(calls[0]).toEqual([
    "chat.asks.answer",
    { sessionId: "tests", permissionId: "p-tests", optionId: "p-tests-yes" },
  ]);
  expect(await answer("unsupported")).toBe("opened");
  expect(opened).toEqual(["tests"]);
  await expect(answer("refused")).rejects.toThrow();
  await expect(answer("native.invalid_request")).rejects.toThrow();
  expect(opened).toHaveLength(1);
});

test("the shortcuts answer nothing here while the home's own chat shows its card, or after unmount", async () => {
  const card = await mount({ shortcuts: false });
  await card.event("cmux-acpmux-permissionAllowOnce", "cmux-acpmux-permissionDeny");
  expect(card.sent).toEqual([]);
  await card.unmount();
  const gone = await mount();
  await gone.unmount();
  await gone.event("cmux-acpmux-permissionAllowOnce");
  expect(gone.sent).toEqual([]);
});

test("on the shared page host, a host without the op opens the chat (its unknown_op, as callPageHost reports it)", async () => {
  const item = { sessionId: "tests", permissionId: "p-tests" } as NeedsYouItem;
  const choice = { id: "p-tests-yes", label: "Allow once", tone: "allow" } as const;
  const opened: string[] = [];
  const page = {
    call: async () => {
      throw pageError("cmux.protocol.unknown_op", "unknown op cmux.agent.chat.asks.answer");
    },
  } as unknown as Parameters<typeof callPageHost>[0];
  const outcome = await answerFromHome(
    (method, params) => callPageHost(page, method, params),
    item,
    choice,
    (id) => void opened.push(id),
  );
  expect(outcome).toBe("opened");
  expect(opened).toEqual(["tests"]);
});

test("on the shared page host, a malformed request still says refused (invalid_params opens nothing)", async () => {
  const item = { sessionId: "tests", permissionId: "p-tests" } as NeedsYouItem;
  const choice = { id: "p-tests-yes", label: "Allow once", tone: "allow" } as const;
  const opened: string[] = [];
  const page = {
    call: async () => {
      throw pageError("cmux.protocol.invalid_params", "bad params");
    },
  } as unknown as Parameters<typeof callPageHost>[0];
  await expect(
    answerFromHome(
      (method, params) => callPageHost(page, method, params),
      item,
      choice,
      (id) => void opened.push(id),
    ),
  ).rejects.toThrow();
  expect(opened).toEqual([]);
});
