// l10n-allow-file: deterministic gallery fixture content, not shipped UI.
import { useMemo } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { SourceUses } from "./SourceUses";
import type { SourceUse, SourceUsesClient, SourceUsesPage } from "./sourceUses";

type Props = { state: "replies" | "empty" | "empty-page" };
const use: SourceUse = {
  seq: 23,
  at: Date.UTC(2026, 10, 20, 7, 30),
  turnId: "turn",
  replyId: "turn.boot.1",
  toolCallId: "read-design",
  kind: "file",
  uri: "file:///workspace/docs/design.md",
};

function GallerySourceUses({ state }: Props) {
  const strings = useMemo(() => createStrings(table), []);
  const client = useMemo<SourceUsesClient>(
    () => ({
      async call<R>(op: string, params: unknown) {
        if (op !== "cmux.markdown.sourceUses") return {} as R;
        const more = Boolean((params as { cursor?: string }).cursor);
        const page: SourceUsesPage = {
          sessionId: "originating-chat",
          uri: use.uri,
          uses:
            state === "replies" || more
              ? [use, { ...use, seq: 41, at: use.at + 120_000, replyId: "other.boot.1", turnId: "other" }]
              : [],
          nextCursor: state === "empty-page" && !more ? "older-events" : null,
        };
        return page as R;
      },
    }),
    [state],
  );
  return (
    <div className="md-page" style={{ paddingTop: 24 }}>
      <SourceUses path="/workspace/docs/design.md" client={client} strings={strings} />
    </div>
  );
}

const open: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Replies using this page" });
  await ctx.waitFor(() => ctx.document.querySelector(".md-source-uses [aria-busy=false]"));
};

export default componentEntry<Props>({
  id: "markdown.source-uses",
  title: "Replies using a Markdown page",
  area: "Markdown",
  height: 220,
  widths: { narrow: 360, normal: 640, wide: 900 },
  styles: () => Promise.all([import("../shared/pageBase.css"), import("./styles.css")]),
  covers: ["pages/markdown/SourceUses.tsx"],
  load: async () => GallerySourceUses,
  variants: {
    closed: {
      props: { state: "replies" },
      note: "The originating chat is available; no query runs until the disclosure opens.",
    },
    replies: {
      props: { state: "replies" },
      play: open,
      note: "Each entry returns to its exact stamped reply in the originating chat.",
    },
    empty: { props: { state: "empty" }, play: open, note: "A finished query with no uses says so." },
    "scan-continues": {
      props: { state: "empty-page" },
      play: open,
      note: "An empty page with a cursor offers Load more instead of claiming no uses.",
    },
  },
});
