// l10n-allow-file: test fixture tool titles and option names, not shipped UI.
// An answer on the chat's permission card reaches the ask it was given for, and a refusal is never
// silent (the global inbox lane's audit, 2026-10-26). Before: the card sent its answer with `void`,
// so a refusal from acpmux (the ask already answered from a banner, the Feed or another window,
// withdrawn, or a policy change) was dropped. The keys were spent on that ask too: ⌥⌘1 and 1 did
// nothing more while it still waited, with nothing on screen to say why.
// - A refused answer says so on the card, and the keys answer that ask again.
// - An answer acpmux takes says nothing, and a held key never answers twice.
// - Each answer names its own ask: once the card shows the next ask, a key answers the next ask
//   with that ask's option, and the first ask's late refusal never shows on it.
// - A key and a click answer an ask once between them, an ask shown again while its answer is out
//   is not answered twice, and a late reply to an answer before never changes the card (Codex
//   review of #25236: replies out of order, a key then a click, A then B then A).
// - Any refusal shows: a thenable's, a throw's, and a deny with feedback that rejects or throws.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxPermission } from "../src/agent-session/acpmux/model";

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
const { PermissionCard } = await import("../src/agent-session/acpmux/PermissionCard");
const { translate } = await import("../src/agent-session/acpmux/i18n");

const ask = (permissionId: string, allowId = `${permissionId}-yes`): AcpmuxPermission => ({
  permissionId,
  title: "Run rm -rf build",
  kind: "execute",
  command: "rm -rf build",
  pending: true,
  options: [
    { id: allowId, name: "Yes", kind: "allow_once", allow: true },
    { id: `${permissionId}-no`, name: "No", kind: "reject_once", allow: false },
  ],
});

type Sent = { permissionId: string; optionId: string; settle: { resolve(): void; reject(error: Error): void } };

type Options = {
  reply?(optionId: string): unknown;
  focusComposer?(): void;
  onDenyWithFeedback?(optionId: string, text: string): Promise<boolean>;
};

async function mount(first: AcpmuxPermission, options: Options = {}) {
  const host = dom.window.document.createElement("div");
  dom.window.document.body.append(host);
  const root = createRoot(host);
  const sent: Sent[] = [];
  const render = (permission: AcpmuxPermission) =>
    act(async () =>
      root.render(
        <PermissionCard
          permission={permission}
          harness="claude"
          onAnswer={(optionId) =>
            options.reply
              ? options.reply(optionId)
              : new Promise<void>((resolve, reject) => {
                  sent.push({ permissionId: permission.permissionId, optionId, settle: { resolve, reject } });
                })
          }
          onDenyWithFeedback={options.onDenyWithFeedback}
          focusComposer={options.focusComposer}
        />,
      ),
    );
  await render(first);
  const key = (key: string) =>
    act(async () => void dom.window.document.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key })));
  const shortcut = (action: string) =>
    act(async () => void dom.window.dispatchEvent(new dom.window.Event(`cmux-acpmux-${action}`)));
  const settle = (index: number, ok: boolean) =>
    act(async () => {
      const { settle } = sent[index]!;
      if (ok) settle.resolve();
      else settle.reject(new Error("no pending permission"));
      await Promise.resolve();
    });
  const alert = () => host.querySelector('[role="alert"]')?.textContent ?? undefined;
  const click = (label: string) =>
    act(async () => {
      const button = [...host.querySelectorAll("button")].find((b) => b.textContent?.includes(label));
      if (!button) throw new Error(`no button ${label}`);
      button.click();
    });
  const type = (text: string) =>
    act(async () => {
      const field = host.querySelector("textarea")!;
      const set = Object.getOwnPropertyDescriptor(dom.window.HTMLTextAreaElement.prototype, "value")!.set!;
      set.call(field, text);
      field.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
    });
  const flush = () => act(async () => void (await new Promise((resolve) => setTimeout(resolve, 0))));
  return {
    host,
    sent,
    render,
    key,
    shortcut,
    settle,
    alert,
    click,
    type,
    flush,
    unmount: () => act(async () => root.unmount()),
  };
}

