// Notes that did not load ("not available offline yet") carry a Try again, and it loads them: before, the
// store remembered the failed build and never asked again, so the line stayed with nothing to do until the
// page was reopened (scripts/cmux-next/check-connection-notices.py: a terminal state carries an action).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { teardownDom } from "./support/domTeardown";
import type { ListResult, ReleaseNotes } from "../src/pages/changelog/types";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterAll(async () => {
  await teardownDom(saved, { scope });
});

function notes(build: string): ReleaseNotes {
  return {
    build,
    shortVersion: `1.0.0-nightly.${build}`,
    date: "2026-11-10",
    highlights: [],
    summary: [{ group: "new" as const, title: `Change in ${build}` }],
    changes: [],
  };
}

const LIST: ListResult = {
  current: "100",
  builds: [{ build: "100", shortVersion: "1.0.0-nightly.100", date: "2026-11-10", highlights: 0 }],
};

/** A host whose notes fail `failures` times (offline), then answer; `lists` counts network list reads. */
function flakyHost(failures: number, list: () => ListResult = () => LIST) {
  let left = failures;
  const seen = { gets: 0, lists: 0 };
  const client = {
    async call<R>(op: string, params: unknown): Promise<R> {
      const p = (params ?? {}) as { cached?: boolean; build?: string };
      if (op === "cmux.changelog.list") {
        if (!p.cached) seen.lists += 1;
        return list() as R;
      }
      if (op === "cmux.changelog.get") {
        seen.gets += 1;
        if (left-- > 0) throw new Error("offline");
        return notes(String(p.build)) as R;
      }
      if (op === "cmux.changelog.installable") return { installs: false } as R;
      throw new Error(`unexpected ${op}`);
    },
    async subscribe() {
      return () => {};
    },
  };
  return { client: client as never, seen };
}

test("retry asks again for a build whose notes did not load, and the selected one shows", async () => {
  const { ChangelogStore } = await import("../src/pages/changelog/store");
  const h = flakyHost(1);
  const store = new ChangelogStore(h.client);
  await store.start();
  await store.firstScreen();
  expect(store.getSnapshot().missing).toBe(true);
  expect(store.getSnapshot().unavailable["100"]).toBe(true);
  // A re-render asks nothing (ensure remembers the failure); only the person's Try again does.
  await store.ensure("100");
  expect(h.seen.gets).toBe(1);

  await store.retry("100");
  const s = store.getSnapshot();
  expect(h.seen.gets).toBe(2);
  expect(s.unavailable["100"]).toBeUndefined();
  expect(s.missing).toBe(false);
  expect(s.notes?.build).toBe("100");
});

test("retry with no build reads the list again, for an update whose builds were not listed yet", async () => {
  const { ChangelogStore } = await import("../src/pages/changelog/store");
  let listed: ListResult = { current: "99", builds: [] };
  const h = flakyHost(0, () => listed);
  const store = new ChangelogStore(h.client);
  await store.start({ from: "1.0.0-nightly.99", to: "1.0.0-nightly.100" });
  expect(store.getSnapshot().inSpan).toEqual([]);
  const before = h.seen.lists;
  listed = LIST;
  await store.retry();
  expect(h.seen.lists).toBe(before + 1);
  expect(store.getSnapshot().inSpan).toEqual(["100"]);
});

test("the Digest's unavailable line has Try again, and the click loads the notes", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ChangelogStore } = await import("../src/pages/changelog/store");
  const { DigestPage } = await import("../src/pages/changelog/DigestPage");
  const strings = {
    language: "en",
    t: (key: string) =>
      ({
        "changelog.page.unavailable": "The notes for this version are not available offline yet.",
        "changelog.page.tryAgain": "Try Again",
      })[key] ?? key,
    format: (key: string, ...args: string[]) => `${key} ${args.join(" ")}`,
  };
  const h = flakyHost(1);
  const store = new ChangelogStore(h.client);
  await store.start();
  await store.firstScreen();
  const root = createRoot(host);
  const draw = () =>
    act(() =>
      root.render(
        <DigestPage
          store={store}
          strings={strings as unknown as Parameters<typeof DigestPage>[0]["strings"]}
          s={store.getSnapshot()}
        />,
      ),
    );
  draw();
  expect(host.textContent).toContain("not available offline yet");
  const button = [...host.querySelectorAll("button")].find((b) => b.textContent === "Try Again");
  expect(button).toBeDefined();
  await act(async () => {
    button!.click();
    await store.firstScreen();
  });
  draw();
  expect(host.textContent).not.toContain("not available offline yet");
  expect(host.textContent).toContain("Change in 100");
  act(() => root.unmount());
});
