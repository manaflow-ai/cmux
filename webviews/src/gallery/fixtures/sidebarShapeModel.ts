/** Review-only sidebar fixture for the chrome parity gallery.
 *
 * Every dimension is derived from `sidebarScale`; variants change treatment and
 * content, never individual geometry. The fixture is intentionally separate
 * from production defaults until the design review picks a direction.
 */
export type SidebarDensity = "compact" | "comfortable";
export type SidebarAppearance = "light" | "dark";
export type SidebarVariant = "A" | "B" | "C" | "D";

export type SidebarShapeTokens = Readonly<{
  scale: number;
  rowHeight: number;
  edgeInset: number;
  contentInset: number;
  iconBox: number;
  iconSize: number;
  trailingInset: number;
  groupGap: number;
  rowRadius: number;
  selectionRadius: number;
  titleSize: number;
  labelSize: number;
}>;

export function sidebarScale(density: SidebarDensity, uiScale = 1): number {
  // Compact is 32 logical px; comfortable is 36. Future modes add a scale,
  // rather than introducing one-off spacing or type literals.
  return (density === "comfortable" ? 36 / 32 : 1) * uiScale;
}

export function sidebarTokens(density: SidebarDensity, uiScale = 1): SidebarShapeTokens {
  const scale = sidebarScale(density, uiScale);
  const px = (value: number) => Math.round(value * scale * 100) / 100;
  return {
    scale,
    rowHeight: px(32),
    edgeInset: px(8),
    contentInset: px(12),
    iconBox: px(16),
    iconSize: px(14),
    trailingInset: px(8),
    groupGap: px(8),
    rowRadius: px(8),
    selectionRadius: px(8),
    titleSize: px(14),
    labelSize: px(11),
  };
}

export type SidebarRow = Readonly<{
  title: string;
  detail?: string;
  icon?: string;
  selected?: boolean;
}>;

export type SidebarGroup = Readonly<{
  title: string;
  rows: readonly SidebarRow[];
  colour?: string;
}>;

export function sidebarGroups(variant: SidebarVariant): readonly SidebarGroup[] {
  const groups: SidebarGroup[] = [
    {
      title: "Today",
      rows: [
        { title: "Review parity", detail: "Working", icon: "agent.session", selected: true },
        { title: "Design pass", detail: "2h ago", icon: "agent.chat" },
      ],
    },
    {
      title: "cmux NEXT",
      rows: [
        { title: "Sidebar proportions", icon: "workspace" },
        { title: "Cloud workspaces", detail: "Remote", icon: "cloud" },
        { title: "Composer polish", icon: "agent.chat" },
      ],
    },
    {
      title: "Research",
      rows: [
        { title: "Design references", icon: "browser" },
        { title: "Native chrome", icon: "workspace" },
        { title: "Archive", icon: "folder" },
      ],
    },
  ];
  if (variant === "B")
    return groups.map((group) => ({ ...group, colour: "var(--agent-ansi-4, var(--cmux-accent, currentColor))" }));
  return groups;
}

export function sidebarVariantClass(variant: SidebarVariant): string {
  return `sidebar-shape--${variant.toLowerCase()}`;
}
