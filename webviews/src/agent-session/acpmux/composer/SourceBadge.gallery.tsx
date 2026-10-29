// l10n-allow-file: gallery fixtures (sample file names, app names and a prompt), not shipped UI.
// Where an attachment came from (composer/SourceBadge.tsx; Leo, 2026-10-29: "Also, I guess it's,
// like, you know, be interesting to add, like, attributions for screenshots and attachments and
// whatnot, right? I think, like, Spotlight has an interesting feature for that, where just at the top
// right, there's a little icon that says, Oh, hey, this came from Cmax, this came from Claude, or
// whatever."). The composer's chips and the sent prompt's thumbnails and files, each with its source
// app's icon at the top-right corner. `corner` is what ships; the others are the designs it was
// picked over. The app icons are drawn stand-ins (the host draws the real ones).
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { AttachmentSource, ComposerAttachment } from "../attachments";
import type { PromptImage } from "../model";

type Design = "before" | "corner" | "small" | "labelled" | "outside";
type Props = { design: Design };

const APPS: Record<string, { hue: number; letter: string }> = {
  "com.google.Chrome": { hue: 210, letter: "C" },
  "com.apple.screenshot.launcher": { hue: 0, letter: "S" },
  "com.cmuxterm.app": { hue: 265, letter: "c" },
  "com.apple.finder": { hue: 195, letter: "F" },
};
const SOURCES: Record<string, AttachmentSource> = {
  chrome: { name: "Google Chrome", bundleId: "com.google.Chrome", site: "github.com" },
  screenshot: { name: "Screenshot", bundleId: "com.apple.screenshot.launcher" },
  cmux: { name: "cmux", bundleId: "com.cmuxterm.app" },
  finder: { name: "Finder", bundleId: "com.apple.finder" },
};

/// A stand-in app icon: a rounded square in the app's hue with its letter, as a PNG data URL.
function appIcon(bundleId: string): string | undefined {
  const app = APPS[bundleId];
  if (!app) return undefined;
  const canvas = document.createElement("canvas");
  canvas.width = canvas.height = 64;
  const ink = canvas.getContext("2d")!;
  const fill = ink.createLinearGradient(0, 0, 0, 64);
  fill.addColorStop(0, `hsl(${app.hue} 80% 62%)`);
  fill.addColorStop(1, `hsl(${app.hue} 75% 42%)`);
  ink.fillStyle = fill;
  ink.beginPath();
  ink.roundRect(4, 4, 56, 56, 14);
  ink.fill();
  ink.fillStyle = "white";
  ink.font = "600 34px -apple-system, system-ui, sans-serif";
  ink.textAlign = "center";
  ink.textBaseline = "middle";
  ink.fillText(app.letter, 32, 34);
  return canvas.toDataURL("image/png");
}

/// A screenshot-like picture `width`×`height` in `hue`, as base64 PNG bytes.
function shot(width: number, height: number, hue: number): string {
  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const ink = canvas.getContext("2d")!;
  ink.fillStyle = `hsl(${hue} 30% 16%)`;
  ink.fillRect(0, 0, width, height);
  ink.fillStyle = `hsl(${hue} 30% 26%)`;
  ink.fillRect(0, 0, width, height * 0.08);
  ink.fillRect(0, 0, width * 0.22, height);
  ink.fillStyle = `hsl(${hue} 70% 62%)`;
  for (let line = 0; line < 8; line += 1)
    ink.fillRect(width * 0.27, height * (0.16 + line * 0.09), width * (0.3 + ((line * 37) % 40) / 100), height * 0.03);
  const url = canvas.toDataURL("image/png");
  return url.slice(url.indexOf(",") + 1);
}

const DESIGNS = `
  [data-source-design=small] .acpmux-source-badge { width: 12px; top: 5px; right: 5px; }
  [data-source-design=small] .acpmux-file-chip > .acpmux-source-badge { width: 10px; left: 18px; }
  [data-source-design=labelled] .acpmux-attachment-image > .acpmux-source-badge,
  [data-source-design=labelled] .cv-user__sourced > .acpmux-source-badge {
    display: flex; align-items: center; gap: 3px; width: auto; aspect-ratio: auto;
    padding: 2px 6px 2px 2px; border-radius: 9px; filter: none;
    background: color-mix(in srgb, var(--acpmux-composer-bg, var(--agent-page-bg)) 86%, transparent);
    box-shadow: 0 0 0 0.5px var(--agent-border-strong);
    color: var(--agent-text); font-size: var(--text-caption); line-height: 14px; white-space: nowrap;
  }
  [data-source-design=labelled] .acpmux-attachment-image > .acpmux-source-badge > img,
  [data-source-design=labelled] .cv-user__sourced > .acpmux-source-badge > img { width: 14px; height: 14px; }
  [data-source-design=labelled] .acpmux-attachment-image > .acpmux-source-badge::after,
  [data-source-design=labelled] .cv-user__sourced > .acpmux-source-badge::after { content: attr(aria-label); }
  [data-source-design=outside] .acpmux-attachment-image > .acpmux-source-badge { width: 18px; top: -5px; right: -5px; }
  [data-source-design=outside] .cv-user__sourced > .acpmux-source-badge { width: 18px; top: -5px; right: -5px; }
  [data-source-design=outside] .acpmux-attachments { overflow: visible; padding-top: 6px; }
`;

