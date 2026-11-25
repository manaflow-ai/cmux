// The public UI base for customization pages, plugins and web pages: compose these instead of
// hand-rolled views, so every page follows the theme, the density and the design scale the app
// does. Import from here only; the pieces behind it may move. See kit/README.md.
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
