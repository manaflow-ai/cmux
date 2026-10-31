// l10n-allow-file: gallery fixtures (sample prompts and image names), not shipped UI.
// The images a sent prompt carries, above its bubble (UserBubble.tsx SentImages): each a rounded
// thumbnail cropped to fill a fixed height, its slot held while acpmux reads it, named on hover by
// its file name or, for a pasted screenshot, its size; one that cannot be drawn says so.
import { useEffect, useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { AcpmuxRow, PromptImage } from "../model";
import { primeSentImages } from "./imageEntries";
import { ImageViewerContext } from "./imageViewerContext";
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

function GallerySentImages({ images, pending = false, primedLate = false, attachmentOnly }: Props) {
  if (primedLate) return <GalleryPrimedLate images={images} />;
  if (attachmentOnly) return <GalleryAttachmentOnly images={images} state={attachmentOnly} />;
  return <GalleryShownImages images={images} pending={pending} />;
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
        <div className="cv-user" style={{ padding: 16 }}>
          <UserBubble row={row} text="" />
        </div>
      </TurnActionsContext.Provider>
    </ImageViewerContext.Provider>
  );
}

function GalleryShownImages({ images, pending = false }: Props) {
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
      </TurnActionsContext.Provider>
    </ImageViewerContext.Provider>
  );
}

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
      note: "Three pasted screenshots (square, wide, tall): each fills a fixed-height rounded thumbnail; hover names its size.",
      props: { images: pasted },
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
