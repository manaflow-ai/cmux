// Settings > Cloud > Environment (RFD 0222 (c)1): the card reads the daemon's `vault-env` list and
// grants, sends Add, Edit and Delete as `cmux.settings.vault.run`, refuses a key-shaped variable
// before sending (one click moves it to Secrets with what was typed), and is not drawn on a daemon
// without `vault-env-v1`.
import { afterAll, expect, test } from "bun:test";
import type { MockSettingsProvider } from "./mockProvider";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle, changeValue, click } = await import("./testing");

const card = (container: HTMLElement) => container.querySelector<HTMLElement>('[data-card="environmentVault"]');

async function open(setup?: (provider: MockSettingsProvider) => void) {
  const page = await renderPage({ path: "/settings/cloud", setup });
  await settle();
  return page;
}

test("Variables, Secrets and machine grants list what the daemon answers, never a value", async () => {
  const page = await open();
  const element = card(page.container)!;
  const variables = element.querySelector('[data-vault-list="env"]')!;
  const secrets = element.querySelector('[data-vault-list="proxy"]')!;
  expect(variables.querySelector('[data-vault-entry="NODE_ENV"]')).not.toBeNull();
  expect(secrets.querySelector('[data-vault-entry="GITHUB_TOKEN"]')!.textContent).toContain("api.github.com");
  expect(secrets.querySelector('[data-vault-entry="STRIPE_SECRET_KEY"]')!.textContent).toContain(
    "Not sent to any host yet",
  );
  const grants = element.querySelector('[data-vault-list="grants"]')!;
  expect(grants.querySelector('[data-vault-grant="mac-studio"]')!.textContent).toContain("All entries");
  const revoked = grants.querySelector('[data-vault-grant="vm_7f3a"]')!;
  expect(revoked.textContent).toContain("GITHUB_TOKEN");
  expect(revoked.textContent).toContain("Revoked");
  page.unmount();
});

test("Add Secret sends set with proxy delivery and the typed hosts, then the value field is gone", async () => {
  const page = await open();
  await click(card(page.container)!.querySelector('[data-vault="addSecret"]')!);
  const form = () => card(page.container)!.querySelector<HTMLElement>('[data-vault-form="proxy"]');
  const value = form()!.querySelector<HTMLInputElement>('[data-vault-field="value"]')!;
  expect(value.type).toBe("password");
  await changeValue(form()!.querySelector('[data-vault-field="name"]')!, "OPENAI_API_KEY");
  await changeValue(value, "sk-test");
  await changeValue(form()!.querySelector('[data-vault-field="hosts"]')!, "api.openai.com, *.openai.com");
  await click(form()!.querySelector('[data-vault="save"]')!);
  await settle();
  expect(page.provider.vaultRuns.at(-1)).toEqual({
    action: "set",
    params: {
      name: "OPENAI_API_KEY",
      value: "sk-test",
      delivery: "proxy",
      allowedHosts: ["api.openai.com", "*.openai.com"],
    },
  });
  expect(form()).toBeNull();
  const row = card(page.container)!.querySelector('[data-vault-list="proxy"] [data-vault-entry="OPENAI_API_KEY"]')!;
  expect(row.textContent).not.toContain("sk-test");
  page.unmount();
});

test("a key-shaped variable is refused before sending; Add as Secret carries the name and value", async () => {
  const page = await open();
  const before = page.provider.vaultRuns.length;
  await click(card(page.container)!.querySelector('[data-vault="addVariable"]')!);
  const variableForm = card(page.container)!.querySelector<HTMLElement>('[data-vault-form="env"]')!;
  await changeValue(variableForm.querySelector('[data-vault-field="name"]')!, "ANTHROPIC_API_KEY");
  await changeValue(variableForm.querySelector('[data-vault-field="value"]')!, "typed-once");
  await click(variableForm.querySelector('[data-vault="save"]')!);
  await settle();
  expect(page.provider.vaultRuns.length).toBe(before);
  const refusal = card(page.container)!.querySelector('[data-vault-failure="keyShaped"]')!;
  expect(refusal.textContent).toContain("ANTHROPIC_API_KEY looks like a key");
  await click(refusal.querySelector('[data-vault="useSecret"]')!);
  const secretForm = card(page.container)!.querySelector<HTMLElement>('[data-vault-form="proxy"]')!;
  expect(secretForm.querySelector<HTMLInputElement>('[data-vault-field="name"]')!.value).toBe("ANTHROPIC_API_KEY");
  expect(secretForm.querySelector<HTMLInputElement>('[data-vault-field="value"]')!.value).toBe("typed-once");
  page.unmount();
});

test("Edit moves a secret's hosts with policy, and Delete sends rm", async () => {
  const page = await open();
  const entry = () => card(page.container)!.querySelector<HTMLElement>('[data-vault-entry="STRIPE_SECRET_KEY"]');
  await click(entry()!.querySelector('[data-vault-action="edit"]')!);
  const policy = entry()!.querySelector<HTMLElement>('[data-vault-policy="STRIPE_SECRET_KEY"]')!;
  await changeValue(policy.querySelector('[data-vault-field="hosts"]')!, "api.stripe.com");
  await click(policy.querySelector('[data-vault="save"]')!);
  await settle();
  expect(page.provider.vaultRuns.at(-1)).toEqual({
    action: "policy",
    params: { name: "STRIPE_SECRET_KEY", delivery: "proxy", allowedHosts: ["api.stripe.com"] },
  });
  expect(entry()!.textContent).toContain("api.stripe.com");
  await click(entry()!.querySelector('[data-vault-action="delete"]')!);
  await settle();
  expect(page.provider.vaultRuns.at(-1)).toEqual({ action: "rm", params: { name: "STRIPE_SECRET_KEY" } });
  expect(entry()).toBeNull();
  page.unmount();
});

test("a daemon refusal reads as its own sentence", async () => {
  const page = await open();
  await click(card(page.container)!.querySelector('[data-vault="addVariable"]')!);
  const form = card(page.container)!.querySelector<HTMLElement>('[data-vault-form="env"]')!;
  await changeValue(form.querySelector('[data-vault-field="name"]')!, "9BAD");
  await changeValue(form.querySelector('[data-vault-field="value"]')!, "x");
  await click(form.querySelector('[data-vault="save"]')!);
  await settle();
  expect(card(page.container)!.querySelector('[role="alert"]')!.textContent).toContain("That name can't be used");
  page.unmount();
});

test("a daemon without vault-env-v1 draws no card; signed out explains", async () => {
  const unsupported = await open((provider) => {
    provider.vault = { available: true, unsupported: true, entries: [], grants: [] };
  });
  expect(card(unsupported.container)).toBeNull();
  unsupported.unmount();
  const signedOut = await open((provider) => {
    provider.vault = { available: false, unsupported: false, entries: [], grants: [] };
  });
  expect(card(signedOut.container)!.querySelector("[data-vault-unavailable]")!.textContent).toContain("Sign in");
  signedOut.unmount();
});

test("a failed grants read keeps the lists and says so in place of No machine has access", async () => {
  const page = await open((provider) => {
    provider.vault = { ...provider.vault, grants: [], grantsCode: "http_503" };
  });
  const element = card(page.container)!;
  expect(element.querySelector('[data-vault-entry="NODE_ENV"]')).not.toBeNull();
  expect(element.querySelector('[data-vault-failure="grants"]')!.textContent).toContain("Couldn't load");
  expect(element.querySelector('[data-vault-empty="grants"]')).toBeNull();
  page.unmount();
});
