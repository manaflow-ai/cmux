// l10n-allow-file: gallery notes describe fixtures, not shipped copy.
// The composer ring's plan usage popover (PlanUsageCard.tsx), after Leo's two references
// (2026-11-04): Claude desktop's "Plan usage limits · Ultra" card (5-hour limit, Resets at 10:00 PM,
// 22%; Weekly · all models, Resets Mon 3:00 PM, 41%; See all →) and Codex's ring popover ("Usage
// source: Your Pro plan", Weekly limit 10% left, Credits 56,766 credits, Manage usage).
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { ContextRing } from "./ComposerPickers";
import { UsageRingMenu } from "./composerChrome";
import type { AcpmuxUsageLimits } from "./model";
import { PlanUsageCardBody, type PlanUsageLook } from "./PlanUsageCard";
import { planUsageLook } from "./planUsageLook.experiment";

/// The gallery's pinned clock, so the reset times read the same in every capture.
const NOW = Date.UTC(2026, 10, 4, 3, 0);
const galleryNow = () => NOW;
const seconds = NOW / 1000;

const claude: AcpmuxUsageLimits = {
  windows: [
    { id: "session", usedPercent: 22, resetsAt: seconds + 5 * 3600 },
    { id: "weekly", usedPercent: 41, resetsAt: seconds + 4 * 86_400 },
  ],
};
const claudeNearCap: AcpmuxUsageLimits = {
  windows: [
    { id: "session", usedPercent: 96, resetsAt: seconds + 40 * 60 },
    { id: "weekly", usedPercent: 63, resetsAt: seconds + 4 * 86_400 },
    { id: "weekly_opus", usedPercent: 88, resetsAt: seconds + 4 * 86_400 },
  ],
};
const codex: AcpmuxUsageLimits = {
  windows: [
    { id: "session", usedPercent: 35, windowMins: 300, resetsAt: seconds + 2 * 3600 },
    { id: "weekly", usedPercent: 90, windowMins: 10080, resetsAt: seconds + 2 * 86_400 },
  ],
  plan: "pro",
  credits: { balance: "56766" },
};

type Props = {
  limits?: AcpmuxUsageLimits;
  family?: string;
  look?: PlanUsageLook;
  /// Draw the composer ring in plan mode (hover or right-click it) instead of the card alone.
  ring?: boolean;
};

function GalleryPlanUsage({ limits, family, look, ring }: Props) {
  if (ring)
    return (
      <div className="plan-usage-gallery plan-usage-gallery--ring">
        <UsageRingMenu>
          <ContextRing used={60_000} size={400_000} plan={{ limits, family }} now={galleryNow} />
        </UsageRingMenu>
      </div>
    );
  return (
    <div className="plan-usage-gallery">
      <div className="ui-card ui-glass acpmux-context-card acpmux-plan-pop">
        <PlanUsageCardBody limits={limits} family={family} look={look} now={galleryNow} onOpenUrl={() => {}} />
      </div>
    </div>
  );
}

const hoverRing: Play = async (ctx) => {
  await ctx.hover({ selector: "button.acpmux-context-ring" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-plan-pop .acpmux-plan-usage"));
};

/// The experiment's step: the popover the arm draws, opened from the ring when the variant has one.
const showPopover: Play = async (ctx) => {
  if (ctx.document.querySelector("button.acpmux-context-ring")) await hoverRing(ctx);
  else await ctx.waitFor(() => ctx.document.querySelector(".acpmux-plan-usage"));
};

const rightClickRing: Play = async (ctx) => {
  const ring = ctx.document.querySelector("button.acpmux-context-ring");
  if (!ring) throw new Error("The usage ring is missing");
  ring.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 20, clientY: 20 }));
  await ctx.waitFor(() => ctx.document.querySelectorAll('[role^="menuitem"]').length === 3);
};

const looks = ["claude-bars", "codex-rows", "compact"] as const;
const lookNotes: Record<PlanUsageLook, string> = {
  "claude-bars":
    "Shipped: Claude desktop's card. Plan usage limits (· plan when reported), See all → to the account's usage page; each window's name, reset time and percent used on one line with an accent bar under it.",
  "codex-rows":
    "Alternative: Codex's popover. Usage source: Your Pro plan, one row per window with the share left, credits, Manage usage. No bars, and no title at all when the harness names no plan (Claude).",
  compact:
    "Alternative: one line per window with a short inline bar, the reset time under it. Denser, but the bar is too short to read a share at a glance.",
};

export default componentEntry<Props>({
  id: "agent-pane.plan-usage-card",
  title: "Plan usage popover",
  area: "Agent pane",
  pane: true,
  height: 280,
  widths: { narrow: 360, normal: 520, wide: 720 },
  covers: [
    "agent-session/acpmux/PlanUsageCard.tsx#PlanUsageCardBody",
    "agent-session/acpmux/composerChrome.tsx#UsageRingMenu",
  ],
  styles: () =>
    Promise.all([
      import("./styles.css"),
      import("./composerControls.css"),
      import("./contextCard.css"),
      import("./planUsageCard.css"),
      import("./PlanUsageCard.gallery.css"),
    ]),
  load: async () => GalleryPlanUsage,
  variants: {
    ...Object.fromEntries(
      looks.flatMap((look) => [
        [
          `${look}-claude`,
          {
            note: `${lookNotes[look]} Claude chat (5-hour 22%, weekly 41%).`,
            props: { limits: claude, family: "claude", look },
          },
        ],
        [
          `${look}-codex`,
          {
            note: `${lookNotes[look]} Codex chat on a Pro plan with credits.`,
            props: { limits: codex, family: "codex", look },
          },
        ],
      ]),
    ),
    "claude-bars-near-cap": {
      note: "Near the cap: three windows (the Opus week too); the 5-hour one resets within the hour. The ring draws the 96% one.",
      props: { limits: claudeNearCap, family: "claude", look: "claude-bars" },
    },
    "none-reported": {
      note: "Nothing reported yet (a fresh chat, or a sign-in with no plan limits): the card says so, never a 0%. The ring itself stays on the context in this state.",
      props: { family: "codex", look: "claude-bars" },
    },
    "ring-plan-hover": {
      note: "The composer ring in plan mode: it draws the window closest to its cap (weekly, 90%) and hovering it opens the popover.",
      props: { limits: codex, family: "codex", ring: true },
      play: hoverRing,
    },
    "ring-menu": {
      note: "The ring's right-click (Leo: \"i want to be able to right click disable it\"): Context Usage or Plan Usage, checked, then Hide Usage Ring. The button row's right-click shows it again.",
      props: { limits: claude, family: "claude", ring: true },
      play: rightClickRing,
    },
  },
  experiment: {
    definition: planUsageLook,
    script: [{ name: "Show the plan usage popover", run: showPopover }],
  },
});
