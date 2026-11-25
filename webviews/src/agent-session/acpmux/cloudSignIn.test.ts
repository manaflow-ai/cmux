import { expect, test } from "bun:test";
import { makeCloudSignInRetry, oneCloudStart, type CloudStartAnswer } from "./cloudRun";
import { CLOUD_SIGN_IN_ANSWERS, startAfterSignIn, waitForCloudSignIn } from "./cloudSignIn";

type Call = [string, Record<string, unknown> | undefined];

/// A native host whose `cloud.signIn` waits until the test answers it.
function host() {
  const calls: Call[] = [];
  let answer!: (signedIn: boolean) => void;
  const call = (method: string, params?: Record<string, unknown>) => {
    calls.push([method, params]);
    if (method !== "cloud.signIn") return Promise.resolve(undefined);
    return new Promise<unknown>((resolve, reject) => {
      answer = (signedIn) => (signedIn ? resolve({ signedIn: true }) : reject({ code: "not_signed_in" }));
    });
  };
  return { calls, call, answer: (signedIn: boolean) => answer(signedIn) };
}

test("sign-in recovery signs in on the click, then sends the preserved prompt once", async () => {
  const prompt = { task: "Fix the failing Cloud build", home: true, harness: "codex", model: "gpt-6.1-sol" };
  const native = host();
  const send = oneCloudStart(async (method, params) => void native.calls.push([method, params]));
  const retry = makeCloudSignInRetry(() =>
    startAfterSignIn(
      waitForCloudSignIn(native.call, "first-send"),
      () => true,
      () => send({ ...prompt, signedIn: true }, "first-send"),
    ),
  );
  const first = retry();
  expect(retry()).toBe(first);
  native.answer(true);
  await expect(first).resolves.toBe(true);
  expect(native.calls).toEqual([
    ["cloud.signIn", { key: "first-send" }],
    ["cloud.startChat", { ...prompt, key: "first-send", signedIn: true }],
  ]);
  await expect(retry()).resolves.toBe(false);
  expect(native.calls).toHaveLength(2);
});

test("a page that left Cloud after the browser signed in sends nothing again, and drops the kept click", async () => {
  const native = host();
  const wait = waitForCloudSignIn(native.call, "k");
  let waiting = true;
  const sends: string[] = [];
  const started = startAfterSignIn(
    wait,
    () => waiting,
    () => (sends.push("again"), Promise.resolve<CloudStartAnswer>({ ok: true })),
  );
  native.answer(true);
  // The race: the host answered signed in, and the page withdrew before reading that answer.
  waiting = false;
  wait.withdraw();
  await expect(started).resolves.toEqual(CLOUD_SIGN_IN_ANSWERS.withdrawn);
  expect(sends).toEqual([]);
  expect(native.calls.map(([method]) => method)).toEqual(["cloud.signIn", "cloud.signInCancel"]);
});

test("leaving Cloud while the browser is open ends the wait at once", async () => {
  const native = host();
  const wait = waitForCloudSignIn(native.call, "k");
  wait.withdraw();
  await expect(wait.ended).resolves.toEqual(CLOUD_SIGN_IN_ANSWERS.withdrawn);
  expect(native.calls).toEqual([
    ["cloud.signIn", { key: "k" }],
    ["cloud.signInCancel", {}],
  ]);
  // The browser coming back later changes nothing.
  native.answer(true);
  await expect(wait.ended).resolves.toEqual(CLOUD_SIGN_IN_ANSWERS.withdrawn);
});

test("a sign-in that ends signed out offers Sign in again", async () => {
  const native = host();
  const wait = waitForCloudSignIn(native.call, "k");
  native.answer(false);
  await expect(
    startAfterSignIn(
      wait,
      () => true,
      () => undefined,
    ),
  ).resolves.toEqual(CLOUD_SIGN_IN_ANSWERS.notSignedIn);
});

test("a sign-in that never returns expires to Sign in again and ends the app's browser sign-in", async () => {
  const native = host();
  const wait = waitForCloudSignIn(native.call, "k", 5);
  const end = await wait.ended;
  expect(end).toEqual(CLOUD_SIGN_IN_ANSWERS.expired);
  expect(end !== "signedIn" && !end.ok && end.code).toBe("not_signed_in");
  expect(native.calls).toEqual([
    ["cloud.signIn", { key: "k" }],
    ["cloud.signInCancel", { expired: true }],
  ]);
});

test("the host's own refusal reaches the card with its code and words", async () => {
  const wait = waitForCloudSignIn(
    () => Promise.reject({ code: "transport.gesture_required", message: "no click" }),
    "k",
  );
  await expect(wait.ended).resolves.toEqual({ ok: false, code: "transport.gesture_required", message: "no click" });
});
