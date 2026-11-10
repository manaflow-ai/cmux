// l10n-allow-file: gallery fixtures, public-safe chrome and sample tab labels.
// The selected tab is the foreground (design/selected-is-foreground.md): a review of the folder tab's
// shape, corner radius and join, drawn from the real layer tokens (--cmux-content-surface,
// --cmux-chrome-shade, --cmux-selected-surface), so the gallery's theme and background axes show it
// light, dark and over an image. The native strip draws the same outline (TabCell+CornerFeet.swift,
// ChromeShadeHoles.swift): the content and its selected tab are one shape in the content's surface,
// and the chrome's shade is everything else, so over a picture the tab shows exactly what the content does.

export type FolderShape = "goo" | "square" | "pill";
export type FolderJoin = "seamless" | "hairline";

export type FolderTabsProps = {
  /** goo: concave fillets into the content (ships); square: the tab sits on the edge with sharp inner
   * corners; pill: the gray pill before this change. */
  shape: FolderShape;
  /** The fillets' radius, in points (the native strip: 8). */
  fillet: number;
  /** The tab's top corner radius (the native compact tab: 6). */
  radius: number;
  join: FolderJoin;
  /** Which tab is selected; 0 is the first, on the content's leading edge. */
  selected: number;
  /** Pins the look instead of following the gallery's theme and background axes: light, dark, or a
   * picture behind a see-through window (the selected row keeps the selection fill there). */
  scene?: FolderScene;
  /** card: one content card (the default window); floating: Floating Panes, each pane its own card
   * with its own strip, its pane padding kept (Metrics.codePanePadding). */
  panes?: FolderPanes;
  /** The content card's corner radius (layout.paneCornerRadius; 12 by default). 0: a square card whose
   * straight top edge the folder joins, no wedges. */
  cardRadius?: number;
};

export type FolderScene = "light" | "dark" | "image";
export type FolderPanes = "card" | "floating";

const TABS = ["retry.ts", "Agent: plan the fix", "docs / backoff", "Terminal"];
const W = 760;
const H = 300;
const SIDEBAR = 172;
const GAP = 6;
const STRIP_TOP = 10;
const TAB_TOP = 14;
const TAB_W = 132;
const TAB_GAP = 2;
const CARD_R = 12;
/** Floating Panes' pane padding: each strip's first tab starts this far inside its card. */
const PANE_PAD = 4;

type Box = { x0: number; x1: number; top: number; bottom: number };

/** The content card and its selected tab as one outline (y down), clockwise: the card's top edge
 * rises into the tab through concave fillets of `f`, or straight up its side when the tab leads. */
export function folderOutline(
  card: Box,
  tab: { a: number; b: number; top: number },
  rt: number,
  f: number,
  R = CARD_R,
): string {
  const { x0, x1, top: T, bottom: B } = card;
  const { a, b, top: t } = tab;
  const leads = a <= x0 + 0.5;
  const p: string[] = [`M ${x0} ${B - R}`];
  if (leads) {
    p.push(`L ${x0} ${t + rt}`);
  } else {
    p.push(`L ${x0} ${T + R}`, `A ${R} ${R} 0 0 1 ${x0 + R} ${T}`);
    p.push(f > 0 ? `L ${a - f} ${T} A ${f} ${f} 0 0 0 ${a} ${T - f}` : `L ${a} ${T}`);
    p.push(`L ${a} ${t + rt}`);
  }
  p.push(`A ${rt} ${rt} 0 0 1 ${a + rt} ${t}`, `L ${b - rt} ${t}`, `A ${rt} ${rt} 0 0 1 ${b} ${t + rt}`);
  p.push(f > 0 ? `L ${b} ${T - f} A ${f} ${f} 0 0 0 ${b + f} ${T}` : `L ${b} ${T}`);
  p.push(
    `L ${x1 - R} ${T}`,
    `A ${R} ${R} 0 0 1 ${x1} ${T + R}`,
    `L ${x1} ${B - R}`,
    `A ${R} ${R} 0 0 1 ${x1 - R} ${B}`,
  );
  p.push(`L ${x0 + R} ${B}`, `A ${R} ${R} 0 0 1 ${x0} ${B - R}`, "Z");
  return p.join(" ");
}

