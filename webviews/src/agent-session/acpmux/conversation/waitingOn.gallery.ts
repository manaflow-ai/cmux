// l10n-allow-file: gallery regression fixtures, not shipped UI.
// Leo 2026-10-21: a new chat read "Thinking" forever while the folder's trust question waited on
// him. While an ask above the composer waits on the person, the running turn's line says so
// (waitingOn.ts): never "Thinking", never a ticking "Working for".
import { agentPaneEntry } from "../../../gallery/format";
import { activity, chat, CWD, row, tool, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";
import type { AcpmuxPermission } from "../model";

const permission: AcpmuxPermission = {
  permissionId: "waiting-permission",
  title: "Run the tests",
  command: "bun test src/fetch",
  pending: true,
  options: [
    { id: "allow_once", name: "Yes", kind: "allow_once", allow: true },
    { id: "reject_once", name: "No", kind: "reject_once", allow: false },
  ],
};

// A new chat's first prompt, held while the folder's trust question is open.
const heldForTrust = chat([user("Add retries to the fetch helper", 0, { pending: true })], { isWorking: false });
// A running turn whose next call waits for the person's Yes.
const heldForPermission = chat(
  [
    user("Fix the flaky retry test, then run the suite", 2),
    activity([tool("Read src/fetch/retry.ts", "read", "completed")], 1),
    row("permission", 0, { permission }),
  ],
  { isWorking: true, permission },
);

const line = (ctx: Parameters<Play>[0]) =>
  ctx.document.querySelector(".cv-waiting")?.textContent ?? ctx.document.querySelector(".cv-worked")?.textContent;

/// The trust question's wait names the folder, points at the question right on the composer, and a
/// click on it lands on the question's primary answer (Leo, 2026-10-21: Claude "thinks" forever).
const waitsOnTrust: Play = async (ctx) => {
  await waitsOn("Waiting for you to trust atlas-web")(ctx);
  const dock = ctx.document.querySelector(".acpmux-dock");
  const stack = dock?.querySelector(":scope > .acpmux-asks-stack");
  if (!stack?.querySelector(".acpmux-trust-ask[data-asking]")) throw new Error("No open trust question in the dock");
  if (stack.nextElementSibling !== dock?.querySelector(":scope > .acpmux-composer"))
    throw new Error("The trust question is not right above the composer");
  await ctx.click({ selector: ".cv-waiting__show" });
  await ctx.waitFor(() => ctx.document.activeElement?.classList.contains("acpmux-trust-ask-primary"));
};

const waitsOn =
  (words: string): Play =>
  async (ctx) => {
    await ctx.waitFor(() => line(ctx) === words);
    if (ctx.document.querySelector(".cv-thinking:not(.cv-waiting)"))
      throw new Error("The turn reads Thinking while it waits on the person");
    if (ctx.document.querySelector(".cv-worked__time")) throw new Error("A clock ticks while the turn waits");
  };

export default agentPaneEntry({
  id: "agent-pane.waiting-on-you",
  title: "Waiting for you: the turn's line while an ask waits",
  area: "Agent pane",
  height: 420,
  widths: { narrow: 400, normal: 760, wide: 760 },
  anchors: [{ selector: ".acpmux-composer-bar" }],
  covers: [
    "agent-session/acpmux/conversation/Thinking.tsx",
    "agent-session/acpmux/conversation/WorkingFor.tsx",
    "agent-session/acpmux/TrustAsk.tsx",
  ],
  keywords: ["thinking", "waiting", "trust", "permission", "blocked"],
  variants: {
    "trust-held-prompt": {
      note: "The first prompt waits on the trust question: the line names the folder and points at the question on the composer; a click lands on Trust folder.",
      snapshot: heldForTrust,
      native: { "acp.trust.get": { cwd: CWD, level: "unknown" } },
      play: waitsOnTrust,
    },
    "permission-mid-turn": {
      note: "A running turn waits for a Yes: no clock, no call name, the wait in words.",
      snapshot: heldForPermission,
      native: { "acp.trust.get": { cwd: CWD, level: "trusted" } },
      play: waitsOn("Waiting for you: allow this?"),
    },
  },
});
