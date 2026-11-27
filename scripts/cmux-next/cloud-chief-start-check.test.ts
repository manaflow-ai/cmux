import { expect, test } from "bun:test";
import { chiefReply, chiefStartAuth, CredentialLimitError, replyStep } from "./cloud-chief-start-check";

const row = (id: string, text: string, author = "chief") => ({
  row: { id, author, parts: [{ type: "text", text }] },
});

function check(...rows: ReturnType<typeof row>[]) {
  const api = { read: async () => ({ rows: { rows } }) };
  return chiefReply(api, "conversation", "chief", new Set(["old"]), "again", 0);
}

test("a fresh Chief quota failure reports the provider limit on the first snapshot, as not judged", async () => {
  const run = check(row("new", "(turn failed on claude: You've hit your weekly limit · resets Friday)"));
  await expect(run).rejects.toThrow(/weekly limit/);
  await expect(run).rejects.toBeInstanceOf(CredentialLimitError);
});

test("a plain reply naming the credential's limit is not judged, not a timeout", async () => {
  await expect(check(row("new", "You've hit your weekly limit · resets Dec 1, 9am (UTC)"))).rejects.toBeInstanceOf(CredentialLimitError);
});

test("a wrong reply or another turn failure is never read as the credential's limit", async () => {
  expect(await check(row("new", "pong-wrong"))).toBeNull();
  const run = check(row("new", "(turn failed on claude: provider refused)"));
  await expect(run).rejects.toThrow(/provider refused/);
  await expect(run).rejects.not.toBeInstanceOf(CredentialLimitError);
});

test("a failed turn can include a partial reply or quote the expected word", async () => {
  for (const text of [
    "(turn failed: could not answer again)",
    "again\n\n(turn failed on claude (fallback for other): provider refused)",
  ]) {
    await expect(check(row("new", text))).rejects.toThrow(/turn failed/i);
  }
});

test("sign-in failures still fail immediately", async () => {
  await expect(check(row("new", "Not logged in"))).rejects.toThrow(/without a model/);
});

test("an unrelated message or quoted prompt cannot prove the turn", async () => {
  expect(await check(row("new", "Can't answer “Reply with only the word again” yet"))).toBeNull();
});

test("only a fresh reply from the Chief proves the turn", async () => {
  const reply = await check(
    row("old", "(turn failed: old quota failure)"),
    row("user-row", "(turn failed: unrelated)", "user"),
    row("user-echo", "again", "user"),
    row("new", "again"),
  );
  expect(reply?.text).toBe("again");
});

test("SR2 uses the default CodeRouter route without reading or sending a Claude secret", () => {
  const auth = chiefStartAuth({
    CHIEF_START_AUTH: "sr2",
    ANTHROPIC_API_KEY: "should-not-be-read",
    CLAUDE_CODE_OAUTH_TOKEN: "should-not-be-read",
  });
  expect(auth).toEqual({ mode: "sr2", turnTail: "" });
});

test("owner mode keeps API-key preference and OAuth fallback", () => {
  expect(chiefStartAuth({ ANTHROPIC_API_KEY: "api", CLAUDE_CODE_OAUTH_TOKEN: "oauth" })).toEqual({
    mode: "owner",
    secret: "api",
    turnTail: JSON.stringify({ env: { ANTHROPIC_API_KEY: "api" } }),
  });
  expect(chiefStartAuth({ CLAUDE_CODE_OAUTH_TOKEN: "oauth" })).toEqual({
    mode: "owner",
    secret: "oauth",
    turnTail: JSON.stringify({ env: { CLAUDE_CODE_OAUTH_TOKEN: "oauth" } }),
  });
});

test("owner mode still fails when no Claude credential is available", () => {
  expect(() => chiefStartAuth({})).toThrow(/ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN/);
});

function journal() {
  const steps: { step: string; status: string; detail: string }[] = [];
  return {
    steps,
    record: (s: { step: string; status: string; detail: string }) => void steps.push(s),
    skip: (step: string, detail: string) => void steps.push({ step, status: "skip", detail }),
  };
}

test("a reply step at the credential's limit ends skipped as NOT JUDGED, and so do the reply steps after it", async () => {
  const J = journal();
  const state = { notJudged: null as string | null };
  await replyStep(J as any, state, "app reply", async () => { throw new CredentialLimitError("You've hit your weekly limit"); });
  await replyStep(J as any, state, "web reply", async () => { throw new Error("must not run"); });
  expect(J.steps.map((s) => s.status)).toEqual(["skip", "skip"]);
  expect(J.steps.every((s) => s.detail.startsWith("NOT JUDGED: the credential is at its limit"))).toBe(true);
  expect(state.notJudged).toMatch(/weekly limit/);
});

test("any other reply-step error still fails the step and the run", async () => {
  const J = journal();
  const state = { notJudged: null as string | null };
  await expect(replyStep(J as any, state, "app reply", async () => { throw new Error("no reply from chief in 240 s"); })).rejects.toThrow(/no reply/);
  expect(J.steps).toEqual([expect.objectContaining({ step: "app reply", status: "fail" })]);
  expect(state.notJudged).toBeNull();
  await replyStep(J as any, state, "web reply", async () => ({ detail: "reply in 3 s" }));
  expect(J.steps.at(-1)).toEqual(expect.objectContaining({ status: "pass" }));
});
