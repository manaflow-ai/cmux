// The join consent ask on the server card page over a fake host: it draws who asked for what, the
// question, the note and why an Allow did not take; Deny and Allow are click-only buttons (no key
// presses either), both off while a write is in flight; the store sends one answer per press and
// none while writing or with no ask; a refused Allow leaves the ask up; and the panel's cancel is
// heard (so the panel never hides the ask itself) and does nothing.
import { describe, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { Strings } from "../src/pages/shared/i18n";
import { pageError } from "../src/pages/shared/pageClient";
import { askStatus } from "../src/pages/server-cards/join-consent/fixtures";
import { JoinConsentCard } from "../src/pages/server-cards/join-consent/JoinConsentCard";
import { viewOf } from "../src/pages/server-cards/join-consent/model";
import { JoinConsentStore } from "../src/pages/server-cards/join-consent/store";
import type { JoinConsentStatus } from "../src/pages/server-cards/join-consent/types";

const strings: Strings = {
  language: "en",
  t: (key) => `[${key}]`,
  format: (key, ...args) => `[${key}:${args.join(",")}]`,
};

class FakeHost {
  status: JoinConsentStatus = askStatus();
  calls: string[] = [];
  refuseAllow = false;
  private listener?: () => void;
  private seq = 0;

  async call<T>(op: string): Promise<T> {
    this.calls.push(op);
    if (op === "cmux.joinConsent.status") return structuredClone(this.status) as T;
    if (op === "cmux.joinConsent.allow" && this.refuseAllow)
      throw pageError("cmux.page.user_only", "Only your own click on Allow allows this.");
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

  test("Deny and Allow take no key and are both off while writing", () => {
    for (const layout of ["stacked", "compact", "banner"] as const) {
      const html = renderToStaticMarkup(
        <JoinConsentCard status={askStatus()} strings={strings} layout={layout} onAnswer={() => undefined} />,
      );
      expect(html).toContain('data-action="deny"');
      expect(html).toContain('data-action="allow"');
      expect(html).not.toContain("disabled");
      // A click-only DialogButton draws no key hint and binds no key.
      expect(html).not.toContain("aria-keyshortcuts");
    }
    const writing = renderToStaticMarkup(
      <JoinConsentCard status={askStatus({ writing: true })} strings={strings} onAnswer={() => undefined} />,
    );
    expect(writing.match(/disabled=""/g)?.length).toBe(2);
    expect(
      renderToStaticMarkup(
        <JoinConsentCard status={askStatus({ ask: null })} strings={strings} onAnswer={() => undefined} />,
      ),
    ).toBe("");
  });

  test("one press sends one answer; none while writing or with no ask", async () => {
    const host = new FakeHost();
    const store = await opened(host);
    await store.answer(true);
    expect(host.answers()).toEqual(["cmux.joinConsent.allow"]);
    host.change(askStatus({ writing: true }));
    await settle();
    await store.answer(true);
    await store.answer(false);
    expect(host.answers()).toEqual(["cmux.joinConsent.allow"]);
    host.change(askStatus({ ask: null }));
    await settle();
    await store.answer(false);
    expect(host.answers()).toEqual(["cmux.joinConsent.allow"]);
    host.change(askStatus());
    await settle();
    await store.answer(false);
    expect(host.answers()).toEqual(["cmux.joinConsent.allow", "cmux.joinConsent.deny"]);
  });

  test("a refused Allow leaves the ask as it is", async () => {
    const host = new FakeHost();
    host.refuseAllow = true;
    const store = await opened(host);
    await store.answer(true);
    expect(store.getSnapshot()?.ask).toEqual({ requester: "studio-mac", surface: "screen" });
  });
});
