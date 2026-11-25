// l10n-allow-file: gallery fixtures (sample prompts, senders and replies), not shipped UI.
// The prompt rail's hover card (Leo, 2026-11-07: "Our left Rails side thing, it's not formatted
// properly. First off, it's all bold. Second off, it's not using enough space horizontally. Third
// off, ... you need to have, like, the prompt separated from the response" and "if you, you know,
// you're in the rail, and then you hover over to the right, perhaps you can expand or whatever, and
// perhaps you can just show a few more lines by default"). The prompt is a one-line title; the reply
// is under it in regular weight with its lists, bold and code; the card is as wide as its words up to
// the arm's widest; the pointer moving into it opens it down to more of the reply. The compare view
// runs each arm of card.experiment.ts. Synthetic prompts only.
import { agentPaneEntry } from "../../../gallery/format";
import type { Play, PlayContext } from "../../../gallery/play";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import { incomingPrompt } from "../conversation/incomingMessage";
import type { AcpmuxRow } from "../model";
import { threadMinimapCard } from "./card.experiment";

const LONG_PROMPT =
  "Let's audit the rollout rules against the real failures from last week, and tell me which ones would have caught the updater regression before it reached the nightly channel";
const LIST_REPLY = [
  "Audited the rollout rules against last week's failures and rolled the policy change out end to end.",
  "",
  "- **Audit:** 508 updater runs; 200 failed on the same signature check, all on one channel.",
  "- **Rule gap:** the canary step skipped `verify-signature` when the cache was warm.",
  "- **Fix:** the canary now runs `verify-signature` every time, and the nightly waits on it.",
  "- **Backfill:** re-ran the 200 failed updates; every one installed cleanly.",
  "- **Watch:** a dashboard alert fires when more than 2% of a channel's updates fail.",
  "- **Follow-up:** the stable channel takes the same rule on Monday.",
  "",
  "Nothing else in the rules would have caught it: the other checks ran after the download.",
  "",
  "## Details",
  "",
  "The failing runs all came from machines that had the previous build cached, so the canary read the cached manifest and never fetched the new signature. With the cache cold every run checked it.",
].join("\n");
const CODE_REPLY = [
  "The retry wrapper was swallowing the abort: `fetchWithRetry` caught `AbortError` and retried it like a network error.",
  "",
  "```ts",
  "if (error.name === 'AbortError') throw error;",
  "```",
  "",
  "Now an abort ends the loop at once, and `retries` counts only network failures. The tests in `fetch.test.ts` cover both paths, and `bun test` is green.",
].join("\n");
const SHORT_REPLY = "Done. The flag is on for the beta channel only.";

const fromSession = (body: string, minutes: number, id: string): AcpmuxRow => {
  const incoming = incomingPrompt(body, {
    _meta: { provenance: { kind: "session_message", from: "fleet-mesh-id", fromName: "fleet-mesh", to: "me" } },
  });
  return incoming?.kind === "message"
    ? user(incoming.message.text, minutes, { id, incoming, resend: body })
    : user(body, minutes, { id });
};

/// Twelve turns; the ones the variants point at are tick 2 (long prompt, list reply), tick 4 (code
/// reply), tick 6 (another session's message) and tick 8 (a short turn).
const turns: [AcpmuxRow, string][] = Array.from({ length: 12 }, (_, index) => {
  const minutes = 300 - index * 2;
  const id = `user-${index + 1}`;
  if (index === 2) return [user(LONG_PROMPT, minutes, { id }), LIST_REPLY];
  if (index === 4) return [user("Why does cancel keep retrying the request?", minutes, { id }), CODE_REPLY];
  if (index === 6)
    return [
      fromSession(
        "ack. The router helper (on it since your first report) now has the wider scope: lanes 1 and 2, and the three open fixes. Order: the canary rule first, then the backfill, then the alert.",
        minutes,
        id,
      ),
      "Acknowledged. I'll pick up the canary rule first and report back when the backfill is done.",
    ];
  if (index === 8) return [user("Turn the flag on for beta", minutes, { id }), SHORT_REPLY];
  return [
    user(`Prompt ${index + 1}: check the next step of the plan`, minutes, { id }),
    `Step ${index + 1} checked.\n\nThe reply has a second paragraph so each turn has some height in the transcript.`,
  ];
});
const rows = turns.flatMap(([prompt, reply], index) => [
  prompt,
  assistant(reply, 299.8 - index * 2),
  summary(299.6 - index * 2, { status: "completed", durationMs: 42_000 + index * 1000, toolCount: 3 }),
]);

