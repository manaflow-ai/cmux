// l10n-allow-file: gallery fixtures (sample prompts and image names), not shipped UI.
// The images a sent prompt carries, above its bubble (UserBubble.tsx SentImages): each a rounded
// thumbnail of the whole image at most 160px tall and 480px wide, in the bubble's column with its
// right edge on the bubble's, its slot held while acpmux reads it, named on hover by its file name
// or, for a pasted screenshot, its size; one that cannot be drawn says so. A prompt whose images
// were placed in its text draws each where it was put, at the same size, in its final box from the
// first frame (Leo, 2026-11-22: "there should be no problem doing so for inline attachments after
// send").
import { useEffect, useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import {
  attachmentsHoldTheirBoxes,
  heldUntilReleased,
  paintShot,
  type Shot,
} from "../../../gallery/fixtures/sentMedia";
import type { AcpmuxRow, PromptImage } from "../model";
import { attachmentRetry } from "../../../pages/shared/attachmentRetry";
import { primeSentImages } from "./imageEntries";
import { ImageViewerContext } from "./imageViewerContext";
import { PresentationContext } from "./presentationContextModel";
import { TurnActionsContext, type TurnActions } from "./turnActions";
import { SentImages, UserBubble } from "./UserBubble";

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
  /// Only a prompt with every image placed in its text, as the composer sends a paste: the images
  /// where they were put (InlinePromptContent.tsx), after `placedBefore` and before this text.
  placedIn?: string;
  placedBefore?: string;
  /// The chat's width in px: a pane split in half, a third or a quarter of a 1440px window.
  column?: number;
  /// acpmux's reads answer only when the play releases them (gallery/fixtures/sentMedia.ts), so the
  /// first frame draws every image before its bytes.
  held?: boolean;
  /// A prompt sent as words, the first image, more words, then a file, each where it was put in
  /// the text; the image's bytes arrive `lateMs` after the row draws, as acpmux's read does.
  mixed?: { lateMs: number };
};

