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

export type NativePopupEventType = "pick" | "change" | "search" | "highlight" | "complete" | "submit" | "dismiss";

export type NativePopupSide = "top" | "bottom";

export type NativePopupAlign = "start" | "end";

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
  footer?: NativePopupRow[];
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
