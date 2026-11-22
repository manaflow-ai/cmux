// Changes' Fix failing checks button (experiment `changes-fix-checks-button`, off by default): one
// button on a pull request row that names what it sends, "Fix 2 failing checks", counting only the
// branch's own reds. A check that fails on the base branch's tip too is left out and said so ("Failing
// on base too, not sent"). Its arms differ in how much they show before the click:
//   quiet   a muted text button; a click drafts acpmux's message into the composer, unsent;
//   count   a red-count button whose hover lists what it sends and what it leaves out; a click drafts;
//   preview a click opens the message the agent gets, and Send sends it to the chat.
// The message and the classifier are acpmux's (`_acpmux/pr_feedback`); this only shows them.
import { useEffect, useRef, useState } from "react";
import { useT } from "../i18n";
import { Popover } from "../../../ui/Popover";
import { Tooltip } from "../../../ui/Tooltip";
import type { FixChecksLook } from "./fixChecks.experiment";
import { fixChecksPreview, type FixChecksPreview } from "./fixChecks";
import type { PrFeedbackRequest } from "./prFeedback";

/// What the button reads and sends with, for the chat shown now (App.tsx): acpmux's checks answer for
/// a pull request, and a message sent to the chat's agent.
export type FixChecksActions = {
  read: (url: string) => ReturnType<PrFeedbackRequest>;
  send: (markdown: string) => void;
};

type Read = FixChecksPreview | "reading" | "failed" | undefined;

export function FixChecksButton({
  url,
  count,
  onBase,
  look,
  onDraft,
  actions,
}: {
  url: string;
  /// The branch's own reds (fixChecks.ts `ownFailing`); -1 when the row has no count.
  count: number;
  /// How many reds fail on base too, from the row, until acpmux's answer names them.
  onBase: number;
  look: Exclude<FixChecksLook, "off">;
  /// Drafts acpmux's message into the composer (prFeedback.ts, Labs' ⋯ item's path).
  onDraft: () => void;
  actions?: FixChecksActions;
}) {
  const t = useT();
  const [read, setRead] = useState<Read>(undefined);
  const [open, setOpen] = useState(false);
  const [anchor, setAnchor] = useState<HTMLButtonElement | null>(null);
  const asked = useRef<ReturnType<PrFeedbackRequest> | undefined>(undefined);
  // New counts are a new read: what was read before names other reds.
  useEffect(() => setRead(undefined), [count, onBase, url]);
  const label =
    count > 0 ? t("sessionInfo.changes.fixChecks", { n: count }) : t("sessionInfo.changes.fixFailingChecks");
  const load = () => {
    if (!actions || (read !== undefined && read !== "failed")) return;
    setRead("reading");
    const request = actions.read(url);
    asked.current = request;
    request.answer.then(
      (answer) => {
        if (asked.current === request && request.stillShown()) setRead(fixChecksPreview(answer) ?? "failed");
      },
      () => {
        if (asked.current === request) setRead("failed");
      },
    );
  };
  const button = (extra: Partial<React.ButtonHTMLAttributes<HTMLButtonElement>> = {}) => (
    <button
      type="button"
      ref={setAnchor}
      className="acpmux-session-info-link acpmux-session-info-fix"
      data-look={look}
      {...extra}
    >
      {look === "count" && <span className="acpmux-session-info-fix__dot" aria-hidden="true" />}
      {label}
    </button>
  );
  if (look === "quiet") return <div className="acpmux-session-info-fix-row">{button({ onClick: onDraft })}</div>;
  if (look === "count" || !actions)
    return (
      <div className="acpmux-session-info-fix-row">
        <Tooltip className="ui-card acpmux-session-info-fix__card" label={<FixList read={read} onBase={onBase} />}>
          {button({ onClick: onDraft, onPointerEnter: load, onFocus: load })}
        </Tooltip>
      </div>
    );
  const preview = typeof read === "object" ? read : undefined;
  return (
    <div className="acpmux-session-info-fix-row">
      {button({
        "aria-haspopup": "dialog",
        "aria-expanded": open,
        onClick: () => {
          setOpen(true);
          load();
        },
      })}
      <Popover
        open={open}
        onOpenChange={setOpen}
        anchor={anchor}
        label={t("sessionInfo.changes.fixChecksMessage")}
        className="acpmux-session-info-fix__popover"
        align="start"
      >
        <div className="acpmux-session-info-fix__preview">
          <div className="acpmux-session-info-fix__heading">{t("sessionInfo.changes.fixChecksMessage")}</div>
          {preview ? (
            <pre className="acpmux-session-info-fix__draft">{preview.draft}</pre>
          ) : (
            <div className="acpmux-session-info-fix__note">
              {read === "failed" ? t("error.requestFailed") : t("sessionInfo.changes.fixChecksReading")}
            </div>
          )}
          <NotSent names={preview?.onBase} onBase={onBase} />
          <div className="acpmux-session-info-fix__actions">
            <button type="button" className="acpmux-session-info-link" onClick={() => setOpen(false)}>
              {t("git.cancel")}
            </button>
            <button
              type="button"
              className="acpmux-session-info-fix__send"
              disabled={!preview || preview.empty}
              onClick={() => {
                if (preview && !preview.empty && asked.current?.stillShown()) actions.send(preview.draft);
                setOpen(false);
              }}
            >
              {t("composer.send")}
            </button>
          </div>
        </div>
      </Popover>
    </div>
  );
}

/// The hover card's lists: what the click sends, then what it leaves out.
function FixList({ read, onBase }: { read: Read; onBase: number }) {
  const t = useT();
  const preview = typeof read === "object" ? read : undefined;
  return (
    <div className="acpmux-session-info-fix__list">
      <div className="acpmux-session-info-fix__heading">{t("sessionInfo.changes.fixChecksSends")}</div>
      {preview ? (
        <ul>
          {preview.own.map((check) => (
            <li key={check.name}>
              <span className="acpmux-session-info-fix__name">{check.name}</span>
              {check.step && <span className="acpmux-session-info-fix__step"> {check.step}</span>}
            </li>
          ))}
        </ul>
      ) : (
        <div className="acpmux-session-info-fix__note">
          {read === "failed" ? t("error.requestFailed") : t("sessionInfo.changes.fixChecksReading")}
        </div>
      )}
      <NotSent names={preview?.onBase} onBase={onBase} />
    </div>
  );
}

/// The base reds the message leaves out, by name once acpmux has named them.
function NotSent({ names, onBase }: { names?: string[]; onBase: number }) {
  const t = useT();
  if (names ? names.length === 0 : onBase <= 0) return null;
  return (
    <div className="acpmux-session-info-fix__base">
      <div className="acpmux-session-info-fix__heading">{t("sessionInfo.changes.fixChecksNotSent")}</div>
      {names ? (
        <ul>
          {names.map((name) => (
            <li key={name}>{name}</li>
          ))}
        </ul>
      ) : (
        <div className="acpmux-session-info-fix__note">{t("sessionInfo.changes.failingOnBase", { count: onBase })}</div>
      )}
    </div>
  );
}
