// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// The "Worked for" gallery entry (WorkedOverBackground.gallery.ts) drew a Claude Code background-task
// notification as the person's own bubble, raw tags and all: its user_message named no client, a
// record no live acpmux path writes. As acpmux records one (client `adopt` or `watch`), the
// notification is its summary's notice line (incomingMessage.ts), never a bubble.
import { expect, test } from "bun:test";
import { workedOverBackgroundEvents } from "../src/agent-session/acpmux/conversation/WorkedOverBackground.gallery";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
import { incomingPrompt } from "../src/agent-session/acpmux/conversation/incomingMessage";
import { connect, fakeDaemon } from "./support/agentPairDaemon";

test("the gallery's background task notification draws as its notice line, not a bubble", async () => {
  const { client, rows } = await connect(fakeDaemon(workedOverBackgroundEvents() as never));
  try {
    const view = turnView(rows(), new Set()).filter((row) => row.kind !== "date");
    expect(view.some((row) => row.kind === "user" && row.text?.includes("<task-notification>"))).toBe(false);
    const notice = view.findIndex((row) => row.kind === "user" && row.incoming?.kind === "notice");
    expect(view[notice]?.incoming).toEqual({ kind: "notice", text: "Background command finished" });
    // The entry still shows what it is for: "Worked for" right under the notice.
    expect(view[notice + 1]?.kind).toBe("worked");
  } finally {
    client.close();
  }
});

test("a notification is the person's own only when no acpmux path recorded it", () => {
  const text = "<task-notification><summary>Background command finished</summary></task-notification>";
  for (const client of ["adopt", "watch"])
    expect(incomingPrompt(text, { client })).toEqual({ kind: "notice", text: "Background command finished" });
  expect(incomingPrompt(text, undefined)).toBeUndefined();
});
