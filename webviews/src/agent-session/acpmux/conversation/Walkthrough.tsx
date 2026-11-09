// The browser walkthrough an agent ran before it said a UI change was done (walkthroughModel.ts), under
// its answer: one line that says whether the flow passed, then a strip of the steps, each a
// screenshot over a green or red mark and its one line. A click on a shot opens it in the image
// viewer. The line folds the strip; the choice is kept per turn like any other fold.
// References: claude/web/merge-status (cmux-design-references), a check list of passed and failed
// rows with a mark each; design/verify-walkthrough.md.
import { memo } from "react";
import { useT } from "../i18n";
import { ReplyImage } from "../chips/ReplyImage";
import { useTranscriptDisclosure } from "./transcriptDisclosureModel";
import { useAnchoredCollapse } from "./useAnchoredCollapse";
import { AlertCircle, Check, ChevronRight, Close } from "./icons";
import type { Walkthrough as WalkthroughModel, WalkthroughStep } from "./walkthroughModel";
import "./Walkthrough.css";

/// Where the flow ran, short: `localhost:5173/settings`.
function place(url: string): string {
  try {
    const parsed = new URL(url);
    const host = parsed.hostname === "127.0.0.1" ? "localhost" : parsed.hostname;
    return `${host}${parsed.port ? `:${parsed.port}` : ""}${parsed.pathname === "/" ? "" : parsed.pathname}`;
  } catch {
    return url;
  }
}

function Mark({ step }: { step: WalkthroughStep }) {
  if (step.ok) return <Check size={12} className="cv-walk__mark is-ok" />;
  if (step.skipped) return <span className="cv-walk__mark is-skipped" aria-hidden />;
  return <Close size={12} className="cv-walk__mark is-failed" />;
}

function Step({ step }: { step: WalkthroughStep }) {
  const t = useT();
  const verdict = step.ok
    ? t("walkthrough.stepPassed")
    : step.skipped
      ? t("walkthrough.stepSkipped")
      : t("walkthrough.stepFailed");
  return (
    <li className={`cv-walk__step${step.ok ? " is-ok" : step.skipped ? " is-skipped" : " is-failed"}`}>
      <span className="cv-walk__shot">
        {step.image ? (
          <ReplyImage
            src={step.image}
            alt={step.line}
            fallback={<span className="cv-walk__blank" />}
            thumb
            hideMissing
          />
        ) : (
          <span className="cv-walk__blank" />
        )}
      </span>
      <span className="cv-walk__caption" title={step.error ? `${step.line}\n${step.error}` : step.line}>
        <Mark step={step} />
        <span className="cv-walk__line">
          <span className="cv-walk__visually-hidden">{verdict}: </span>
          {step.n}. {step.line}
        </span>
      </span>
      {step.error && <span className="cv-walk__error">{step.error}</span>}
    </li>
  );
}

export const Walkthrough = memo(function Walkthrough({ id, walkthrough }: { id: string; walkthrough: WalkthroughModel }) {
  const t = useT();
  // Open unless the reader folded it: the proof is what the strip is for.
  const [open, setOpen] = useTranscriptDisclosure(`walkthrough:${id}`, true, true);
  // Opens and closes as every fold does: the strip under it moves with it, no pop-in.
  const fold = useAnchoredCollapse({ open, onOpenChange: setOpen });
  const { steps, passed, error, url } = walkthrough;
  const done = steps.filter((s) => s.ok).length;
  const failedAt = steps.find((s) => !s.ok && !s.skipped);
  const head = passed
    ? t("walkthrough.passed", { done, total: steps.length })
    : error
      ? t("walkthrough.noServer")
      : t("walkthrough.failed", { n: failedAt?.n ?? steps.length, done, total: steps.length });
  const bodyId = `walkthrough-${id}`;
  return (
    <section className={`cv-walk${passed ? " is-pass" : " is-fail"}`} aria-label={head}>
      <button
        type="button"
        className="cv-walk__head"
        aria-expanded={open}
        aria-controls={open ? bodyId : undefined}
        ref={fold.headerRef}
        onClick={fold.toggle}
      >
        {passed ? (
          <Check size={14} className="cv-walk__verdict is-ok" />
        ) : (
          <AlertCircle size={14} className="cv-walk__verdict is-failed" />
        )}
        <span className="cv-walk__title">{head}</span>
        {url && <span className="cv-walk__place">{place(url)}</span>}
        <ChevronRight size={14} className={`cv-walk__chevron cv-rotor${open ? " is-open" : ""}`} />
      </button>
      {fold.present && (
        <div {...fold.bodyProps}>
          <div id={bodyId} className="cv-walk__body">
          {error && <p className="cv-walk__why">{error}</p>}
          <ol className="cv-walk__steps">
            {steps.map((step) => (
              <Step key={step.n} step={step} />
            ))}
            </ol>
          </div>
        </div>
      )}
    </section>
  );
});

