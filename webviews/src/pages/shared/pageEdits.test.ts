// Every page's automatic keep reasons (p13-webui-089): the first trusted edit, form interaction or
// beforeunload handler tells the host once, untrusted events count for nothing, and the page's save,
// a route change or a store's save end the edits.
import { describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { KEEP_ALIVE_OP, PageKeepAlive, pageKeepAliveFor, type PageClient } from "./pageClient";
import { EDITS_SAVED_EVENT, editReason, watchPageEdits, type EditsWindow } from "./pageEdits";

type Sent = { reason: string; on: boolean };

function recording() {
  const sent: Sent[] = [];
  const client: PageClient = {
    call: async <R>(op: string, params: unknown) => {
      if (op === KEEP_ALIVE_OP) sent.push(params as Sent);
      return {} as R;
    },
    subscribe: async () => () => {},
    handle: () => () => {},
  };
  return { client, keep: new PageKeepAlive(client), sent };
}

// One realm for targets and events: another test file may leave a jsdom `Event` on globalThis.
const dom = new JSDOM("<!doctype html><body></body>");
const { Event: DomEvent, EventTarget: DomEventTarget } = dom.window;
const element = (html: string) => {
  const host = dom.window.document.createElement("div");
  host.innerHTML = html;
  return host.firstElementChild!;
};

/** A document that records its listeners, so a test can hand them trusted events. */
class FakeDocument extends DomEventTarget {
  readonly added: { type: string; capture: boolean }[] = [];
  readonly edits: ((event: Event) => void)[] = [];

  override addEventListener(
    type: string,
    listener: EventListenerOrEventListenerObject | null,
    options?: boolean | AddEventListenerOptions,
  ): void {
    super.addEventListener(type, listener, options);
    const capture = typeof options === "object" ? options.capture === true : options === true;
    this.added.push({ type, capture });
    if ((type === "input" || type === "change") && typeof listener === "function") this.edits.push(listener);
  }

  /** The person's edit of `target`, as the engine delivers it (`isTrusted`). */
  edit(target: unknown, type: "input" | "change" = "input", trusted = true): void {
    const event = { type, isTrusted: trusted, target, composedPath: () => [target] } as unknown as Event;
    for (const listener of this.edits) listener(event);
  }
}

function watched() {
  const { keep, sent } = recording();
  const doc = new FakeDocument();
  const win = new DomEventTarget() as EditsWindow;
  const stop = watchPageEdits(doc, win, keep);
  return { keep, sent, doc, win, stop };
}

describe("editReason", () => {
  test("text written is a user edit; a control set by hand is a form interaction", () => {
    expect(editReason(element("<input>"))).toBe("user_edits");
    expect(editReason(element('<input type="email">'))).toBe("user_edits");
    expect(editReason(element("<textarea></textarea>"))).toBe("user_edits");
    expect(editReason({ tagName: "DIV", isContentEditable: true })).toBe("user_edits");
    expect(editReason(element('<input type="checkbox">'))).toBe("form_interaction");
    expect(editReason(element("<select></select>"))).toBe("form_interaction");
  });

  test("a query, a button, a read-only field or no element is nothing", () => {
    expect(editReason(element('<input type="search">'))).toBeNull();
    expect(editReason(element('<input type="button">'))).toBeNull();
    expect(editReason(element('<input type="hidden">'))).toBeNull();
    expect(editReason(element("<textarea readonly></textarea>"))).toBeNull();
    expect(editReason(element("<div></div>"))).toBeNull();
    expect(editReason(null)).toBeNull();
    expect(editReason(dom.window.document)).toBeNull();
  });
});

describe("watchPageEdits", () => {
  test("the first trusted edit tells the host once; typing after it sends nothing", () => {
    const { doc, sent, stop } = watched();
    const field = element("<textarea></textarea>");
    for (let key = 0; key < 50; key += 1) doc.edit(field);
    doc.edit(field, "change");
    expect(sent).toEqual([{ reason: "user_edits", on: true }]);
    stop();
  });

  test("an untrusted event (page script's own dispatch) sets nothing", () => {
    const { doc, sent, stop } = watched();
    doc.edit(element("<input>"), "input", false);
    doc.edit(element('<input type="checkbox">'), "change", false);
    expect(sent).toEqual([]);
    stop();
  });

  test("a control set by hand is a form interaction, apart from the edits", () => {
    const { doc, sent, stop } = watched();
    doc.edit(element('<input type="checkbox">'), "change");
    doc.edit(element("<select></select>"), "change");
    doc.edit(element('<input type="search">'));
    expect(sent).toEqual([{ reason: "form_interaction", on: true }]);
    stop();
  });

  test("one capture-phase input and change listener per document, however many clients", () => {
    const { keep } = recording();
    const doc = new FakeDocument();
    const win = new DomEventTarget() as EditsWindow;
    const stop = watchPageEdits(doc, win, keep);
    watchPageEdits(doc, win, keep);
    const edits = doc.added.filter((entry) => entry.type === "input" || entry.type === "change");
    expect(edits).toEqual([
      { type: "input", capture: true },
      { type: "change", capture: true },
    ]);
    stop();
  });

  test("the page's save ends its edits, and the next edit tells the host again", () => {
    const { doc, sent, stop } = watched();
    doc.edit(element("<input>"));
    doc.edit(element('<input type="radio">'), "change");
    doc.dispatchEvent(new DomEvent(EDITS_SAVED_EVENT));
    expect(sent).toEqual([
      { reason: "user_edits", on: true },
      { reason: "form_interaction", on: true },
      { reason: "user_edits", on: false },
      { reason: "form_interaction", on: false },
    ]);
    doc.edit(element("<input>"));
    expect(sent.at(-1)).toEqual({ reason: "user_edits", on: true });
    expect(EDITS_SAVED_EVENT).toBe("cmux.page.edits.saved");
    stop();
  });

  test("a route change ends the automatic edits, not a store's own", () => {
    const { keep, doc, win, sent, stop } = watched();
    const store = {};
    doc.edit(element("<input>"));
    win.dispatchEvent(new DomEvent("hashchange"));
    expect(sent).toEqual([
      { reason: "user_edits", on: true },
      { reason: "user_edits", on: false },
    ]);
    keep.set("user_edits", true, store);
    doc.edit(element("<input>"));
    win.dispatchEvent(new DomEvent("hashchange"));
    expect(keep.has("user_edits")).toBe(true);
    expect(sent.length).toBe(3);
    stop();
  });

  test("a beforeunload listener holds before_unload until the last one is removed", () => {
    const { win, sent, stop } = watched();
    const first = () => {};
    const second = () => {};
    win.addEventListener("beforeunload", first);
    win.addEventListener("beforeunload", first); // the same listener twice is one
    win.addEventListener("beforeunload", second, { capture: true });
    win.addEventListener("unload", first);
    win.removeEventListener("beforeunload", first);
    expect(sent).toEqual([{ reason: "before_unload", on: true }]);
    win.removeEventListener("beforeunload", second); // not the capture one: still held
    expect(sent.length).toBe(1);
    win.removeEventListener("beforeunload", second, true);
    expect(sent).toEqual([
      { reason: "before_unload", on: true },
      { reason: "before_unload", on: false },
    ]);
    const controller = new dom.window.AbortController();
    win.addEventListener("beforeunload", first, { signal: controller.signal });
    controller.abort("unmounted"); // a reason of its own: no DOMException across realms
    expect(sent.slice(2)).toEqual([
      { reason: "before_unload", on: true },
      { reason: "before_unload", on: false },
    ]);
    stop();
  });

  test("an onbeforeunload function holds before_unload; clearing it ends it", () => {
    const { keep, sent } = recording();
    let stored: unknown = null;
    // The engine's accessor lives on the window's prototype chain, as WebKit's does.
    const proto = Object.create(DomEventTarget.prototype) as object;
    Object.defineProperty(proto, "onbeforeunload", {
      configurable: true,
      get: () => stored,
      set: (value: unknown) => {
        stored = value;
      },
    });
    const win = Object.setPrototypeOf(new DomEventTarget(), proto) as EditsWindow;
    const stop = watchPageEdits(new FakeDocument(), win, keep);
    win.onbeforeunload = () => "unsaved";
    expect(typeof stored).toBe("function"); // the engine's own handler is still set
    win.onbeforeunload = null;
    expect(sent).toEqual([
      { reason: "before_unload", on: true },
      { reason: "before_unload", on: false },
    ]);
    stop();
    expect(Object.getOwnPropertyDescriptor(win, "onbeforeunload")).toBeUndefined();
  });
});

describe("PageKeepAlive holders", () => {
  test("a reason holds while any holder does; editsSaved ends every holder's edits", () => {
    const { keep, sent } = recording();
    const composer = {};
    const other = {};
    keep.set("draft", true, composer);
    keep.set("draft", true, other);
    keep.set("draft", false, composer);
    expect(keep.has("draft")).toBe(true);
    keep.set("draft", false, composer); // an end it does not hold changes nothing
    keep.set("draft", false, other);
    keep.set("user_edits", true, composer);
    keep.set("user_edits", true, other);
    keep.editsSaved();
    keep.editsSaved();
    expect(sent).toEqual([
      { reason: "draft", on: true },
      { reason: "draft", on: false },
      { reason: "user_edits", on: true },
      { reason: "user_edits", on: false },
    ]);
  });

  test("one keep-alive per client, so the automatic edits and a store share it", () => {
    const { client } = recording();
    expect(pageKeepAliveFor(client)).toBe(pageKeepAliveFor(client));
    expect(pageKeepAliveFor(null)).not.toBe(pageKeepAliveFor(null));
  });
});
