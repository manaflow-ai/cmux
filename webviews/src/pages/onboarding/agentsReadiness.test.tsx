// The agents step with the providers' readiness (logins done right): one list, each provider once.
// The host sends `signInReadiness` and `signInAccounts`; Claude Code and Codex take their
// provider's state and one action in place, GitHub is one more row of the same list, and a sign-in
// runs over `cmux.onboarding.accounts.run` through the controller Settings uses. Without the keys
// the list is exactly as before.
import { afterAll, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { renderToStaticMarkup } from "react-dom/server";
import { installDom } from "../settings/testDom";
import { createStrings } from "../shared/i18n";
import { ACCOUNT_ACTIONS } from "../shared/signIn/accountSignIn";
import { READINESS, type ReadinessFixture } from "../shared/signIn/galleryFixtures";
import { agentsState, withReadiness } from "./fixtures";
import table from "./generated/strings.json";
import { MockOnboardingProvider } from "./mockProvider";
import { OnboardingPage } from "./Onboarding";
import { OPS, type OnboardingState } from "./ops";
import { OnboardingStore } from "./store";

const restore = installDom();
afterAll(() => restore());

const strings = createStrings(table, ["en"]);

const stateFor = (readiness?: ReadinessFixture): OnboardingState =>
  readiness ? withReadiness(agentsState("mixed"), READINESS[readiness]) : agentsState("mixed");

function render(readiness?: ReadinessFixture): string {
  const store = new OnboardingStore(null, stateFor(readiness));
  return renderToStaticMarkup(<OnboardingPage store={store} strings={strings} />);
}

const count = (html: string, needle: string) => html.split(needle).length - 1;
const row = (html: string, agent: string) => {
  const start = html.indexOf(`class="onb-agent" data-agent="${agent}"`);
  const end = html.indexOf("</li>", start);
  return html.slice(start, end);
};

/** The page on the mock host, its sign-in recorded. */
async function mount(readiness: ReadinessFixture, setup?: (mock: MockOnboardingProvider) => void) {
  const mock = new MockOnboardingProvider("agents", stateFor(readiness));
  const runs: { op: string; params: unknown }[] = [];
  const call = mock.call.bind(mock);
  mock.call = async <R,>(op: string, params: unknown): Promise<R> => {
    runs.push({ op, params });
    return call<R>(op, params);
  };
  setup?.(mock);
  const store = new OnboardingStore(mock);
  const root = document.createElement("div");
  document.body.append(root);
  const react = createRoot(root);
  await act(async () => {
    react.render(<OnboardingPage store={store} strings={strings} />);
    await store.start();
  });
  const settle = () => act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
  const rowOf = (agent: string) => root.querySelector<HTMLElement>(`.onb-agent[data-agent="${agent}"]`)!;
  const click = (agent: string) =>
    act(async () => rowOf(agent).querySelector<HTMLButtonElement>("[data-ready-action]")!.click());
  return {
    root,
    runs,
    rowOf,
    click,
    settle,
    unmount: () => {
      act(() => react.unmount());
      store.stop();
      root.remove();
    },
  };
}

test("one list: each provider once, GitHub as one more row", () => {
  for (const fixture of Object.keys(READINESS) as ReadinessFixture[]) {
    const html = render(fixture);
    expect(count(html, 'class="onb-agent-list"')).toBe(1);
    for (const agent of ["claude", "codex", "gemini", "opencode", "github"])
      expect(count(html, `class="onb-agent" data-agent="${agent}"`)).toBe(1);
  }
});

test("each row shows the daemon's state; installing comes from the agents rows", () => {
  const html = render("mixed");
  expect(row(html, "github")).toContain('data-ready-action="addAccount"');
  expect(row(html, "github")).toContain("Signed in as octocat");
  expect(row(html, "codex")).toContain('data-ready-state="installing"');
  expect(row(html, "codex")).not.toContain("data-ready-action=");
  expect(row(html, "claude")).toContain('data-ready-action="signIn"');
  // Agents with no provider keep their own rows.
  expect(row(html, "gemini")).toContain('data-trailing="signIn"');
  const fresh = render("fresh");
  expect(row(fresh, "codex")).toContain('data-ready-action="install"');
  expect(row(fresh, "github")).toContain('data-ready-action="signIn"');
});

test("without the keys the list is as before", () => {
  const html = render();
  expect(html).not.toContain("data-ready-");
  expect(html).not.toContain('data-agent="github"');
  expect(count(html, 'class="onb-agent"')).toBe(4);
});

test("Sign In runs over cmux.onboarding.accounts.run: the code in its own row, then ready by itself", async () => {
  let release!: () => void;
  const page = await mount("signingIn", (mock) => {
    mock.signIn.hold = new Promise<void>((resolve) => (release = resolve));
  });
  await page.click("codex");
  await page.settle();
  const codex = page.rowOf("codex");
  expect(codex.dataset.readyState).toBe("signingIn");
  expect(codex.textContent).toContain("K7QX-29PF");
  expect(page.root.textContent!.split("K7QX-29PF").length - 1).toBe(1);
  const runs = page.runs
    .filter((run) => run.op === OPS.accountsRun)
    .map((run) => (run.params as { action: string }).action);
  expect(runs).toEqual([ACCOUNT_ACTIONS.start, ACCOUNT_ACTIONS.finish]);
  await act(async () => release());
  await page.settle();
  expect(page.rowOf("codex").dataset.readyState).toBe("ready");
  expect(page.rowOf("codex").querySelector('[data-ready-action="addAccount"]')).not.toBeNull();
  page.unmount();
});

test("a refused sign-in says why and offers Try Again, which starts again", async () => {
  const page = await mount("signingIn", (mock) => {
    mock.signIn.refusal = "cancelled";
  });
  await page.click("claude");
  await page.settle();
  const claude = page.rowOf("claude");
  expect(claude.dataset.readyState).toBe("failed");
  expect(claude.textContent).toContain("cancelled on the provider's page");
  await page.click("claude");
  await page.settle();
  const starts = page.runs.filter(
    (run) => run.op === OPS.accountsRun && (run.params as { action: string }).action === ACCOUNT_ACTIONS.start,
  );
  expect(starts.length).toBe(2);
  page.unmount();
});

test("Install runs the agents' install op", async () => {
  const page = await mount("fresh");
  await page.click("codex");
  expect(page.runs.some((run) => run.op === OPS.install && (run.params as { id: string }).id === "codex")).toBe(true);
  page.unmount();
});
