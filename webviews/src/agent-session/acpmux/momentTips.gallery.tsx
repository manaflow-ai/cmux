// l10n-allow-file: gallery fixtures (the moment tips' English text), not shipped UI.
// Moment tips (momentTipsModel.ts, wow idea 20): a built feature's one tip, shown when its situation
// is on screen. Chosen: `plan-glass` (the live wiring draws it, `live`); the others stay here.
import { createElement, useEffect, useRef, useState, type ComponentType } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import type { FeatureTipLook } from "../../ui/FeatureTip";
import { memoryTipHost } from "../../ui/featureTips/store";

type Moment = "plan" | "away";
/** `live`: the shipped wiring (PaneMomentTips: its anchors and scheduler), records in memory. */
type Props = { moment: Moment; look: FeatureTipLook; side?: "top" | "bottom"; live?: boolean };

const TEXT: Record<Moment, { selector: string; title: string; body: string }> = {
  plan: {
    selector: ".acpmux-plan-build-chevron",
    title: "Build it twice, keep the better one",
    body: "This menu builds the plan on two agents, then compares them.",
  },
  away: {
    selector: ".acpmux-since-jump__body",
    title: "Catch up on what happened",
    body: "Jump to where you left off; a recap waits there.",
  },
};

const noop = () => undefined;

type Loaded = {
  Split: typeof import("./PermissionCard").PlanBuildSplit;
  Tip: typeof import("../../ui/FeatureTip").FeatureTip;
  Live: typeof import("./momentTips").PaneMomentTips;
};

function GalleryMoment({ moment, look, side, live, Split, Tip, Live }: Props & Loaded) {
  const stage = useRef<HTMLDivElement>(null);
  const [anchor, setAnchor] = useState<Element | null>(null);
  const text = TEXT[moment];
  useEffect(() => setAnchor(stage.current?.querySelector(text.selector) ?? null), [text.selector]);
  const [open, setOpen] = useState(true);
  const [deps] = useState(() => ({ host: memoryTipHost(), schedule: { openedAt: 0, focused: () => true } }));
  return (
    <div ref={stage} className="feature-tip-gallery">
      <div className="feature-tip-gallery-body">
        {moment === "plan" ? (
          <div className="acpmux-permission-actions">
            <Split harness="claude" onHere={noop} onBuild={noop}>
              <button type="button" className="ui-button acpmux-permission-primary">
                Approve plan
              </button>
            </Split>
          </div>
        ) : (
          <fieldset className="ui-glass acpmux-since-jump" data-shown="" data-side="below">
            <button type="button" className="acpmux-since-jump__body">
              <span className="acpmux-since-jump__count">12 new messages</span>
            </button>
          </fieldset>
        )}
      </div>
      <div className="ui-glass feature-tip-gallery-composer">Ask anything</div>
      {live ? (
        <Live turnWorking waitingOnPerson={moment === "plan"} host={deps.host} schedule={deps.schedule} forceOn />
      ) : (
        <Tip
          anchor={open ? anchor : null}
          open={open}
          side={side ?? "bottom"}
          title={text.title}
          body={text.body}
          newLabel="New"
          closeLabel="Close tip"
          look={look}
          onClose={() => setOpen(false)}
        />
      )}
    </div>
  );
}

const shown: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector("[data-feature-tip]"));
  const tip = ctx.find({ selector: "[data-feature-tip]" });
  if (ctx.document.activeElement && tip.contains(ctx.document.activeElement))
    throw new Error("a moment tip took focus");
};

const closes: Play = async (ctx) => {
  await shown(ctx);
  await ctx.click({ role: "button", name: "Close tip" });
  await ctx.waitFor(() => !ctx.document.querySelector("[data-feature-tip]"));
};

export default componentEntry<Props>({
  id: "agent.moment-tips",
  title: "Moment tips",
  area: "Agent pane",
  pane: true,
  height: 320,
  widths: { narrow: 390, normal: 560, wide: 860 },
  anchors: [{ selector: "[data-feature-tip]" }],
  covers: ["agent-session/acpmux/momentTips.tsx#PaneMomentTips", "agent-session/acpmux/momentTipsModel.ts#momentTips"],
  load: () =>
    Promise.all([import("./PermissionCard"), import("../../ui/FeatureTip"), import("./momentTips")]).then(
      ([card, tip, live]) =>
        (props: Props) =>
          createElement(GalleryMoment as ComponentType<Props & Loaded>, {
            ...props,
            Split: card.PlanBuildSplit,
            Tip: tip.FeatureTip,
            Live: live.PaneMomentTips,
          }),
    ),
  styles: () =>
    Promise.all([
      import("./styles.css"),
      import("../../ui/popupSurface.css"),
      import("./conversation/unread.css"),
      import("../../ui/featureTip.gallery.css"),
    ]),
  variants: {
    live: {
      note: "What ships behind moment-tips: a waiting plan card; the chat's own wiring claims the tip and points it at the build menu.",
      props: { moment: "plan", look: "glass", live: true },
      play: shown,
    },
    "plan-glass": {
      note: "Chosen: popup glass under the plan card's build chevron, the moment Build on two agents applies.",
      props: { moment: "plan", look: "glass" },
      play: shown,
    },
    "plan-above": {
      note: "Above the chevron, clear of the card's rows below. Gallery only.",
      props: { moment: "plan", look: "glass", side: "top" },
      play: shown,
    },
    "plan-veil": {
      note: "The card role's thinner veil. Gallery only.",
      props: { moment: "plan", look: "veil" },
      play: shown,
    },
    "away-glass": {
      note: "On a return to news: under the Jump to new pill, where the away recap waits.",
      props: { moment: "away", look: "glass" },
      play: shown,
    },
    close: { note: "The X closes it for good.", props: { moment: "plan", look: "glass" }, play: closes },
  },
});
