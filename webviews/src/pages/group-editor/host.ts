// The workspace group editor page's ops with its host (the native bubble, SidebarGroupEditor.swift).
// The page owns no data: the host streams one session per open (and a refresh of it when the group
// changes), and every edit goes back as a call that carries the session id, so a late call never
// applies to a newer open.

export const GroupEditorOps = {
  /** Stream: the open editor (`id` "" while none is open); a refresh keeps the id, bumps `revision`. */
  session: "cmux.groupEditor.session",
  /** {session, revision, height}: the session is drawn; the bubble sizes to `height` and shows. */
  ready: "cmux.groupEditor.ready",
  /** {session, name}: every edit of the name field; the host commits the latest when it closes. */
  draft: "cmux.groupEditor.draft",
  /** {session, color}: a palette dot was pressed (`GroupEditorColor.id`). */
  color: "cmux.groupEditor.color",
  /** {session}: the custom color dot was pressed. */
  customColor: "cmux.groupEditor.customColor",
  /** {session, item}: an action row was pressed (its id), or the emoji button (`SET_ICON_ITEM`). */
  item: "cmux.groupEditor.item",
  /** {session}: Return or Escape. */
  close: "cmux.groupEditor.close",
} as const;

/** The emoji or icon button's item: the group's Set Icon action (the shared icon picker). */
export const SET_ICON_ITEM = "workspaceGroup.setIcon";

/** The editor's words, in the host's language (GroupEditorStrings). */
export interface GroupEditorStrings {
  readonly editor: string;
  readonly nameLabel: string;
  readonly namePlaceholder: string;
  readonly customColor: string;
  readonly emoji: string;
}

/** One palette dot. */
export interface GroupEditorColor {
  readonly id: string;
  /** The dot's spoken name ("No color" for the first). */
  readonly label: string;
  /** The dot's fill, a CSS color. */
  readonly css: string;
  readonly chosen: boolean;
  /** The No color dot's hairline edge. */
  readonly outlined: boolean;
}

/** One action row. */
export interface GroupEditorItem {
  readonly id: string;
  readonly title: string;
  /** A data: URL of a black template image, drawn as a mask in the secondary text color. */
  readonly icon: string | null;
  /** The trailing text: the action's shortcut, or a value (the Sort row's "Manual"). */
  readonly shortcut: string | null;
}

export interface GroupEditorSession {
  /** "" when no editor is open: the page draws nothing. */
  readonly id: string;
  /** Bumps on every event; a refresh keeps the same id. */
  readonly revision: number;
  readonly name: string;
  /** The name the person typed this open (the host's last draft), or null while the field is untouched. A
   * page that reloads while the editor is open shows it, so the field holds what the close commits. */
  readonly draft?: string | null;
  readonly strings: GroupEditorStrings;
  readonly colors: readonly GroupEditorColor[];
  /** The custom color (when chosen) and whether it is the group's color. */
  readonly custom: { readonly css: string | null; readonly chosen: boolean };
  /** Sections of rows, a hairline between each. */
  readonly sections: readonly (readonly GroupEditorItem[])[];
}

/** The closed state: what the page draws before the first open and after a close. */
export const NO_SESSION: GroupEditorSession = {
  id: "",
  revision: 0,
  name: "",
  strings: { editor: "", nameLabel: "", namePlaceholder: "", customColor: "", emoji: "" },
  colors: [],
  custom: { css: null, chosen: false },
  sections: [],
};
