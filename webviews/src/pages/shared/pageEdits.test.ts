// Every page's automatic keep reasons: the first trusted edit or form interaction
// tells the host once, untrusted events count for nothing, and the page's save, a route change or a
// store's save end the edits. before_unload holds only while the page asks (askBeforeUnload), never
// for a listener a library adds, and createPageClient installs the watch on every bridged page.
import { describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { installNativeMenu, nativeMenu } from "../../ui/nativeMenu";
import { createFragmentHistory } from "../settings/router";
import {
  createPageClient,
  KEEP_ALIVE_OP,
  PageKeepAlive,
  pageKeepAliveFor,
  RECEIVE_MANY_NAME,
  RECEIVE_NAME,
  type PageClient,
} from "./pageClient";
import { askBeforeUnload, EDITS_SAVED_EVENT, editReason, watchPageEdits } from "./pageEdits";

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
  const win = new DomEventTarget();
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
    const win = new DomEventTarget();
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
});

describe("askBeforeUnload", () => {
  test("the page asks on unload and holds before_unload until it lets go", () => {
    const { keep, sent } = recording();
    const { window: win } = new JSDOM("<!doctype html>");
    const unload = () => {
      const event = new win.Event("beforeunload", { cancelable: true });
      win.dispatchEvent(event);
      return event.defaultPrevented;
    };
    const release = askBeforeUnload(win, keep);
    expect(unload()).toBe(true);
    release();
    release(); // a second release changes nothing
    expect(unload()).toBe(false);
    expect(sent).toEqual([
      { reason: "before_unload", on: true },
      { reason: "before_unload", on: false },
    ]);
  });
});

describe("createPageClient", () => {
  type Sent = { t: string; id: number; op?: string; params?: unknown };
  const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

  test("a bridged page watches its edits once, on the page's own keep-alive; a router asks nothing", async () => {
    const { window: win } = new JSDOM("<!doctype html><body></body>", { url: "https://cmux.page/settings.html" });
    const doc = win.document;
    const edits: ((event: Event) => void)[] = [];
    type Add = (
      type: string,
      listener: EventListenerOrEventListenerObject | null,
      options?: boolean | AddEventListenerOptions,
    ) => void;
    const addToDocument = doc.addEventListener.bind(doc) as Add;
    doc.addEventListener = ((...[type, listener, options]: Parameters<Add>) => {
      addToDocument(type, listener, options);
      if ((type === "input" || type === "change") && typeof listener === "function") edits.push(listener);
    }) as typeof doc.addEventListener;
    const envelopes: Sent[] = [];
    const cmuxPage = {
      postMessage: async (body: unknown) => {
        const envelope = body as Sent;
        envelopes.push(envelope);
        return { t: "ok", id: envelope.id, value: null };
      },
    };
    const keepAlives = () =>
      envelopes.filter((envelope) => envelope.t === "call" && envelope.op === KEEP_ALIVE_OP).map((e) => e.params);

    const scope = globalThis as Record<string, unknown>;
    const keys = ["document", "window", "webkit", RECEIVE_NAME, RECEIVE_MANY_NAME];
    const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
    const menu = nativeMenu();
    scope.document = doc;
    scope.window = win;
    scope.webkit = { messageHandlers: { cmuxPage } };
    try {
      const client = createPageClient();
      expect(client).not.toBeNull();
      expect(createPageClient()).not.toBeNull(); // a second client of the same document
      expect(edits.length).toBe(2); // one input and change pair

      const field = doc.createElement("textarea");
      const typed = { type: "input", isTrusted: true, target: field, composedPath: () => [field] };
      for (let key = 0; key < 5; key += 1) edits[0]!(typed as unknown as Event);
      await flush();
      expect(keepAlives()).toEqual([{ reason: "user_edits", on: true }]);
      pageKeepAliveFor(client).editsSaved();
      await flush();
      expect(keepAlives()).toEqual([
        { reason: "user_edits", on: true },
        { reason: "user_edits", on: false },
      ]);

      // The Settings router boots after the client: its history adds a beforeunload listener that
      // asks only while a blocker is set.
      const history = createFragmentHistory(win as unknown as Window);
      win.onbeforeunload = () => undefined;
      const unload = new win.Event("beforeunload", { cancelable: true });
      win.dispatchEvent(unload);
      expect(unload.defaultPrevented).toBe(false);
      await flush();
      expect(keepAlives().length).toBe(2);
      history.destroy();
    } finally {
      for (const [key, had, value] of saved) {
        if (had) scope[key] = value;
        else delete scope[key];
      }
      installNativeMenu(menu);
    }
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
