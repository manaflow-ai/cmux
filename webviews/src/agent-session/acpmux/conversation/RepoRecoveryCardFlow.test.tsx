// l10n-allow-file: test fixtures, not shipped UI.
// The repository recovery card from click to verified chip: a connect that didn't take says so and
// offers Check again, a failure offers Try again, a missing install link is fetched, and a
// verified attach ends in the "GitHub connected" chip.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { translate } from "../i18n";
import { RepoRecoveryCard } from "./RepoRecoveryCard";
import type { RepoRecovery } from "./repoRecoveryCardModel";
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

const retry = {
  action: "cloud.repo.add",
  args: { session: "s", repo: "acme/demo" },
  wait_action: "cloud.repo.wait_github",
};
const url = "https://github.com/apps/cmux/installations/new";

test("a connect that didn't take says so; Check again verifies and ends in the connected chip", async () => {
  const { calls, request } = host({
    "cloud.repo.wait_github": [{ connected: false }, { connected: true }],
    "cloud.repo.add": [{ state: "done", repo: "acme/demo" }],
  });
  const card = await render({ code: "repo.needs_github", installUrl: url, retry }, request);
  expect(card.textContent).toContain(translate("cloudRepository.connectNeeded", { target: "acme/demo" }));
  await click(card, translate("cloudRepository.connect"));
  expect(opened).toEqual([url]);
  expect(calls[0]).toEqual({ method: "cloud.repo.wait_github", params: { timeout_ms: 60_000 } });
  expect(card.textContent).toContain(translate("cloudRepository.notConnectedYet"));
  await click(card, translate("cloudRepository.checkAgain"));
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

test("no install link anywhere: says so and offers Try again and Check again", async () => {
  const { request } = host({ "cloud.repo.local": [{}] });
  const card = await render({ code: "repo.needs_github", retry }, request);
  await click(card, translate("cloudRepository.connect"));
  expect(card.textContent).toContain(translate("cloudRepository.noLink"));
  const labels = [...card.querySelectorAll("button")].map((node) => node.textContent);
  expect(labels).toEqual([translate("cloudRepository.tryAgain"), translate("cloudRepository.checkAgain")]);
});

test("the retried attach still needing GitHub goes back to Check again, not to a failure", async () => {
  const { request } = host({
    "cloud.repo.wait_github": [{ connected: true }],
    "cloud.repo.add": [{ code: "repo.needs_github" }],
  });
  const card = await render({ code: "repo.needs_github", installUrl: url, retry }, request);
  await click(card, translate("cloudRepository.connect"));
  expect(card.textContent).toContain(translate("cloudRepository.notConnectedYet"));
});
