// l10n-allow-file: debug fixture (made-up people, prompts and replies), not shipped UI.
// A shared chat for `debug.agent_pane seed_rows` with `fixture: "shared"`, so a capture of the real
// app shows chat multiplayer (Leo, 2026-10-26: "we can still do the regular chat multiplayer"):
// each teammate's prompt under their face and name, who answered an ask, who else has the chat
// open in the header and who types over the composer. The rows replace the transcript; the
// presence goes to the live faces (LivePresence.tsx) for the chat on screen, until the chat's own
// acpmux says otherwise (a presence notification, a switch).
import type { AcpmuxRow } from "../model";
import type { ChatPresence, Participant } from "./participants";

const ANA: Participant = { id: "tailnet:ana@example.com", name: "Ana Ruiz" };
const SAM: Participant = { id: "tailnet:sam@example.com", name: "Sam Okafor" };
const MEI: Participant = { id: "tailnet:mei@example.com", name: "Mei Lin" };

export const SHARED_PRESENCE: ChatPresence = { viewing: [ANA, SAM, MEI], typing: [ANA] };

export function sharedRows(at: number): AcpmuxRow[] {
  const row = (id: string, offset: number, fields: Record<string, unknown>) =>
    ({ id: `shared-${id}`, version: 1, at: at + offset, ...fields }) as AcpmuxRow;
  return [
    row("ask", 0, { kind: "user", text: "Add retry with backoff to the uploader", seq: 1, author: ANA }),
    row("done", 60_000, {
      kind: "assistant",
      text: "Done: three tries, doubling from 200 ms, only on 5xx and timeouts.",
    }),
    row("done-summary", 60_000, { kind: "turnSummary", durationMs: 42_000, toolCount: 0, seq: 3, status: "completed" }),
    row("test", 300_000, { kind: "user", text: "Cover it with a test that fakes two timeouts", seq: 4 }),
    row("allow", 360_000, {
      kind: "permissionRecord",
      permission: {
        permissionId: "shared-perm-1",
        title: "bun test src/uploader",
        pending: false,
        options: [{ id: "allow", name: "Allow once", allow: true, kind: "allow_once" }],
      },
      decision: { kind: "allowed" },
      answeredBy: SAM,
    }),
    row("tested", 420_000, {
      kind: "assistant",
      text: "Added `uploader.retry.test.ts`; it passes, and fails without the retry.",
    }),
    row("tested-summary", 420_000, {
      kind: "turnSummary",
      durationMs: 42_000,
      toolCount: 0,
      seq: 8,
      status: "completed",
    }),
    row("log", 600_000, { kind: "user", text: "Also log each retry at debug level", seq: 9, author: SAM }),
    row("logged", 660_000, { kind: "assistant", text: "Each retry now logs its attempt and wait at debug level." }),
    row("logged-summary", 660_000, {
      kind: "turnSummary",
      durationMs: 42_000,
      toolCount: 0,
      seq: 11,
      status: "completed",
    }),
  ];
}
