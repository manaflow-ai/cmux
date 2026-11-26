// Every hover tooltip and hover preview in webviews/src, by the class list its root renders with.
// hover-glass.test.ts fails when the page code opens a Tooltip, an AnchoredCard or a role="tooltip"
// surface whose own class is not listed here, so a new one is checked from its first commit.
export type HoverSurface = { name: string; className: string; role?: string };

const TOOLTIP = "ui-tooltip ui-glass"; // ui/Tooltip.tsx Tooltip's popup
const CARD = "ui-tooltip ui-card ui-glass"; // ui/Tooltip.tsx AnchoredCard's popup

export const HOVER_SURFACES: HoverSurface[] = [
  { name: "tooltip", className: TOOLTIP },
  { name: "title tooltip (ui/titleTooltips.ts)", className: "ui-title-tooltip ui-glass" },
  { name: "toolbar hint (ui/Toolbar.tsx)", className: `${CARD} ui-hint` },
  { name: "goal preview (TaskGoalStrip.tsx)", className: `${TOOLTIP} ui-card acpmux-goal-preview` },
  { name: "PR checks (PullRequestCard.tsx)", className: `${TOOLTIP} ui-card acpmux-pr-card__checkNames` },
  { name: "message group hover (MessageGroupHead.tsx)", className: `${TOOLTIP} ui-card cv-group-hover__popup` },
  {
    name: "subagent preview (SubagentPreview.tsx)",
    className: `${TOOLTIP} ui-card acpmux-agent-card__popup acpmux-subagent-preview`,
  },
  { name: "agent card (AgentLine.tsx)", className: `${TOOLTIP} ui-card acpmux-agent-card__popup` },
  { name: "hat peek (SubagentTray.tsx)", className: `${TOOLTIP} ui-card acpmux-agent-card__popup acpmux-hat-peek` },
  { name: "New Tab hover card (StageCards.tsx)", className: `${TOOLTIP} ui-card ui-glass nt-hovercard` },
  { name: "changes breakdown (ChangesSection.tsx)", className: `${TOOLTIP} acpmux-session-info-breakdown` },
  { name: "link card (LinkHoverCard.tsx)", className: `${CARD} ui-glass ui-glass-floats cv-link-preview` },
  {
    name: "PR card (LinkHoverCard.tsx)",
    className: `${CARD} ui-glass ui-glass-floats cv-link-preview acpmux-pr-card`,
  },
  {
    name: "cmux link card (CmuxLinkChip.tsx)",
    className: `${CARD} ui-glass ui-glass-floats cv-link-preview cv-cmux-link-card`,
  },
  {
    name: "Home link card (HomeLinkChip.tsx)",
    className: `${CARD} ui-glass ui-glass-floats cv-link-preview hm-link-preview`,
  },
  { name: "Markdown link bubble (linkOverlays.tsx)", className: `${CARD} md-link-bubble` },
  {
    name: "session hover card (useSessionHover.tsx)",
    className: `${CARD} ui-glass ui-glass-floats acpmux-session-hover-card`,
  },
  {
    name: "tool visual card (ToolVisualPreview.tsx)",
    className: `${CARD} ui-glass ui-glass-floats cv-tool-visual-card`,
  },
  {
    name: "context card, compact (ComposerPickers.tsx)",
    className: `${CARD} acpmux-context-card acpmux-context-pop acpmux-context-pop--compact`,
  },
  {
    name: "context card, breakdown (ComposerPickers.tsx)",
    className: `${CARD} acpmux-context-card acpmux-context-pop acpmux-context-pop--breakdown`,
  },
  {
    name: "context card, plan (ComposerPickers.tsx)",
    className: `${CARD} acpmux-context-card acpmux-context-pop acpmux-plan-pop`,
  },
  { name: "chart tooltip (chief-usage/charts.tsx)", className: "ui-glass cu-tooltip" },
  {
    name: "header tool preview (HeaderToolPreview.tsx)",
    className: "ui-card ui-glass acpmux-header-preview",
    role: "tooltip",
  },
  { name: "thread minimap card (PreviewCard.tsx)", className: "ui-card ui-glass acpmux-minimap__card" },
];
