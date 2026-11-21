// The native popup wire. Its Swift twin is CmuxNextDesign/Overlay/PopupProtocol; change both together.

export type NativePopupRowKind =
  | "action"
  | "toggle"
  | "choice"
  | "section"
  | "separator"
  | "text"
  | "slider"
  | "submenu"
  | "textField";

/** `navigate`: Left or Right asked for the previous or next rail tab (`value`); the page picks it. */
export type NativePopupEventType =
  | "pick"
  | "change"
  | "search"
  | "highlight"
  | "complete"
  | "submit"
  | "dismiss"
  | "navigate";

export type NativePopupSide = "top" | "bottom";

export type NativePopupAlign = "start" | "end";

/**
 * Where the rail's tabs sit, as the web picker's harness placements draw them: `symbols` a wrapping
 * row of marks across the top (names only as tooltips), `top` a wrapping strip of marks with names,
 * `left` a column of marks with names, `compact` a narrow column with each name under its mark.
 * Absent: the original column beside the title and search.
 */
export type NativePopupRailPlacement = "symbols" | "left" | "top" | "compact";

export interface NativePopupAnchor {
  left: number;
  top: number;
  right: number;
  bottom: number;
}

export interface NativePopupOption {
  id: string;
  label: string;
  disabled?: boolean;
}

export interface NativePopupAction {
  id: string;
  label: string;
  icon?: string;
  disabled?: boolean;
  keepOpen?: boolean;
}

export type NativePopupAutoHighlight = "none" | "first" | "always";

export interface NativePopupField {
  id: string;
  value: string;
  placeholder: string;
  disabled?: boolean;
  submitOnReturn?: boolean;
  autoHighlight?: NativePopupAutoHighlight;
  completeOnTab?: boolean;
  editSequence?: number;
}

export type NativePopupSliderStyle = "accent" | "minimal";

export interface NativePopupSliderStop {
  value: string;
  label: string;
  description?: string;
  accessibilityLabel?: string;
}

export interface NativePopupSlider {
  stops: NativePopupSliderStop[];
  selectedValue?: string;
  defaultValue?: string;
  recommendedValue?: string;
  recommendedLabel?: string;
  minimumLabel?: string;
  maximumLabel?: string;
  accessibilityLabel?: string;
  style?: NativePopupSliderStyle;
}

export interface NativePopupRow {
  id: string;
  kind: NativePopupRowKind;
  label: string;
  description?: string;
  icon?: string;
  shortcut?: string;
  disabled?: boolean;
  disabledReason?: string;
  checked?: boolean;
  value?: string;
  keepOpen?: boolean;
  placeholder?: string;
  options?: NativePopupOption[];
  actions?: NativePopupAction[];
  children?: NativePopupRow[];
  minimum?: number;
  maximum?: number;
  step?: number;
  slider?: NativePopupSlider;
  completion?: string;
  editSequence?: number;
  /**
   * The trailing item of a row whose `children` open beside it (a model's effort column: its
   * level, then a chevron), or a submenu's current value before its chevron.
   */
  sideLabel?: string;
  /** A rail tab's agent mark (a brand, agent or provider id the native brand catalog knows). */
  mark?: string;
  /** A rail tab's text mark when it has no `mark` (its name's initial, or an emoji icon). */
  monogram?: string;
}

/**
 * One column of a popup laid out as columns (the model picker's harness rail, its models, then the
 * shown model's effort and Fast), side by side under the search row; each scrolls on its own.
 */
export interface NativePopupColumn {
  id: string;
  /** The column's accessible name. */
  label: string;
  /** Points wide; absent on the last column, which takes what is left of the popup's width. */
  width?: number;
  /** The rows draw as a narrow rail of marks (`mark`, `monogram` or `icon`), the checked one lit. */
  rail?: boolean;
  rows: NativePopupRow[];
}

export interface NativePopupModel {
  schemaVersion: 1;
  id: string;
  revision: number;
  anchor: NativePopupAnchor;
  side: NativePopupSide;
  align: NativePopupAlign;
  width: number;
  rows: NativePopupRow[];
  parentId?: string;
  title?: string;
  search?: NativePopupField;
  highlighted?: string;
  rail?: NativePopupRow[];
  railWidth?: number;
  railPlacement?: NativePopupRailPlacement;
  footer?: NativePopupRow[];
  /** Columns side by side under the search row (and under `rows`, which span the popup). Not with a rail. */
  columns?: NativePopupColumn[];
  /** The columns' band is at most this tall; a longer column scrolls. */
  columnsHeight?: number;
  /**
   * A control at the search row's leading edge, drawn as its mark (the picker's account avatar):
   * a `submenu` whose children open beside the popup, or an `action`. Needs `search`.
   */
  searchAccessory?: NativePopupRow;
}

/** Every top-level row a popup draws, in order: rail, search accessory, rows, columns, footer. */
export function nativePopupRows(model: {
  rail?: NativePopupRow[];
  searchAccessory?: NativePopupRow;
  rows: NativePopupRow[];
  columns?: NativePopupColumn[];
  footer?: NativePopupRow[];
}): NativePopupRow[] {
  return [
    ...(model.rail ?? []),
    ...(model.searchAccessory ? [model.searchAccessory] : []),
    ...model.rows,
    ...(model.columns ?? []).flatMap((column) => column.rows),
    ...(model.footer ?? []),
  ];
}

export interface NativePopupEvent {
  type: NativePopupEventType;
  popupId: string;
  revision: number;
  id?: string;
  value?: string;
  reason?: string;
  editSequence?: number;
}
