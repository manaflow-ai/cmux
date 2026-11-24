// l10n-allow-file: gallery fixtures (chat and subagent names), not shipped UI.
// Where a subagent's own pane says whose subagent it is (Leo, 2026-11-22: "it is prob ok to somehow
// denote the \"subagent of\"... at the top i feel like"), beside a normal chat's header at the same
// width, so the two layouts match (Leo, 2026-11-22: "we should align things better").
// - `summary-slot` (picked): the subagent's name in the title, "Subagent of <chat>" muted beside it
//   where a chat's rolling summary used to go (.acpmux-subagent-of). A chat's header is its name
//   alone (#53564), so both are one line, as tall, and nothing below moves.
// - `breadcrumb`: "<chat> › <subagent>" as the title. Same height, but the chat's name crowds the
//   subagent's out first at narrow widths (not picked).
// - `title-badge`: a "Subagent" badge before the name, the chat's name only in the tooltip, so the
//   chat it came from is hidden (not picked).
// Synthetic data.
import type { ReactNode } from "react";
import { componentEntry, type ComponentVariant } from "../../../gallery/format";
import { ThreadTitle } from "../header/ThreadTitle";

type Look = "summary-slot" | "breadcrumb" | "title-badge";
type Props = { look: Look };

const CHAT = "Release prep";
const AGENT = "Diff review";

function Header({ children, pane }: { children: ReactNode; pane: string }) {
  return (
    <header className="acpmux-header" data-pane={pane}>
      <div className="acpmux-header-status-slot">
        <span className="acpmux-header-status-content">{children}</span>
      </div>
    </header>
  );
}

function SubagentHeaderOfGallery({ look }: Props) {
  return (
    <div className="acpmux-shell" style={{ display: "flex", flexDirection: "column" }}>
      <Header pane="chat">
        <ThreadTitle title={CHAT} onRename={() => undefined} />
      </Header>
      <Header pane="subagent">
        {look === "summary-slot" && (
          <>
            <ThreadTitle title={AGENT} />
            <span className="acpmux-subagent-of" data-subagent-of="">{`Subagent of ${CHAT}`}</span>
          </>
        )}
        {look === "breadcrumb" && <ThreadTitle title={`${CHAT} › ${AGENT}`} />}
        {look === "title-badge" && (
          <span style={{ display: "inline-flex", alignItems: "center", gap: "var(--space-1, 4px)" }}>
            <span
              /* tooltip-allow: gallery fixture of a not-picked look */ title={`Subagent of ${CHAT}`}
              style={{
                fontSize: "var(--text-caption)",
                color: "var(--agent-muted)",
                border: "1px solid var(--agent-border, #8884)",
                borderRadius: 999,
                padding: "0 var(--space-1, 4px)",
              }}
            >
              Subagent
            </span>
            <ThreadTitle title={AGENT} />
          </span>
        )}
      </Header>
    </div>
  );
}

const NOTES: Record<Look, string> = {
  "summary-slot": "Picked: the subagent's name with whose subagent it is muted beside it; same height as the chat's.",
  breadcrumb: "Not picked: the chat's name in the title crowds the subagent's out first at narrow widths.",
  "title-badge": "Not picked: the chat it came from is only in a tooltip.",
};

const height = (ctx: { document: Document }, pane: string) =>
  ctx.document.querySelector(`[data-pane="${pane}"]`)?.getBoundingClientRect().height;

function variant(look: Look): ComponentVariant<Props> {
  return {
    note: NOTES[look],
    props: { look },
    play: async (ctx) => {
      await ctx.waitFor(() => height(ctx, "chat") !== undefined && height(ctx, "subagent") !== undefined);
      const text = ctx.document.querySelector('[data-pane="subagent"]')?.textContent ?? "";
      if (look !== "title-badge" && !text.includes(CHAT)) throw new Error(`${look} does not name the chat`);
      if (look !== "summary-slot") return;
      const off = Math.abs((height(ctx, "chat") ?? 0) - (height(ctx, "subagent") ?? 0));
      if (off > 1) throw new Error(`the subagent's header is ${off} px off the chat's`);
    },
  };
}

export default componentEntry<Props>({
  id: "agent-pane.subagent-header-of",
  title: "Whose subagent a pane shows, at its top",
  area: "Agent pane",
  pane: true,
  height: 140,
  // A quarter, a third and a half of a 1440 px window.
  widths: { narrow: 360, normal: 480, wide: 720 },
  anchors: [{ selector: '[data-pane="subagent"]' }],
  covers: ["agent-session/acpmux/subagents/subagentPanes.ts#paneHeading"],
  keywords: ["subagent", "subagent of", "provenance", "header", "layout shift"],
  styles: () => Promise.all([import("../styles.css"), import("../header/header.css")]),
  load: async () => SubagentHeaderOfGallery,
  variants: {
    "summary-slot": variant("summary-slot"),
    breadcrumb: variant("breadcrumb"),
    "title-badge": variant("title-badge"),
  },
});
