// A Cloud chat's GitHub sign-in on its machine (cloudGitHubSignIn.ts) and the Cloud card's draw with
// the shared DeviceSignInCard (CloudSignIn.tsx): each step names the chat, only GitHub's device page
// opens, the code is visible text only, and Codex's device code and Claude's paste use the shared card.
import { act } from "react";
import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "../../pages/settings/testDom";
import type { CloudSignIn as SignIn, LoginStart } from "./cloudAgentLogin";

const restore = installDom();
afterAll(() => restore());
const { createRoot } = await import("react-dom/client");
const { cloudGitHubSignIn, isGitHubDevicePage, GITHUB_DEVICE_PAGE } = await import("./cloudGitHubSignIn");
const { CloudSignIn } = await import("./conversation/CloudSignIn");

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

const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));

type Call = { method: string; args: unknown[] };
function fakeClient(answers: { start?: unknown; finish?: () => Promise<unknown>; startError?: unknown }) {
  const calls: Call[] = [];
  return {
    calls,
    client: {
      accountSignInStart: (...args: unknown[]) => {
        calls.push({ method: "start", args });
        return answers.startError ? Promise.reject(answers.startError) : Promise.resolve(answers.start);
      },
      accountSignInFinish: (...args: unknown[]) => {
        calls.push({ method: "finish", args });
        return answers.finish ? answers.finish() : new Promise<unknown>(() => {});
      },
      accountSignInCancel: (...args: unknown[]) => {
        calls.push({ method: "cancel", args });
        return Promise.resolve({});
      },
    },
  };
}

const STARTED = {
  account: "github:octo",
  loginId: "login_gh",
  url: GITHUB_DEVICE_PAGE,
  userCode: "1A2B-3C4D",
  needsCode: false,
  expiresAtMs: Date.now() + 600_000,
  added: true,
};

test("only GitHub's device page qualifies", () => {
  expect(isGitHubDevicePage("https://github.com/login/device")).toBe(true);
  for (const url of [
    "http://github.com/login/device",
    "https://github.com/login/device?next=/x",
    "https://github.com/login/device#x",
    "https://github.com/settings/tokens",
    "https://github.com:8443/login/device",
    "https://u@github.com/login/device",
    "https://github.com.evil.example/login/device",
    "https://gist.github.com/login/device",
    7,
    undefined,
  ])
    expect(isGitHubDevicePage(url)).toBe(false);
});

test("each step names the chat; the start opens the device page once", async () => {
  const { calls, client } = fakeClient({ start: STARTED, finish: () => Promise.resolve({ signedIn: true }) });
  const opened: string[] = [];
  const transport = cloudGitHubSignIn({ sessionId: "s1", currentClient: () => client, openURL: (u) => opened.push(u) });
  const start = await transport.run({ action: "signInStart", family: "github", provider: "github" });
  expect(start).toEqual({ ok: true, value: { signIn: STARTED } });
  expect(opened).toEqual([GITHUB_DEVICE_PAGE]);
  const finish = await transport.run({ action: "signInFinish", loginId: "login_gh" });
  expect(finish as unknown).toEqual({ ok: true, value: { finished: { signedIn: true } } });
  await transport.run({ action: "signInCancel", loginId: "login_gh" });
  expect(calls).toEqual([
    { method: "start", args: ["github", "s1"] },
    { method: "finish", args: ["login_gh", "s1"] },
    { method: "cancel", args: ["login_gh", "s1"] },
  ]);
});

test("another page is never opened, another family never starts, a refusal keeps its reason", async () => {
  const opened: string[] = [];
  const odd = fakeClient({ start: { ...STARTED, url: "https://github.com/settings/tokens" } });
  const transport = cloudGitHubSignIn({
    sessionId: "s1",
    currentClient: () => odd.client,
    openURL: (u) => opened.push(u),
  });
  await transport.run({ action: "signInStart", family: "github" });
  expect(opened).toEqual([]);
  expect((await transport.run({ action: "signInStart", family: "codex" })).ok).toBe(false);
  expect((await transport.run({ action: "accountRemove", account: "github:octo" })).ok).toBe(false);
  const refused = fakeClient({ startError: { code: -32000, reason: "remote_refused" } });
  const shut = cloudGitHubSignIn({ sessionId: "s1", currentClient: () => refused.client, openURL: () => {} });
  expect(await shut.run({ action: "signInStart", family: "github" })).toEqual({
    ok: false,
    error: { code: -32000, reason: "remote_refused" },
  });
  // A machine without the method answers with no sign-in (the card falls back).
  const old = fakeClient({ startError: { code: -32601 } });
  const older = cloudGitHubSignIn({ sessionId: "s1", currentClient: () => old.client, openURL: () => {} });
  expect(await older.run({ action: "signInStart", family: "github" })).toEqual({ ok: true, value: {} });
});

