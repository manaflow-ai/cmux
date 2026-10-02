// View-level types of the Changes pane. The data model and state machine live in model.ts.
import type { CSSProperties, Dispatch } from "react";
import type { ChangeScope, ChangesAction, ChangesPaneState, ChangesSource } from "./model";

/** Placement inside the window, CSS px. Half-pixel edges are honored (see snapFrame). */
export interface PaneFrame {
  left: number;
  top: number;
  width: number;
  height: number;
}

/** Tracked-only card copy. */
export interface ChangesBanner {
  title: string;
  body: string;
  actionLabel: string;
  secondaryLabel: string;
}

export type MenuIcon =
  | "refresh"
  | "wrap"
  | "split"
  | "collapse"
  | "file"
  | "image"
  | "plus-minus"
  | "cube"
  | "clipboard"
  | "eye";

/** A row of a popover menu: a separator or an item that dispatches `action` when chosen. */
export type MenuRow =
  | "-"
  | {
      label: string;
      icon?: MenuIcon;
      checked?: boolean;
      submenu?: boolean;
      disabled?: boolean;
      /** What choosing the row does. Rows without one only close the menu. */
      run?: () => void;
    };

/** Side effects the pane cannot perform itself (they belong to the app). */
export interface ChangesPaneEffects {
  /** Refresh / Retry. */
  onRefresh?: (scope: ChangeScope) => void;
  /** Open in a tab / in the editor. */
  onOpenFile?: (path: string, where: "tab" | "editor") => void;
}

export interface ChangesPaneProps extends ChangesPaneEffects {
  /** What each scope shows. */
  changes: ChangesSource;
  /** Uncontrolled: initial UI state (a capture is an initial state). */
  initial?: Partial<ChangesPaneState>;
  /** Controlled: UI state and its dispatcher (reduce with changesReducer). */
  state?: ChangesPaneState;
  dispatch?: Dispatch<ChangesAction>;
  /** Placement inside the window. Default MANUAL_FRAME. */
  frame?: PaneFrame;
  /**
   * The app build the capture shows. `manual` (default; manual-*, fixture-* and the SOTA
   * captures): the branch pill on its own row, a 250px tree. `live` (live-freestyle-*): the
   * branch pill beside the scope pill (wrapping only when the row is too narrow), a 200px
   * tree. Neither follows from the pane's width (the 583.5px and 949.5px manual panes both
   * have the 250px tree, the 820px live pane 200px).
   */
  build?: "manual" | "live";
  /**
   * Render only the diffs near the viewport (Pierre's Virtualizer), for change sets with
   * hundreds of files. Read once at mount. Off by default: the captures render every diff.
   */
  virtualize?: boolean;
  /** Called once when diffs, file headers and the tree have all rendered (see usePaneReady). */
  onReady?: () => void;
  className?: string;
  style?: CSSProperties;
}
