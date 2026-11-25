// The device sign-in card, the account list and the readiness rows (logins done right): each
// state draws its one action, the code is text only, and the adapter reads the daemon's wire.
import { act } from "react";
import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "../../settings/testDom";
import type { SignInView } from "./accountSignIn";

const restore = installDom();
afterAll(() => restore());
const { createRoot } = await import("react-dom/client");
const { DeviceSignInCard, primaryAction } = await import("./DeviceSignInCard");
const { AccountSwitcher } = await import("./AccountSwitcher");
const { readinessAction, agentFamily } = await import("./ProviderReadiness");
const { SIGN_IN_STATES, SIGN_IN_STATE_FAMILY, ACCOUNT_LISTS } = await import("./galleryFixtures");
const adapter = await import("./accountSignIn");

let unmount: (() => void) | null = null;
afterEach(() => {
  unmount?.();
  unmount = null;
  document.body.replaceChildren();
});

async function draw(node: React.ReactNode): Promise<HTMLElement> {
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  await act(async () => root.render(node));
  unmount = () => act(() => root.unmount());
  return container;
}

const noop = () => {};
const handlers = { onCopy: noop, onCancel: noop, onRetry: noop, onDone: noop, onInstall: noop, onSubmitCode: noop };
const actionsIn = (root: ParentNode) =>
  [...root.querySelectorAll<HTMLElement>("[data-sign-in-action]")].map((node) => node.dataset.signInAction);

const EXPECTED: Record<keyof typeof SIGN_IN_STATES, string[]> = {
  starting: ["cancel"],
  code: ["copy", "cancel"],
  "code-not-copied": ["copy", "cancel"],
  approve: ["cancel"],
  paste: ["continue", "cancel"],
  "signed-in": ["done"],
  expired: ["newCode"],
  cancelled: ["tryAgain"],
  "shared-machine": ["done"],
  failed: ["tryAgain"],
  "not-installed": ["install"],
};

for (const look of ["inline", "sheet", "strip"] as const) {
  for (const [name, view] of Object.entries(SIGN_IN_STATES) as [keyof typeof SIGN_IN_STATES, SignInView][]) {
    test(`${look}: ${name} draws its one action`, async () => {
      await draw(<DeviceSignInCard family={SIGN_IN_STATE_FAMILY[name]} view={view} look={look} {...handlers} />);
      // The sheet is a dialog, drawn in a portal: read the whole document.
      expect(actionsIn(document.body)).toEqual(EXPECTED[name]);
      expect(EXPECTED[name][0]).toBe(primaryAction(view));
      const solid = [...document.body.querySelectorAll<HTMLElement>('[data-sign-in-action][data-variant="solid"]')];
      expect(solid.length).toBeLessThanOrEqual(1);
    });
  }
}

test("the code is the visible text only: no attribute carries it", async () => {
  for (const look of ["inline", "sheet", "strip"] as const) {
    await draw(<DeviceSignInCard family="codex" view={SIGN_IN_STATES.code} look={look} {...handlers} />);
    expect(document.body.textContent).toContain("K7QX-29PF");
    const values = [document.body, ...document.body.querySelectorAll("*")].flatMap((node) =>
      [...node.attributes].map((attr) => attr.value),
    );
    expect(values.some((value) => value.includes("K7QX-29PF"))).toBe(false);
    unmount?.();
    unmount = null;
    document.body.replaceChildren();
  }
});

test("an expired code offers New Code and shows no code", async () => {
  let retried = 0;
  await draw(<DeviceSignInCard family="github" view={{ state: "expired" }} {...handlers} onRetry={() => retried++} />);
  expect(document.body.textContent).toContain("New Code");
  expect(document.body.textContent).not.toContain("WDJB-MJHT");
  await act(async () => document.body.querySelector<HTMLButtonElement>('[data-sign-in-action="newCode"]')!.click());
  expect(retried).toBe(1);
});

test("not installed without an installer closes instead of offering a dead button", async () => {
  await draw(<DeviceSignInCard family="claude" view={{ state: "notInstalled" }} onDone={noop} />);
  expect(actionsIn(document.body)).toEqual(["done"]);
});

test("the account list: one group per provider, the default marked, one Add account each", async () => {
  const root = await draw(<AccountSwitcher accounts={ACCOUNT_LISTS["twoEach"]} />);
  const groups = [...root.querySelectorAll<HTMLElement>("[data-sign-in-family]")].map(
    (node) => node.dataset.signInFamily,
  );
  expect(groups).toEqual(["github", "codex", "claude"]);
  expect(root.querySelectorAll('[data-sign-in-row-action="add"]').length).toBe(3);
  expect(root.querySelectorAll("[data-sign-in-default]").length).toBe(3);
  // The default offers no Use; the other does. The CLI's own login has no Remove.
  const codex1 = root.querySelector('[data-sign-in-account="codex-1"]')!;
  const codex2 = root.querySelector('[data-sign-in-account="codex-2"]')!;
  expect(codex1.querySelector('[data-sign-in-row-action="use"]')).toBeNull();
  expect(codex1.querySelector('[data-sign-in-row-action="remove"]')).toBeNull();
  expect(codex2.querySelector('[data-sign-in-row-action="use"]')).not.toBeNull();
});