test("a refused answer says so on the card, and the keys answer that ask again", async () => {
  const card = await mount(ask("p1"));
  await card.key("1");
  expect(card.sent.map((s) => [s.permissionId, s.optionId])).toEqual([["p1", "p1-yes"]]);
  expect(card.alert()).toBeUndefined();
  await card.settle(0, false);
  expect(card.alert()).toBe(translate("permission.error.refused"));
  // The ask still waits (acpmux never took the answer): its keys work again.
  await card.shortcut("permissionAllowOnce");
  expect(card.sent.map((s) => [s.permissionId, s.optionId])).toEqual([
    ["p1", "p1-yes"],
    ["p1", "p1-yes"],
  ]);
  // A new answer clears the refusal until acpmux says how it went.
  expect(card.alert()).toBeUndefined();
  await card.unmount();
});

test("an answer acpmux takes shows nothing, and a held key never answers twice", async () => {
  const card = await mount(ask("p1"));
  await card.key("3");
  await card.key("3");
  await card.shortcut("permissionDeny");
  expect(card.sent.map((s) => s.optionId)).toEqual(["p1-no"]);
  await card.settle(0, true);
  expect(card.alert()).toBeUndefined();
  await card.key("1");
  expect(card.sent).toHaveLength(1);
  await card.unmount();
});

test("each answer names its own ask, and the ask before's late refusal never shows on the next", async () => {
  const card = await mount(ask("p1"));
  await card.key("1");
  // acpmux took p1 and the agent asks again before p1's reply lands: the card now shows p2.
  await card.render(ask("p2", "p2-allow"));
  await card.key("1");
  expect(card.sent.map((s) => [s.permissionId, s.optionId])).toEqual([
    ["p1", "p1-yes"],
    ["p2", "p2-allow"],
  ]);
  await card.settle(0, false);
  expect(card.alert()).toBeUndefined();
  // p2's own refusal does show, and re-arms p2's keys only.
  await card.settle(1, false);
  expect(card.alert()).toBe(translate("permission.error.refused"));
  await card.key("1");
  expect(card.sent.at(-1)).toMatchObject({ permissionId: "p2", optionId: "p2-allow" });
  await card.unmount();
});

test("a key and a click answer an ask once between them", async () => {
  const card = await mount(ask("p1"));
  await card.key("1");
  await card.click(translate("permission.allowOnce"));
  await card.click(translate("permission.deny"));
  expect(card.sent.map((s) => s.optionId)).toEqual(["p1-yes"]);
  // Refused: one more answer may go, and only one.
  await card.settle(0, false);
  await card.click(translate("permission.deny"));
  await card.key("1");
  expect(card.sent.map((s) => s.optionId)).toEqual(["p1-yes", "p1-no"]);
  await card.unmount();
});

test("a late reply to an answer before never changes the card", async () => {
  const card = await mount(ask("p1"));
  await card.key("1");
  await card.render(ask("p2", "p2-allow"));
  await card.key("1");
  await card.render(ask("p3", "p3-allow"));
  await card.key("1");
  // p3's refusal lands first, then p1's: the card still names p3's, and p3's keys stay armed.
  await card.settle(2, false);
  await card.settle(0, false);
  expect(card.alert()).toBe(translate("permission.error.refused"));
  await card.key("1");
  expect(card.sent.at(-1)).toMatchObject({ permissionId: "p3", optionId: "p3-allow" });
  // p3's answer is out again: p2's late success neither clears it nor frees p3's keys.
  await card.settle(1, true);
  await card.key("1");
  expect(card.sent).toHaveLength(4);
  await card.unmount();
});

