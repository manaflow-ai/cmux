// l10n-allow-file: gallery fixtures (sample prompts and image names), not shipped UI.
// The images a sent prompt carries, above its bubble (UserBubble.tsx SentImages): each a rounded
// thumbnail of the whole image at most 160px tall and 480px wide, in the bubble's column with its
// right edge on the bubble's, its slot held while acpmux reads it, named on hover by its file name
// or, for a pasted screenshot, its size; one that cannot be drawn says so.
import { useEffect, useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import type { AcpmuxRow, PromptImage } from "../model";
import { attachmentRetry } from "../../../pages/shared/attachmentRetry";
import { primeSentImages } from "./imageEntries";
import { ImageViewerContext } from "./imageViewerContext";
import { PresentationContext } from "./presentationContextModel";
import { TurnActionsContext, type TurnActions } from "./turnActions";
import { SentImages, UserBubble } from "./UserBubble";

type Shot = { width: number; height: number; hue: number };
type Props = {
  /// `unread`: acpmux's read of it keeps failing (a reconnect that outlasts the tries again).
  images: (PromptImage & { shot?: Shot; broken?: boolean; unread?: boolean })[];
  pending?: boolean;
  /// The pane's own paste: acpmux's echo names each image (by the SHA-256 of its bytes) before
  /// the pane has primed it, and acpmux's read never answers; the pane's priming draws it.
  primedLate?: boolean;
  attachmentOnly?: "sending" | "actions";
  /// Also sends the first image inside a prompt's text (InlinePromptContent.tsx).
  inline?: boolean;
  /// Only a prompt with every image placed in its text, as the composer sends a paste: the block
  /// above the bubble (UserBubble.tsx `.cv-user__inline-strip`), over this text.
  placedIn?: string;
};

/// A screenshot-like image `shot.width`×`shot.height`: a title bar, a sidebar and lines of text.
function paint({ width, height, hue }: Shot): string {
  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const ink = canvas.getContext("2d")!;
  ink.fillStyle = `hsl(${hue} 30% 16%)`;
  ink.fillRect(0, 0, width, height);
  ink.fillStyle = `hsl(${hue} 30% 24%)`;
  ink.fillRect(0, 0, width, height * 0.07);
  ink.fillRect(0, 0, width * 0.22, height);
  ink.fillStyle = `hsl(${hue} 70% 62%)`;
  for (let line = 0; line < 9; line += 1)
    ink.fillRect(width * 0.27, height * (0.14 + line * 0.08), width * (0.3 + ((line * 37) % 40) / 100), height * 0.025);
  return canvas.toDataURL("image/png");
}

/// The id acpmux names a data URL's image by: the SHA-256 of its bytes.
async function acpmuxId(src: string): Promise<string> {
  const bytes = Uint8Array.from(atob(src.slice(src.indexOf(",") + 1)), (char) => char.charCodeAt(0));
  const hash = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  return Array.from(hash, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

/// Sent images named by acpmux before the pane primed them: the slots wait on a read that never
/// answers until the pane's priming lands a moment later.
function GalleryPrimedLate({ images }: Props) {
  const [named, setNamed] = useState<Props["images"]>();
  useEffect(() => {
    let live = true;
    const painted = images.map((image) => ({ image, src: paint(image.shot!) }));
    void Promise.all(painted.map(async ({ image, src }) => ({ ...image, id: await acpmuxId(src) }))).then((ids) => {
      if (!live) return;
      setNamed(ids);
      // gallery-capture: `pasted-echo-first`'s play `primed` waits for the image to draw.
      setTimeout(() => {
        void primeSentImages(
          painted.map(({ image, src }) => ({
            id: `paste-${image.id}`,
            kind: "image" as const,
            name: image.name ?? "image.png",
            mimeType: "image/png",
            size: src.length,
            data: src.slice(src.indexOf(",") + 1),
          })),
        );
      }, 300);
    });
    return () => {
      live = false;
    };
  }, [images]);
  return named ? <GallerySentImages images={named} pending /> : null;
}

/// The capture moment of `pasted-echo-first`: the priming above landed and the image drew in its
/// slot, not the placeholder the 300 ms timer leaves while it waits.
const primed: Play = ({ waitFor, document }) =>
  waitFor(() => document.querySelector("img.cv-user__image") && !document.querySelector(".cv-user__image-placeholder"));

function GallerySentImages({
  images,
  pending = false,
  primedLate = false,
  inline = false,
  attachmentOnly,
  placedIn,
}: Props) {
  if (primedLate) return <GalleryPrimedLate images={images} />;
  if (placedIn !== undefined) return <GalleryPlacedImages images={images} text={placedIn} />;
  if (attachmentOnly) return <GalleryAttachmentOnly images={images} state={attachmentOnly} />;
  return <GalleryShownImages images={images} pending={pending} inline={inline} />;
}

function GalleryAttachmentOnly({ images, state }: { images: Props["images"]; state: "sending" | "actions" }) {
  const [actions] = useState<TurnActions>(() => {
    const urls = new Map(images.map((image) => [image.id, image.shot && paint(image.shot)]));
    return {
      promptImage: (id: string) => Promise.resolve(urls.get(id)),
      ...(state === "actions" && {
        retry: () => {},
        fork: () => {},
        forkSeq: 7,
        promptTurns: new Map([["attachment-only", 7]]),
        branches: {
          of: new Map([["attachment-only", { index: 0, sessions: ["session-1", "session-2"] }]]),
          open: () => {},
        },
      }),
    };
  });
  const row: AcpmuxRow = {
    id: "attachment-only",
    version: 1,
    kind: "user",
    at: Date.now() - 10_000,
    images,
    ...(state === "sending" && {
      delivery: {
        state: "sending" as const,
        slow: true,
        promptId: "prompt-attachment-only",
        sessionId: "session-1",
        sentAt: Date.now() - 10_000,
      },
    }),
  };
  return (
    <ImageViewerContext.Provider value={() => {}}>
      <TurnActionsContext.Provider value={actions}>
        {/* The Messages view, where a delivered prompt draws its own Retry (MessageActions.tsx PromptActions). */}
        <PresentationContext.Provider value={state === "actions" ? "messages" : "transcript"}>
          <div className="cv-user" style={{ padding: 16 }}>
            <UserBubble row={row} text="" />
          </div>
        </PresentationContext.Provider>
      </TurnActionsContext.Provider>
    </ImageViewerContext.Provider>
  );
}

/// A prompt whose images were placed in its text: its words around them, the images in the block
/// above its bubble.
function GalleryPlacedImages({ images, text }: { images: Props["images"]; text: string }) {
  const [actions] = useState<TurnActions>(() => {
    const urls = new Map(images.map((image) => [image.id, image.shot && paint(image.shot)]));
    return { promptImage: (id: string) => Promise.resolve(urls.get(id)) };
  });
  const row: AcpmuxRow = {
    id: "placed",
    version: 1,
    kind: "user",
    at: 1,
    text,
    inlineParts: [
      ...images.map((image) => ({ kind: "image" as const, ...image, placed: true as const })),
      { kind: "text" as const, text },
    ],
  };
  return (
    <ImageViewerContext.Provider value={() => {}}>
      <TurnActionsContext.Provider value={actions}>
        <div className="cv-user" style={{ padding: 16 }}>
          <UserBubble row={row} text={text} />
        </div>
      </TurnActionsContext.Provider>
    </ImageViewerContext.Provider>
  );
}

/// Every sent image draws whole and belongs to its message (Leo, 2026-11-21: "if you sent it
/// iinline you prob shouldn't have such odd stuff"): its drawn box has the image's own shape (within
/// 2%, so nothing is cropped), it sits in the bubble's column, the block's right edge is the
/// bubble's, and the block stands the same small gap above the bubble.
const wholeAndAttached: Play = async ({ waitFor, document }) => {
  const drawn = () => [...document.querySelectorAll<HTMLImageElement>("img.cv-user__image")];
  await waitFor(() => drawn().length > 0 && drawn().every((image) => image.complete && image.naturalWidth > 0));
  const bubble = document.querySelector(".cv-user__bubble")?.getBoundingClientRect();
  const column = document.querySelector(".cv-user")?.getBoundingClientRect();
  if (!bubble || !column) throw new Error("no bubble to attach the images to");
  let right = -Infinity;
  let bottom = -Infinity;
  for (const image of drawn()) {
    const box = image.getBoundingClientRect();
    const natural = image.naturalWidth / image.naturalHeight;
    const shown = box.width / box.height;
    if (Math.abs(shown / natural - 1) > 0.02)
      throw new Error(`a ${image.naturalWidth}x${image.naturalHeight} image draws ${box.width}x${box.height}: cropped`);
    if (box.width > 0.7 * (column.width - 32) + 1)
      throw new Error(`an image ${box.width}px wide runs past the bubble's column`);
    right = Math.max(right, box.right);
    bottom = Math.max(bottom, box.bottom);
  }
  if (Math.abs(right - bubble.right) > 1.5)
    throw new Error(`the images' right edge ${right} is not the bubble's ${bubble.right}`);
  const gap = bubble.top - bottom;
  if (gap < 4 || gap > 8) throw new Error(`the images stand ${gap}px above their bubble, not 6`);
};

function GalleryShownImages({ images, pending = false, inline = false }: Props) {
  const [actions] = useState(() => {
    const urls = new Map(
      images.map((image) => [image.id, image.broken ? "data:image/png;base64,AAAA" : image.shot && paint(image.shot)]),
    );
    const unread = new Set(images.filter((image) => image.unread).map((image) => image.id));
    // The gallery shows where the tries again end, not the seconds they take.
    if (unread.size > 0) attachmentRetry.delaysMs = [0, 0, 0];
    return {
      promptImage: (id: string) =>
        pending
          ? new Promise<never>(() => {})
          : unread.has(id)
            ? Promise.reject(new Error("socket closed"))
            : Promise.resolve(urls.get(id)),
    };
  });
  return (
    <ImageViewerContext.Provider value={() => {}}>
      <TurnActionsContext.Provider value={actions}>
        <div className="cv-user" style={{ padding: 16 }}>
          <SentImages images={images} />
          <div className="ui-glass cv-user__bubble">Why does the sidebar overlap the toolbar here?</div>
        </div>
        {inline && (
          <div className="cv-user" style={{ padding: 16 }}>
            <UserBubble
              row={{
                id: "inline",
                version: 1,
                kind: "user",
                at: 1,
                inlineParts: [
                  { kind: "text" as const, text: "This strip " },
                  { kind: "image" as const, ...images[0]!, placed: true as const },
                  { kind: "text" as const, text: " runs past the bubble." },
                ],
              }}
              text="This strip runs past the bubble."
            />
          </div>
        )}
      </TurnActionsContext.Provider>
    </ImageViewerContext.Provider>
  );
}

/// Leo's 2026-11-21 capture: a plan list cut from the chat, wide and short.
const leoWide: Props["images"] = [
  { id: "leo-wide", mimeType: "image/png", name: "image.png", shot: { width: 1550, height: 300, hue: 230 } },
];
const leoText =
  "the plan system in general i dont think we have good enough prompting/calling/expiry maybe? idk what the lifecycle is for this but this may not be that great right now";

const pasted: Props["images"] = [
  { id: "a", mimeType: "image/png", name: "image.png", shot: { width: 2458, height: 2324, hue: 220 } },
  { id: "b", mimeType: "image/png", name: "image.png", shot: { width: 3024, height: 1180, hue: 150 } },
  { id: "c", mimeType: "image/png", name: "image.png", shot: { width: 780, height: 1688, hue: 30 } },
];

export default componentEntry<Props>({
  id: "agent-pane.sent-images",
  title: "Sent prompt images",
  area: "Agent pane",
  pane: true,
  height: 260,
  covers: ["agent-session/acpmux/conversation/UserBubble.tsx#SentImages"],
  load: async () => GallerySentImages,
  variants: {
    pasted: {
      note: "Three pasted screenshots (square, wide, tall): each the whole image at most 160px tall; hover names its size.",
      height: 440,
      // Sized, as the pane's own paste is (it measured each image): the unsized read, whose square
      // slots take their shapes when the bytes land, is "loading" and "loading-sized"'s to show.
      props: { images: pasted.map((image) => ({ ...image, width: image.shot!.width, height: image.shot!.height })) },
    },
    "wide-strip": {
      note: "A strip cut from a chat (1568×74, Leo's 2026-11-05 capture): the whole strip at 480px wide, never a magnified crop of its middle.",
      props: {
        images: [{ id: "w", mimeType: "image/png", name: "image.png", shot: { width: 1568, height: 74, hue: 250 } }],
      },
    },
    narrow: {
      note: "The wide strip in a narrow chat, above a legacy prompt and placed mid-text in another: each in the block above its bubble, scaled down whole, never past its edge.",
      props: {
        images: [{ id: "w", mimeType: "image/png", name: "image.png", shot: { width: 1568, height: 74, hue: 250 } }],
        inline: true,
      },
    },
    named: {
      note: "Dropped files keep their names on hover.",
      props: {
        images: [
          {
            id: "n",
            mimeType: "image/png",
            name: "Screenshot 2026-10-20 at 09.14.02.png",
            shot: { width: 1440, height: 900, hue: 280 },
          },
          { id: "m", mimeType: "image/png", name: "build-times.png", shot: { width: 1200, height: 800, hue: 100 } },
        ],
      },
    },
    "placed-wide": {
      note: "Leo's case (2026-11-21): a wide, short screenshot (1550×300) pasted into the text. Whole, 480px wide, in the bubble's column, its right edge on the bubble's and 6px above it; was a 320px strip of unreadable text 4px in from the bubble's edge under a bright frame.",
      props: { images: leoWide, placedIn: leoText },
      play: wholeAndAttached,
    },
    "placed-tall": {
      note: "A tall phone screenshot (780×1688) pasted into the text: whole at 160px tall, never cropped to a square, attached to its bubble.",
      height: 320,
      props: {
        images: [{ id: "tall", mimeType: "image/png", name: "image.png", shot: { width: 780, height: 1688, hue: 30 } }],
        placedIn: "Why is the tab bar cut off on this screen?",
      },
      play: wholeAndAttached,
    },
    "placed-several": {
      note: "Three pasted screenshots (square, wide, tall) in one prompt: each whole in its own shape, wrapping inside the bubble's column, the block's right edge on the bubble's.",
      height: 480,
      props: {
        images: pasted.map((image) => ({ ...image, id: `placed-${image.id}` })),
        placedIn: "These three screens disagree about the toolbar.",
      },
      play: wholeAndAttached,
    },
    failed: {
      note: "An image acpmux answers but the engine cannot draw: its slot says Couldn't load image.",
      props: { images: [pasted[0]!, { id: "x", mimeType: "image/png", name: "image.png", broken: true }] },
    },
    "read-failed": {
      note: "A screenshot whose read still fails after its tries again: its slot says Couldn't load image with a Retry under it, never an empty gap.",
      props: { images: [pasted[0]!, { ...pasted[1]!, id: "unread-b", unread: true }] },
    },
    "read-failed-sized": {
      note: "A failed read whose record names its size keeps the thumbnail's own wide shape, so a Retry that draws it moves nothing.",
      props: {
        images: [{ ...pasted[1]!, id: "unread-sized", unread: true, width: 3024, height: 1180 }],
      },
    },
    "read-failed-all": {
      note: "Three screenshots whose reads all failed: each slot has its own Retry.",
      props: { images: pasted.map((image) => ({ ...image, id: `unread-all-${image.id}`, unread: true })) },
    },
    loading: {
      note: "While acpmux reads the images, each slot holds its thumbnail's height (square: no size known yet).",
      // Ids of their own: the pane keeps a read image by id (imageEntries.ts) for every frame.
      props: { images: pasted.map((image) => ({ ...image, id: `loading-${image.id}` })), pending: true },
    },
    "pasted-echo-first": {
      note: "A pasted screenshot whose echo names it before the pane primed it, while acpmux's read of a long chat is slow: it draws once the pane's priming lands, never an empty box.",
      props: { images: [pasted[0]!], primedLate: true },
      play: primed,
    },
    "loading-sized": {
      note: "Images whose record names their size: each slot is reserved at its own shape before acpmux reads it, so nothing snaps when it loads.",
      props: {
        images: pasted.map((image) => ({
          ...image,
          id: `sized-${image.id}`,
          width: image.shot!.width,
          height: image.shot!.height,
        })),
        pending: true,
      },
    },
    "attachment-only-sending": {
      note: "An image-only prompt keeps its Still sending clock beside the attachment without drawing an empty glass bubble.",
      props: { images: pasted.slice(0, 2), attachmentOnly: "sending" },
    },
    "attachment-only-actions": {
      note: "A delivered image-only prompt keeps its action row: Copy, Retry, Fork and version arrows under the attachment.",
      props: { images: pasted.slice(0, 2), attachmentOnly: "actions" },
      play: async (ctx) => ctx.hover({ selector: ".cv-user" }),
    },
  },
});
