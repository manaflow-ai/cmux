// l10n-allow-file: fixture sessions for the gallery, the mock host (`/group-editor/?mock`) and the
// tests. The app's words and colors come from the host (GroupEditorStrings, GroupTint); these are
// public-safe stand-ins in the same shape.
import type { GroupEditorColor, GroupEditorItem, GroupEditorSession } from "./host";

/** A black template icon as the host sends one (a data: URL), here a small SVG path. */
function icon(path: string): string {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="none" stroke="black" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round">${path}</svg>`;
  return `data:image/svg+xml,${encodeURIComponent(svg)}`;
}

const ICONS = {
  newWorkspace: icon('<rect x="2.5" y="2.5" width="11" height="11" rx="2.5"/><path d="M8 5.5v5M5.5 8h5"/>'),
  newWindow: icon('<rect x="2" y="3" width="12" height="10" rx="2"/><path d="M2 6h12"/>'),
  close: icon('<circle cx="8" cy="8" r="5.5"/><path d="M6 6l4 4M10 6l-4 4"/>'),
  pin: icon('<path d="M6 2.5h4M7 2.5v4L4.5 9h7L9 6.5v-4M8 9v4.5"/>'),
  moveToTop: icon('<path d="M4 7l4-4 4 4M8 3v10"/>'),
  sort: icon('<path d="M3 4.5h10M5 8h6M7 11.5h2"/>'),
  ungroup: icon('<rect x="2" y="2" width="7" height="7" rx="1.5"/><rect x="7" y="7" width="7" height="7" rx="1.5"/>'),
  delete: icon('<path d="M3 4.5h10M6.5 4.5V3h3v1.5M4.5 4.5l.7 8.5h5.6l.7-8.5"/>'),
};

/** The group palette in the editor's order: none first, then the colors (content, as GroupColor's). */
const PALETTE: ReadonlyArray<[id: string, label: string, css: string]> = [
  ["grey", "No color", "hsl(240 2% 57%)"],
  ["red", "Red", "hsl(3 100% 67%)"],
  ["orange", "Orange", "hsl(36 100% 52%)"],
  ["yellow", "Yellow", "hsl(50 100% 52%)"],
  ["green", "Green", "hsl(135 64% 50%)"],
  ["cyan", "Cyan", "hsl(197 100% 70%)"],
  ["blue", "Blue", "hsl(210 100% 52%)"],
  ["purple", "Purple", "hsl(280 85% 65%)"],
  ["pink", "Pink", "hsl(348 100% 61%)"],
];

/** The palette with `chosen` (a palette id, or null for none of them) ringed. */
export function fixtureColors(chosen: string | null): GroupEditorColor[] {
  return PALETTE.map(([id, label, css]) => ({ id, label, css, chosen: id === chosen, outlined: id === "grey" }));
}

/** The standard rows (SidebarGroupEditing.standardItems): pin titles the change it makes. */
export function fixtureSections(options: { pinned?: boolean; icons?: boolean } = {}): GroupEditorItem[][] {
  const row = (id: string, title: string, glyph: string, shortcut: string | null = null): GroupEditorItem => ({
    id,
    title,
    icon: options.icons === false ? null : glyph,
    shortcut,
  });
  return [
    [
      row("workspaceGroup.newWorkspace", "New Workspace in Group", ICONS.newWorkspace, "⌘N"),
      row("workspaceGroup.moveToNewWindow", "Move to New Window", ICONS.newWindow),
      row("workspaceGroup.closeWorkspaces", "Close All in Group", ICONS.close),
    ],
    [
      row("workspaceGroup.togglePin", options.pinned ? "Unpin Group" : "Pin Group", ICONS.pin),
      row("workspaceGroup.moveToTop", "Move to Top", ICONS.moveToTop),
      row("sidebar.group.sort", "Sort", ICONS.sort, "Manual"),
    ],
    [
      row("workspaceGroup.ungroup", "Ungroup", ICONS.ungroup),
      row("workspaceGroup.delete", "Delete Group", ICONS.delete),
    ],
  ];
}

export interface FixtureOptions {
  id?: string;
  revision?: number;
  name?: string;
  /** A palette id, "custom" for the custom color, or null for no color. */
  chosen?: string | null;
  pinned?: boolean;
  icons?: boolean;
}

/** One open editor, as the host streams it. */
export function fixtureSession(options: FixtureOptions = {}): GroupEditorSession {
  const chosen = options.chosen === undefined ? "blue" : options.chosen;
  const custom = chosen === "custom";
  return {
    id: options.id ?? "fixture-group",
    revision: options.revision ?? 1,
    name: options.name ?? "Frontend",
    strings: {
      editor: "Edit Workspace Group",
      nameLabel: "Group name",
      namePlaceholder: "Name this group",
      customColor: "Custom color",
      emoji: "Choose emoji or icon",
    },
    // No color rings the grey dot, as the native editor does.
    colors: fixtureColors(custom ? null : (chosen ?? "grey")),
    custom: { css: custom ? "hsl(143 25% 49%)" : null, chosen: custom },
    sections: fixtureSections({ pinned: options.pinned, icons: options.icons }),
  };
}
