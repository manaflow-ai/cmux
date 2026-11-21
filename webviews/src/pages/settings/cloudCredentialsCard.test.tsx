// Settings > Cloud > Cloud Credentials (https://github.com/manaflow-ai/cmux/issues/48427): the page reads the
// team's issuer from the host (`cmux.settings.cloudCredentials.state`) when the card opens, shows the issuer,
// discovery and JWKS URLs, and fills each cloud's setup steps with that team's issuer and id. Signed out it
// explains; a refused read offers Try Again, which reads again.
import { afterAll, expect, test } from "bun:test";
import type { MockSettingsProvider } from "./mockProvider";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle, click } = await import("./testing");

const card = (container: HTMLElement) => container.querySelector<HTMLElement>('[data-card="cloudCredentials"]')!;

async function open(setup?: (provider: MockSettingsProvider) => void) {
  const page = await renderPage({ path: "/settings/cloud", setup });
  await settle();
  return page;
}

test("the card shows the team's issuer URLs and fills every cloud's steps with them", async () => {
  const page = await open();
  const element = card(page.container);
  const info = page.provider.cloudCredentials.info!;
  const value = (id: string) =>
    element.querySelector(`[data-credentials-url="${id}"] [data-credentials-value]`)!.textContent;
  expect(value("issuer")).toBe(info.issuer);
  expect(value("discovery")).toBe(info.discovery_url);
  expect(value("jwks")).toBe(info.jwks_url);
  expect(value("subject")).toBe(info.subject_format);
  const providers = [...element.querySelectorAll("[data-credentials-provider]")].map((row) =>
    row.getAttribute("data-credentials-provider"),
  );
  expect(providers).toEqual(["aws", "gcp", "azure", "vault", "generic"]);
  // Each cloud's steps name this team's issuer; AWS trusts only this team's machines.
  for (const provider of providers) {
    const row = element.querySelector<HTMLElement>(`[data-credentials-provider="${provider}"]`)!;
    await click(row.querySelector<HTMLButtonElement>("button")!);
    await settle();
    const steps = row.querySelector(`[data-credentials-steps="${provider}"]`)!;
    expect(steps.textContent).toContain(provider === "aws" ? info.issuer.replace(/^https:\/\//, "") : info.issuer);
    expect(steps.querySelector('[data-credentials-step="machine"]')!.textContent).toContain("/run/cmux-oidc/token");
  }
  expect(element.querySelector('[data-credentials-steps="aws"]')!.textContent).toContain(`team:${info.team}:machine:*`);
  page.unmount();
});

test("signed out the card explains, and a refused read offers Try Again that reads again", async () => {
  const signedOut = await open((provider) => {
    provider.cloudCredentials = { available: false };
  });
  expect(card(signedOut.container).querySelector("[data-credentials-unavailable]")).not.toBeNull();
  expect(card(signedOut.container).querySelector("[data-credentials-url]")).toBeNull();
  signedOut.unmount();

  const refused = await open((provider) => {
    provider.cloudCredentials = { available: true, error: "auth.forbidden" };
  });
  const element = card(refused.container);
  expect(element.querySelector('[data-credentials-error="auth.forbidden"]')).not.toBeNull();
  const good = new (await import("./mockProvider")).MockSettingsProvider().cloudCredentials;
  refused.provider.cloudCredentials = good;
  await click(element.querySelector<HTMLButtonElement>("[data-credentials-refresh]")!);
  await settle();
  expect(
    card(refused.container).querySelector('[data-credentials-url="issuer"] [data-credentials-value]')!.textContent,
  ).toBe(good.info!.issuer);
  refused.unmount();
});
