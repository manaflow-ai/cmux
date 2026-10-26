// One animated avatar (`cmux-avatar/1`): the row of `state` in the set's sheet, stepped through by a
// CSS animation at the state's rate, mirrored for the facing its frames are not drawn in. No timer and
// no observer: the browser runs the animation only while the element is rendered, and stops it with
// the element (display: none, unmounted). Reduce Motion, `still` or a `frame` draws one frame.
import type { CSSProperties } from "react";
import "./avatars.css";
import { avatarTrack, type AvatarFacing, type AvatarState } from "./format";
import type { AvatarSet } from "./sets";

export type AnimatedAvatarProps = {
  set: AvatarSet;
  state?: AvatarState;
  facing?: AvatarFacing;
  /** The drawn width in px; the height keeps the frame's ratio. Pixel art scales by whole steps. */
  size?: number;
  /** Draws this frame of the row and nothing moves. */
  frame?: number;
  /** Draws the row's first frame (the static frame) and nothing moves. */
  still?: boolean;
  label?: string;
};

export function AnimatedAvatar({
  set,
  state = "idle",
  facing = "right",
  size,
  frame,
  still = false,
  label,
}: AnimatedAvatarProps) {
  const { manifest, sheet, size: full } = set;
  const track = avatarTrack(manifest, state, facing);
  const width = size ?? manifest.frame.width;
  // Whole-pixel steps keep pixel art crisp: 32 px frames at 88 px draw at 64.
  const scale =
    manifest.pixelArt && width >= manifest.frame.width
      ? Math.floor(width / manifest.frame.width)
      : width / manifest.frame.width;
  const w = manifest.frame.width * scale;
  const h = manifest.frame.height * scale;
  const moving = frame === undefined && !still && track.frames > 1;
  const style = {
    width: w,
    height: h,
    backgroundImage: `url("${sheet}")`,
    backgroundSize: `${full.width * scale}px ${full.height * scale}px`,
    backgroundPositionX: `${-Math.min(frame ?? 0, track.frames - 1) * w}px`,
    backgroundPositionY: `${-track.row * h}px`,
    "--avatar-end": `${-(track.frames - 1) * w}px`,
    "--avatar-steps": track.frames,
    "--avatar-duration": `${track.frames / track.fps}s`,
    "--avatar-iterations": track.loop ? "infinite" : 1,
  } as CSSProperties;
  return (
    <span
      // A new state or facing starts its row from the first frame.
      key={`${state}-${facing}`}
      className="cmux-avatar"
      role={label ? "img" : undefined}
      aria-label={label}
      aria-hidden={label ? undefined : true}
      data-avatar={manifest.id}
      data-state={state}
      data-facing={facing}
      data-moving={moving ? "true" : "false"}
      data-mirrored={track.mirrored ? "true" : "false"}
      data-pixel={manifest.pixelArt ? "true" : "false"}
      style={style}
    />
  );
}