function agentSignIn(agent: SignIn["agent"], login: LoginStart, github?: SignIn["github"]): SignIn {
  return {
    agent,
    start: () => Promise.resolve(login),
    open: () => {},
    openOnMachine: () => Promise.resolve(false),
    finish: () => new Promise<boolean>(() => {}),
    apiKey: () => Promise.resolve(false),
    gateway: () => Promise.resolve(false),
    cancel: () => {},
    reserve: () => Promise.resolve(undefined),
    resend: () => Promise.resolve(),
    ...(github ? { github } : {}),
  };
}

const button = (root: ParentNode, label: string) =>
  [...root.querySelectorAll<HTMLButtonElement>("button")].find((node) => node.textContent === label);

test("the Cloud card's GitHub link turns into the shared card with the code as text only", async () => {
  const { client } = fakeClient({ start: STARTED });
  const opened: string[] = [];
  const github = cloudGitHubSignIn({ sessionId: "s1", currentClient: () => client, openURL: (u) => opened.push(u) });
  const login: LoginStart = { loginId: "l1", url: "https://auth.openai.com/codex/device", needsCode: false };
  const root = await draw(<CloudSignIn signIn={agentSignIn("codex", login, github)} rowId="r" prompt="p" />);
  const link = button(root, "Sign In to GitHub");
  expect(link).toBeDefined();
  await act(async () => link!.click());
  await settle();
  const card = root.querySelector<HTMLElement>(".signin[data-look=inline]");
  expect(card?.querySelector(".signin-code")?.textContent).toBe("1A2B-3C4D");
  expect(opened).toEqual([GITHUB_DEVICE_PAGE]);
  // Never in an attribute.
  for (const node of root.querySelectorAll("*"))
    for (const attribute of node.attributes) expect(attribute.value.includes("1A2B")).toBe(false);
});

test("no GitHub link without a transport or on a key-only card", async () => {
  const login: LoginStart = { loginId: "l1", url: "https://auth.openai.com/codex/device", needsCode: false };
  const plain = await draw(<CloudSignIn signIn={agentSignIn("codex", login)} rowId="r" prompt="p" />);
  expect(button(plain, "Sign In to GitHub")).toBeUndefined();
  unmount?.();
  const { client } = fakeClient({ start: STARTED });
  const github = cloudGitHubSignIn({ sessionId: "s1", currentClient: () => client, openURL: () => {} });
  const keyed = await draw(<CloudSignIn signIn={agentSignIn("claude", login, github)} rowId="r" prompt="p" keyOnly />);
  expect(button(keyed, "Sign In to GitHub")).toBeUndefined();
});

test("Codex's device code and Claude's paste draw with the shared card, Open sign-in page beside it", async () => {
  const codex: LoginStart = {
    loginId: "l1",
    url: "https://auth.openai.com/codex/device",
    userCode: "WXYZ-1234",
    needsCode: false,
  };
  const root = await draw(<CloudSignIn signIn={agentSignIn("codex", codex)} rowId="r" prompt="p" />);
  await act(async () => root.querySelector<HTMLButtonElement>(".cv-turn-error__primary")!.click());
  await settle();
  expect(root.querySelector("[data-testid=cloud-signin-code] .signin-code")?.textContent).toBe("WXYZ-1234");
  expect(root.querySelector(".signin [data-sign-in-action=copy]")).not.toBeNull();
  expect(root.querySelector(".signin [data-sign-in-action=cancel]")).not.toBeNull();
  expect(button(root, "Open sign-in page")).toBeDefined();
  unmount?.();

  const claude: LoginStart = { loginId: "l2", url: "https://claude.ai/oauth/authorize", needsCode: true };
  const pasted: (string | undefined)[] = [];
  const signIn = {
    ...agentSignIn("claude", claude),
    finish: (_: string, code?: string) => (pasted.push(code), new Promise<boolean>(() => {})),
  };
  const paste = await draw(<CloudSignIn signIn={signIn} rowId="r" prompt="p" />);
  await act(async () => paste.querySelector<HTMLButtonElement>(".cv-turn-error__primary")!.click());
  await settle();
  const field = paste.querySelector<HTMLInputElement>(".signin-paste-field");
  expect(field).not.toBeNull();
  expect(button(paste, "Open sign-in page")).toBeDefined();
  await act(async () => {
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
    setter.call(field, " pasted#code ");
    field!.dispatchEvent(new Event("input", { bubbles: true }));
  });
  await act(async () => paste.querySelector<HTMLButtonElement>("[data-sign-in-action=continue]")!.click());
  expect(pasted).toEqual(["pasted#code"]);
});