/// The chips and sent images for `design`, with the host's icon answer stood in for.
function useFixtures(design: Design) {
  const [fixtures] = useState(() => {
    const actions = (window.cmuxAcpmuxActions ??= {});
    actions["attachment.sourceIcon"] = async (params) => {
      const src = typeof params.bundleId === "string" ? appIcon(params.bundleId) : undefined;
      return src ? { src } : {};
    };
    const sourced = (source: AttachmentSource) => (design === "before" ? {} : { source });
    const wide = shot(1440, 900, 220);
    const tall = shot(780, 1290, 150);
    const square = shot(900, 900, 30);
    const chips: ComposerAttachment[] = [
      {
        id: "web",
        kind: "image",
        name: "image.png",
        mimeType: "image/png",
        size: 1,
        data: wide,
        ...sourced(SOURCES.chrome!),
      },
      {
        id: "shot",
        kind: "image",
        name: "Screenshot 2026-10-29 at 10.14.02.png",
        mimeType: "image/png",
        size: 1,
        data: tall,
        ...sourced(SOURCES.screenshot!),
      },
      {
        id: "cap",
        kind: "image",
        name: "Screenshot 2026-10-29 10.15.11.png",
        mimeType: "image/png",
        size: 1,
        data: square,
        ...sourced(SOURCES.cmux!),
      },
      { id: "unknown", kind: "image", name: "image.png", mimeType: "image/png", size: 1, data: shot(1200, 800, 280) },
      {
        id: "file",
        kind: "link",
        name: "build-times.csv",
        mimeType: "text/csv",
        size: 18_400,
        path: "/Users/sample/Desktop/build-times.csv",
        ...sourced(SOURCES.finder!),
      },
    ];
    const images: PromptImage[] = chips
      .filter((chip) => chip.kind === "image")
      .map((chip) => ({
        id: `sent-${design}-${chip.id}`,
        mimeType: chip.mimeType,
        name: chip.name,
        src: `data:image/png;base64,${chip.data}`,
        ...(chip.source ? { source: chip.source } : {}),
      }));
    return { chips, images };
  });
  return fixtures;
}

export default componentEntry<Props>({
  id: "agent-pane.attachment-source",
  title: "Attachment source badge",
  area: "Composer",
  pane: true,
  height: 420,
  widths: { normal: 620, narrow: 340 },
  covers: [
    "agent-session/acpmux/composer/SourceBadge.tsx#SourceBadge",
    "agent-session/acpmux/conversation/UserBubble.tsx#SentImages",
  ],
  styles: () =>
    Promise.all([import("../styles.css"), import("../conversation/conversation.css")]).then(() => undefined),
  load: () =>
    Promise.all([
      import("./attachmentIntake"),
      import("../conversation/UserBubble"),
      import("../conversation/turnActions"),
      import("../conversation/imageViewerContext"),
    ]).then(
      ([{ AttachmentStrip }, { SentImages, UserBubble }, { TurnActionsContext }, { ImageViewerContext }]) =>
        function Gallery({ design }: Props) {
          const fixtures = useFixtures(design);
          const [actions] = useState(() => ({
            promptImage: (id: string) => Promise.resolve(fixtures.images.find((image) => image.id === id)?.src),
          }));
          return (
            <div
              className="acpmux-shell"
              style={{ padding: 20, display: "block", height: "auto" }}
              data-source-design={design}
            >
              <style>{DESIGNS}</style>
              <div className="acpmux-composer">
                <div className="acpmux-composer-box ui-glass" style={{ minHeight: 112 }}>
                  <AttachmentStrip attachments={fixtures.chips} onRemove={() => {}} />
                  <div style={{ padding: 16 }}>Why does the sidebar overlap the toolbar here?</div>
                </div>
              </div>
              <ImageViewerContext.Provider value={() => {}}>
                <TurnActionsContext.Provider value={actions}>
                  <div className="cv-user" style={{ marginTop: 28 }}>
                    <SentImages images={fixtures.images} />
                    <UserBubble
                      row={{
                        id: `files-${design}`,
                        version: 1,
                        kind: "user",
                        at: 1,
                        inlineParts: fixtures.chips
                          .filter((chip) => chip.kind === "link")
                          .map((chip) => ({
                            kind: "file" as const,
                            name: chip.name,
                            mimeType: chip.mimeType,
                            size: chip.size,
                            uri: `file://${chip.path}`,
                            ...(chip.source ? { source: chip.source } : {}),
                          })),
                      }}
                      text="Why does the sidebar overlap the toolbar here?"
                    />
                  </div>
                </TurnActionsContext.Provider>
              </ImageViewerContext.Provider>
            </div>
          );
        },
    ),
  variants: {
    before: {
      note: "Before: the same chips and sent prompt with no source recorded. No chip wears an icon (as an unknown source still does after).",
      props: { design: "before" },
    },
    corner: {
      note: "Shipped. The source app's own 16px icon in the tile's top-right corner (a web image from Google Chrome, a Screenshot capture, cmux's Attach Screenshot), on the file glyph's corner for a file from Finder; the fourth image's source is unknown, so it wears none. In the composer the × takes that corner while the pointer is on the tile. The tooltip names the source (\"From Google Chrome · github.com\").",
      props: { design: "corner" },
    },
    small: {
      note: "A 12px icon: quieter, but at Retina it reads as a coloured dot rather than an app.",
      props: { design: "small" },
    },
    labelled: {
      note: "Icon and the app's name in a glass pill: names it without hovering, but covers a wide strip of a small thumbnail and repeats on every chip.",
      props: { design: "labelled" },
    },
    outside: {
      note: "Spotlight's straddle: an 18px icon over the tile's corner. It needs the strip to stop clipping its top edge and crowds the next chip.",
      props: { design: "outside" },
    },
  },
});