const tick = (n: number) => `[data-tick="${n}"]`;
const pointAt =
  (n: number): Play =>
  async (ctx: PlayContext) => {
    if (!ctx.document.querySelector(tick(n))) return;
    await ctx.hover({ selector: tick(n) });
    await ctx.waitFor(() => ctx.document.querySelector(".acpmux-minimap__card"));
  };
/// Points at the tick, then moves right into its card, which opens down to more of the reply.
const openOn =
  (n: number): Play =>
  async (ctx: PlayContext) => {
    await pointAt(n)(ctx);
    if (!ctx.document.querySelector(".acpmux-minimap__card")) return;
    await ctx.hover({ selector: ".acpmux-minimap__card" });
    await ctx.waitFor(() => ctx.document.querySelector(".acpmux-minimap__card[data-open]"));
  };

/// Twelve of forty prompts loaded and the index not answered: an old tick's card holds a blank line.
const TOTAL = 40;
const heldRows = rows.slice(-12 * 3);
const pointAtUnloaded: Play = async (ctx) => {
  const list = ctx.find({ selector: ".acpmux-minimap__list" });
  list.dispatchEvent(new ctx.document.defaultView!.WheelEvent("wheel", { deltaY: -1, bubbles: true }));
  await ctx.scroll({ selector: ".acpmux-minimap__list" }, "top");
  await ctx.hover({ selector: tick(3) });
};

export default agentPaneEntry({
  id: "agent-pane.thread-minimap-card",
  title: "Thread minimap: hover card",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 880, normal: 1040, wide: 1240 },
  anchors: [{ selector: ".acpmux-scroll" }],
  covers: [
    "agent-session/acpmux/threadMinimap/PreviewCard.tsx#PreviewCard",
    "agent-session/acpmux/threadMinimap/ThreadMinimap.tsx#ThreadMinimap",
  ],
  experiment: {
    definition: threadMinimapCard,
    script: [
      { name: "point at the list reply", run: pointAt(2) },
      { name: "move into the card", run: (ctx) => ctx.hover({ selector: ".acpmux-minimap__card" }) },
    ],
  },
  variants: {
    "long-prompt-list": {
      note: "A long prompt over a reply with a list: the prompt is one line cut with an ellipsis, the reply under it regular weight with its bold labels, and the card as wide as the arm lets it be.",
      snapshot: chat(rows, { title: "Hover card: long prompt, list reply" }),
      play: pointAt(2),
    },
    opened: {
      note: "The pointer moved right from the tick into the card: it opens down to more of the reply (fourteen lines, then it scrolls), from where it was; the title stays under the pointer and no tick moves.",
      snapshot: chat(rows, { title: "Hover card: opened" }),
      play: openOn(2),
    },
    "code-reply": {
      note: "A reply with code spans and a fenced block: the spans draw in the mono face; the fence is left to the transcript.",
      snapshot: chat(rows, { title: "Hover card: code reply" }),
      play: pointAt(4),
    },
    "other-session": {
      note: "Another session's message: its sender above the one-line title, and the reply under it.",
      snapshot: chat(rows, { title: "Hover card: another session's message" }),
      play: pointAt(6),
    },
    short: {
      note: "A short prompt and reply: the card stays at its least width, sized to its words.",
      snapshot: chat(rows, { title: "Hover card: short turn" }),
      play: pointAt(8),
    },
    unloaded: {
      note: "An unloaded prompt's card (the prompt index not answered yet): a blank title line where its words go, at the card's least width.",
      snapshot: chat(heldRows, { title: "Hover card: unloaded prompt", canLoadOlder: true, promptCount: TOTAL }),
      play: pointAtUnloaded,
    },
  },
});
