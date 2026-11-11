import { memo, useRef, useState, type KeyboardEvent, type ReactNode } from "react";
import { useT } from "../i18n";
import { skillDraftProblems, skillSteps, type SkillAction, type SkillDraft, type SkillOffer } from "./skillOffer";
import "./SkillOfferCard.css";

/// How the card is drawn. `compact` (shipped): the question, the skill's name and when to use it,
/// its steps behind a "Show steps" disclosure. `preview`: the same head over the whole SKILL.md body
/// in a code block. `checklist`: the numbered steps as a list, with a chip per source chat. The
/// gallery compares them (SkillOfferCard.gallery.tsx).
export type SkillCardLook = "compact" | "preview" | "checklist";

/// Opens and closes its content's height (a grid row from 0fr to 1fr), so the card folds to its
/// note with no jump. Closed, its content is inert: no focus, no clicks. Reduced motion settles it in
/// one frame (SkillOfferCard.css).
function Fold({ open, className, children }: { open: boolean; className?: string; children: ReactNode }) {
  return (
    <div className={className ? `cv-skill__fold ${className}` : "cv-skill__fold"} data-open={open} inert={!open}>
      <div className="cv-skill__clip">{children}</div>
    </div>
  );
}

const FIELD_TAGS = ["INPUT", "TEXTAREA"];

