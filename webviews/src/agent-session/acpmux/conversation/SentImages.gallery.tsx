// l10n-allow-file: gallery fixtures (sample prompts and image names), not shipped UI.
// The images a sent prompt carries, above its bubble (UserBubble.tsx SentImages): each a rounded
// thumbnail of the whole image at most 160px tall and 480px wide, in the bubble's column with its
// right edge on the bubble's, its slot held while acpmux reads it, named on hover by its file name
// or, for a pasted screenshot, its size; one that cannot be drawn says so.
import { useEffect, useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import type { AcpmuxRow, PromptImage } from "../model";
import { primeSentImages } from "./imageEntries";
import { ImageViewerContext } from "./imageViewerContext";
import { PresentationContext } from "./presentationContextModel";
import { TurnActionsContext, type TurnActions } from "./turnActions";
import { SentImages, UserBubble } from "./UserBubble";

type Shot = { width: number; height: number; hue: number };
type Props = {
  images: (PromptImage & { shot?: Shot; broken?: boolean })[];
  pending?: boolean;
  /// The pane's own paste: acpmux's echo names each image (by the SHA-256 of its bytes) before
  /// the pane has primed it, and acpmux's read never answers; the pane's priming draws it.
  primedLate?: boolean;
  attachmentOnly?: "sending" | "actions";
  /// Also sends the first image inside a prompt's text (InlinePromptContent.tsx).
  inline?: boolean;
  /// Only a prompt with every image placed in its text, as the composer sends a paste: the images
  /// where they were put, at the head of the bubble, then this text.
  placedIn?: string;
  /// A prompt sent as words, the first image, more words, then a file, each where it was put in
  /// the text; the image's bytes arrive `lateMs` after the row draws, as acpmux's read does.
  mixed?: { lateMs: number };
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
  mixed,
}: Props) {
  if (mixed) return <GalleryMixedPrompt images={images} lateMs={mixed.lateMs} />;
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

/// A prompt whose images were placed in its text: the images where they were put, in its bubble.
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

/// Every sent image draws whole and belongs to its message (Leo, 2026-11-21: "if you sent it
/// iinline you prob shouldn't have such odd stuff"): its drawn box has the image's own shape (within
/// 2%, so nothing is cropped) and it sits inside its bubble, never past its edges.
const wholeAndAttached: Play = async ({ waitFor, document }) => {
  const drawn = () => [...document.querySelectorAll<HTMLImageElement>("img.cv-user__image")];
  await waitFor(() => drawn().length > 0 && drawn().every((image) => image.complete && image.naturalWidth > 0));
  const bubble = document.querySelector(".cv-user__bubble")?.getBoundingClientRect();
  const column = document.querySelector(".cv-user")?.getBoundingClientRect();
  if (!bubble || !column) throw new Error("no bubble to attach the images to");
  for (const image of drawn()) {
    const box = image.getBoundingClientRect();
    const natural = image.naturalWidth / image.naturalHeight;
    const shown = box.width / box.height;
    if (Math.abs(shown / natural - 1) > 0.02)
      throw new Error(`a ${image.naturalWidth}x${image.naturalHeight} image draws ${box.width}x${box.height}: cropped`);
    if (box.width > 0.7 * (column.width - 32) + 1)
      throw new Error(`an image ${box.width}px wide runs past the bubble's column`);
    if (box.left < bubble.left - 0.5 || box.right > bubble.right + 0.5 || box.top < bubble.top - 0.5)
      throw new Error(`an image at ${box.left},${box.top} sits outside its bubble`);
  }
};

function GalleryShownImages({ images, pending = false, inline = false }: Props) {
  const [actions] = useState(() => {
    const urls = new Map(
      images.map((image) => [image.id, image.broken ? "data:image/png;base64,AAAA" : image.shot && paint(image.shot)]),
    );
    return {
      promptImage: (id: string) => (pending ? new Promise<never>(() => {}) : Promise.resolve(urls.get(id))),
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
      note: "Leo's case (2026-11-21): a wide, short screenshot (1550×300) pasted into the text. Whole, at most 480px wide, where it was put inside its bubble; was a 320px strip of unreadable text under a bright frame.",
      props: { images: leoWide, placedIn: leoText },
      play: wholeAndAttached,
    },
    "placed-tall": {
      note: "A tall phone screenshot (780×1688) pasted into the text: whole at 160px tall, never cropped to a square, inside its bubble.",
      height: 320,
      props: {
        images: [{ id: "tall", mimeType: "image/png", name: "image.png", shot: { width: 780, height: 1688, hue: 30 } }],
        placedIn: "Why is the tab bar cut off on this screen?",
      },
      play: wholeAndAttached,
    },
    "placed-several": {
      note: "Three pasted screenshots (square, wide, tall) in one prompt: each whole in its own shape, wrapping inside its bubble.",
      height: 480,
      props: {
        images: pasted.map((image) => ({ ...image, id: `placed-${image.id}` })),
        placedIn: "These three screens disagree about the toolbar.",
      },
      play: wholeAndAttached,
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
