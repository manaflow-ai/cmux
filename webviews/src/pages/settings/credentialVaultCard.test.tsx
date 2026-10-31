// Chief > Credential Vault (cmux issue 26412): the card lists every vault secret by name with its
// last use and scope, and its gestures go to the host (which shows the secure sheets). It never
// receives or shows a value.
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle, click, ops } = await import("./testing");

const card = (container: HTMLElement) => container.querySelector<HTMLElement>('[data-card="credential-vault"]');
const row = (container: HTMLElement, name: string) =>
  card(container)!.querySelector<HTMLElement>(`[data-vault-secret="${name}"]`)!;
const names = (container: HTMLElement) =>
  [...card(container)!.querySelectorAll<HTMLElement>("[data-vault-secret]")].map((el) => el.dataset.vaultSecret);

test("the Chief page lists each vault secret by name, its use and who may use it", async () => {
  const page = await renderPage({ path: "/settings/chief" });
  await settle();
  expect(card(page.container)?.querySelector(".group-title")?.textContent).toBe("Credential Vault");
  expect(names(page.container)).toEqual(["GH_TOKEN", "OPENAI_API_KEY"]);
  expect(row(page.container, "GH_TOKEN").querySelector(".row-help")?.getAttribute("aria-label")).toContain(
    "agent session 4f2a",
  );
  expect(row(page.container, "OPENAI_API_KEY").querySelector(".row-help")?.textContent).toContain("Never used");
  expect(row(page.container, "OPENAI_API_KEY").querySelector(".row-help")?.textContent).toContain("work account");
  const agents = (name: string) =>
    row(page.container, name).querySelector<HTMLButtonElement>('[role="switch"]')!.getAttribute("aria-checked");
  expect(agents("GH_TOKEN")).toBe("true");
  expect(agents("OPENAI_API_KEY")).toBe("false");
  page.unmount();
});

test("Add, Replace, Delete and the Agents switch go to the host, and the list follows", async () => {
  const page = await renderPage({ path: "/settings/chief" });
  await settle();
  await click(card(page.container)!.querySelector<HTMLButtonElement>('[data-vault="add"]')!);
  await settle();
  expect(ops(page.provider, "cmux.settings.credential_vault.add")).toEqual([{}]);
  expect(names(page.container)).toContain("NEW_TOKEN");

  await click(row(page.container, "GH_TOKEN").querySelector<HTMLButtonElement>('[data-vault="replace"]')!);
  await settle();
  expect(ops(page.provider, "cmux.settings.credential_vault.replace")).toEqual([{ name: "GH_TOKEN" }]);

  await click(row(page.container, "GH_TOKEN").querySelector<HTMLButtonElement>('[role="switch"]')!);
  await settle();
  expect(ops(page.provider, "cmux.settings.credential_vault.scope")).toEqual([{ name: "GH_TOKEN", scope: ["user"] }]);
  expect(row(page.container, "GH_TOKEN").querySelector('[role="switch"]')!.getAttribute("aria-checked")).toBe("false");

  await click(row(page.container, "OPENAI_API_KEY").querySelector<HTMLButtonElement>('[data-vault="remove"]')!);
  await settle();
  expect(ops(page.provider, "cmux.settings.credential_vault.remove")).toEqual([{ name: "OPENAI_API_KEY" }]);
  expect(names(page.container)).not.toContain("OPENAI_API_KEY");
  page.unmount();
});

test("an empty vault says how to add one, and a build without the vault has no card", async () => {
  const empty = await renderPage({
    path: "/settings/chief",
    setup: (provider) =>
      provider.setHost({ ...provider.host, credential_vault: { loaded: true, error: null, secrets: [] } }),
  });
  await settle();
  expect(card(empty.container)?.textContent).toContain("cmux vault set");
  empty.unmount();

  const none = await renderPage({
    path: "/settings/chief",
    setup: (provider) => provider.setHost({ ...provider.host, credential_vault: null }),
  });
  await settle();
  expect(card(none.container)).toBeNull();
  none.unmount();
});

test("the Agents switch changes only agents: an agents-only secret never gains the person", async () => {
  const { withAgents } = await import("./components/CredentialVaultCard");
  expect(withAgents(["agents"], false)).toEqual(["user"]);
  expect(withAgents(["agents"], true)).toEqual(["agents"]);
  expect(withAgents(["user", "agents"], false)).toEqual(["user"]);
  expect(withAgents(["user"], true)).toEqual(["user", "agents"]);
});

test("vault use summaries stay short and preserve the full details", async () => {
  const note = "work account ".repeat(12);
  const page = await renderPage({
    path: "/settings/chief",
    setup: (provider) => {
      const vault = provider.host.credential_vault!;
      provider.setHost({
        ...provider.host,
        credential_vault: {
          ...vault,
          secrets: vault.secrets.map((secret) => ({ ...secret, note })),
        },
      });
    },
  });
  await settle();
  const segmenter = new Intl.Segmenter(undefined, { granularity: "grapheme" });
  for (const line of card(page.container)!.querySelectorAll<HTMLElement>(".row-help")) {
    expect([...segmenter.segment(line.textContent ?? "")].length).toBeLessThanOrEqual(60);
  }
  const used = row(page.container, "GH_TOKEN").querySelector<HTMLElement>(".row-help")!;
  expect(used.title).toContain("agent session 4f2a");
  expect(used.title).toContain(note);
  expect(used.getAttribute("aria-label")).toBe(used.title);
  page.unmount();
});

test.each([Number.MAX_SAFE_INTEGER, Number.MIN_SAFE_INTEGER])(
  "an out-of-range vault use timestamp (%p) leaves the Chief controls usable",
  async (last_used_ms) => {
    const page = await renderPage({
      path: "/settings/chief",
      setup: (provider) => {
        const vault = provider.host.credential_vault!;
        provider.setHost({
          ...provider.host,
          credential_vault: {
            ...vault,
            secrets: vault.secrets.map((secret) => ({ ...secret, last_used_ms })),
          },
        });
      },
    });
    try {
      await settle();
      expect(names(page.container)).toEqual(["GH_TOKEN", "OPENAI_API_KEY"]);
      expect(row(page.container, "GH_TOKEN").querySelector(".row-help")?.textContent).toContain("Never used");
      await click(row(page.container, "GH_TOKEN").querySelector<HTMLButtonElement>('[role="switch"]')!);
      await settle();
      expect(ops(page.provider, "cmux.settings.credential_vault.scope")).toEqual([
        { name: "GH_TOKEN", scope: ["user"] },
      ]);
    } finally {
      page.unmount();
    }
  },
);
