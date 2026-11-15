import { useRef, type MouseEvent } from "react";

/// A media viewer's stage (the area around the image or video it shows) as the scrim of a sheet: a
/// click on the stage itself, beside the media, closes the viewer. A click on the media or on its
/// controls (a video's play, scrub, mute) lands on them, not on the stage, and does nothing here.
///
/// Only a press that began on the stage itself counts: a scrub or a pan that starts on the media and
/// ends beside it fires its click on the stage (their common ancestor) and must not close. And only a
/// fresh press (a click run's first, `detail` 1): a double click on a thumbnail opens the viewer on its
/// first click, and its second lands on the stage and must not close what just opened (#27955).
///
/// Every media viewer spreads `props` on its stage: the image viewer, the video viewer, the Home
/// channel lightbox. Escape and a press on the dialog's own backdrop close them through ui/Dialog.
export function useScrimClose(
  onClose: () => void,
  enabled = true,
): {
  /// Whether the viewer has seen a fresh press anywhere on its stage, media included, since it opened
  /// (the image viewer's double-click zoom waits for one).
  pressed: { readonly current: boolean };
  props: {
    onMouseDown(event: MouseEvent<HTMLElement>): void;
    onClick(event: MouseEvent<HTMLElement>): void;
  };
} {
  const pressed = useRef(false);
  const pressedStage = useRef(false);
  return {
    pressed,
    props: {
      onMouseDown(event) {
        const fresh = event.detail <= 1;
        if (fresh) pressed.current = true;
        pressedStage.current = fresh && event.target === event.currentTarget;
      },
      onClick(event) {
        if (enabled && pressedStage.current && event.target === event.currentTarget) onClose();
      },
    },
  };
}
