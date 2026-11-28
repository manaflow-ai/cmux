import { expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { chiefReply, chiefStartAuth, saveReplyEvidence } from "./cloud-chief-start-check";

test("guest evidence preserves late daemon diagnostics and scrubs credentials before saving", async () => {
  const dir = mkdtempSync(join(tmpdir(), "chief-evidence-"));
  try {
    const stdout = "startup\n".repeat(400) + "\nconversation source: cloud\nowner-secret-value\n== traces\nturn dispatch failed";
    await saveReplyEvidence(async () => ({ code: 0, stdout, stderr: "owner-secret-value" }), dir, ["owner-secret-value"]);
    const saved = readFileSync(join(dir, "failure-evidence.txt"), "utf8");
    expect(saved).toContain("conversation source: cloud");
    expect(saved).toContain("turn dispatch failed");
    expect(saved).not.toContain("owner-secret-value");
    expect(saved).toContain("[secret]");
  } finally {
    rmSync(dir, { recursive: true });
  }
});

const row = (id: string, text: string, author = "chief") => ({
  row: { id, author, parts: [{ type: "text", text }] },
});

function check(...rows: ReturnType<typeof row>[]) {
  const api = { read: async () => ({ rows: { rows } }) };
  return chiefReply(api, "conversation", "chief", new Set(["old"]), "again", 0);
}

test("a fresh Chief quota failure reports the provider limit on the first snapshot", async () => {
  await expect(check(row("new", "(turn failed on claude: You've hit your weekly limit · resets Friday)")))
    .rejects.toThrow(/weekly limit/);
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
  expect(await check(row("new", "again later"))).toBeNull();
  expect(await check(row("new", "not-again"))).toBeNull();
});

test("a fresh echo can have punctuation or Markdown without becoming a different answer", async () => {
  for (const text of ["again.", "**again**", "_again_", "`again`", "“again”", "\nagain!\n"]) {
    expect((await check(row("new", text)))?.text).toBe(text);
  }
});

test("the run-specific echo keeps its full identifier", async () => {
  const expected = "pong-123-2";
  for (const text of ["**pong-123-2**.", "pong-123-1", "pong-123-20", "Reply with only the word pong-123-2"]) {
    const api = { read: async () => ({ rows: { rows: [row("new", text)] } }) };
    const reply = await chiefReply(api, "conversation", "chief", new Set(), expected, 0);
    expect(reply?.text ?? null).toBe(text === "**pong-123-2**." ? text : null);
  }
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
