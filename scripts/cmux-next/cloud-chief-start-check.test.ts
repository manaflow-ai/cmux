import { expect, test } from "bun:test";
import { chiefReply } from "./cloud-chief-start-check";

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
