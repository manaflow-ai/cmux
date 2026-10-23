// l10n-allow-file: gallery fixture (sample attachment names and paths), not shipped UI.
import { useState, type ComponentProps } from "react";
import { componentEntry, type ChipHostFixture } from "../../../gallery/format";
import { LOGIN_TESTS_MP4 } from "../../../gallery/fixtures/toolImages";
import { AttachmentStrip } from "./attachmentIntake";

type AttachmentStripProps = Pick<ComponentProps<typeof AttachmentStrip>, "attachments" | "codex" | "error">;

const movie = "/Users/you/src/atlas-web/out/login-tests.mp4";
const denied = "/Users/you/.ssh/login-tests.mp4";
const outside = "/tmp/fleetviz/login-tests.mp4";
const missing = "/Users/you/src/atlas-web/out/missing.mp4";
const savedRemote = "/remote/saved/login-tests.mp4";
const data = `data:video/mp4;base64,${LOGIN_TESTS_MP4}`;

const localMovieHost: ChipHostFixture = {
  paths: { [movie]: { place: "root", folder: false } },
  media: { [movie]: data },
};

function GalleryAttachmentStrip(props: AttachmentStripProps) {
  const [attachments, setAttachments] = useState(props.attachments);
  return (
    <AttachmentStrip
      {...props}
      attachments={attachments}
      onRemove={(id) => setAttachments((items) => items.filter((item) => item.id !== id))}
    />
  );
}

export default componentEntry<AttachmentStripProps>({
  id: "agent-pane.composer-attachment-strip",
  title: "Composer movie attachments",
  area: "Agent pane",
  covers: [
    "agent-session/acpmux/composer/attachmentIntake.tsx#AttachmentStrip",
    "agent-session/acpmux/chips/ReplyMedia.tsx#ReplyMedia",
  ],
  load: async () => GalleryAttachmentStrip,
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("../conversation/conversation.css"),
      import("../chips/chips.css"),
      import("../composerAttachments.css"),
    ]),
  widths: { narrow: 360, normal: 640, wide: 860 },
  variants: {
    playable: {
      note: "A local recording uses the host-checked poster/player while keeping its filename and Remove control compact.",
      chipHost: localMovieHost,
      props: {
        attachments: [{ id: "movie", kind: "link", name: "login-tests.mp4", mimeType: "", size: 0, path: movie }],
      },
    },
    denied: {
      note: "A denied recording stays filename-only and does not request media bytes.",
      chipHost: { paths: { [denied]: { place: "denied", folder: false } } },
      props: {
        attachments: [{ id: "denied", kind: "link", name: "login-tests.mp4", mimeType: "", size: 0, path: denied }],
      },
    },
    outside: {
      note: "A legacy temporary path outside the session roots keeps the safe fallback until the host confirms it.",
      chipHost: { paths: { [outside]: { place: "outside", folder: false } }, policy: { outsideRoots: "confirm" } },
      props: {
        attachments: [{ id: "outside", kind: "link", name: "login-tests.mp4", mimeType: "", size: 0, path: outside }],
      },
    },
    missing: {
      note: "A missing recording keeps its filename fallback without an unauthorized load.",
      chipHost: { paths: { [missing]: { place: "missing", folder: false } } },
      props: {
        attachments: [{ id: "missing", kind: "link", name: "missing.mp4", mimeType: "", size: 0, path: missing }],
      },
    },
    "saved-remote": {
      note: "A retained remote copy stays filename-only when this pane cannot resolve its path policy.",
      chipHost: {},
      props: {
        attachments: [
          {
            id: "saved-remote",
            kind: "link",
            name: "login-tests.mp4",
            mimeType: "",
            size: 0,
            path: savedRemote,
            saved: true,
          },
        ],
      },
    },
  },
});
