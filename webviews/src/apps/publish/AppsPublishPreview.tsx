// l10n-allow-file: gallery stage for a native surface; the app's words are in its Swift strings.
// The Apps tier (RFD 0003 E-A, E-C, behind experiments.appsTier) as the Mac app draws it: the
// browser pane's Publish popover and the sidebar's Apps section. Render only: every value here is
// the Rust rules' answer (ops apps_tier_*), never computed.
import "./publish.css";
import { Button } from "../../ui/Button";
import { Input } from "../../ui/Input";
import { Surface } from "../../ui/surface/Surface";
import type { AppsSection, PublishOutcome, PublishPopover } from "./types";

const PROBLEM_TEXT: Record<NonNullable<PublishPopover["problem"]>, string> = {
  nameEmpty: "The name needs a letter or a digit.",
};

function Toolbar() {
  return (
    <div className="apps-publish-toolbar">
      <span className="apps-publish-url">p-3000--k7x2m9qa.preview.cmux.dev/invoices</span>
      <Button variant="subtle" size="sm" aria-pressed="true">
        <span aria-hidden="true">↑</span> Publish
      </Button>
    </div>
  );
}

function Popover({ popover, outcome }: { popover: PublishPopover; outcome?: PublishOutcome }) {
  return (
    // oxlint-disable-next-line jsx-a11y/aria-role -- the Surface role, not an ARIA role
    <Surface role="popover" as="section" className="apps-publish-popover" aria-label="Publish">
      <div className="apps-publish-title">Publish preview</div>
      <div className="apps-publish-field">
        <span className="apps-publish-label">Name</span>
        <Input
          size="sm"
          variant="outline"
          readOnly
          value={popover.name}
          aria-label="Name"
          aria-invalid={popover.problem ? true : undefined}
        />
      </div>
      <div className="apps-publish-hint">
        {popover.problem ? (
          <span className="apps-publish-problem">{PROBLEM_TEXT[popover.problem]}</span>
        ) : (
          <span>{popover.hostLabel}.preview.cmux.dev</span>
        )}
      </div>
      <div className="apps-publish-field">
        <span className="apps-publish-label">Audience</span>
        <div className="apps-publish-segments">
          {(["private", "team"] as const).map((a) => (
            <Button
              key={a}
              variant={popover.audience === a ? "subtle" : "ghost"}
              size="sm"
              aria-pressed={popover.audience === a}
            >
              {a === "private" ? "Only me" : "My team"}
            </Button>
          ))}
        </div>
      </div>
      <div className="apps-publish-field">
        <span className="apps-publish-label">Start</span>
        <span className="apps-publish-start">{popover.startFrom}</span>
      </div>
      {outcome ? <Outcome outcome={outcome} /> : null}
      <div className="apps-publish-actions">
        <Button variant="subtle" size="sm">
          Cancel
        </Button>
        <Button variant="solid" size="sm" disabled={!popover.canPublish}>
          {outcome?.kind === "failed" ? "Try again" : "Publish"}
        </Button>
      </div>
    </Surface>
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
        <Button variant="subtle" size="sm">
          Open
        </Button>
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
    <nav className="apps-publish-sidebar" aria-label="Apps">
      <div className="apps-publish-section-header">Apps</div>
      {section.error ? <div className="apps-publish-section-note">{section.error}</div> : null}
      <ul className="apps-publish-rows">
        {section.rows.map((row) => (
          <li key={row.slug} className="apps-publish-row" data-clickable={row.url ? true : undefined}>
            <span className="apps-publish-dot" data-dot={row.dot} />
            <span className="apps-publish-row-title">{row.title}</span>
            {row.pinned ? <span className="apps-publish-pin">Pinned</span> : null}
            <span className="apps-publish-row-detail">{row.detail}</span>
          </li>
        ))}
        {section.publishRow ? (
          <li className="apps-publish-row apps-publish-row-add" data-clickable>
            <span aria-hidden="true">+</span>
            <span className="apps-publish-row-title">Publish preview…</span>
          </li>
        ) : null}
      </ul>
    </nav>
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
