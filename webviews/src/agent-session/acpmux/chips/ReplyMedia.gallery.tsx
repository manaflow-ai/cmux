// l10n-allow-file: gallery video fixture and state descriptions, not shipped UI.
import { componentEntry } from "../../../gallery/format";
import { LOGIN_TESTS_MP4 } from "../../../gallery/fixtures/toolImages";

type Props = { src: string; name: string };
const props = { src: `data:video/mp4;base64,${LOGIN_TESTS_MP4}`, name: "Login test recording" };

export default componentEntry<Props>({
  id: "agent-pane.video-thumbnail",
  title: "Video hover preview",
  area: "Agent pane",
  covers: ["agent-session/acpmux/chips/ReplyMedia.tsx#VideoThumbnail"],
  load: () =>
    import("./ReplyMedia").then(({ VideoThumbnail }) => (value: Props) => (
      <VideoThumbnail {...value} onError={() => {}} />
    )),
  styles: () =>
    Promise.all([import("../styles.css"), import("../conversation/conversation.css"), import("./chips.css")]),
  widths: { narrow: 360, normal: 640, wide: 860 },
  variants: {
    poster: {
      props,
      note: "A pointer sweep leaves the poster still; rest for the shared 450 ms hover delay to preview muted.",
    },
    "motion-off": {
      props,
      note: "Motion off prevents hover playback. Click still plays from the start with sound and controls.",
      play: async (ctx) => {
        ctx.document.documentElement.dataset.cmuxMotion = "off";
      },
    },
  },
});
