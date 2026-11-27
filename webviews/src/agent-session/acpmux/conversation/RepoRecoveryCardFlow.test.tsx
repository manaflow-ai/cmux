// l10n-allow-file: test fixtures, not shipped UI.
// The repository recovery card from click to verified chip: a connect that didn't take waits for
// GitHub again on its own, a missing install link is asked for again on its own (no Try again or
// Check again: autoRetry.ts), a failed attach offers Try again, and a verified attach ends in the
// "GitHub connected" chip.
import { afterEach, expect, jest, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { translate } from "../i18n";
import { RepoRecoveryCard, RepoRecoveryCardView } from "./RepoRecoveryCard";
import type { RepoRecovery, RepoRecoveryView } from "./repoRecoveryCardModel";
import { LiveUpdatesContext } from "../../../ui/liveUpdates";
import { pageClocks } from "../../../ui/pageClock";
import { settleReact } from "../../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const opened: string[] = [];

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  dom.window.open = ((url: string) => {
    opened.push(url);
    return null;
  }) as typeof dom.window.open;
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  jest.useRealTimers();
  await settleReact();
  dom?.window.close();
  dom = undefined;
  opened.length = 0;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

test("recovery countdown ticks without reconciling actions and releases its clock while retained hidden", async () => {
  jest.useFakeTimers();
  jest.setSystemTime(1_000);
  const container = installDom();
  Object.defineProperty(document, "visibilityState", { value: "visible", configurable: true });
  let reads = 0;
  const view: RepoRecoveryView = {
    tone: "quiet",
    message: { literal: "Waiting for GitHub" },
    until: 61_000,
    get actions() {
      reads++;
      return [];
    },
  };
  root = createRoot(container);
  const draw = (active: boolean) =>
    act(async () =>
      root!.render(
        <LiveUpdatesContext.Provider value={active}>
          <RepoRecoveryCardView view={view} />
        </LiveUpdatesContext.Provider>,
      ),
    );
  await draw(true);
  const initialReads = reads;
  const initial = container.textContent;
  await act(async () => jest.advanceTimersByTime(10_000));
  expect(container.textContent).not.toBe(initial);
  expect(reads).toBe(initialReads);
  await draw(false);
  expect(pageClocks(document).subscribers).toBe(0);
  const hidden = container.textContent;
  await act(async () => jest.advanceTimersByTime(10_000));
  expect(container.textContent).toBe(hidden);
  await draw(true);
  expect(container.textContent).not.toBe(hidden);
  expect(pageClocks(document).subscribers).toBe(1);
});

type Call = { method: string; params?: Record<string, unknown> };
/** A host that answers each method from a queue of replies (a thrown value rejects). */
function host(replies: Record<string, unknown[]>) {
  const calls: Call[] = [];
  const request = <T,>(method: string, params?: Record<string, unknown>): Promise<T> => {
    calls.push({ method, params });
    const next = replies[method]?.shift();
    return next instanceof Error ? Promise.reject(next) : Promise.resolve(next as T);
  };
  return { calls, request };
}

async function render(recovery: RepoRecovery, request: ReturnType<typeof host>["request"]) {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(<RepoRecoveryCard recovery={recovery} request={request} />);
  });
  return container;
}

async function click(container: HTMLElement, label: string) {
  const button = [...container.querySelectorAll("button")].find((node) => node.textContent === label);
  if (!button) throw new Error(`no button "${label}" in: ${container.textContent}`);
  await act(async () => {
    button.dispatchEvent(new dom!.window.MouseEvent("click", { bubbles: true }));
  });
}

/** Polls, one event-loop turn at a time, until `done` holds (the card's first ask again comes within a second). */
async function until(done: () => boolean, ms = 4_000) {
  const end = Date.now() + ms;
  while (!done()) {
    if (Date.now() > end) throw new Error("timed out waiting");
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  }
}

const retry = {
  action: "cloud.repo.add",
  args: { session: "s", repo: "acme/demo" },
  wait_action: "cloud.repo.wait_github",
};
const url = "https://github.com/apps/cmux/installations/new";

