// l10n-allow-file: public synthetic filenames and prompt in gallery fixtures.
import React from "react";
import { componentEntry } from "../../gallery/format";
import type { ComposerAttachment } from "./attachments";

type Props = { look: "balanced" | "compact" | "stacked" };
const files: ComposerAttachment[] = [
  {
    id: "pem",
    kind: "link",
    name: "manaflow-cmux-production-signing-key.pem",
    size: 2048,
    mimeType: "application/x-pem-file",
    path: "/Users/sample/Keys/manaflow-cmux-production-signing-key.pem",
    saved: true,
  },
  {
    id: "zip",
    kind: "link",
    name: "release-build-diagnostic-bundle.zip",
    size: 12_800_000,
    mimeType: "application/zip",
    path: "/Users/sample/Downloads/release-build-diagnostic-bundle.zip",
    saved: true,
  },
  {
    id: "md",
    kind: "link",
    name: "notes.md",
    size: 720,
    mimeType: "text/markdown",
    path: "/Users/sample/notes.md",
    saved: true,
  },
];
export default componentEntry<Props>({
  id: "agent-pane.file-attachment",
  title: "File attachment chips",
  area: "Composer",
  pane: true,
  height: 390,
  widths: { normal: 560, narrow: 320 },
  covers: ["agent-session/acpmux/FileAttachment.tsx#FileAttachment"],
  styles: () => import("./styles.css"),
  load: () =>
    Promise.all([import("./composer/attachmentIntake"), import("./conversation/UserBubble")]).then(
      ([{ AttachmentStrip }, { UserBubble }]) =>
        function Files({ look }: Props) {
          return (
            <div
              className="acpmux-shell"
              style={{ padding: 20, display: "block", height: "auto" }}
              data-file-look={look}
            >
              <style>{`
          [data-file-look=compact] .acpmux-file-chip { max-width: 260px; gap: 4px; }
          [data-file-look=stacked] .acpmux-file-chip { height: 44px; flex-wrap: wrap; }
          [data-file-look=stacked] .acpmux-file-chip__size { width: 100%; padding-left: 22px; }
        `}</style>
              <div className="acpmux-composer">
                <div className="acpmux-composer-box ui-glass" style={{ minHeight: 112 }}>
                  <AttachmentStrip attachments={files} onRemove={() => {}} />
                  <div style={{ padding: 16 }}>Please use these files.</div>
                </div>
              </div>
              <div className="cv-user" style={{ marginTop: 36 }}>
                <UserBubble
                  row={{
                    id: "files",
                    version: 1,
                    kind: "user",
                    at: 1,
                    inlineParts: files.map((file) => ({
                      kind: "file",
                      name: file.name,
                      mimeType: file.mimeType,
                      size: file.size,
                      uri: `file://${file.path}`,
                    })),
                  }}
                  text="Please use these files."
                />
              </div>
            </div>
          );
        },
    ),
  variants: {
    balanced: { props: { look: "balanced" } },
    compact: { props: { look: "compact" } },
    stacked: { props: { look: "stacked" } },
  },
});
