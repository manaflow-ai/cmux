// The Share dialog's big rows are one button each (Leo, 2026-11-07: "ok we need a way to turn this back
// to restricted" and "if you have these big blocks you need to have the blocks be clickable. like
// google sign-in those huge "buttons""). General access, with Anyone with the link on, is a row whose
// press opens Restricted / Anyone with the link, and Restricted turns the link off; each person's row
// opens their role, with Remove beside it.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { ShareDialogBody } from "./ShareDialog";
import { translate } from "../i18n";
import type { ShareView } from "./shareState";
import { settleReact } from "../../../../test/support/domTeardown";
import { actTurn, until } from "../../../../test/support/until";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>");
  const requestAnimationFrame = (callback: FrameRequestCallback) =>
    setTimeout(() => callback(Date.now()), 0) as unknown as number;
  const cancelAnimationFrame = (handle: number) => clearTimeout(handle);
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "getComputedStyle",
    "requestAnimationFrame",
    "cancelAnimationFrame",
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
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame,
    cancelAnimationFrame,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root)
    await act(async () => {
      root!.unmount();
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  root = undefined;
  await new Promise((resolve) => setTimeout(resolve, 0));
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const settle = () =>
  act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });

const shared: ShareView = {
  people: [{ account: "@sam", role: "view", joined: false }],
  general: "anyone",
  links: [],
  inviteUrl: "https://share.example.com/i/1",
  guestsNow: 0,
};

async function render(calls: string[]) {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(
      <ShareDialogBody
        chat="Add retries"
        view={shared}
        onInvite={() => {}}
        onRole={(account, role) => calls.push(`role ${account} ${role}`)}
        onRemove={(account) => calls.push(`remove ${account}`)}
        onGeneral={(access) => calls.push(`general ${access}`)}
        onCopy={() => {}}
        onDone={() => {}}
      />,
    );
  });
  return container;
}

test("General access is one button the size of its block, and Restricted turns the link off", async () => {
  const calls: string[] = [];
  const container = await render(calls);
  const row = container.querySelector<HTMLButtonElement>(".share-dialog__general");
  expect(row?.tagName).toBe("BUTTON");
  expect(row?.getAttribute("aria-haspopup")).toBe("menu");
  // The mark, the access, its hint and the link's role are all inside the one target.
  expect(row?.querySelector(".share-dialog__general-mark")).not.toBeNull();
  expect(row?.textContent).toContain(translate("share.anyone"));
  expect(row?.textContent).toContain(translate("share.anyoneHint"));
  await act(async () => row!.click());
  await settle();
  const restricted = [...document.querySelectorAll<HTMLElement>('[role="menuitemradio"]')].find((item) =>
    item.textContent?.includes(translate("share.restricted")),
  );
  expect(restricted).toBeDefined();
  await act(async () => restricted!.click());
  await settle();
  expect(calls).toEqual(["general restricted"]);
});

// A signed-in guest on Anyone with the link may send (cmux#38102); a guest nobody signed in watches.
// The row says so: its hint names both, and its role is the People rows' "Can send", never "Viewer".
test("Anyone with the link says signed-in people can send and others can view", async () => {
  const container = await render([]);
  const row = container.querySelector<HTMLButtonElement>(".share-dialog__general")!;
  expect(row.querySelector(".share-dialog__hint")?.textContent).toBe(
    "Signed-in people can send messages; others can view",
  );
  const role = row.querySelector(".share-dialog__fixed-role")?.textContent;
  expect(role).toBe(translate("share.role.talk"));
  expect(role).not.toBe(translate("share.role.view"));
});

test("a person's row is one button for their role, with Remove its own button beside it", async () => {
  const calls: string[] = [];
  const container = await render(calls);
  const person = container.querySelector<HTMLElement>(".share-dialog__people li:nth-child(2)")!;
  const row = person.querySelector<HTMLButtonElement>(".share-dialog__person-pick");
  expect(row?.tagName).toBe("BUTTON");
  expect(row?.textContent).toContain("@sam");
  expect(row?.textContent).toContain(translate("share.role.view"));
  // Remove is not inside the row's button (no button in a button).
  expect(row?.querySelector("button")).toBeNull();
  await act(async () => row!.click());
  await settle();
  const talk = [...document.querySelectorAll<HTMLElement>('[role="menuitemradio"]')].find((item) =>
    item.textContent?.includes(translate("share.role.talk")),
  );
  await act(async () => talk!.click());
  await settle();
  expect(calls).toEqual(["role @sam talk"]);
});

// An invite nobody opened yet says so under the name; one in the chat now says that instead.
test("a pending invitee's row says they haven't opened it yet", async () => {
  const container = installDom();
  const view: ShareView = {
    ...shared,
    people: [
      { account: "@new", role: "view", joined: false, opened: false },
      { account: "@here", role: "talk", joined: true, opened: true },
      { account: "@left", role: "view", joined: false, opened: true },
    ],
  };
  await act(async () => {
    root = createRoot(container);
    root.render(
      <ShareDialogBody
        chat="Add retries"
        view={view}
        onInvite={() => {}}
        onRole={() => {}}
        onRemove={() => {}}
        onGeneral={() => {}}
        onCopy={() => {}}
        onDone={() => {}}
      />,
    );
  });
  const hints = [...container.querySelectorAll(".share-dialog__people li")].map(
    (row) => row.querySelector(".share-dialog__hint")?.textContent ?? null,
  );
  expect(hints).toEqual([null, translate("share.notJoined"), translate("share.inChatNow"), null]);
});

// A result that is not a refusal (a role change) shows muted on the status line, not as an alert.
test("a notice shows muted on the status line", async () => {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(
      <ShareDialogBody
        chat="Add retries"
        view={shared}
        notice="@sam changed to Can send."
        onInvite={() => {}}
        onRole={() => {}}
        onRemove={() => {}}
        onGeneral={() => {}}
        onCopy={() => {}}
        onDone={() => {}}
      />,
    );
  });
  const line = container.querySelector(".share-dialog__status")!;
  expect(line.textContent).toBe("@sam changed to Can send.");
  expect(line.getAttribute("role")).toBeNull();
  expect(line.hasAttribute("data-hint")).toBe(true);
});

test("a failed read of the chat's shares is read again on its own, with no Try again", async () => {
  // Leo, 2026-11-22: "vacuous decisions like that should be just done": the open's read asks again
  // on the shared backoff (autoRetry.ts, first ask within 1 s) and says nothing at first.
  installDom();
  const { ShareDialogHost } = await import("./ShareControl");
  let reads = 0;
  const call = async (op: string) => {
    if (op !== "state") return {};
    reads += 1;
    if (reads === 1) throw new Error("share: 503 Service Unavailable");
    return { shares: [] };
  };
  root = createRoot(document.getElementById("root")!);
  await act(async () =>
    root!.render(<ShareDialogHost sessionId="s" chat="Demo" open onOpenChange={() => undefined} call={call} />),
  );
  await act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
  expect(reads).toBe(1);
  expect(document.body.textContent).not.toContain(translate("share.error.generic"));
  await until(() => reads >= 2, actTurn);
  expect(reads).toBe(2);
  expect(document.body.textContent).not.toContain(translate("share.error.generic"));
  expect(document.body.textContent).not.toContain(translate("share.stillReading"));
});
