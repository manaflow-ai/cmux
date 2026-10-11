// l10n-allow-file: gallery fixtures (sample URLs), not shipped UI.
import { componentEntry, type ChipHostFixture } from "../../../gallery/format";
import type { ReactNode } from "react";

type UrlChipProps = { href: string; icon?: ReactNode; children: ReactNode };

const FAVICON =
  "data:image/svg+xml," +
  encodeURIComponent(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><rect width="16" height="16" rx="4" fill="#e07a5f"/><path d="M4 8h8M8 4v8" stroke="#fff" stroke-width="2"/></svg>',
  );

const host: ChipHostFixture = {
  sites: {
    "https://docs.example.test/guide": { title: "Example docs", icon: FAVICON },
  },
};

export default componentEntry<UrlChipProps>({
  id: "agent-pane.url-chip",
  title: "URL chips",
  area: "Agent pane",
  covers: ["agent-session/acpmux/chips/LinkChips.tsx#UrlChip"],
  load: () => import("./LinkChips").then((module) => module.UrlChip),
  styles: () =>
    Promise.all([import("../styles.css"), import("../conversation/conversation.css"), import("./chips.css")]),
  widths: { narrow: 360, normal: 640, wide: 860 },
  variants: {
    globe: { props: { href: "https://example.test/docs/getting-started", children: "example.test/docs" } },
    "cached-favicon": {
      chipHost: host,
      props: { href: "https://docs.example.test/guide", children: "Example docs" },
    },
    "long-url": {
      props: {
        href: "https://example.test/research/2026/agent-session/gallery/fixtures?view=transcript&sort=recent&filter=public",
        children: "example.test/research/2026/agent-session/gallery/fixtures?view=transcript&sort=recent&filter=public",
      },
    },
  },
});
