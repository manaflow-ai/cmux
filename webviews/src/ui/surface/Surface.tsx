// THE SURFACE PRIMITIVE. Every card, popover, menu, toast, sheet, tooltip, hover card, pill and ask
// card is one `<Surface role>`: it renders ONE element, `class="ui-surface"` with `data-surface-role`,
// and surface.css styles it only from `--surface-<role>-*` (schemas/surface-roles/surface-roles.json, the
// block in ui/glass/glass.css). A surface never styles its own shell: a different look is a different
// role value, which a theme (a look) can override in one place.
//
// Material comes from the role (Leo 2026-11-22: "our shitty multi layer glass + web view. we need to
// properly do that once and for all"). A floating role composes the existing glass (`.ui-glass`, and
// `data-host-glass` where the App draws it under the page); a content role composes
// `.ui-glass.ui-glass-content`: near-solid tint, hairline ring, no backdrop-filter, no shadow. A
// floating surface opened from inside another is a sibling, never a child, so it never stacks a blur.
//
// Slots have fixed geometry, so nothing shifts: the header row and the actions row reserve their block
// size from tokens, and hover and focus change paint only.
import { createContext, use, type HTMLAttributes, type ReactNode, type Ref } from "react";
import roles from "../../../../schemas/surface-roles/surface-roles.json";
import { Button, type ButtonProps } from "../Button";
import { cx } from "../cx";
import "./surface.css";

/** The roles a web surface can take (the JSON's `name`s that a primitive draws). */
export type SurfaceRole = "ask" | "card" | "popover" | "menu" | "hoverCard" | "tooltip" | "toast" | "sheet" | "pill";

/** How the role is drawn: window (the app's pane glass), floating (one host glass) or content. */
export type SurfaceMaterial = "window" | "floating" | "content";

export const SURFACE_ROLES: readonly SurfaceRole[] = [
  "ask",
  "card",
  "popover",
  "menu",
  "hoverCard",
  "tooltip",
  "toast",
  "sheet",
  "pill",
];

const MATERIALS = new Map<string, SurfaceMaterial>(
  roles.roles.map((role) => [role.name, role.web.material as SurfaceMaterial]),
);

/** The role's material, read from the one source. */
export function surfaceMaterial(role: SurfaceRole): SurfaceMaterial {
  return MATERIALS.get(role) ?? "content";
}

/** Which glass the App draws under a floating surface (`data-host-glass`), when it does. */
export type SurfaceHostGlass = "popover" | "menu" | "chip";

/** A tone changes ink only (the header's icon); never a fill, a size or a box. */
export type SurfaceTone = "neutral" | "attention" | "danger";

type DataAttributes = { [name: `data-${string}`]: string | undefined };

/** The element a surface (or a slot) renders; one, never a wrapper. */
export type SurfaceTag = "div" | "fieldset" | "section" | "article" | "aside" | "form" | "pre" | "p";

type ElementProps = HTMLAttributes<HTMLElement> & DataAttributes & { ref?: Ref<any> };

export type SurfaceProps = Omit<ElementProps, "role"> & {
  role: SurfaceRole;
  /** The one element it renders (default div; the ask card is a fieldset so its keys belong to a group). */
  as?: SurfaceTag;
  tone?: SurfaceTone;
  /** A floating surface the App draws its glass under (ui/glass/hostGlass.ts). */
  hostGlass?: SurfaceHostGlass;
};

const TitleId = createContext<string | undefined>(undefined);

export function Surface({ role, as: Tag = "div", tone, hostGlass, className, children, ...rest }: SurfaceProps) {
  const material = surfaceMaterial(role);
  const hosted = material === "floating" && hostGlass;
  return (
    <Tag
      {...rest}
      className={cx(
        "ui-surface",
        material === "floating" && "ui-glass ui-glass-transient",
        material === "content" && "ui-glass ui-glass-content",
        className,
      )}
      data-surface-role={role}
      data-surface-material={material}
      data-tone={tone && tone !== "neutral" ? tone : undefined}
      data-host-glass={hosted ? hostGlass : undefined}
      data-host-glass-cover={hosted ? "" : undefined}
    >
      {children}
    </Tag>
  );
}

type HeaderProps = {
  /** The leading icon, drawn in a 16 box and centred in it. */
  icon?: ReactNode;
  /** Beside the title at the trailing edge (a count, a close control). */
  trailing?: ReactNode;
  className?: string;
  titleClassName?: string;
  titleProps?: DataAttributes;
  /** The title's id, for the surface's `aria-labelledby`. */
  titleId?: string;
  children: ReactNode;
};

/** The header row: a leading icon box (16) and the title, one line, a fixed block size. */
function Header({ icon, trailing, className, titleClassName, titleProps, titleId, children }: HeaderProps) {
  const inherited = use(TitleId);
  return (
    <div className={cx("ui-surface-header", className)}>
      {icon != null && (
        <span className="ui-surface-icon" aria-hidden="true">
          {icon}
        </span>
      )}
      <div {...titleProps} id={titleId ?? inherited} className={cx("ui-surface-title", titleClassName)}>
        {children}
      </div>
      {trailing != null && <span className="ui-surface-trailing">{trailing}</span>}
    </div>
  );
}

/** The body: detail text and anything that reads as prose, in the role's body type. */
function Body({ as: Tag = "div", className, ...rest }: ElementProps & { as?: SurfaceTag }) {
  return <Tag {...rest} className={cx("ui-surface-body", className)} />;
}

type InsetProps = ElementProps & {
  as?: SurfaceTag;
  /** Code or a path: the mono face at the detail step. */
  mono?: boolean;
  /** The well scrolls inside its own box (a long command, a plan) rather than growing the surface. */
  scroll?: boolean;
};

/** The recessed well for code or detail: the scale's inset fill, the control corner, padding 8. */
function Inset({ as: Tag = "div", mono, scroll, className, ...rest }: InsetProps) {
  return (
    <Tag
      {...rest}
      className={cx(className, "ui-surface-inset")}
      data-mono={mono ? "" : undefined}
      data-scroll={scroll ? "" : undefined}
    />
  );
}

/** The actions row: the secondary actions at the leading edge, `Surface.Trailing` (the primary) at the trailing
 * edge. A row is as tall as one control; a narrow surface wraps it without moving the rest. */
function Actions({ className, ...rest }: ElementProps) {
  return <div {...rest} className={cx("ui-surface-actions", className)} />;
}

/** The trailing group of an actions row (the answers), kept together when the row wraps. */
function Trailing({ className, ...rest }: ElementProps) {
  return <span {...rest} className={cx("ui-surface-actions-end", className)} />;
}

/** The kind an action takes: the one primary is the accent, every other action is quiet. */
export type SurfaceActionKind = "primary" | "secondary";

/** A button of the actions row, from ui/Button at the row's control height. */
function Action({ kind = "secondary", ...rest }: { kind?: SurfaceActionKind } & Omit<ButtonProps, "variant" | "size">) {
  return <Button {...rest} variant={kind === "primary" ? "solid" : "subtle"} size="md" />;
}

/** The keycap hint slot of an action: the keys after the label, a fixed gap, caption size. */
function Keys({ className, ...rest }: ElementProps) {
  return <span {...rest} className={cx("ui-surface-keys", className)} />;
}

Surface.Header = Header;
Surface.Body = Body;
Surface.Inset = Inset;
Surface.Actions = Actions;
Surface.Trailing = Trailing;
Surface.Action = Action;
Surface.Keys = Keys;
Surface.TitleId = TitleId;
