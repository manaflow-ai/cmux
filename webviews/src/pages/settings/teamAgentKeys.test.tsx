// Settings > Accounts > Team agent keys: admins add, replace and remove the team's Claude and Codex
// keys (a password field and a kind choice; removal asks inline), members only read the status, and
// signed out the card offers Sign In. The pasted key is sent once and the field is cleared.
import { afterAll, expect, test } from "bun:test";
import { mockAgentKeys } from "./mockAgentKeys";
import type { TeamAgentKeysState } from "./ops";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, changeValue, click } = await import("./testing");

const render = (agentKeys: TeamAgentKeysState) =>
  renderPage({
    path: "/settings/accounts",
    setup: (provider) => {
      provider.accounts = { ...provider.accounts, agentKeys };
    },
  });
type Page = Awaited<ReturnType<typeof render>>;
const card = (page: Page) => page.container.querySelector<HTMLElement>('[data-card="team-agent-keys"]')!;
const row = (page: Page, agent: string) => card(page).querySelector<HTMLElement>(`[data-agent-key="${agent}"]`)!;
const action = (scope: ParentNode, id: string) =>
  scope.querySelector<HTMLButtonElement>(`[data-agent-key-action="${id}"]`);

test("an admin sees each agent's status and can add, replace and remove", async () => {
  const page = await render(mockAgentKeys.admin);
  expect(card(page).querySelector(".group-title")?.textContent).toBe("Team agent keys");
  expect(card(page).textContent).toContain("in place of their own keys");
  expect(row(page, "claude").textContent).toContain("Team key set");
  expect(row(page, "claude").textContent).toContain("…abcd");
  expect(action(row(page, "claude"), "edit")?.textContent).toBe("Replace");
  expect(action(row(page, "claude"), "remove")).not.toBeNull();
  expect(row(page, "codex").textContent).toContain("Not set");
  expect(action(row(page, "codex"), "edit")?.textContent).toBe("Add Key");
  expect(action(row(page, "codex"), "remove")).toBeNull();
  page.unmount();
});

test("saving sends the agent, kind and key once, then clears the field", async () => {
  const page = await render(mockAgentKeys.admin);
  await click(action(row(page, "codex"), "edit")!);
  const form = row(page, "codex").querySelector<HTMLFormElement>("[data-agent-key-form]")!;
  const field = form.querySelector<HTMLInputElement>('input[type="password"]')!;
  expect(action(form, "save")!.disabled).toBe(true);
  await changeValue(form.querySelector<HTMLSelectElement>("select")!, "oauth");
  await changeValue(field, "token-0123456789wxyz");
  await click(action(form, "save")!);
  const saves = page.provider.accountRuns.filter((run) => run.action === "agentKeySave");
  expect(saves).toEqual([{ action: "agentKeySave", provider: "codex", name: "oauth", secret: "token-0123456789wxyz" }]);
  expect(row(page, "codex").querySelector("[data-agent-key-form]")).toBeNull();
  expect(row(page, "codex").textContent).toContain("Team key set");
  expect(page.container.innerHTML).not.toContain("token-0123456789");
  page.unmount();
});

test("removing asks inline first and Cancel sends nothing", async () => {
  const page = await render(mockAgentKeys.admin);
  await click(action(row(page, "claude"), "remove")!);
  expect(row(page, "claude").querySelector("[data-agent-key-confirm]")?.textContent).toContain(
    "go back to their own keys",
  );
  await click([...row(page, "claude").querySelectorAll("button")].find((b) => b.textContent === "Cancel")!);
  expect(page.provider.accountRuns.some((run) => run.action === "agentKeyRemove")).toBe(false);
  await click(action(row(page, "claude"), "remove")!);
  await click(action(row(page, "claude"), "confirm-remove")!);
  expect(page.provider.accountRuns.at(-1)).toEqual({ action: "agentKeyRemove", provider: "claude" });
  expect(row(page, "claude").textContent).toContain("Not set");
  page.unmount();
});

test("a member reads the status and that admins manage it, with no controls", async () => {
  const page = await render(mockAgentKeys.member);
  expect(card(page).querySelector("[data-agent-keys-note]")?.textContent).toBe(
    "Your team's owners and admins manage these keys.",
  );
  expect(row(page, "claude").textContent).toContain("Team key set");
  expect(card(page).querySelector("[data-agent-key-action]")).toBeNull();
  expect(card(page).querySelector('input[type="password"]')).toBeNull();
  page.unmount();
});

test("signed out offers Sign In; a personal team has nothing to share", async () => {
  const signedOut = await render(mockAgentKeys.signedOut);
  expect(card(signedOut).querySelector('[data-action="sign-in"]')?.textContent).toBe("Sign In");
  expect(card(signedOut).querySelector("[data-agent-key]")).toBeNull();
  signedOut.unmount();
  const personal = await render(mockAgentKeys.personal);
  expect(card(personal).querySelector("[data-agent-keys-note]")?.textContent).toContain("personal team");
  expect(card(personal).querySelector("[data-agent-key]")).toBeNull();
  personal.unmount();
});

test("a refusal shows its copy on the agent's row", async () => {
  const page = await render(mockAgentKeys.conflict);
  expect(row(page, "claude").querySelector('[role="alert"]')?.textContent).toBe(
    "Another admin changed this key; try again.",
  );
  page.unmount();
});