test("a connect that didn't take waits for GitHub again on its own and ends in the connected chip", async () => {
  const { calls, request } = host({
    "cloud.repo.wait_github": [{ connected: false }, { connected: true }],
    "cloud.repo.add": [{ state: "done", repo: "acme/demo" }],
  });
  const card = await render({ code: "repo.needs_github", installUrl: url, retry }, request);
  expect(card.textContent).toContain(translate("cloudRepository.connectNeeded", { target: "acme/demo" }));
  await click(card, translate("cloudRepository.connect"));
  expect(opened).toEqual([url]);
  expect(calls[0]).toEqual({ method: "cloud.repo.wait_github", params: { timeout_ms: 60_000 } });
  // No Check again: the card asks GitHub again by itself, once, and attaches.
  expect([...card.querySelectorAll("button")].map((node) => node.textContent)).toEqual([
    translate("cloudRepository.openGithubAgain"),
  ]);
  await until(() => card.querySelector(".cv-repo-recovery__chip") !== null);
  expect(calls.map((call) => call.method)).toEqual([
    "cloud.repo.wait_github",
    "cloud.repo.wait_github",
    "cloud.repo.add",
  ]);
  const chip = card.querySelector(".cv-repo-recovery__chip");
  expect(chip?.textContent).toBe(translate("cloudRepository.connectedAttached", { repo: "acme/demo" }));
});

test("a failed attach offers Try again, which retries the same repository", async () => {
  const { calls, request } = host({
    "cloud.repo.wait_github": [{ connected: true }],
    "cloud.repo.add": [{ code: "repo.clone_failed" }, { state: "done", repo: "acme/demo" }],
  });
  const card = await render({ code: "repo.needs_github", installUrl: url, retry }, request);
  await click(card, translate("cloudRepository.connect"));
  expect(card.querySelector("[role=alert]")?.textContent).toContain(
    translate("cloudRepository.attachFailedRepo", { target: "acme/demo" }),
  );
  await click(card, translate("cloudRepository.tryAgain"));
  expect(calls.filter((call) => call.method === "cloud.repo.add").map((call) => call.params)).toEqual([
    retry.args,
    retry.args,
  ]);
  expect(card.querySelector(".cv-repo-recovery__chip")).not.toBeNull();
});

test("no install link: Connect fetches one from the app, opens it and waits", async () => {
  const { calls, request } = host({
    "cloud.repo.local": [{ connect: { install_url: url } }],
    "cloud.repo.wait_github": [{ connected: true }],
    "cloud.repo.add": [{ state: "done", repo: "acme/demo" }],
  });
  const card = await render({ code: "repo.needs_github", retry }, request);
  await click(card, translate("cloudRepository.connect"));
  expect(opened).toEqual([url]);
  expect(calls.map((call) => call.method)).toEqual(["cloud.repo.local", "cloud.repo.wait_github", "cloud.repo.add"]);
  expect(card.querySelector(".cv-repo-recovery__chip")).not.toBeNull();
});

test("no install link yet: no button; the card asks the app again on its own and brings Connect back", async () => {
  const { calls, request } = host({ "cloud.repo.local": [{}, { connect: { install_url: url } }] });
  const card = await render({ code: "repo.needs_github", retry }, request);
  await click(card, translate("cloudRepository.connect"));
  expect(card.textContent).toContain(translate("cloudRepository.linking"));
  expect(card.querySelectorAll("button").length).toBe(0);
  await until(() => calls.length === 2 && card.querySelectorAll("button").length > 0);
  // The link found on the card's own ask opens nothing by itself: Connect opens it.
  expect(opened).toEqual([]);
  expect([...card.querySelectorAll("button")].map((node) => node.textContent)).toEqual([
    translate("cloudRepository.connect"),
  ]);
});

test("the retried attach still needing GitHub goes back to waiting on GitHub, not to a failure", async () => {
  const { request } = host({
    "cloud.repo.wait_github": [{ connected: true }],
    "cloud.repo.add": [{ code: "repo.needs_github" }],
  });
  const card = await render({ code: "repo.needs_github", installUrl: url, retry }, request);
  await click(card, translate("cloudRepository.connect"));
  expect(card.textContent).toContain(translate("cloudRepository.waitingGithub"));
  expect(card.querySelector("[role=alert]")).toBeNull();
});

test("no access: Install opens GitHub with no wait, and Try again adds the same repository here once access is granted", async () => {
  const again = { action: "cloud.repo.add", args: { session: "s", repo: "acme/demo" } };
  const { calls, request } = host({ "cloud.repo.add": [{ state: "done", repo: "acme/demo" }] });
  const card = await render({ code: "repo.no_access", org: "acme", installUrl: url, retry: again }, request);
  await click(card, translate("cloudRepository.installOn", { target: "acme" }));
  expect(opened).toEqual([url]);
  // GitHub is connected already: nothing to wait on, and nothing runs before the person comes back.
  expect(calls).toEqual([]);
  await click(card, translate("cloudRepository.tryAgain"));
  expect(calls).toEqual([{ method: "cloud.repo.add", params: again.args }]);
  expect(card.querySelector(".cv-repo-recovery__chip")?.textContent).toBe(
    translate("cloudRepository.attachedRepo", { repo: "acme/demo" }),
  );
});