test("the account list with none: each provider says so and offers Add account", async () => {
  const root = await draw(<AccountSwitcher accounts={ACCOUNT_LISTS["none"]} />);
  expect(root.querySelectorAll(".signin-none").length).toBe(3);
  expect(root.querySelectorAll('[data-sign-in-row-action="add"]').length).toBe(3);
});

test("a signed-out row offers Sign in, and inline puts the card in that row", async () => {
  const root = await draw(
    <AccountSwitcher
      accounts={ACCOUNT_LISTS["signedOut"]}
      look="inline"
      signIn={{ family: "codex", account: "codex-1", view: SIGN_IN_STATES.code }}
    />,
  );
  const row = root.querySelector('[data-sign-in-account="codex-1"]')!;
  expect(row.querySelector(".signin")).not.toBeNull();
  expect(root.querySelectorAll(".signin").length).toBe(1);
  expect(root.querySelector('[data-sign-in-account="github-2"] [data-sign-in-row-action="signIn"]')).not.toBeNull();
});

test("readiness: one action per state; installing and signing in only wait", () => {
  const states = ["notInstalled", "installing", "signInRequired", "signingIn", "ready", "failed"] as const;
  expect(states.map(readinessAction)).toEqual(["install", null, "signIn", null, "addAccount", "tryAgain"]);
  expect(["claude", "codex", "gemini", "opencode"].map(agentFamily)).toEqual(["claude", "codex", null, null]);
});

test("button labels are Title Case, as the pages' existing buttons", async () => {
  await draw(<DeviceSignInCard family="github" view={{ state: "expired" }} {...handlers} />);
  expect(document.body.textContent).toContain("New Code");
  expect(document.body.textContent).toContain("Sign In to GitHub");
});

test("Copy stays Copy after the code is copied (the line says it is copied)", async () => {
  await draw(<DeviceSignInCard family="codex" view={SIGN_IN_STATES.code} {...handlers} />);
  expect(document.body.querySelector('[data-sign-in-action="copy"]')!.textContent).toBe("Copy");
});

test("the adapter reads each way of finishing and checks the page", () => {
  const base = { account: "codex-2", loginId: "l1", needsCode: false, expiresAtMs: 1000, added: true };
  expect(
    adapter.parseSignInStart({ ...base, url: "https://auth.openai.com/codex/device", userCode: " K7QX-29PF " })?.way,
  ).toEqual({ kind: "code", code: "K7QX-29PF" });
  expect(adapter.parseSignInStart({ ...base, url: "https://github.com/login/device", userCode: "AB-CD" })?.url).toBe(
    "https://github.com/login/device",
  );
  expect(adapter.parseSignInStart({ ...base, url: "https://claude.ai/oauth/authorize", needsCode: true })?.way).toEqual(
    {
      kind: "paste",
    },
  );
  const auto = "https://claude.ai/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A54545%2Fcallback";
  expect(adapter.parseSignInStart({ ...base, url: auto, autoUrl: auto, callbackPort: 54545 })?.way).toEqual({
    kind: "approve",
  });
  // The port must match the daemon's, or the person pastes the code.
  expect(adapter.parseSignInStart({ ...base, url: auto, autoUrl: auto, callbackPort: 1 })?.way).toEqual({
    kind: "paste",
  });
  // Only a provider's own https page.
  expect(adapter.parseSignInStart({ ...base, url: "https://evil.example.com/login", userCode: "X" })).toBeUndefined();
  expect(adapter.parseSignInStart({ ...base, url: "http://github.com/login/device", userCode: "X" })).toBeUndefined();
  expect(adapter.parseSignInStart({ ...base, loginId: "", url: "https://github.com/login/device" })).toBeUndefined();
  expect(
    adapter.parseSignInStart({ ...base, expiresAtMs: undefined, url: "https://github.com/x", userCode: "X" })
      ?.expiresAtMs,
  ).toBe(Number.POSITIVE_INFINITY);
});

test("the adapter maps the daemon's reasons", () => {
  expect(adapter.signInFailure({ reason: "not_installed" })).toBe("not_installed");
  expect(adapter.signInFailure({ data: { reason: "expired" } })).toBe("expired");
  expect(adapter.signInFailure({ details: { reason: "cancelled" } })).toBe("cancelled");
  expect(adapter.signInFailure({ reason: "shared_machine" })).toBe("shared_machine");
  expect(adapter.signInFailure({ reason: "boom" })).toBe("other");
  expect(adapter.signInFailure(undefined)).toBe("other");
  expect(adapter.failedView("not_installed")).toEqual({ state: "notInstalled" });
  expect(adapter.failedView("expired")).toEqual({ state: "expired" });
  expect(adapter.parseAccountRow({ id: "a", family: "nope", name: "x" })).toBeUndefined();
  expect(adapter.parseAccountRow({ id: "a", family: "github", name: "x", default: true, signedIn: true })).toEqual({
    id: "a",
    family: "github",
    name: "x",
    signedIn: true,
    default: true,
    builtin: false,
  });
});

test("a finished sign-in is titled by its provider, and the paste field says what goes in it", async () => {
  await draw(
    <DeviceSignInCard family="codex" view={{ state: "signedIn", account: "you@example.com" }} {...handlers} />,
  );
  expect(document.body.querySelector(".signin-title")!.textContent).toBe("ChatGPT");
  await draw(<DeviceSignInCard family="claude" view={SIGN_IN_STATES.paste} {...handlers} />);
  expect(document.body.querySelector(".signin-paste-field")!.getAttribute("placeholder")).toBe("One-time code");
});
