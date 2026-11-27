// l10n-allow-file: gallery stage for a native surface; the app's words are in its Swift strings.
// The Apps tier (RFD 0003 E-A, E-C, behind experiments.appsTier) as the Mac app draws it: the
// browser pane's Publish popover and the sidebar's Apps section. Render only: every value here is
// the Rust rules' answer (ops apps_tier_*), never computed.
import "./publish.css";
import type { AppsSection, PublishOutcome, PublishPopover } from "./types";

const PROBLEM_TEXT: Record<NonNullable<PublishPopover["problem"]>, string> = {
  nameEmpty: "The name needs a letter or a digit.",
};

function Toolbar() {
  return (
    <div className="apps-publish-toolbar">
      <span className="apps-publish-url">p-3000--k7x2m9qa.preview.cmux.dev/invoices</span>
      <button type="button" className="apps-publish-toolbar-button" aria-pressed="true">
        <span aria-hidden="true">↑</span> Publish
      </button>
    </div>
  );
}

function Popover({ popover, outcome }: { popover: PublishPopover; outcome?: PublishOutcome }) {
  return (
    <div className="apps-publish-popover" role="dialog" aria-label="Publish">
      <div className="apps-publish-title">Publish preview</div>
      <label className="apps-publish-field">
        <span className="apps-publish-label">Name</span>
        <input readOnly value={popover.name} aria-invalid={popover.problem ? true : undefined} />
      </label>
      <div className="apps-publish-hint">
        {popover.problem ? (
          <span className="apps-publish-problem">{PROBLEM_TEXT[popover.problem]}</span>
        ) : (
          <span>{popover.hostLabel}.preview.cmux.dev</span>
        )}
      </div>
      <div className="apps-publish-field">
        <span className="apps-publish-label">Audience</span>
        <div className="apps-publish-segments" role="radiogroup">
          {(["private", "team"] as const).map((a) => (
            <span key={a} role="radio" aria-checked={popover.audience === a} className="apps-publish-segment">
              {a === "private" ? "Only me" : "My team"}
            </span>
          ))}
        </div>
      </div>
      <div className="apps-publish-field">
        <span className="apps-publish-label">Start</span>
        <span className="apps-publish-start">{popover.startFrom}</span>
      </div>
      {popover.command ? <code className="apps-publish-command">{popover.command}</code> : null}
      {outcome ? <Outcome outcome={outcome} /> : null}
      <div className="apps-publish-actions">
        <button type="button" className="apps-publish-secondary">
          Cancel
        </button>
        <button type="button" className="apps-publish-primary" disabled={!popover.canPublish}>
          {outcome?.kind === "failed" ? "Try again" : "Publish"}
        </button>
      </div>
    </div>
  );
}

function Outcome({ outcome }: { outcome: PublishOutcome }) {
  if (outcome.kind === "published")
    return (
      <div className="apps-publish-outcome" data-kind="published">
        <span className="apps-publish-dot" data-dot="live" />
        <span className="apps-publish-outcome-text">
          v{outcome.version} is live at <a href={outcome.url ?? undefined}>{outcome.url}</a>
        </span>
        <button type="button" className="apps-publish-secondary">
          Open
        </button>
      </div>
    );
  return (
    <div className="apps-publish-outcome" data-kind="failed">
      <span className="apps-publish-dot" data-dot="failed" />
      <span className="apps-publish-outcome-text">
        <strong>{outcome.code}</strong> {outcome.message}
      </span>
    </div>
  );
}

function Section({ section }: { section: AppsSection }) {
  return (
    <div className="apps-publish-sidebar" role="list" aria-label="Apps">
      <div className="apps-publish-section-header">Apps</div>
      {section.error ? <div className="apps-publish-section-note">{section.error}</div> : null}
      {section.rows.map((row) => (
        <div key={row.slug} role="listitem" className="apps-publish-row" data-clickable={row.url ? true : undefined}>
          <span className="apps-publish-dot" data-dot={row.dot} />
          <span className="apps-publish-row-title">{row.title}</span>
          {row.pinned ? <span className="apps-publish-pin">Pinned</span> : null}
          <span className="apps-publish-row-detail">{row.detail}</span>
        </div>
      ))}
      {section.publishRow ? (
        <div role="listitem" className="apps-publish-row apps-publish-row-add" data-clickable>
          <span aria-hidden="true">+</span>
          <span className="apps-publish-row-title">Publish preview…</span>
        </div>
      ) : null}
    </div>
  );
}

export type AppsPublishPreviewProps = {
  popover?: PublishPopover;
  outcome?: PublishOutcome;
  section?: AppsSection;
};

export function AppsPublishPreview({ popover, outcome, section }: AppsPublishPreviewProps) {
  return (
    <div className="apps-publish-stage">
      {section ? <Section section={section} /> : null}
      {popover ? (
        <div className="apps-publish-pane">
          <Toolbar />
          <Popover popover={popover} outcome={outcome} />
        </div>
      ) : null}
    </div>
  );
}