/// The skill distiller (skillOffer.ts): on the closing turn of the third chat that did the same kind
/// of task, a drafted skill to save. Save writes it (`onResolve`, `_acpmux/skill_resolve`) with the
/// draft as drawn, or as edited; Edit turns the draft into fields checked against the daemon's limits;
/// Not now declines it for good. With focus inside, Return saves, `e` edits, `d` or Escape is Not now
/// (Escape while editing drops the edits, and Cmd-Return in a field saves); the card never takes focus
/// by itself, so the composer keeps it. Once settled it folds to one line. Without `onResolve` (a
/// replay, a guest, a read-only transcript) it draws the draft with no buttons.
export const SkillOfferCard = memo(function SkillOfferCard({
  offer,
  onResolve,
  look = "compact",
  startEditing = false,
}: {
  offer: SkillOffer;
  onResolve?: (action: SkillAction, draft?: SkillDraft) => void;
  look?: SkillCardLook;
  /// Draws the edit fields from the start, without moving focus (the gallery's edit state).
  startEditing?: boolean;
}) {
  const t = useT();
  const actions = onResolve !== undefined;
  const settled = offer.outcome !== undefined;
  const busy = offer.busy !== undefined;
  const [draft, setDraft] = useState<SkillDraft | null>(() =>
    startEditing ? { name: offer.name, description: offer.description, body: offer.body } : null,
  );
  const [stepsOpen, setStepsOpen] = useState(false);
  // Edit moves focus to the name field once it draws (the person asked for the fields).
  const focusName = useRef(false);
  // The last error stays in its fold while the fold closes, so the line shrinks instead of blanking.
  const [shownError, setShownError] = useState(offer.error);
  if (offer.error && offer.error !== shownError) setShownError(offer.error);
  const editing = actions && !settled && draft !== null;
  const problems = editing ? skillDraftProblems(draft) : {};
  const invalid = Object.keys(problems).length > 0;

  const save = () => {
    if (!onResolve || settled || busy || (editing && invalid)) return;
    onResolve(
      "save",
      editing
        ? { name: draft.name, description: draft.description.trim(), body: draft.body }
        : { name: offer.name, description: offer.description, body: offer.body },
    );
  };
  const dismiss = () => {
    if (!onResolve || settled || busy) return;
    onResolve("dismiss");
  };
  const edit = () => {
    if (!actions || settled || editing) return;
    focusName.current = true;
    setDraft({ name: offer.name, description: offer.description, body: offer.body });
  };
  const onKeyDown = (event: KeyboardEvent<HTMLElement>) => {
    if (!actions || settled || event.nativeEvent.isComposing) return;
    const target = event.target as HTMLElement;
    const key = event.key;
    if (FIELD_TAGS.includes(target.tagName)) {
      if (key === "Escape") setDraft(null);
      else if (key === "Enter" && (event.metaKey || event.ctrlKey)) save();
      else return;
    } else {
      if (event.metaKey || event.ctrlKey || event.altKey) return;
      // Return and Space on a button are the button's own.
      if (key === "Enter" && target.tagName !== "BUTTON") save();
      else if (key === "e" && !editing) edit();
      else if (key === "Escape" && editing) setDraft(null);
      else if ((key === "d" || key === "Escape") && !editing) dismiss();
      else return;
    }
    event.preventDefault();
    event.stopPropagation();
  };

  const steps = look === "checklist" ? skillSteps(offer.body) : [];
  const note =
    offer.outcome?.action === "save" ? (
      <>
        {t("skillOffer.saved", { name: offer.outcome.name ?? offer.name })}
        {offer.outcome.path && <span className="cv-skill__path">{offer.outcome.path}</span>}
      </>
    ) : (
      t("skillOffer.dismissed")
    );

  const field = (name: keyof SkillDraft, label: string, hint: string, control: ReactNode) => (
    <label className="cv-skill__field">
      <span className="cv-skill__label">{label}</span>
      {control}
      {problems[name] && <span className="cv-skill__hint">{hint}</span>}
    </label>
  );

  return (
    // oxlint-disable-next-line jsx-a11y/no-noninteractive-element-interactions -- hears the keys of its focusable draft, fields and buttons.
    <section
      className="cv-skill"
      data-look={look}
      data-settled={settled}
      aria-label={t("skillOffer.label", { name: offer.name })}
      aria-busy={busy || undefined}
      onKeyDown={onKeyDown}
    >
      <Fold open={!settled} className="cv-skill__body">
        <p className="cv-skill__question">{t("skillOffer.title", { n: offer.count })}</p>
        {editing ? (
          <div className="cv-skill__form">
            {field(
              "name",
              t("skillOffer.nameField"),
              t("skillOffer.invalidName"),
              <input
                className="cv-skill__input is-mono"
                aria-label={t("skillOffer.nameField")}
                value={draft.name}
                spellCheck={false}
                autoComplete="off"
                aria-invalid={problems.name || undefined}
                disabled={busy}
                ref={(element) => {
                  if (element && focusName.current) {
                    focusName.current = false;
                    element.focus();
                  }
                }}
                onChange={(event) => setDraft({ ...draft, name: event.target.value })}
              />,
            )}
            {field(
              "description",
              t("skillOffer.descriptionField"),
              t("skillOffer.invalidDescription"),
              <input
                className="cv-skill__input"
                aria-label={t("skillOffer.descriptionField")}
                value={draft.description}
                aria-invalid={problems.description || undefined}
                disabled={busy}
                onChange={(event) => setDraft({ ...draft, description: event.target.value })}
              />,
            )}
            {field(
              "body",
              t("skillOffer.bodyField"),
              t("skillOffer.invalidBody"),
              <textarea
                className="cv-skill__input cv-skill__textarea is-mono"
                aria-label={t("skillOffer.bodyField")}
                value={draft.body}
                rows={8}
                spellCheck={false}
                aria-invalid={problems.body || undefined}
                disabled={busy}
                onChange={(event) => setDraft({ ...draft, body: event.target.value })}
              />,
            )}
          </div>
        ) : (
          <>
            {/* oxlint-disable-next-line jsx-a11y/no-noninteractive-tabindex -- the Tab stop where Return saves, e edits and d is Not now, as the memory card's fact lines. */}
            <div className="cv-skill__draft" data-skill-draft="" tabIndex={actions && !settled ? 0 : undefined}>
              <div className="cv-skill__head">
                <span className="cv-skill__name">{offer.name}</span>
                {offer.drafted === "shapes" && <span className="cv-skill__tag">{t("skillOffer.fromShapes")}</span>}
              </div>
              {offer.description && <p className="cv-skill__description">{offer.description}</p>}
            </div>
            {look === "compact" && (
              <>
                <button
                  type="button"
                  className="cv-skill__disclose"
                  aria-expanded={stepsOpen}
                  onClick={() => setStepsOpen((open) => !open)}
                >
                  {stepsOpen ? t("skillOffer.hideSteps") : t("skillOffer.showSteps")}
                </button>
                <Fold open={stepsOpen}>
                  <pre className="cv-skill__source">{offer.body}</pre>
                </Fold>
              </>
            )}
            {look === "preview" && <pre className="cv-skill__source">{offer.body}</pre>}
            {look === "checklist" && (
              <>
                {steps.length > 0 ? (
                  <ol className="cv-skill__steps">
                    {steps.map((step, index) => (
                      // Steps may repeat; their place is their identity.
                      // oxlint-disable-next-line react/no-array-index-key -- a fixed list drawn once per record.
                      <li key={index}>{step}</li>
                    ))}
                  </ol>
                ) : (
                  <pre className="cv-skill__source">{offer.body}</pre>
                )}
                {offer.chats.length > 0 && (
                  <div className="cv-skill__chats">
                    <span className="cv-skill__tag">{t("skillOffer.fromChats")}</span>
                    {offer.chats.map((chat) => (
                      <span key={chat.sessionId} className="cv-skill__chip" title={chat.prompt}>
                        {chat.prompt || chat.sessionId}
                      </span>
                    ))}
                  </div>
                )}
              </>
            )}
          </>
        )}
        <Fold open={offer.error !== undefined}>
          <output className="cv-skill__error" role="alert">
            {shownError}
          </output>
        </Fold>
        {actions && (
          <div className="cv-skill__foot">
            {editing ? (
              <button type="button" className="cv-skill__button" disabled={busy} onClick={() => setDraft(null)}>
                {t("skillOffer.cancel")}
              </button>
            ) : (
              <>
                <button
                  type="button"
                  className="cv-skill__button"
                  disabled={busy}
                  aria-keyshortcuts="D Escape"
                  onClick={dismiss}
                >
                  {t("skillOffer.notNow")}
                </button>
                <button type="button" className="cv-skill__button" disabled={busy} aria-keyshortcuts="E" onClick={edit}>
                  {t("skillOffer.edit")}
                </button>
              </>
            )}
            <button
              type="button"
              className="cv-skill__button is-save"
              disabled={busy || (editing && invalid)}
              aria-keyshortcuts={editing ? "Meta+Enter" : "Enter"}
              onClick={save}
            >
              {t("skillOffer.save")}
            </button>
          </div>
        )}
      </Fold>
      <Fold open={settled} className="cv-skill__done">
        <p className="cv-skill__note">{note}</p>
      </Fold>
    </section>
  );
});
