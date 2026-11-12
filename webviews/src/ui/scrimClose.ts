import { useRef, type MouseEvent } from "react";

/// A media viewer's stage (the area around the image or video it shows) as the scrim of a sheet: a
/// click on the stage itself, beside the media, closes the viewer. A click on the media or on its
/// controls (a video's play, scrub, mute) lands on them, not on the stage, and does nothing here.
///
/// The stage closes only after a fresh press inside it since the viewer opened (a click run's first,
/// `detail` 1): a double click on a thumbnail opens the viewer on its first click, and its second
/// lands on the stage and must not close what just opened (#27955).
///
/// Every media viewer spreads `props` on its stage: the image viewer, the video viewer, the Home
/// channel lightbox. Escape and a press on the dialog's own backdrop close them through ui/Dialog.
export function useScrimClose(
  onClose: () => void,
  enabled = true,
): {
  /// Whether the stage has seen a fresh press since the viewer opened.
  pressed: { readonly current: boolean };
  props: {
    onMouseDown(event: MouseEvent<HTMLElement>): void;
    onClick(event: MouseEvent<HTMLElement>): void;
  };
} {
  const pressed = useRef(false);
  return {
    pressed,
    props: {
      onMouseDown(event) {
        if (event.detail <= 1) pressed.current = true;
      },
      onClick(event) {
        if (enabled && pressed.current && event.target === event.currentTarget) onClose();
      },
    },
  };
}
