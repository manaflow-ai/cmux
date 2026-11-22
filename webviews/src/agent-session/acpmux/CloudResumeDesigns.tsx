// l10n-allow-file: gallery design fixtures for where a slow Cloud resume says so, not shipped UI.
// Three places for the one note a slow resume gets (afterDelay.ts: only past RESUME_NOTE_DELAY_MS),
// side by side in the gallery around a chat whose prompt was just sent to a paused machine. Only
// `queue` ships (ComposerQueue's held-for-wake line); `footer` and `transcript` exist here alone, so
// the choice is made on what each looks like.
import { ComposerQueue } from "./ComposerQueue";
import { Spinner } from "./conversation/icons";
import { translate as t } from "./i18n";

/// `queue`: the note is the line over the held prompt in the composer's queue (shipped).
/// `footer`: a quiet line with a spinner under the composer's input.
/// `transcript`: a quiet line with a spinner under the last reply, where the answer will stream.
export type CloudResumeDesign = "queue" | "footer" | "transcript";

export type CloudResumeDesignsProps = {
  design: CloudResumeDesign;
  /// The resume has run past the threshold: the note shows. False: the first 1.5 s, when nothing does.
  slow: boolean;
};

const PROMPT = "Run the upload test 200 times and tell me if it still flakes.";

export function CloudResumeDesigns({ design, slow }: CloudResumeDesignsProps) {
  const note = (
    <span className="acpmux-resume-design-note" data-enter="fade">
      <Spinner size={12} loading />
      {t("composer.heldForWake")}
    </span>
  );
  return (
    <div className="acpmux-resume-design" data-design={design}>
      <style>{STYLES}</style>
      <div className="acpmux-resume-design-transcript">
        <p className="acpmux-resume-design-user">Make the upload assertion wait for the completion event.</p>
        <p>Done: the test waits for the upload's completion event, and 200 runs passed.</p>
        {/* Its line is there from the first frame, empty, so the note moves nothing. */}
        {design === "transcript" && <div className="acpmux-resume-design-slot">{slow && note}</div>}
      </div>
      {design === "queue" ? (
        <ComposerQueue
          queue={[{ id: "held-1", prompt: PROMPT, held: true, waking: true }]}
          t={t}
          wakeNoteDelayMs={slow ? 0 : 3_600_000}
        />
      ) : null}
      <div className="acpmux-resume-design-composer">
        <span className="acpmux-resume-design-placeholder">
          {design === "queue" ? "Queue another message…" : PROMPT}
        </span>
        {design === "footer" && <div className="acpmux-resume-design-slot">{slow && note}</div>}
      </div>
    </div>
  );
}

const STYLES = `
.acpmux-resume-design{display:flex;flex-direction:column;justify-content:flex-end;gap:8px;height:100%;padding:16px 24px;box-sizing:border-box;color:var(--agent-text);font-size:var(--text-body)}
.acpmux-resume-design-transcript{display:flex;flex-direction:column;gap:12px}
.acpmux-resume-design-transcript p{margin:0}
.acpmux-resume-design-user{align-self:flex-end;max-width:80%;padding:6px 12px;border-radius:14px;background:var(--agent-input-bg)}
.acpmux-resume-design-composer{display:flex;flex-direction:column;gap:6px;padding:10px 12px;border-radius:14px;background:var(--agent-input-bg)}
.acpmux-resume-design-placeholder{color:var(--acpmux-composer-placeholder)}
.acpmux-resume-design-slot{min-height:18px}
.acpmux-resume-design-note{display:inline-flex;align-items:center;gap:6px;color:var(--acpmux-composer-dim,var(--agent-muted));font-size:var(--text-detail)}
`;
