// l10n-allow-file: gallery fixtures (sample file names and pick cards), not shipped UI.
// The strip's chips that are not a staged file: a browser pick (BrowserPickChip.tsx), its number in
// its badge and the person's comment over the element and page, and the placeholders of files still
// coming in (PendingChip in attachmentIntake.tsx): reading, streaming to the session's machine, and
// an upload that failed with its Retry.
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import type { ComposerAttachment } from "../attachments";
import { BROWSER_PICK_HEADER } from "./browserPickModel";
import type { PendingAttachment } from "./attachmentIntakeModel";

type Props = { show: "pick" | "pending" };

const pick = [
  BROWSER_PICK_HEADER,
  "Pick: 1",
  "Comment: Make this button blue",
  "Page: https://example.com/checkout",
  "Element: <button>",
  "Text: Place order",
].join("\n");

const picks: ComposerAttachment[] = [
  {
    id: "design-1",
    kind: "text",
    name: "1 · Make this button blue",
    mimeType: "text/plain",
    size: pick.length,
    text: pick,
  },
];

const pending: PendingAttachment[] = [
  { id: "reading", name: "screen-recording.mov", image: false, video: true, fileSize: 48_000_000 },
  { id: "uploading", name: "build-log.txt", image: false, fileSize: 2_400_000, uploading: true, progress: 0.4 },
  {
    id: "failed",
    name: "trace.json",
    image: false,
    fileSize: 9_200_000,
    failed: "The session's machine went offline",
    uploadFailed: true,
  },
];

const chips: Play = async (ctx) => {
  await ctx.waitFor(
    () =>
      ctx.document.querySelector(".acpmux-composer-box .acpmux-attachment-remove, .acpmux-browser-pick-number") !==
      null,
  );
};

export default componentEntry<Props>({
  id: "agent-pane.attachment-intake-chips",
  title: "Browser pick and pending attachment chips",
  area: "Composer",
  pane: true,
  height: 220,
  widths: { normal: 620, narrow: 340 },
  covers: [
    "agent-session/acpmux/composer/BrowserPickChip.tsx#BrowserPickChip",
    "agent-session/acpmux/composer/attachmentIntake.tsx#PendingChip",
  ],
  styles: () => Promise.all([import("../styles.css"), import("../composerAttachments.css")]).then(() => undefined),
  load: () =>
    import("./attachmentIntake").then(
      ({ AttachmentStrip }) =>
        function Gallery({ show }: Props) {
          return (
            <div className="acpmux-shell" style={{ padding: "var(--ds-space-5)", display: "block", height: "auto" }}>
              <div className="acpmux-composer">
                <div className="acpmux-composer-box ui-glass" style={{ minHeight: 112 }}>
                  <AttachmentStrip
                    attachments={show === "pick" ? picks : []}
                    pending={show === "pending" ? pending : []}
                    onRemove={() => {}}
                    onCancel={() => {}}
                    onRetry={() => {}}
                  />
                  <div style={{ padding: "var(--ds-space-4)" }}>Why does the order button look grey?</div>
                </div>
              </div>
            </div>
          );
        },
    ),
  variants: {
    pick: {
      note: "A browser pick: its number in a badge (the pin on the page), the comment as its title, the element and page under it.",
      props: { show: "pick" },
      play: chips,
    },
    pending: {
      note: "Files still coming in: a video being read, a log streaming to the session's machine, and an upload that failed with its Retry.",
      props: { show: "pending" },
      play: chips,
    },
  },
});
