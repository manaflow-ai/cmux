// Instrument, the public UI base for customization pages, plugins and web pages: compose these instead
// of hand-rolled views, so every page follows the theme, the density and the design scale the app
// does. Import from here only; the pieces behind it may move. See kit/README.md and kit/CHANGELOG.md.
import "./kit.css";

export { Row, type RowDensity, type RowProps } from "./Row";
export { List, type ListProps } from "./List";
export { Pill, type PillProps, type PillSize, type PillTone } from "./Pill";
export { Avatar, type AvatarProps, type AvatarSize } from "./Avatar";
export { Field, type FieldProps } from "./Field";
export { Glass, type GlassLevel, type GlassProps } from "./Glass";
export { GlassMenu, type GlassMenuItem, type GlassMenuProps } from "./GlassMenu";
export { PopoverButton, type PopoverButtonProps } from "./PopoverButton";
export { Button, type ButtonProps, type ButtonSize, type ButtonVariant } from "../ui/Button";
export { Popover, type PopoverProps, type UiAnchor } from "../ui/Popover";
export { Input, type InputProps } from "../ui/Input";
export { Tooltip, TooltipProvider, type TooltipProps } from "../ui/Tooltip";
// The hover card the app already draws (a link's, a pull request's): Card is AnchoredCard by another name.
export {
  AnchoredCard,
  AnchoredCard as Card,
  type AnchoredCardProps,
  type AnchoredCardProps as CardProps,
} from "../ui/Tooltip";
export {
  Menu,
  MenuButton,
  MenuCheckboxItem,
  MenuGroup,
  MenuItem,
  MenuPopup,
  MenuRadioGroup,
  MenuRadioItem,
  MenuSeparator,
  Submenu,
  type MenuButtonProps,
  type MenuCheckboxItemProps,
  type MenuItemProps,
  type MenuPopupProps,
  type MenuProps,
  type MenuRadioGroupProps,
  type SubmenuProps,
} from "../ui/Menu";
// The surface primitive every card, sheet and ask card is drawn with: Panel is Surface by another name,
// with its slots (Panel.Header, .Body, .Inset, .Actions, .Trailing, .Action, .Keys).
export {
  Surface,
  Surface as Panel,
  type SurfaceProps,
  type SurfaceProps as PanelProps,
  type SurfaceRole,
  type SurfaceRole as PanelRole,
  type SurfaceTone,
} from "../ui/surface/Surface";
// Motion: the durations and the curve are the tokens below (`motion(step)`, MOTION, EASE_STANDARD);
// these read them as a node resolves them, and say how much may move now.
export { motionToken, warmMotionTokens } from "../ui/motion/motionTokens";
export { motionMode, springEasing, type MotionMode } from "../ui/motion/motionMode";
export { INSTRUMENT_VERSION } from "./version";
export { Icon } from "../agent-session/acpmux/icons/Icon";
export { StatusGlyph } from "../ui/StatusGlyph";
export type { StatusGlyphName } from "../ui/statusGlyphs.generated";
export { Spinner } from "../agent-session/acpmux/conversation/icons";
export * from "./tokens";
export { MinimalSessions, SessionList, type Session, type SessionListProps } from "./presets/SessionList";
export {
  DEFAULT_SESSION_LOOK,
  MINIMAL_SESSIONS_LOOK,
  sessionLook,
  type SessionLook,
  type SessionState,
} from "./presets/sessionLook";
