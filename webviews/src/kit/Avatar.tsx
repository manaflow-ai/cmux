// A person's or agent's picture, or their initials on a neutral tile (no hue: the sidebar spec
// "no colour the user didn't choose"). People are circles, agents rounded squares, as on Home.
import { graphemePrefix, initials } from "../ui/initials";
import { cx } from "../ui/cx";

/** sm 16, md 20, lg 32: the icon and control scale. */
export type AvatarSize = "sm" | "md" | "lg";

export interface AvatarProps {
  /** The name the initials come from; also the picture's alt text when `labelled`. */
  name: string;
  src?: string;
  size?: AvatarSize;
  shape?: "person" | "agent";
  /** Read the name to assistive tech; leave false when the row beside it already says it. */
  labelled?: boolean;
  className?: string;
}

export function Avatar({ name, src, size = "md", shape = "person", labelled = false, className }: AvatarProps) {
  return (
    <span
      className={cx("kit-avatar", className)}
      data-size={size}
      data-shape={shape}
      role={labelled ? "img" : undefined}
      aria-label={labelled ? name : undefined}
      aria-hidden={labelled ? undefined : "true"}
    >
      {src ? (
        <img className="kit-avatar-img" src={src} alt="" draggable={false} />
      ) : (
        graphemePrefix(initials(name), size === "lg" ? 2 : 1)
      )}
    </span>
  );
}
