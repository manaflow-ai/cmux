import { act } from "react";
import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "./testDom";
import { githubAppName } from "./components/githubAppName.experiment";
import fixture from "./githubAppName.gallery";

const restore = installDom();
const previous = globalThis.cmuxExperiments;
afterEach(() => {
  globalThis.cmuxExperiments = previous;
});
afterAll(() => restore());
const { renderPage, settle } = await import("./testing");

async function render(arm?: string, variant = "disconnected") {
  globalThis.cmuxExperiments = arm ? { [githubAppName.id]: arm } : {};
  return renderPage({
    path: "/settings/accounts",
    setup(provider) {
      provider.accounts = fixture.variants[variant]!.accounts!;
    },
  });
}

test("GitHub App name proposals are absent by default and for stale arms", async () => {
  expect(githubAppName.defaultArm).toBe("off");
  for (const arm of [undefined, "off", "unknown"]) {
    const page = await render(arm);
    try {
      expect(page.container.querySelector("[data-github-name-preview]")).toBeNull();
      expect(page.container.querySelector('[data-github-action="connect"]')).not.toBeNull();
    } finally {
      page.unmount();
    }
  }
});

for (const [arm, name, bot] of [
  ["cmux", "cmux", "cmux[bot]"],
  ["agents", "cmux agents", "cmux-agents[bot]"],
  ["cloud", "cmux Cloud", "cmux-cloud[bot]"],
]) {
  test(`${arm} labels a proposal and preserves Connect GitHub`, async () => {
    const page = await render(arm);
    try {
      const preview = page.container.querySelector("[data-github-name-preview]")!;
      expect(preview.textContent).toContain(name!);
      expect(preview.textContent).toContain(bot!);
      expect(preview.textContent).toContain("Name proposal only. Your GitHub connection is unchanged.");
      await act(async () => page.container.querySelector<HTMLButtonElement>('[data-github-action="connect"]')!.click());
      await settle();
      expect(page.provider.accountRuns.at(-1)).toMatchObject({ action: "githubConnect" });
    } finally {
      page.unmount();
    }
  });

  test(`${arm} preserves sign-in, reconfigure and disconnect confirmation`, async () => {
    const signedOut = await render(arm, "signed-out");
    try {
      await act(async () => signedOut.container.querySelector<HTMLButtonElement>('[data-action="sign-in"]')!.click());
      await settle();
      expect(signedOut.provider.accountRuns.at(-1)).toMatchObject({ action: "signIn" });
    } finally {
      signedOut.unmount();
    }
    const page = await render(arm, "connected");
    try {
      await act(async () =>
        page.container.querySelector<HTMLButtonElement>('[data-github-action="reconfigure"]')!.click(),
      );
      await settle();
      expect(page.provider.accountRuns.at(-1)).toMatchObject({
        action: "githubReconfigure",
        account: "sample-github",
      });
      const before = page.provider.accountRuns.length;
      await act(async () =>
        page.container.querySelector<HTMLButtonElement>('[data-github-action="disconnect"]')!.click(),
      );
      await settle();
      expect(page.provider.accountRuns.length).toBe(before);
      const row = page.container.querySelector('[data-github-connection="sample-github"]')!;
      expect(row.querySelector("output")?.textContent).toBe("Disconnect GitHub?");
      const confirm = [...row.querySelectorAll<HTMLButtonElement>("button")].find(
        (button) => button.textContent === "Disconnect",
      )!;
      await act(async () => confirm.click());
      await settle();
      expect(page.provider.accountRuns.at(-1)).toMatchObject({
        action: "githubDisconnect",
        account: "sample-github",
      });
    } finally {
      page.unmount();
    }
  });
}
