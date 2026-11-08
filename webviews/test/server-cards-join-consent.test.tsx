// The join consent ask on the server card page over a fake host: it draws who asked for what, the
// question, the note and why an Allow did not take; Deny is a click-only button (no key press
// either), off while a write is in flight, and the page draws no Allow (the app panel's native
// button is Allow); the store sends one Deny per press and none while writing or with no ask; a
// refused Deny leaves the ask up; and the panel's cancel is heard (so the panel never hides the ask
// itself) and does nothing.
import { describe, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { Strings } from "../src/pages/shared/i18n";
import { pageError } from "../src/pages/shared/pageClient";
import { askStatus } from "../src/pages/server-cards/join-consent/fixtures";
import { JoinConsentCard } from "../src/pages/server-cards/join-consent/JoinConsentCard";
import { viewOf } from "../src/pages/server-cards/join-consent/model";
import { JoinConsentStore } from "../src/pages/server-cards/join-consent/store";
import { JoinConsentOps, type JoinConsentStatus } from "../src/pages/server-cards/join-consent/types";

const strings: Strings = {
  language: "en",
  t: (key) => `[${key}]`,
  format: (key, ...args) => `[${key}:${args.join(",")}]`,
};

class FakeHost {
  status: JoinConsentStatus = askStatus();
  calls: string[] = [];
  refuseDeny = false;
  private listener?: () => void;
  private seq = 0;

  async call<T>(op: string): Promise<T> {
    this.calls.push(op);
    if (op === "cmux.joinConsent.status") return structuredClone(this.status) as T;
    if (op === "cmux.joinConsent.deny" && this.refuseDeny)
      throw pageError("cmux.page.user_only", "Only your own click or key denies this.");
    return null as T;
  }

  async subscribe<E>(_stream: string, onEvent: (data: E, seq: number) => void) {
    this.listener = () => onEvent({} as E, ++this.seq);
    return () => {};
  }

  change(status: JoinConsentStatus) {
    this.status = status;
    this.listener?.();
  }

  answers() {
    return this.calls.filter((op) => op !== "cmux.joinConsent.status");
  }
}

const settle = async () => {
  for (let index = 0; index < 20; index++) await Promise.resolve();
};

async function opened(host: FakeHost) {
  const store = new JoinConsentStore(host);
  await store.start();
  await settle();
  return store;
}

describe("Join Consent ask", () => {
  test("draws who asked for what, the question, the note and the error", () => {
    const screen = viewOf(askStatus({ error: "Touch ID was cancelled." }), strings)!;
    expect(screen.title).toBe("[devices.join.ask.screen:studio-mac]");
    expect(screen.question).toBe("[devices.join.ask.screenQuestion]");
    expect(screen.note).toBe("[devices.join.ask.note]");
    expect(screen.error).toBe("Touch ID was cancelled.");
    const control = viewOf(askStatus({ ask: { requester: "hb", surface: "control" } }), strings)!;
    expect(control.title).toBe("[devices.join.ask.control:hb]");
    expect(control.question).toBe("[devices.join.ask.controlQuestion]");
    expect(viewOf(askStatus({ ask: null }), strings)).toBeNull();
    expect(viewOf(undefined, strings)).toBeNull();
  });

  test("the page draws no Allow (the panel's native button is Allow); Deny takes no key and is off while writing", () => {
    for (const layout of ["stacked", "compact", "banner"] as const) {
      const html = renderToStaticMarkup(
        <JoinConsentCard status={askStatus()} strings={strings} layout={layout} onDeny={() => undefined} />,
      );
      expect(html).toContain('data-action="deny"');
      expect(html).not.toContain('data-action="allow"');
      expect(html).not.toContain("disabled");
      // A click-only DialogButton draws no key hint and binds no key.
      expect(html).not.toContain("aria-keyshortcuts");
    }
    const standIn = renderToStaticMarkup(
      <JoinConsentCard status={askStatus()} strings={strings} onDeny={() => undefined} controlStandIn />,
    );
    expect(standIn).toContain('data-action="allow"');
    const writing = renderToStaticMarkup(
      <JoinConsentCard
        status={askStatus({ writing: true })}
        strings={strings}
        onDeny={() => undefined}
        controlStandIn
      />,
    );
    expect(writing.match(/disabled=""/g)?.length).toBe(2);
    expect(
      renderToStaticMarkup(
        <JoinConsentCard status={askStatus({ ask: null })} strings={strings} onDeny={() => undefined} />,
      ),
    ).toBe("");
  });

  test("one press sends one Deny; none while writing or with no ask; the page has no Allow op", async () => {
    const host = new FakeHost();
    const store = await opened(host);
    host.change(askStatus({ writing: true }));
    await settle();
    await store.deny();
    expect(host.answers()).toEqual([]);
    host.change(askStatus({ ask: null }));
    await settle();
    await store.deny();
    expect(host.answers()).toEqual([]);
    host.change(askStatus());
    await settle();
    await store.deny();
    expect(host.answers()).toEqual(["cmux.joinConsent.deny"]);
    expect(Object.values(JoinConsentOps)).not.toContain("cmux.joinConsent.allow");
  });

  test("a refused Deny leaves the ask as it is", async () => {
    const host = new FakeHost();
    host.refuseDeny = true;
    const store = await opened(host);
    await store.deny();
    expect(store.getSnapshot()?.ask).toEqual({ requester: "studio-mac", surface: "screen" });
  });
});
