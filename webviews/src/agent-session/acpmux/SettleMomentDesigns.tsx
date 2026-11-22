// l10n-allow-file: gallery design fixtures for the settle moment, not shipped UI.
// The moment a chat settles because its pull request merged (acpmux hub/auto_settle.rs, opt-in
// Settings > General > Settle Chats), drawn as Leo's sidebar beside the chat's foot so the designs
// compare where the eye is: "now" (nothing settles; the row keeps its merged glyph), (a) the toast
// names the chat and the pull request with Undo, (b) the row fades into a Settled group at the
// list's foot, (c) the row stays put with an inline "merged, settled" chip and Undo. Leo picks one;
// the shipped toast (SettledToast.gallery.tsx) and shelf (SettledShelf.gallery.tsx) are unchanged.
// Leo, 2026-11-18: "there's the archived/settled chats for it, etc".
import { useMemo } from "react";
import { createNoticeQueue } from "../../ui/NoticeStack";
import { PullRequestGlyph } from "./session-info/PullRequestGlyph";
import type { PullRequestGlyphState } from "./session-info/pullRequestGlyphModel";
import { ToastLayer } from "./ToastLayer";
import "./SettleMomentDesigns.css";

export type SettleMomentDesign = "now" | "toast" | "fade" | "chip";

export interface SettleMomentDesignsProps {
  design: SettleMomentDesign;
}

type Row = { id: string; title: string; age: string; pr?: { number: number; state: PullRequestGlyphState } };

const SETTLING = "fix-login";
const ROWS: Row[] = [
  { id: "cache", title: "Make cache misses visible", age: "2m", pr: { number: 50112, state: "open" } },
  { id: SETTLING, title: "Fix login", age: "6m", pr: { number: 123, state: "merged" } },
  { id: "retry", title: "Try a second retry policy", age: "1h" },
  { id: "notes", title: "Draft the release notes", age: "3h", pr: { number: 50087, state: "draft" } },
  { id: "dock", title: "Why does the dock flicker on resize?", age: "1d" },
];
const settling = ROWS.find((row) => row.id === SETTLING)!;

const noop = () => undefined;

function ChatRow({ row, settled }: { row: Row; settled?: "fade" | "chip" }) {
  return (
    <li className="smd-row" data-settled={settled}>
      <span className="smd-row-title">{row.title}</span>
      {settled === "chip" ? (
        <>
          <span className="smd-chip">
            <PullRequestGlyph state="merged" size={11} />
            merged, settled
          </span>
          <button type="button" className="smd-undo">
            Undo
          </button>
        </>
      ) : (
        <>
          {row.pr && (
            <span className="smd-pr" data-state={row.pr.state}>
              <PullRequestGlyph state={row.pr.state} size={11} />
              {row.pr.number}
            </span>
          )}
          <span className="smd-age">{row.age}</span>
        </>
      )}
    </li>
  );
}

function Sidebar({ design }: SettleMomentDesignsProps) {
  // Now and (c) keep the row where it was; (a) and (b) take it off the list.
  const listed = design === "now" || design === "chip" ? ROWS : ROWS.filter((row) => row.id !== SETTLING);
  return (
    <nav className="smd-sidebar" aria-label="Sidebar">
      <header className="smd-workspace">cmux</header>
      <ul className="smd-list">
        {listed.map((row) => (
          <ChatRow key={row.id} row={row} settled={design === "chip" && row.id === SETTLING ? "chip" : undefined} />
        ))}
      </ul>
      {design === "fade" && (
        <section className="smd-settled" aria-label="Settled">
          <header className="smd-settled-head">
            <span>Settled</span>
            <span className="smd-settled-count">1</span>
          </header>
          <ul className="smd-list">
            <ChatRow row={settling} settled="fade" />
          </ul>
        </section>
      )}
    </nav>
  );
}

export function SettleMomentDesigns({ design }: SettleMomentDesignsProps) {
  const queue = useMemo(() => {
    const made = createNoticeQueue();
    if (design === "toast") {
      // The gallery holds it: nothing times out under a capture.
      made.show({
        id: `settled:${SETTLING}`,
        message: `Settled “${settling.title}” · PR #${settling.pr!.number} merged`,
        group: "settled",
        duration: 0,
        actions: [{ id: "undo", label: "Undo", onSelect: noop }],
      });
    }
    return made;
  }, [design]);
  return (
    <div className="smd" data-design={design}>
      <Sidebar design={design} />
      <div className="acpmux-shell toast-gallery smd-chat">
        <div className="acpmux-main" data-dock="float">
          <div className="acpmux-stage toast-gallery-stage">
            <p className="toast-gallery-row">
              Merged pull request 123 into main. The login redirect keeps the return path now.
            </p>
          </div>
          <div className="acpmux-dock">
            <ToastLayer queue={queue} />
            <div className="acpmux-composer">
              <div className="acpmux-composer-box ui-glass toast-gallery-composer">Ask for follow-up changes</div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