test("an ask shown again while its answer is out is not answered twice", async () => {
  const card = await mount(ask("p1"));
  await card.key("1");
  await card.render(ask("p2", "p2-allow"));
  await card.key("1");
  await card.render(ask("p1"));
  await card.key("1");
  await card.click(translate("permission.allowOnce"));
  expect(card.sent.map((s) => s.optionId)).toEqual(["p1-yes", "p2-allow"]);
  // Its answer was refused: now it may go again, once.
  await card.settle(0, false);
  await card.key("1");
  await card.key("1");
  expect(card.sent.map((s) => s.optionId)).toEqual(["p1-yes", "p2-allow", "p1-yes"]);
  await card.unmount();
});

test("a thenable's refusal and a throw both show, and free the ask", async () => {
  let calls = 0;
  const card = await mount(ask("p1"), {
    reply: () => {
      calls += 1;
      // oxlint-disable-next-line unicorn/no-thenable -- the card must follow any thenable onAnswer returns.
      if (calls === 1) return { then: (_ok: unknown, fail: (error: Error) => void) => fail(new Error("refused")) };
      throw new Error("no connection");
    },
  });
  await card.key("1");
  await card.flush();
  expect(card.alert()).toBe(translate("permission.error.refused"));
  await card.key("1");
  await card.flush();
  expect(calls).toBe(2);
  expect(card.alert()).toBe(translate("permission.error.refused"));
  await card.key("1");
  expect(calls).toBe(3);
  await card.flush();
  await card.unmount();
});

for (const [how, fail] of [
  [
    "rejects",
    (optionId: string, text: string, denies: string[]) => {
      denies.push(`${optionId}:${text}`);
      return Promise.reject(new Error("connection dropped"));
    },
  ],
  [
    "throws",
    (optionId: string, text: string, denies: string[]) => {
      denies.push(`${optionId}:${text}`);
      throw new Error("no chat to answer in");
    },
  ],
] as const)
  test(`a deny with feedback that ${how} keeps the text and frees the ask`, async () => {
    const denies: string[] = [];
    const card = await mount(ask("p1"), {
      onDenyWithFeedback: (optionId, text) => fail(optionId, text, denies),
    });
    await card.key("3");
    const field = card.host.querySelector("textarea")!;
    await act(async () => {
      const set = Object.getOwnPropertyDescriptor(dom.window.HTMLTextAreaElement.prototype, "value")!.set!;
      set.call(field, "use a temp dir");
      field.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
    });
    await card.click(translate("permission.feedbackSend"));
    await card.flush();
    expect(denies).toEqual(["p1-no:use a temp dir"]);
    const after = card.host.querySelector("textarea");
    expect(after?.value).toBe("use a temp dir");
    expect(after?.readOnly).toBe(false);
    // The field can send again: the ask was never answered.
    await card.click(translate("permission.feedbackSend"));
    await card.flush();
    expect(denies).toHaveLength(2);
    await card.unmount();
  });

for (const late of [false, true])
  test(`a feedback deny ${late ? "taken" : "refused"} late never touches the next ask's field or focus`, async () => {
    const replies: Array<(ok: boolean) => void> = [];
    let composer = 0;
    const card = await mount(ask("p1"), {
      onDenyWithFeedback: () => new Promise<boolean>((resolve) => replies.push(resolve)),
      focusComposer: () => void (composer += 1),
    });
    await card.key("3");
    await card.type("not that");
    await card.click(translate("permission.feedbackSend"));
    // The agent asks again before p1's deny is answered; the person starts telling p2 something else,
    // then moves the keyboard away from the field.
    await card.render(ask("p2"));
    await card.key("3");
    await card.type("try the cache");
    const elsewhere = dom.window.document.createElement("button");
    card.host.append(elsewhere);
    elsewhere.focus();
    const before = composer;
    await act(async () => replies[0]!(late));
    await card.flush();
    const field = card.host.querySelector("textarea");
    expect(field?.value).toBe("try the cache");
    expect(field?.readOnly).toBe(false);
    expect(card.alert()).toBeUndefined();
    expect(dom.window.document.activeElement).toBe(elsewhere);
    expect(composer).toBe(before);
    await card.unmount();
  });

