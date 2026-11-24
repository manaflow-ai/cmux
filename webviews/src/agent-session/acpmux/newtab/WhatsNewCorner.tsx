// What's New in the New Tab page's top-right corner (whatsNew.ts): a quiet link that opens what
// changed in this update, and a small x that hides it until the next one. It sits out of the page's
// flow (screen.css .nt-whats-new, absolutely placed in the corner the page already leaves empty), so
// nothing on the page moves when it comes or goes (Leo 2026-11-24: "make sure to have no layout
// shifts and it's properly placed"). The clicks go to the host (`whatsNew.command`), which does what
// the sidebar's Updated card did: open What's New for the span this update crossed, or mark it seen.
import { useWhatsNew, type WhatsNewCommand } from "./whatsNew";

function Sparkle() {
  return (
    <svg viewBox="0 0 16 16" width="12" height="12" aria-hidden="true" focusable="false">
      <path
        d="M8 1.5c.3 2.9 1.6 4.2 4.5 4.5-2.9.3-4.2 1.6-4.5 4.5C7.7 7.6 6.4 6.3 3.5 6 6.4 5.7 7.7 4.4 8 1.5Zm4.5 8c.15 1.3.7 1.85 2 2-1.3.15-1.85.7-2 2-.15-1.3-.7-1.85-2-2 1.3-.15 1.85-.7 2-2Z"
        fill="currentColor"
      />
    </svg>
  );
}

export function WhatsNewCorner({ onCommand }: { onCommand?: (command: WhatsNewCommand) => void }) {
  const notice = useWhatsNew();
  if (!notice || !onCommand) return null;
  const { look } = notice;
  return (
    <div className="nt-whats-new" data-look={look} role="group" aria-label={notice.title}>
      <button
        type="button"
        className="nt-whats-new-open"
        title={notice.title}
        aria-label={look === "dot" ? `${notice.title}: ${notice.whatsNew}` : undefined}
        onClick={() => onCommand("open")}
      >
        <Sparkle />
        {look === "titled" && (
          <>
            <span className="nt-whats-new-title">{notice.title}</span>
            <span className="nt-whats-new-sep" aria-hidden="true">
              ·
            </span>
          </>
        )}
        {look !== "dot" && <span className="nt-whats-new-label">{notice.whatsNew}</span>}
      </button>
      <button
        type="button"
        className="nt-whats-new-dismiss"
        aria-label={notice.dismiss}
        title={notice.dismiss}
        onClick={() => onCommand("dismiss")}
      >
        <svg viewBox="0 0 16 16" width="10" height="10" aria-hidden="true" focusable="false">
          <path d="M4 4l8 8M12 4l-8 8" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
        </svg>
      </button>
    </div>
  );
}
