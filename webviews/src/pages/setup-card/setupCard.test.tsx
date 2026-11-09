import { describe, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { SetupState } from "../home-messages/cards/setup/setupModel";
import type { PageClient } from "../shared/pageClient";
import { SetupCardPage } from "./SetupCardPage";
import { SETUP_OPS } from "./ops";
import { SetupCardStore } from "./store";

const fresh: SetupState = {
  agents: [
    { id: "claude", name: "Claude Code", state: "missing" },
    { id: "codex", name: "Codex", state: "missing" },
  ],
  account: { signedIn: false },
  cli: "missing",
  classic: null,
};

/** A host that answers `state` and records every call. */
function host(state: SetupState) {
  const calls: [string, unknown][] = [];
  let push: ((next: SetupState) => void) | null = null;
  const client: PageClient = {
    async call<R>(op: string, params: unknown) {
      calls.push([op, params]);
      return (op === SETUP_OPS.state ? state : {}) as R;
    },
    async subscribe<E>(_stream: string, onEvent: (data: E, seq: number) => void) {
      push = (next) => onEvent(next as E, 0);
      return () => {};
    },
    handle: () => () => {},
  };
  return { client, calls, push: (next: SetupState) => push?.(next) };
}

const text = (html: string) => html.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ");

describe("the Set Up cmux page", () => {
  test("shows every row in one card, with the words the first-run probe reads", async () => {
    const { client } = host(fresh);
    const store = new SetupCardStore(client);
    await store.start();
    const words = text(renderToStaticMarkup(<SetupCardPage store={store} />));
    for (const phrase of ["Set Up cmux", "Claude Code", "Codex", "cmux account", "Command line", "Install Claude Code"])
      expect(words).toContain(phrase);
    expect(renderToStaticMarkup(<SetupCardPage store={store} />)).toContain('data-look="rows"');
  });

  test("draws nothing before the host answers, then follows its stream", async () => {
    const { client, push } = host(fresh);
    const store = new SetupCardStore(client);
    expect(text(renderToStaticMarkup(<SetupCardPage store={store} />)).trim()).toBe("");
    await store.start();
    push({ ...fresh, account: { signedIn: true, email: "you@example.com" } });
    expect(store.getSnapshot()?.account.email).toBe("you@example.com");
  });

  test("a row's button and Hide are one host call each", async () => {
    const { client, calls } = host(fresh);
    const store = new SetupCardStore(client);
    store.send(SETUP_OPS.run, { action: { kind: "installCLI" } });
    store.send(SETUP_OPS.hide, {});
    await Promise.resolve();
    expect(calls).toEqual([
      [SETUP_OPS.run, { action: { kind: "installCLI" } }],
      [SETUP_OPS.hide, {}],
    ]);
  });
});
