// l10n-allow-file: synthetic attachment names and fixture error.
import { componentEntry } from "../../gallery/format";
import type { AttachmentManifestReader, UploadManifest } from "./attachmentManifest";

type Props = { state: "first" | "last" | "failed" };
const manifest: UploadManifest = {
  type: "resource_link",
  uri: "file:///sample/9001-attachments.jsonl",
};
export default componentEntry<Props>({
  id: "agent-pane.attachment-manifest",
  title: "Attachment manifest pages",
  area: "Composer",
  pane: true,
  height: 460,
  widths: { normal: 600, narrow: 320 },
  covers: ["agent-session/acpmux/AttachmentManifest.tsx#AttachmentManifestContents"],
  styles: () => import("./styles.css"),
  load: () =>
    Promise.all([import("./AttachmentManifest"), import("./conversation/turnActions")]).then(
      ([{ AttachmentManifestContents }, { TurnActionsContext }]) =>
        function ManifestPage({ state }: Props) {
          const read: AttachmentManifestReader = async (_session, _manifest, offset) => {
            if (state === "failed") throw new Error("offline");
            const start = state === "last" ? 8993 : offset;
            return {
              attachments: Array.from({ length: 8 }, (_, index) => ({
                blockIndex: start + index,
                block: {
                  type: "resource_link",
                  uri: `file:///sample/file-${start + index}.bin`,
                  name: `file-${start + index}.bin`,
                  size: 8_000_000,
                },
                displayPart: { source: { name: "Screenshot" } },
              })),
              hasMore: state === "first" && start + 8 < 9001,
              manifestOffset: start + 8,
            };
          };
          return (
            <div className="acpmux-shell" style={{ display: "block", padding: 16 }}>
              <div className="acpmux-image-viewer-bar">
                <span className="acpmux-image-viewer-title">9001-attachments.jsonl</span>
              </div>
              <TurnActionsContext.Provider
                value={{ attachmentManifestSession: "sample", attachmentManifestPage: read }}
              >
                <AttachmentManifestContents manifest={manifest} />
              </TurnActionsContext.Provider>
            </div>
          );
        },
    ),
  variants: {
    first: { props: { state: "first" } },
    last: { props: { state: "last" } },
    failed: { props: { state: "failed" } },
  },
});