/** The card alone (the pill look, where the tab does not join it). */
function cardOutline({ x0, x1, top: T, bottom: B }: Box, R = CARD_R): string {
  return `M ${x0} ${T + R} A ${R} ${R} 0 0 1 ${x0 + R} ${T} L ${x1 - R} ${T} A ${R} ${R} 0 0 1 ${x1} ${T + R} L ${x1} ${B - R} A ${R} ${R} 0 0 1 ${x1 - R} ${B} L ${x0 + R} ${B} A ${R} ${R} 0 0 1 ${x0} ${B - R} Z`;
}

type Pane = { card: Box; tabs: string[]; selected: number; inset: number };

export function FolderTabs({
  shape,
  fillet,
  radius,
  join,
  selected,
  scene,
  panes = "card",
  cardRadius = CARD_R,
}: FolderTabsProps) {
  const stripBottom = STRIP_TOP + 36;
  const area: Box = { x0: SIDEBAR + GAP, x1: W - GAP, top: stripBottom, bottom: H - GAP };
  const mid = (area.x0 + area.x1) / 2;
  const layout: Pane[] =
    panes === "floating"
      ? [
          {
            card: { ...area, x1: mid - GAP / 2 },
            tabs: TABS.slice(0, 2),
            selected: Math.min(selected, 1),
            inset: PANE_PAD,
          },
          { card: { ...area, x0: mid + GAP / 2 }, tabs: TABS.slice(2), selected: 0, inset: PANE_PAD },
        ]
      : [{ card: area, tabs: TABS, selected, inset: 0 }];
  const joined = shape !== "pill";
  const tabX = (pane: Pane, index: number) => pane.card.x0 + pane.inset + index * (TAB_W + TAB_GAP);
  const outlines = layout.map((pane) => {
    const a = tabX(pane, pane.selected);
    const tab = { a, b: a + TAB_W, top: TAB_TOP };
    return joined
      ? folderOutline(pane.card, tab, radius, shape === "goo" ? fillet : 0, cardRadius)
      : cardOutline(pane.card, cardRadius);
  });
  const shade = `M 0 0 H ${W} V ${H} H 0 Z ${outlines.join(" ")}`;
  const body = layout[0].card;
  return (
    <div
      className="folder-tabs"
      data-shape={shape}
      data-join={join}
      data-scene={scene}
      data-panes={panes}
      style={{ width: W, height: H }}
    >
      <svg className="folder-tabs-layers" viewBox={`0 0 ${W} ${H}`} width={W} height={H} aria-hidden="true">
        <path className="folder-tabs-chrome" d={shade} fillRule="evenodd" />
        {outlines.map((outline) => (
          <path key={outline} className="folder-tabs-content" d={outline} />
        ))}
        {join === "hairline"
          ? outlines.map((outline) => <path key={outline} className="folder-tabs-edge" d={outline} />)
          : null}
        {joined
          ? null
          : layout.map((pane) => (
              <rect
                key={pane.card.x0}
                className="folder-tabs-pill"
                x={tabX(pane, pane.selected)}
                y={TAB_TOP}
                width={TAB_W}
                height={stripBottom - TAB_TOP - 6}
                rx={radius}
              />
            ))}
      </svg>
      {layout.map((pane) => (
        <ol
          key={pane.card.x0}
          className="folder-tabs-strip"
          role="tablist"
          style={{ left: pane.card.x0 + pane.inset, top: TAB_TOP }}
        >
          {pane.tabs.map((title, index) => (
            <li
              key={title}
              className="folder-tabs-tab"
              role="tab"
              aria-selected={index === pane.selected}
              style={{
                left: index * (TAB_W + TAB_GAP),
                width: TAB_W,
                height: stripBottom - TAB_TOP - (joined ? 0 : 6),
              }}
            >
              {title}
            </li>
          ))}
        </ol>
      ))}
      <ul className="folder-tabs-sidebar" style={{ width: SIDEBAR - GAP * 2, left: GAP, top: stripBottom }}>
        <li>Workspaces</li>
        <li className="folder-tabs-row" aria-current="true">
          todo-app
        </li>
        <li className="folder-tabs-row">api-server</li>
        <li className="folder-tabs-row">docs</li>
      </ul>
      <div
        className="folder-tabs-body"
        style={{ left: body.x0 + 20, top: stripBottom + 22, width: body.x1 - body.x0 - 40 }}
      >
        <p>The selected tab is the content it opens: one shape, one surface.</p>
        <i />
        <i className="short" />
      </div>
    </div>
  );
}
