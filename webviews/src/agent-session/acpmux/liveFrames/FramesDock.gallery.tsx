// l10n-allow-file: synthetic window and page pictures for the design comparison.
// The preview window (FramesDock.tsx) on each surface it shows (RFD 0150): a native Mac window the
// daemon offers as a live cmux-rd screen, a native window with no share host (polled frames), and
// a web page (polled frames, unchanged). The daemon is a stand-in that answers with the reply
// `turn_frames.rs` sends.
import { componentEntry } from "../../../gallery/format";
import { linkScheme, setLinkScheme } from "../links";
import { FramesDock, type LatestFrame } from "./FramesDock";
import type { Latest, TurnFrame } from "./turnFrames";

type Surface = "window-live" | "window-frames" | "page";
type Props = { surface: Surface };

const svg = (body: string) =>
  `data:image/svg+xml;base64,${btoa(
    `<svg xmlns="http://www.w3.org/2000/svg" width="640" height="400" viewBox="0 0 640 400">${body}</svg>`,
  )}`;

const WINDOW = svg(
  `<rect width="640" height="400" rx="10" fill="#1f2125"/>
   <rect width="640" height="28" rx="10" fill="#2b2e33"/>
   <circle cx="16" cy="14" r="5" fill="#ff5f57"/><circle cx="32" cy="14" r="5" fill="#febc2e"/><circle cx="48" cy="14" r="5" fill="#28c840"/>
   <rect x="0" y="28" width="150" height="372" fill="#26282c"/>
   <rect x="14" y="48" width="110" height="10" rx="4" fill="#4a4e55"/>
   <rect x="14" y="70" width="90" height="10" rx="4" fill="#3b3f45"/>
   <rect x="14" y="92" width="100" height="10" rx="4" fill="#3b3f45"/>
   <rect x="170" y="48" width="440" height="140" rx="8" fill="#2f3237"/>
   <rect x="170" y="204" width="440" height="80" rx="8" fill="#2f3237"/>
   <rect x="190" y="68" width="200" height="12" rx="4" fill="#6b707a"/>`,
);
const PAGE = svg(
  `<rect width="640" height="400" fill="#f7f7f8"/>
   <rect width="640" height="56" fill="#ffffff"/>
   <rect x="24" y="20" width="120" height="16" rx="6" fill="#111827"/>
   <rect x="24" y="88" width="360" height="28" rx="6" fill="#1f2937"/>
   <rect x="24" y="132" width="520" height="12" rx="4" fill="#9ca3af"/>
   <rect x="24" y="152" width="480" height="12" rx="4" fill="#9ca3af"/>
   <rect x="24" y="196" width="140" height="40" rx="10" fill="#2563eb"/>`,
);

const frame = (full: string): TurnFrame => ({
  index: 0,
  trigger: "edit",
  at: 0,
  thumb: full,
  full,
  width: 640,
  height: 400,
  distance: 0,
});

const REPLIES: Readonly<Record<Surface, Latest>> = {
  "window-live": {
    frame: frame(WINDOW),
    seq: 1,
    surface: "window",
    screen: { device: "d47f285e-d0ba-48b9-a593-508b0b9d1ab4", name: "Studio Mac" },
  },
  "window-frames": { frame: frame(WINDOW), seq: 1, surface: "window" },
  page: { frame: frame(PAGE), seq: 1, surface: "page" },
};

function Dock({ surface }: Props) {
  // The host hands the scheme over in its handshake; the gallery has none.
  if (!linkScheme()) setLinkScheme(undefined, "cmux");
  const latest: LatestFrame = async () => REPLIES[surface];
  return (
    <div className="acpmux-shell" style={{ position: "relative", height: "100%" }}>
      <FramesDock pane={`gallery-frames-dock-${surface}`} latest={latest} working={false} onOpen={() => undefined} />
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.frames-dock",
  title: "Preview window",
  area: "Agent pane",
  pane: true,
  height: 520,
  widths: { narrow: 420, normal: 640 },
  covers: ["agent-session/acpmux/liveFrames/FramesDock.tsx", "agent-session/acpmux/liveFrames/liveFrames.css"],
  load: async () => Dock,
  variants: {
    "window-live": {
      note: "A native Mac window whose Mac runs a share host: the window is a live screen tile, the latest frame its poster, and Watch live opens that Mac's screen through cmux-rd (the app's Mac Screen tab).",
      props: { surface: "window-live" },
    },
    "window-frames": {
      note: "A native Mac window with no share host running (not joined, or no device yet): no tile, polled frames as before.",
      props: { surface: "window-frames" },
    },
    page: {
      note: "A web page: polled frames, unchanged.",
      props: { surface: "page" },
    },
  },
});
