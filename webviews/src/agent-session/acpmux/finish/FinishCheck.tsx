// The check a finished turn's "Worked for" row draws over its chevron for the moment (finish.css):
// a stroke, so it can draw itself in. It takes no width of its own (`.cv-finish-check`), so the row
// moves nothing as it comes and goes.
import "./finish.css";

export function FinishCheck() {
  return (
    <svg className="cv-finish-check" width="14" height="14" viewBox="0 0 14 14" aria-hidden="true" focusable="false">
      <path d="M3.2 7.4 L5.9 10 L10.8 4.2" pathLength={1} />
    </svg>
  );
}
