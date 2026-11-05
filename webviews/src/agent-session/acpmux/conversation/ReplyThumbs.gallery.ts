// l10n-allow-file: gallery fixtures (sample replies and image paths), not shipped UI.
// A reply's image paths draw as thumbnails under their text (Markdown.tsx Thumbs, chips/ReplyImage.tsx
// `thumb`). An image's shape is anything: a wide strip cut from a screen, a tall phone shot, a square
// icon. The thumbnail takes the image's own shape (Leo, 2026-11-05: "This is kind of weird actually.
// I don't think we have good enough looking previews for these").
import { agentPaneEntry, type ChipHostFixture } from "../../../gallery/format";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";

const FOLDER = "/Users/you/.local/share/asks/images";
const WIDE = `${FOLDER}/092c306adc75447a0cfd89e49e7ceb7a118e1b43a6b07b041c2b4e5833d0a350.png`;
const TALL = `${FOLDER}/phone-settings.png`;
const SQUARE = `${FOLDER}/app-icon.png`;

const svg = (width: number, height: number, body: string) =>
  "data:image/svg+xml," +
  encodeURIComponent(
    `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">${body}</svg>`,
  );

// A strip cut from a chat (1568×74, as the screenshot Leo pasted): one line of text across it.
const wide = svg(
  1568,
  74,
  '<rect width="1568" height="74" fill="#26262b"/><rect y="40" width="1568" height="34" fill="#1d1d21"/>' +
    '<circle cx="34" cy="57" r="8" fill="none" stroke="#9a9aa2" stroke-width="2"/>' +
    '<text x="58" y="63" font-family="-apple-system, Helvetica, sans-serif" font-size="17" fill="#c9c9cf">' +
    "I've merged the fix, but it covers one cause. The \"reply only shows when the turn ends\" part is Austin's #32958</text>" +
    '<text x="58" y="24" font-family="-apple-system, Helvetica, sans-serif" font-size="15" fill="#8c8c94">Subagent finished · Fix live working line in transcript</text>',
);
// A phone screen (9:19.5).
const tall = svg(
  390,
  844,
  '<rect width="390" height="844" rx="40" fill="#f2f2f7"/><rect x="20" y="120" width="350" height="56" rx="12" fill="#fff"/>' +
    '<rect x="20" y="196" width="350" height="168" rx="12" fill="#fff"/><rect x="36" y="136" width="120" height="24" rx="6" fill="#d1d1d6"/>' +
    '<text x="20" y="90" font-family="-apple-system, Helvetica, sans-serif" font-size="34" font-weight="700" fill="#111">Settings</text>',
);
// An app icon (1:1).
const square = svg(
  512,
  512,
  '<rect width="512" height="512" rx="112" fill="#3b82f6"/><path d="M150 330l90-150 60 100 40-60 72 110z" fill="#fff"/>',
);

const host: ChipHostFixture = {
  paths: {
    [WIDE]: { place: "root", folder: false },
    [TALL]: { place: "root", folder: false },
    [SQUARE]: { place: "root", folder: false },
  },
  images: { [WIDE]: wide, [TALL]: tall, [SQUARE]: square },
};

const reply = (lines: string[]) =>
  chat(
    [
      user("what's up with this tool call?", 6),
      assistant(lines.join("\n"), 5),
      summary(5, { status: "completed" }),
    ],
    { title: "Tool call in the transcript" },
  );

export default agentPaneEntry({
  id: "agent-pane.reply-thumbs",
  title: "Reply image thumbnails",
  area: "Agent pane",
  covers: ["agent-session/acpmux/chips/ReplyImage.tsx#OpenableImage"],
  variants: {
    "wide-strip": {
      note: "A list item naming a wide screenshot strip (Leo's 2026-11-05 capture): the thumbnail is the strip's own shape.",
      chipHost: host,
      snapshot: reply(["Images he attached with it (1):", "", `- ${WIDE}`]),
    },
    "tall-phone": {
      note: "A tall phone screenshot: the thumbnail keeps its shape at a capped height.",
      chipHost: host,
      snapshot: reply(["The settings screen:", "", `- ${TALL}`]),
    },
    shapes: {
      note: "Wide, tall and square images in one row.",
      chipHost: host,
      snapshot: reply(["Three captures:", "", `- ${WIDE} ${TALL} ${SQUARE}`]),
    },
  },
});
