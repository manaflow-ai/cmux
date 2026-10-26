// l10n-allow-file: test fixture asks and chat names, not shipped UI.
// The home's inbox (HomeInbox.tsx, Leo 2026-10-26: "find the needle in the haystack"): every other
// chat's open ask, answered in place, and nothing answered that the person did not answer.
// - A row's Allow once and Deny send that ask's own option, for that ask's chat, once.
// - A refused answer says so on its row, and the row answers again.
// - ⌥⌘1 and ⌥⌘3 answer the first ask that can be answered in place, and only it.
// - A question, a held pair and another computer's chat have no answers here: the row opens the chat.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxPermission } from "../src/agent-session/acpmux/model";
import type { WatchedAsk } from "../src/agent-session/acpmux/needsYou/model";

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
    permission: { permissionId: "p-cache", title: "Delete the cache", pending: true, options: options("p-cache") },
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

type Sent = { sessionId: string; permissionId?: string; optionId: string; settle(ok: boolean): void };

async function mount() {
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
        onAnswer={(item, choice) =>
          new Promise<void>((resolve, reject) =>
            sent.push({
              sessionId: item.sessionId,
              permissionId: item.permissionId,
              optionId: choice.id,
              settle: (ok) => (ok ? resolve() : reject(new Error("refused"))),
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
  const event = (name: string) => act(async () => void dom.window.dispatchEvent(new dom.window.Event(name)));
  const settle = (index: number, ok: boolean) =>
    act(async () => {
      sent[index]!.settle(ok);
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
  await inbox.settle(0, true);
  expect(inbox.host.textContent).not.toContain("Delete the cache");
  await inbox.unmount();
});

test("a refused answer says so on its row, and the row answers again", async () => {
  const inbox = await mount();
  await inbox.click(inbox.rowOf("Run the payment tests"), allow);
  await inbox.settle(0, false);
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
  await inbox.settle(0, true);
  await inbox.event("cmux-acpmux-permissionAllowOnce");
  expect(inbox.sent.at(-1)?.optionId).toBe("p-cache-yes");
  await inbox.unmount();
});
