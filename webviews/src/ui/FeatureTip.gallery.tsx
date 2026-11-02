// l10n-allow-file: gallery fixtures (tip text from public What's New highlights), not shipped UI.
// Feature tips (leo-workspace design/feature-tips.md): the callout on three controls of the agent
// chat, in three looks. Light and dark are the gallery's theme axis. Chosen and live: the Browser
// button in the `glass` look (featureTips.tsx); the others stay here.
import { createElement, useEffect, useRef, useState, type ComponentType } from "react";
import { componentEntry } from "../gallery/format";
import type { Play } from "../gallery/play";
import type { FeatureTipLook } from "./FeatureTip";
import { PanelToggle } from "../agent-session/acpmux/header/PanelToggle";
import { memoryTipHost } from "./featureTips/store";

type Target = "browser" | "inspector" | "composer";
/** `live`: the shipped wiring itself (PaneFeatureTips: the catalog, the anchor table and the
    scheduler), with records in memory and a page opened long ago. */
type Props = { target: Target; look: FeatureTipLook; live?: boolean };

/** Each placement's control and its tip, from that control's highlight (title, first sentence). */
const PLACEMENTS: Record<Target, { selector: string; side: "top" | "bottom"; title: string; body: string }> = {
  browser: {
    selector: '[data-quick-action="browser"]',
    side: "bottom",
    title: "Agents drive the browser tabs you can see",
    body: "Agents that use the browser now open and drive real Chromium or WebKit tabs in your window.",
  },
  inspector: {
    selector: ".acpmux-header-panel-toggle",
    side: "bottom",
    title: "Session Info shows everything about a chat",
    body: "The toggle at the top right of an agent chat opens Session Info over the chat.",
  },
  composer: {
    selector: ".feature-tip-gallery-composer",
    side: "top",
    title: "Ask a side question while your agent works",
    body: "Type /btw followed by a question in the chat composer.",
  },
};

const noop = () => undefined;

type Loaded = {
  Header: ComponentType<Record<string, unknown>>;
  Tip: typeof import("./FeatureTip").FeatureTip;
  Live: typeof import("../agent-session/acpmux/featureTips").PaneFeatureTips;
};

function GalleryChat({ target, look, live, Header, Tip, Live }: Props & Loaded) {
  const stage = useRef<HTMLDivElement>(null);
  const [anchor, setAnchor] = useState<Element | null>(null);
  const placement = PLACEMENTS[target];
  useEffect(() => setAnchor(stage.current?.querySelector(placement.selector) ?? null), [placement.selector]);
  const [open, setOpen] = useState(true);
  const [liveDeps] = useState(() => ({
    host: memoryTipHost(),
    schedule: { openedAt: 0, focused: () => true },
  }));
  return (
    <div ref={stage} className="feature-tip-gallery">
      <div className="feature-tip-gallery-header">
        <Header
          onTerminal={noop}
          onBrowser={noop}
          onSplitDown={noop}
          onFiles={noop}
          summary={createElement(PanelToggle, {
            label: "Session Info",
            shown: false,
            icon: "view.list",
            onToggle: noop,
          })}
          menu={() => []}
          onMenuOpen={async () => undefined}
        />
      </div>
      <div className="feature-tip-gallery-body" />
      <div className="ui-glass feature-tip-gallery-composer">Ask anything</div>
      {live ? (
        <Live streaming={false} host={liveDeps.host} schedule={liveDeps.schedule} />
      ) : (
        <Tip
          anchor={open ? anchor : null}
          open={open}
          side={placement.side}
          title={placement.title}
          body={placement.body}
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
  const view = ctx.document.defaultView!;
  if (view.getComputedStyle(tip).opacity !== "1") throw new Error("a feature tip opens in one frame, with no fade-in");
  if (ctx.document.activeElement && tip.contains(ctx.document.activeElement))
    throw new Error("a feature tip took focus");
};

const closes: Play = async (ctx) => {
  await shown(ctx);
  await ctx.click({ role: "button", name: "Close tip" });
  await ctx.waitFor(() => !ctx.document.querySelector("[data-feature-tip]"));
};

const variant = (target: Target, look: FeatureTipLook, note: string) => ({
  note,
  props: { target, look },
  play: shown,
});

export default componentEntry<Props>({
  id: "ui.feature-tip",
  title: "Feature tip",
  area: "Agent pane",
  pane: true,
  height: 360,
  widths: { narrow: 390, normal: 560, wide: 860 },
  anchors: [{ selector: "[data-feature-tip]" }],
  covers: [
    "ui/FeatureTip.tsx#FeatureTip",
    "ui/featureTips/FeatureTipHost.tsx#FeatureTipHost",
    "agent-session/acpmux/featureTips.tsx#PaneFeatureTips",
  ],
  load: () =>
    Promise.all([
      import("../agent-session/acpmux/header/ChatHeaderTools"),
      import("./FeatureTip"),
      import("../agent-session/acpmux/featureTips"),
    ]).then(
      ([header, tip, live]) =>
        (props: Props) =>
          createElement(GalleryChat, {
            ...props,
            Header: header.ChatHeaderTools as unknown as ComponentType<Record<string, unknown>>,
            Tip: tip.FeatureTip,
            Live: live.PaneFeatureTips,
          }),
    ),
  styles: () =>
    Promise.all([
      import("../agent-session/acpmux/styles.css"),
      import("./popupSurface.css"),
      import("../agent-session/acpmux/header/header.css"),
      import("./featureTip.gallery.css"),
    ]),
  variants: {
    live: {
      note: "What ships: the chat's own tip wiring picks the Browser tip from the What's New highlight and points it at the real button.",
      props: { target: "browser", look: "glass", live: true },
      play: shown,
    },
    "browser-glass": variant(
      "browser",
      "glass",
      "Chosen and live: the popup glass under the header's Browser button, the New pill in the pane's accent.",
    ),
    "browser-accent": variant(
      "browser",
      "accent",
      "The reference's accent-filled callout, as accent-tinted glass (never opaque). Gallery only.",
    ),
    "browser-veil": variant("browser", "veil", "The card role's thinner veil, no shadow. Gallery only."),
    "session-info-glass": variant(
      "inspector",
      "glass",
      "A recently shipped toolbar control: Session Info toggle. Gallery only.",
    ),
    "composer-glass": variant(
      "composer",
      "glass",
      "A composer feature (/btw): the tip opens above the composer. Gallery only.",
    ),
    "composer-accent": variant("composer", "accent", "The accent look above the composer. Gallery only."),
    close: { note: "The X closes it at once.", props: { target: "browser", look: "glass" }, play: closes },
  },
});
