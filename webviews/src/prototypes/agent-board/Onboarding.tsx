// l10n-allow-file: isolated gallery prototype, not shipped UI.
import { useRef, useState } from "react";
import { Dialog, DialogDescription, DialogTitle } from "../../ui/Dialog";
import { DialogButton } from "../../ui/DialogButton";

/** Token figures come from skills/work-tracking/SKILL.md itself (4.7 KB; ~4 characters a token). */
export const SKILL_LISTING_TOKENS = 110;
export const SKILL_BODY_TOKENS = 1200;

export function Onboarding({ confirming, onConfirm }: { confirming?: boolean; onConfirm(): void }) {
  const [open, setOpen] = useState(Boolean(confirming));
  const turnOn = useRef<HTMLButtonElement>(null);
  return (
    <section className="ab-onboard" aria-labelledby="ab-onboard-title">
      <div className="ab-onboard-copy">
        <p className="ab-eyebrow">Agent Board · Off</p>
        <h1 id="ab-onboard-title">See everything your agents built, with the proof</h1>
        <p className="ab-lede">
          When it is on, each agent keeps a short ledger as it works: what it built, the decisions it made and the
          options it turned down, every state it built (light and dark, Mac and iPhone, empty, loading, error) and the
          screenshot, video or test run that proves each one. The board puts every agent's ledger in one place.
        </p>
        <ul className="ab-points">
          <li>
            <strong>Decisions you can question.</strong> Each fork lists what was chosen and what was rejected, and
            flags the ones only you should decide.
          </li>
          <li>
            <strong>Every permutation, checked or not.</strong> Missing and broken states show up instead of hiding in a
            transcript.
          </li>
          <li>
            <strong>Evidence next to the claim.</strong> Screenshots, videos, tests and builds, each with the commit it
            proves; older ones are marked stale.
          </li>
        </ul>
        <div className="ab-cost" role="note" aria-label="Why Agent Board uses more tokens">
          <h2>Why it uses more tokens</h2>
          <ol>
            <li>
              <strong>One more skill in every agent session.</strong> Claude Code lists it on every turn (about{" "}
              {SKILL_LISTING_TOKENS} tokens), and an agent reads its rules once per session (about{" "}
              {SKILL_BODY_TOKENS.toLocaleString("en-US")} tokens).
            </li>
            <li>
              <strong>Extra work to record and prove.</strong> The agent appends a ledger line after each step and
              captures evidence for each state it builds. Screenshots, recordings and their tool calls are the larger
              cost: often 5 to 15% more tokens on a UI task, less on a backend one.
            </li>
          </ol>
          <p className="ab-cost-foot">
            It applies to agent sessions started after you turn it on. Running sessions are not changed.
          </p>
        </div>
        <div className="ab-onboard-actions">
          <button ref={turnOn} type="button" className="ab-primary" onClick={() => setOpen(true)}>
            Turn on Agent Board
          </button>
          <span className="ab-hint">
            Or set <code>agents.board.enabled</code> to <code>true</code>
          </span>
        </div>
      </div>
      <BoardPreview />
      <Dialog open={open} onOpenChange={setOpen} className="ab-dialog" label="Turn on Agent Board">
        <form
          onSubmit={(event) => {
            event.preventDefault();
            setOpen(false);
            onConfirm();
          }}
        >
          <DialogTitle className="ab-dialog-title">Turn on Agent Board?</DialogTitle>
          <DialogDescription className="ab-dialog-body">
            New agent sessions get the work-tracking skill and spend more tokens recording their work and capturing
            evidence. Sessions already running stay as they are. To turn it off, set agents.board.enabled to false.
          </DialogDescription>
          <div className="ab-dialog-actions">
            <DialogButton dialogKey="escape" onClick={() => setOpen(false)}>
              Cancel
            </DialogButton>
            <DialogButton dialogKey="return" type="submit" className="ab-dialog-default">
              Turn On
            </DialogButton>
          </div>
        </form>
      </Dialog>
    </section>
  );
}

/** A still of the board on sample data, so the person sees what they would get. */
function BoardPreview() {
  const rows: [string, string, string][] = [
    ["Invite link card", "4 of 5 states", "ok"],
    ["Accept an invite", "1 broken", "bad"],
    ["Share from iPhone", "building", "wait"],
  ];
  return (
    <figure className="ab-preview" aria-label="Example of the board">
      <div className="ab-preview-head">
        <span className="ab-dot ab-dot-live" />
        team-invite-link
        <span className="ab-preview-flag">1 decision needs you</span>
      </div>
      {rows.map(([title, meta, tone]) => (
        <div className="ab-preview-row" key={title}>
          <span className={`ab-status ab-status-${tone}`} aria-hidden="true" />
          <span>{title}</span>
          <span className="ab-muted">{meta}</span>
        </div>
      ))}
      <div className="ab-preview-thumbs" aria-hidden="true">
        <span className="ab-thumb ab-thumb-light" />
        <span className="ab-thumb ab-thumb-dark" />
        <span className="ab-thumb ab-thumb-light" />
        <span className="ab-thumb ab-thumb-empty" />
      </div>
      <figcaption className="ab-muted">Sample data</figcaption>
    </figure>
  );
}