const paint = (shot: Shot) => paintShot(shot);

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
  placedBefore,
  column,
  held,
  mixed,
}: Props) {
  if (mixed) return <GalleryMixedPrompt images={images} lateMs={mixed.lateMs} />;
  if (primedLate) return <GalleryPrimedLate images={images} />;
  if (placedIn !== undefined)
    return <GalleryPlacedImages images={images} text={placedIn} before={placedBefore} column={column} held={held} />;
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

/// A prompt whose images were placed in its text: its words around them, each image where it was
/// put. Each part carries its size, as acpmux's record does (hub/prompt_images.rs reads it from the
/// image's header), so its box is final before its bytes land.
function GalleryPlacedImages({
  images,
  text,
  before,
  column,
  held = false,
}: {
  images: Props["images"];
  text: string;
  before?: string;
  column?: number;
  held?: boolean;
}) {
  const [actions] = useState<TurnActions>(() => {
    const urls = new Map(images.map((image) => [image.id, image.shot && paint(image.shot)]));
    return {
      promptImage: (id: string) => (held ? heldUntilReleased(urls.get(id)) : Promise.resolve(urls.get(id))),
    };
  });
  const sized = images.map((image) => ({
    ...image,
    ...(image.shot && { width: image.shot.width, height: image.shot.height }),
  }));
  const row: AcpmuxRow = {
    id: "placed",
    version: 1,
    kind: "user",
    at: 1,
    text: [before, text].filter(Boolean).join(" "),
    inlineParts: [
      ...(before ? [{ kind: "text" as const, text: `${before} ` }] : []),
      ...sized.map((image) => ({ kind: "image" as const, ...image, placed: true as const })),
      ...(text ? [{ kind: "text" as const, text: ` ${text}` }] : []),
    ],
  };
  return (
    <ImageViewerContext.Provider value={() => {}}>
      <TurnActionsContext.Provider value={actions}>
        <div className="cv-user" style={{ padding: 16, ...(column && { width: column, boxSizing: "border-box" }) }}>
          <UserBubble row={row} text={row.text!} />
        </div>
      </TurnActionsContext.Provider>
    </ImageViewerContext.Provider>
  );
}

/// Every placed image draws where it was put (Leo, 2026-11-22: "there should be no problem doing so
/// for inline attachments after send"), whole, in its final box from the first frame.
const placedHolds = attachmentsHoldTheirBoxes({ inBubble: true });

/// Text, an image, more text, then a file, each where the composer put it (Leo, 2026-11-22: "there
/// should be no problem doing so for inline attachments after send"). acpmux's read of the image
/// lands `lateMs` after the row draws; its slot already has the image's shape, so nothing moves.
function GalleryMixedPrompt({ images, lateMs }: { images: Props["images"]; lateMs: number }) {
  const [actions] = useState<TurnActions>(() => {
    const urls = new Map(images.map((image) => [image.id, image.shot && paint(image.shot)]));
    return {
      promptImage: (id: string) =>
        new Promise<string | undefined>((resolve) => setTimeout(() => resolve(urls.get(id)), lateMs)),
    };
  });
  const image = images[0]!;
  const parts = [
    { kind: "text" as const, text: "The toolbar overlaps the sidebar here " },
    { kind: "image" as const, ...image, placed: true as const },
    { kind: "text" as const, text: " and only after a resize, see the log " },
    {
      kind: "file" as const,
      name: "resize-trace.log",
      mimeType: "text/plain",
      size: 48_213,
      uri: "file:///Users/sample/resize-trace.log",
      placed: true as const,
    },
    { kind: "text" as const, text: " for the frames." },
  ];
  const row: AcpmuxRow = {
    id: "mixed",
    version: 1,
    kind: "user",
    at: 1,
    text: parts.map((part) => (part.kind === "text" ? part.text : "")).join(""),
    inlineParts: parts,
  };
  return (
    <ImageViewerContext.Provider value={() => {}}>
      <TurnActionsContext.Provider value={actions}>
        <div className="cv-user" style={{ padding: 16 }}>
          <UserBubble row={row} text={row.text!} />
        </div>
      </TurnActionsContext.Provider>
    </ImageViewerContext.Provider>
  );
}

/// The mixed prompt's check: each attachment sits in the bubble's text in the order it was sent,
/// and from the first frame to the image's arrival no box in the row moves or resizes, the image's
/// slot, the words after it, the file's chip and the bubble included.
const placedInOrderNoShift: Play = async ({ waitFor, document }) => {
  const watched = () => {
    const bubble = document.querySelector<HTMLElement>(".cv-user__bubble");
    const content = bubble?.querySelector<HTMLElement>("[data-inline-content]");
    if (!bubble || !content) return undefined;
    return [bubble, ...content.children].map((node) => {
      const box = (node as HTMLElement).getBoundingClientRect();
      return { node: node as HTMLElement, box: [box.x, box.y, box.width, box.height] };
    });
  };
  await waitFor(() => watched() !== undefined);
  const before = watched()!;
  if (document.querySelector("[data-inline-attachment-strip]"))
    throw new Error("the attachments draw in a block above the text, not where they were put");
  const kinds = before
    .slice(1)
    .map(({ node }) =>
      node.classList.contains("cv-user__inline-image")
        ? "image"
        : node.classList.contains("cv-user__inline-file")
          ? "file"
          : "text",
    );
  if (kinds.join(",") !== "text,image,text,file,text")
    throw new Error(`the bubble draws ${kinds.join(",")}, not text,image,text,file,text`);
  await waitFor(() => {
    const image = document.querySelector<HTMLImageElement>("img.cv-user__image");
    return image !== null && image.complete && image.naturalWidth > 0;
  });
  const after = watched()!;
  let moved = 0;
  before.forEach(({ box }, index) => {
    const now = after[index]?.box ?? [];
    moved = Math.max(moved, ...box.map((value, axis) => Math.abs(value - (now[axis] ?? Infinity))));
  });
  if (moved > 0.5) throw new Error(`a box in the row moved ${moved}px when the image loaded`);
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
      note: "The wide strip in a narrow chat, above a prompt and inside one: each scales down to the bubble, whole, never past its edge.",
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
      note: "Leo's case (2026-11-21): a wide, short screenshot (1550×300) pasted into the text. Whole, at most 480px wide, where it was put in the bubble's text, in its final box from the first frame (Leo, 2026-11-22: \"there should be no problem doing so for inline attachments after send\").",
      height: 320,
      props: { images: leoWide, placedIn: leoText, held: true },
      play: placedHolds,
    },
    "placed-mid-wide": {
      note: "A wide screenshot placed mid-sentence, words before and after it: whole at its own shape, on its line; nothing moves when its bytes land.",
      height: 320,
      props: {
        images: [{ ...leoWide[0]!, id: "mid-wide" }],
        placedBefore: "The plan list here",
        placedIn: "keeps its old items after the task ends.",
        held: true,
      },
      play: placedHolds,
    },
    "placed-tall": {
      note: "A tall phone screenshot (780×1688) pasted into the text: whole at 160px tall, never cropped to a square, where it was put.",
      height: 320,
      props: {
        images: [{ id: "tall", mimeType: "image/png", name: "image.png", shot: { width: 780, height: 1688, hue: 30 } }],
        placedIn: "Why is the tab bar cut off on this screen?",
        held: true,
      },
      play: placedHolds,
    },
    "placed-mid-portrait": {
      note: "A portrait screenshot mid-sentence: its line 160px tall, the words before and after it on the same line.",
      height: 320,
      props: {
        images: [
          { id: "mid-tall", mimeType: "image/png", name: "image.png", shot: { width: 780, height: 1688, hue: 30 } },
        ],
        placedBefore: "On the phone",
        placedIn: "the tab bar is cut off.",
        held: true,
      },
      play: placedHolds,
    },
    "placed-several": {
      note: "Three pasted screenshots (square, wide, tall) in one prompt: each whole in its own shape where it was put, wrapping inside the bubble.",
      height: 560,
      props: {
        images: pasted.map((image) => ({ ...image, id: `placed-${image.id}` })),
        placedIn: "These three screens disagree about the toolbar.",
        held: true,
      },
      play: placedHolds,
    },
    "placed-several-one-line": {
      note: "Three small captures placed in one line of text: each at its own size (never enlarged), the line as tall as the tallest.",
      height: 280,
      props: {
        images: [
          { id: "one-a", mimeType: "image/png", name: "image.png", shot: { width: 120, height: 90, hue: 200 } },
          { id: "one-b", mimeType: "image/png", name: "image.png", shot: { width: 96, height: 120, hue: 120 } },
          { id: "one-c", mimeType: "image/png", name: "image.png", shot: { width: 140, height: 70, hue: 20 } },
        ],
        placedBefore: "Icons:",
        placedIn: "which one reads best?",
        held: true,
      },
      play: placedHolds,
    },
    "placed-text-before-only": {
      note: "Words, then the screenshot last: it ends the bubble, nothing after it.",
      height: 320,
      props: { images: [{ ...leoWide[0]!, id: "before-only" }], placedBefore: "This list:", placedIn: "", held: true },
      play: placedHolds,
    },
    "placed-half": {
      note: "The mid-sentence wide screenshot in a pane split in half (720px): whole, in its final box from the first frame.",
      height: 320,
      props: {
        images: [{ ...leoWide[0]!, id: "half" }],
        placedBefore: "The plan list here",
        placedIn: "keeps its old items after the task ends.",
        column: 720,
        held: true,
      },
      play: placedHolds,
    },
    "placed-third": {
      note: "The same in a pane split in thirds (480px): the screenshot scales down to the bubble, whole.",
      height: 320,
      props: {
        images: [{ ...leoWide[0]!, id: "third" }],
        placedBefore: "The plan list here",
        placedIn: "keeps its old items after the task ends.",
        column: 480,
        held: true,
      },
      play: placedHolds,
    },
    "placed-quarter": {
      note: "The same in a pane split in quarters (360px).",
      height: 320,
      props: {
        images: [{ ...leoWide[0]!, id: "quarter" }],
        placedBefore: "The plan list here",
        placedIn: "keeps its old items after the task ends.",
        column: 360,
        held: true,
      },
      play: placedHolds,
    },
    "placed-mixed-loading": {
      note: 'Leo, 2026-11-22: "there should be no problem doing so for inline attachments after send." Words, a screenshot, more words, then a log file, each where it was put; the screenshot\'s bytes land 600 ms after the row draws into a slot already at its shape, so nothing in the row moves.',
      height: 360,
      props: {
        images: [
          {
            id: "mixed-shot",
            mimeType: "image/png",
            name: "image.png",
            width: 1440,
            height: 900,
            shot: { width: 1440, height: 900, hue: 200 },
          },
        ],
        mixed: { lateMs: 600 },
      },
      play: placedInOrderNoShift,
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
