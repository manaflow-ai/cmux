// Agents > Harnesses (cx-mg91): the card lists acpmux's harnesses from the host, follows a change
// live, reads again when it opens, and its buttons send the host's terminal gestures (Sign In and
// Check run `acpmux harness login <id>` in a terminal tab; the host checks the id).
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle } = await import("./testing");

const card = (container: HTMLElement) => container.querySelector<HTMLElement>('[data-card="harnesses"]');
const ids = (element: HTMLElement) =>
  [...element.querySelectorAll<HTMLElement>("[data-harness]")].map((row) => row.dataset.harness);

test("the card lists the host's harnesses with their names and reads them again when it opens", async () => {
  const page = await renderPage({ path: "/settings/agents" });
  await settle();
  const element = card(page.container)!;
  expect(ids(element)).toEqual(["claude", "codex", "github-copilot-cli", "aider"]);
  expect(element.textContent).toContain("Claude Code");
  expect(element.textContent).toContain("GitHub Copilot");
  expect(page.provider.harnessRuns[0]).toEqual({ action: "refresh" });
  // A terminal-only harness has no sign-in buttons.
  const aider = element.querySelector<HTMLElement>('[data-harness="aider"]')!;
  expect(aider.querySelector("[data-harness-action]")).toBeNull();
  page.unmount();
});

test("Sign In and Check send the gesture for that harness; Browse ACP Registry sends its own", async () => {
  const page = await renderPage({ path: "/settings/agents" });
  await settle();
  const element = card(page.container)!;
  const press = async (selector: string) => {
    await act(async () => element.querySelector<HTMLButtonElement>(selector)!.click());
    await settle();
  };
  await press('[data-harness="codex"] [data-harness-action="signIn"]');
  await press('[data-harness="github-copilot-cli"] [data-harness-action="check"]');
  await press('[data-harness-action="registry"]');
  expect(page.provider.harnessRuns.filter((run) => run.action !== "refresh")).toEqual([
    { action: "signIn", id: "codex" },
    { action: "check", id: "github-copilot-cli" },
    { action: "registry" },
  ]);
  page.unmount();
});

test("a change from the host shows without a reload; no daemon says why", async () => {
  const page = await renderPage({ path: "/settings/agents" });
  await settle();
  await act(async () =>
    page.provider.setHarnesses({
      loading: false,
      problem: null,
      harnesses: [{ id: "grok", name: null, kind: "acp", source: "path", problem: "grok: not signed in" }],
    }),
  );
  await settle();
  let element = card(page.container)!;
  expect(ids(element)).toEqual(["grok"]);
  expect(element.textContent).toContain("grok: not signed in");
  await act(async () => page.provider.setHarnesses({ loading: false, problem: "unreachable", harnesses: [] }));
  await settle();
  element = card(page.container)!;
  expect(element.querySelector<HTMLElement>("[data-harnesses-problem]")!.dataset.harnessesProblem).toBe("unreachable");
  expect(element.textContent).toContain("acpmux did not answer");
  page.unmount();
});
