// A sent image's and video's thumbnail size, apart from their React tiles (UserBubble.tsx,
// SentVideoTile.tsx), so the transcript's height estimate (model.ts) reserves the same box.

/// The sent thumbnail's height (conversation.css), and the narrowest and
/// widest a video's tile draws as a share of that: a tall phone recording or a wide screen
/// recording is cropped to fill past those bounds rather than drawn as a sliver.
export const SENT_IMAGE_HEIGHT = 120;
const SENT_IMAGE_RATIO = { min: 0.75, max: 1.6 };
/// The widest a sent image draws: a wider one shrinks to it, whole.
const SENT_IMAGE_MAX_WIDTH = 320;

/// A video tile's width at SENT_IMAGE_HEIGHT for a video of `size`: square only while no size is known.
export function sentImageWidth(size: { width?: number; height?: number }): number {
  const ratio =
    size.width && size.height
      ? Math.min(SENT_IMAGE_RATIO.max, Math.max(SENT_IMAGE_RATIO.min, size.width / size.height))
      : 1;
  return Math.round(SENT_IMAGE_HEIGHT * ratio);
}

/// A sent image's thumbnail box for an image of `size`: the whole image in its own shape, at most
/// SENT_IMAGE_HEIGHT tall and SENT_IMAGE_MAX_WIDTH wide and never larger than the image, so a wide
/// screenshot is a whole strip, never a magnified crop of its middle (Leo, 2026-11-05: "I don't
/// think we have good enough looking previews for these"). Square while no size is known.
export function sentImageSize(size: { width?: number; height?: number }): { width: number; height: number } {
  if (!size.width || !size.height) return { width: SENT_IMAGE_HEIGHT, height: SENT_IMAGE_HEIGHT };
  const scale = Math.min(1, SENT_IMAGE_HEIGHT / size.height, SENT_IMAGE_MAX_WIDTH / size.width);
  return {
    width: Math.max(1, Math.round(size.width * scale)),
    height: Math.max(1, Math.round(size.height * scale)),
  };
}
