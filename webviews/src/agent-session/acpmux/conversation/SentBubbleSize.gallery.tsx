// l10n-allow-file: gallery fixtures (sample prompts and file names), not shipped UI.
// A sent prompt's bubble from the frame it lands to the frame its images load (Leo, 2026-11-07:
// "We need to be able to, like, know beforehand the size we're going to go for rather than say,
// like, Oh wait, well now we're going to expand"). Each variant draws the prompt as the pane does
// on a send: first its own row (the composer's bytes, `local-…`), then acpmux's echo of it, which
// names each image by the SHA-256 of its bytes before the pane has primed that id
// (imageEntries.ts `primeSentImages`), and acpmux's read never answers. The bubble, its images and
// its files keep one size through all three. Text alone, one image, several files, a long paste and
// long typed text cover what the bubble holds; test/sent-bubble-final-size.test.ts measures it
// every frame.
import { useEffect, useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { ComposerAttachment } from "../attachments";
import type { AcpmuxRow, PromptImage } from "../model";
import { frameName, framesNote } from "../composer/videoPrompt";
import { primeSentImages, withSentShapes } from "./imageEntries";
import { ImageViewerContext } from "./imageViewerContext";
import { TurnActionsContext } from "./turnActions";
import { UserBubble } from "./UserBubble";

type Shot = { width: number; height: number; hue: number };
type Prompt = {
  /// The prompt as recorded; `paste` follows the typed text as one pasted block.
  text: string;
  paste?: string;
  images?: (Shot & { name: string })[];
  files?: { name: string; size: number; mimeType: string }[];
  /// A screen recording sent with its frames (composer/videoPrompt.ts).
  video?: Shot & { name: string; durationMs: number };
};
type Props = { prompts: Prompt[] };

/// A screenshot-like PNG `width`×`height`: a title bar, a sidebar and lines of text.
function paint({ width, height, hue }: Shot, type = "image/png"): string {
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
  return canvas.toDataURL(type);
}

/// The id acpmux names an image by: the SHA-256 of its bytes (hub/prompt_images.rs).
async function acpmuxId(data: string): Promise<string> {
  const bytes = Uint8Array.from(atob(data), (char) => char.charCodeAt(0));
  const hash = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  return Array.from(hash, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

/// The prompt's composer attachments: its images' bytes and its files' links.
function attachmentsOf(prompt: Prompt, key: number): ComposerAttachment[] {
  return [
    ...(prompt.images ?? []).map((image, index): ComposerAttachment => {
      const src = paint(image);
      return {
        id: `composer-${key}-image-${index}`,
        kind: "image",
        name: image.name,
        mimeType: "image/png",
        size: src.length,
        data: src.slice(src.indexOf(",") + 1),
      };
    }),
    ...(prompt.files ?? []).map((file, index): ComposerAttachment => ({
      id: `composer-${key}-file-${index}`,
      kind: "link",
      name: file.name,
      mimeType: file.mimeType,
      size: file.size,
      path: `/Users/leo/Projects/uploader/${file.name}`,
    })),
    ...(prompt.video ? [videoChip(key, prompt.video)] : []),
  ];
}

/// The composer's chip for a video that went with its frames: the one frame the echo names (its
/// poster's bytes). A video sent without frames is a file chip, not a tile (sentVideos.ts).
function videoChip(key: number, video: Shot & { name: string; durationMs: number }): ComposerAttachment {
  const poster = paint(video, "image/jpeg");
  return {
    id: `composer-${key}-video`,
    kind: "link",
    name: video.name,
    mimeType: "video/quicktime",
    size: 18_400_000,
    path: `/Users/leo/Movies/${video.name}`,
    video: {
      durationMs: video.durationMs,
      width: video.width,
      height: video.height,
      poster,
      frames: [{ atMs: 0, data: poster.slice(poster.indexOf(",") + 1) }],
    },
  };
}

/// The row the pane draws the moment it sends (direct.ts `send`): the composer's own bytes.
function sentRow(prompt: Prompt, key: number, attachments: ComposerAttachment[]): AcpmuxRow {
  const text = prompt.paste === undefined ? prompt.text : `${prompt.text}\n${prompt.paste}`;
  const images: PromptImage[] = attachments.flatMap((attachment) =>
    attachment.kind === "image" && attachment.data
      ? [
          {
            id: attachment.id,
            mimeType: attachment.mimeType,
            name: attachment.name,
            src: `data:${attachment.mimeType};base64,${attachment.data}`,
          },
        ]
      : [],
  );
  return {
    id: `local-${key}`,
    version: 1,
    kind: "user",
    at: 1,
    text,
    ...(prompt.paste !== undefined && { pasted: [{ start: prompt.text.length + 1, end: text.length }] }),
    ...(attachments.length && { retryAttachments: attachments }),
    ...(images.length && { images }),
  };
}

/// acpmux's echo of `sent`: the same prompt under its durable id, each image named by its bytes'
/// SHA-256 (direct.ts `user_message`), with no bytes of its own.
async function echoRow(sent: AcpmuxRow, attachments: ComposerAttachment[], key: number): Promise<AcpmuxRow> {
  const named = await Promise.all(
    attachments.flatMap((attachment) =>
      attachment.kind === "image" && attachment.data
        ? [
            acpmuxId(attachment.data).then((id): PromptImage => ({
              id,
              mimeType: attachment.mimeType,
              name: attachment.name,
            })),
          ]
        : [],
    ),
  );
  // A video went with its frames note and its first frame, which the echo names too.
  const video = attachments.find((attachment) => attachment.video);
  const frame = video?.video
    ? {
        id: await acpmuxId(video.video.poster.slice(video.video.poster.indexOf(",") + 1)),
        mimeType: "image/jpeg",
        name: frameName(video.name, 0),
      }
    : undefined;
  const note = video?.video
    ? `\n${framesNote(video.name, video.video.durationMs, video.video.width, video.video.height, [0])}`
    : "";
  // Each image keeps the bytes and size the pane's own row drew it with, as direct.ts does.
  const { images: _images, ...rest } = sent;
  const images = [...withSentShapes(named, sent.images), ...(frame ? [frame] : [])];
  return {
    ...rest,
    id: `durable-${key}`,
    version: 2,
    text: `${sent.text ?? ""}${note}`,
    ...(images.length && { images }),
  };
}

function Sent({ prompt, index }: { prompt: Prompt; index: number }) {
  const [attachments] = useState(() => attachmentsOf(prompt, index));
  const [row, setRow] = useState(() => sentRow(prompt, index, attachments));
  const [primed, setPrimed] = useState(false);
  useEffect(() => {
    if (!row.images?.length && !row.retryAttachments?.length) return;
    let live = true;
    let prime: ReturnType<typeof setTimeout> | undefined;
    // The echo lands a frame or two after the send, before the pane's priming; the priming lands
    // a moment later and draws the images.
    const echo = setTimeout(() => {
      void echoRow(row, attachments, index).then((next) => {
        if (!live) return;
        setRow(next);
        prime = setTimeout(() => void primeSentImages(attachments).then(() => live && setPrimed(true)), 400);
      });
    }, 120);
    return () => {
      live = false;
      clearTimeout(echo);
      clearTimeout(prime);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps -- one send per mount
  }, []);
  return (
    <div
      className="cv-user"
      data-sent-prompt={index}
      data-sent-row={row.id}
      // Settled: its echo landed and the pane primed its images (nothing more will change).
      data-sent-settled={primed || !attachments.length ? "" : undefined}
    >
      <UserBubble key={row.id} row={row} text={row.text ?? ""} />
    </div>
  );
}

function SentBubbleStage({ prompts }: Props) {
  // acpmux's read never answers: only the pane's priming draws an echoed image.
  const [actions] = useState(() => ({ promptImage: () => new Promise<never>(() => {}) }));
  return (
    <ImageViewerContext.Provider value={() => {}}>
      <TurnActionsContext.Provider value={actions}>
        <div style={{ display: "flex", flexDirection: "column", gap: 32, padding: 16 }}>
          {prompts.map((prompt, index) => (
            <Sent key={index} prompt={prompt} index={index} />
          ))}
        </div>
      </TurnActionsContext.Provider>
    </ImageViewerContext.Provider>
  );
}

const PASTE =
  "Okay, there's a really odd thing going on when you move between tabs inside a pane, and it's a tight space, a tight fit or whatever. Like you open a tab, and the tab bar jumps a few pixels, and then the content under it reflows, and then the whole pane settles a moment later. It happens with two tabs and it happens with ten. It happens in a narrow pane more than a wide one. I'd expect the tab bar to know its height before the tab opens and keep it, and the content to keep its place while the new tab draws. Can you find where the height is measured and why it changes after the tab has opened?";

/// `count` numbered lines of a prompt typed with line breaks.
const lines = (count: number) =>
  Array.from({ length: count }, (_, index) => `Step ${index + 1}: retry the upload on a 5xx`).join("\n");

export default componentEntry<Props>({
  id: "agent-pane.sent-bubble-size",
  title: "Sent prompt size",
  area: "Agent pane",
  pane: true,
  height: 640,
  covers: ["agent-session/acpmux/conversation/UserBubble.tsx#UserBubble"],
  load: async () => SentBubbleStage,
  variants: {
    "text-only": {
      note: "A typed prompt alone: the bubble's one size from the frame it lands.",
      height: 200,
      props: { prompts: [{ text: "Why does the upload fail after the second retry?" }] },
    },
    "one-image": {
      note: "A wide screenshot sent with text: acpmux's echo names it before the pane primes it, and its thumbnail keeps the shape it landed with.",
      height: 260,
      props: {
        prompts: [
          {
            text: "The toolbar overlaps the sidebar here, see the strip at the top.",
            images: [{ name: "image.png", width: 2400, height: 600, hue: 220 }],
          },
        ],
      },
    },
    "several-files": {
      note: "Two screenshots and three files sent with text: the images, the file chips and the bubble land at their final size.",
      height: 360,
      props: {
        prompts: [
          {
            text: "These are the logs and the two screens from the failing upload.",
            images: [
              { name: "Screenshot 2026-11-07 at 10.12.04.png", width: 2880, height: 1800, hue: 150 },
              { name: "Screenshot 2026-11-07 at 10.12.31.png", width: 3024, height: 640, hue: 30 },
            ],
            files: [
              { name: "uploader.log", size: 182_000, mimeType: "text/plain" },
              { name: "retry-policy.md", size: 4_200, mimeType: "text/markdown" },
              { name: "network-trace.har", size: 2_400_000, mimeType: "application/json" },
            ],
          },
        ],
      },
    },
    video: {
      note: "A screen recording sent with text: its tile, poster and length land with the prompt, not when acpmux's echo names its frames.",
      height: 260,
      props: {
        prompts: [
          {
            text: "Watch the tab bar jump when the second tab opens.",
            video: { name: "Tab bar jump.mov", width: 1920, height: 1080, hue: 280, durationMs: 14_000 },
          },
        ],
      },
    },
    "long-paste": {
      note: "A 600-character paste under a typed line: its own characters in the bubble's text, part of the message's one body, never a card inside the bubble.",
      height: 360,
      props: { prompts: [{ text: "Can you look at this?", paste: PASTE }] },
    },
    "agent-paste": {
      note: "A pasted Codex handoff: its own text, with a quiet 'Pasted from Codex' line over it so it never passes as the person's words.",
      height: 300,
      props: {
        prompts: [
          {
            text: "Can you pick this up?",
            paste:
              "From Codex:\nHandoff: the upload probe is red on the second retry.\n\nThe backoff doubles from 200 ms but never resets between uploads, so the third upload waits 1.6 s before its first try.\n\nTrace-ID: ask-77",
          },
        ],
      },
    },
    "huge-paste": {
      note: "A 2,300-line stack trace pasted under a question: its first lines as the bubble's text, folded under the prompt's one Show more.",
      height: 640,
      props: {
        prompts: [
          {
            text: "Why does the upload fail after the second retry?",
            paste: Array.from({ length: 2300 }, (_, index) => `    at retry (uploader.ts:${index + 12}:7)`).join("\n"),
          },
        ],
      },
    },
    "short-head-paste": {
      note: "A paste whose first 4,000 characters are one line (zero-width spaces) and whose rest is 50 lines: it folds once under Show more and stays folded.",
      height: 640,
      props: { prompts: [{ text: "Can you look at this?", paste: "x" + "\u200b".repeat(4000) + "\nline".repeat(50) }] },
    },
    "long-text": {
      note: "A 15-line prompt draws whole; a 40-line one opens on its first lines, fading out, over Show more.",
      height: 1100,
      props: { prompts: [{ text: lines(15) }, { text: lines(40) }] },
    },
  },
});
