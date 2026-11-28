// l10n-allow-file: gallery fixtures (sample image URLs), not shipped UI.
import { componentEntry, type ChipHostFixture } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import type { ReactNode } from "react";

type ReplyImageProps = { src: string; alt: string; fallback: ReactNode };
const remote = "https://images.example.test/gallery/remote.png";
const click = "https://images.example.test/gallery/click.png";
const loaded = "https://images.example.test/gallery/loaded.png";
const local = "/Users/you/src/atlas-web/assets/diagram.png";
const outside = "/tmp/fleetviz/out/fleet.png";
const missing = "/Users/you/src/atlas-web/assets/gone.png";
const image =
  "data:image/svg+xml," +
  encodeURIComponent(
    '<svg xmlns="http://www.w3.org/2000/svg" width="80" height="48"><rect width="80" height="48" fill="#6b7280"/><circle cx="24" cy="24" r="12" fill="#f2cc8f"/><path d="M44 36l10-12 12 12" fill="#81b29a"/></svg>',
  );

const imageHost: ChipHostFixture = {
  images: { [remote]: image, [click]: image, [loaded]: image, [local]: image },
};

const playLoad: Play = async (ctx) => {
  await ctx.click({ selector: ".cv-image-placeholder__load" });
  await ctx.waitFor(() => ctx.document.querySelector("img.cv-img"));
};

export default componentEntry<ReplyImageProps>({
  id: "agent-pane.reply-image",
  title: "Reply images",
  area: "Agent pane",
  covers: [
    "agent-session/acpmux/chips/ReplyImage.tsx#ReplyImage",
    "agent-session/acpmux/chips/ReplyImage.tsx#OpenableImage",
  ],
  load: () => import("./ReplyImage").then((module) => module.ReplyImage),
  styles: () =>
    Promise.all([import("../styles.css"), import("../conversation/conversation.css"), import("./chips.css")]),
  checks: {
    layoutShiftMax: {
      value: 0.01,
      reason: "Replacing the real remote placeholder with the host-provided image changes its intrinsic box once.",
    },
  },
  widths: { narrow: 360, normal: 640, wide: 860 },
  variants: {
    "remote-placeholder": {
      chipHost: { ...imageHost, policy: { remoteImages: "click" } },
      props: { src: remote, alt: "Remote gallery image", fallback: "Remote gallery image" },
    },
    "click-to-load": {
      chipHost: { ...imageHost, policy: { remoteImages: "click" } },
      props: { src: click, alt: "Click to load", fallback: "Click to load" },
      play: playLoad,
    },
    loaded: {
      note: "The same host-mediated remote image after the reader's click.",
      chipHost: { ...imageHost, policy: { remoteImages: "click" } },
      props: { src: loaded, alt: "Loaded remote image", fallback: "Loaded remote image" },
      play: playLoad,
    },
    "outside-roots": {
      note: "A /tmp image outside the session folders: alt text, file name, lock and Open (the host confirms).",
      chipHost: { ...imageHost, paths: { [outside]: { place: "outside", folder: false } } },
      props: { src: outside, alt: "Build fleet status", fallback: "Build fleet status" },
    },
    "outside-roots-text": {
      note: "The same image under agentPane.links.outsideRoots = text: no Open.",
      chipHost: {
        ...imageHost,
        paths: { [outside]: { place: "outside", folder: false } },
        policy: { outsideRoots: "text" },
      },
      props: { src: outside, alt: "Build fleet status", fallback: "Build fleet status" },
    },
    missing: {
      note: "A path inside the folders with no file: Image unavailable, no Open.",
      chipHost: { ...imageHost, paths: { [missing]: { place: "missing", folder: false } } },
      props: { src: missing, alt: "Old diagram", fallback: "Old diagram" },
    },
    local: {
      note: "A local session image loads through the host without a prompt.",
      chipHost: imageHost,
      props: { src: local, alt: "Local diagram", fallback: "Local diagram" },
    },
  },
});