test("an ask shown again after its answer was taken is not answered again", async () => {
  const card = await mount(ask("p1"));
  await card.key("1");
  await card.render(ask("p2", "p2-allow"));
  await card.settle(0, true);
  await card.render(ask("p1"));
  await card.key("1");
  await card.click(translate("permission.allowOnce"));
  await card.click(translate("permission.deny"));
  expect(card.sent.map((s) => s.optionId)).toEqual(["p1-yes"]);
  await card.unmount();
});

test("an ask whose feedback deny is out cannot open a second one", async () => {
  const replies: Array<(ok: boolean) => void> = [];
  const denies: string[] = [];
  const card = await mount(ask("p1"), {
    onDenyWithFeedback: (_optionId, text) => {
      denies.push(text);
      return new Promise<boolean>((resolve) => replies.push(resolve));
    },
  });
  await card.key("3");
  await card.type("not that");
  await card.click(translate("permission.feedbackSend"));
  // p2 comes and its field opens, then p1 is back on the card.
  await card.render(ask("p2"));
  await card.key("3");
  await card.render(ask("p1"));
  // p1's deny is still out: neither Deny's click nor its key opens a field to send another.
  await card.click(translate("permission.deny"));
  await card.key("3");
  expect(card.host.querySelector("textarea")).toBeNull();
  // Refused: p1 can be denied again, with a fresh field.
  await act(async () => replies[0]!(false));
  await card.flush();
  expect(card.alert()).toBe(translate("permission.error.refused"));
  await card.click(translate("permission.deny"));
  await card.type("use the cache");
  await card.click(translate("permission.feedbackSend"));
  expect(denies).toEqual(["not that", "use the cache"]);
  await card.unmount();
});

test("an answer still out past the card's memory of taken answers keeps its ask, and its reply", async () => {
  const replies: Array<(ok: boolean) => void> = [];
  const card = await mount(ask("p0"), {
    onDenyWithFeedback: () => new Promise<boolean>((resolve) => replies.push(resolve)),
  });
  await card.key("3");
  await card.type("not that");
  await card.click(translate("permission.feedbackSend"));
  await card.key("1");
  // Far more asks than the card remembers come and are answered and taken while p0's deny is out.
  for (let i = 1; i <= 40; i++) {
    await card.render(ask(`p${i}`));
    await card.key("1");
    await card.settle(i - 1, true);
  }
  // p0 is back with its deny still out: its field still sends, and its keys answer nothing.
  await card.render(ask("p0"));
  await card.key("1");
  expect(card.host.querySelector("textarea")?.readOnly).toBe(true);
  expect(card.sent.filter((s) => s.permissionId === "p0")).toHaveLength(0);
  // Refused: p0's field takes text again, and it can be sent.
  await act(async () => replies[0]!(false));
  await card.flush();
  const field = card.host.querySelector("textarea");
  expect(field?.readOnly).toBe(false);
  expect(field?.value).toBe("not that");
  await card.click(translate("permission.feedbackSend"));
  expect(replies).toHaveLength(2);
  await card.unmount();
});

test("an answer taken late, past the card's memory of taken answers, stays taken", async () => {
  const card = await mount(ask("p0"));
  await card.key("1");
  for (let i = 1; i <= 40; i++) {
    await card.render(ask(`p${i}`));
    await card.key("1");
    await card.settle(i, true);
  }
  // p0 is back and its answer, out all along, is taken now: it is not answered again.
  await card.render(ask("p0"));
  await card.settle(0, true);
  await card.click(translate("permission.allowOnce"));
  await card.key("3");
  expect(card.sent.filter((s) => s.permissionId === "p0")).toHaveLength(1);
  await card.unmount();
});
