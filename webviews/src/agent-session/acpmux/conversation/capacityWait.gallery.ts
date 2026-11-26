// l10n-allow-file: gallery fixtures (sample prompts and agent errors), not shipped UI.
// A turn acpmux holds for capacity (CapacityWaitCard.tsx; RFD model-overload-smoothing §3.8; Leo,
// 2026-11-24: "fix 529s properly with better designs", "send a fella to do the deep work + design and
// stuff to smooth over these siuations better pleaseeeeeee"): one calm state where the failed card
// was, "Waiting for capacity, about 40s" counting down from acpmux's resume time, the raw error
// under Details. Compare arms shows the `capacity-wait` experiment's looks beside the old red card.
import { agentPaneEntry } from "../../../gallery/format";
import { GALLERY_NOW } from "../../../gallery/clock";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import type { CapacityWaitState } from "../capacityWait";
import { capacityWaitLook } from "./capacityWait.experiment";

const prompt = "Run the sidebar tests and fix what fails";
const OVERLOAD = "API Error: Repeated 529 Overloaded errors";
const POOL = "API Error: 503 no non-exhausted claude accounts available; next account frees up in 29m";

const held = (error: string, wait: Omit<CapacityWaitState, "turnId" | "error">) =>
  chat(
    [
      user(prompt, 6),
      assistant("Running the sidebar tests first.", 5.8),
      summary(0.5, { status: "failed", durationMs: 330_000, error, turnId: "t-held" }),
    ],
    { capacityWait: { ...wait, turnId: "t-held", error } },
  );

export default agentPaneEntry({
  id: "agent-pane.capacity-wait",
  title: "Capacity wait",
  area: "Agent pane",
  height: 260,
  covers: [
    "agent-session/acpmux/conversation/CapacityWaitCard.tsx",
    "agent-session/acpmux/conversation/TurnRows.tsx#TurnFooter",
    "agent-session/acpmux/capacityWait.ts",
  ],
  keywords: ["529", "503", "overloaded", "capacity", "rate limit", "waiting", "paused", "retry"],
  variants: {
    overloaded: {
      note: "A turn the model's 529s cut, which acpmux goes on with in 40 s: one quiet line with its countdown, no red, the 529 under Details.",
      snapshot: held(OVERLOAD, { reason: "capacity", since: GALLERY_NOW - 30_000, resumesAt: GALLERY_NOW + 40_000 }),
    },
    "pool-exhausted": {
      note: "Every account of the pool spent: a longer wait reads in minutes, still calm.",
      snapshot: held(POOL, { reason: "capacity", since: GALLERY_NOW - 60_000, resumesAt: GALLERY_NOW + 195_000 }),
    },
    "rate-limit": {
      note: "The account's own rate limit: the same wait until its reset.",
      snapshot: held("API Error: Request rejected (429) · This request would exceed your account's rate limit.", {
        reason: "rate_limit",
        since: GALLERY_NOW - 120_000,
        resumesAt: GALLERY_NOW + 12 * 60_000,
      }),
    },
    deciding: {
      note: "acpmux is still deciding when to go on (no time yet): any moment now.",
      snapshot: held(OVERLOAD, { reason: "capacity" }),
    },
    details: {
      note: "Details open: the harness's own words and Copy error.",
      snapshot: held(OVERLOAD, { reason: "capacity", since: GALLERY_NOW - 30_000, resumesAt: GALLERY_NOW + 40_000 }),
      play: async (ctx) => {
        await ctx.click({ selector: ".cv-capacity-wait .cv-turn-error__details summary" });
      },
    },
  },
  experiment: {
    definition: capacityWaitLook,
    script: [
      {
        name: "open Details",
        run: async (ctx) => {
          await ctx.click({ selector: ".cv-turn-error__details summary" });
        },
      },
    ],
  },
});
