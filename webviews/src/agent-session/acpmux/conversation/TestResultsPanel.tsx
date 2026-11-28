// A test command's results as they come in: the counts tick while it runs, and each failure is a
// line naming the test with a chip that opens the file at its line. The counts and failures are
// read in Rust as the output streams (cmux-tui/crates/acpmux/src/hub/tool_test_results.rs); this
// only draws `tool.testResults`.
import { useT } from "../i18n";
import type { AcpmuxTestResults } from "../model";
import { PathChip } from "../chips/LinkChips";
import { Surface } from "../../../ui/surface/Surface";

export type TestResultsLook = "strip" | "bar";

export function TestResultsPanel({ results, look = "strip" }: { results: AcpmuxTestResults; look?: TestResultsLook }) {
  const t = useT();
  const { passed, failed, skipped, failures, moreFailures, done } = results;
  const total = passed + failed + skipped;
  return (
    <Surface
      role="card"
      as="section"
      className="cv-test-results"
      data-look={look}
      data-done={done ? "true" : "false"}
      data-failed={failed > 0 ? "true" : "false"}
      aria-label={t("testResults.label")}
      aria-live="polite"
    >
      <div className="cv-test-results__counts">
        {total === 0 && !done ? (
          <span className="cv-test-results__waiting">{t("testResults.waiting")}</span>
        ) : (
          <>
            <span className="cv-test-results__count" data-tone="passed">
              {t("testResults.passed", { count: passed })}
            </span>
            {failed > 0 && (
              <span className="cv-test-results__count" data-tone="failed">
                {t("testResults.failed", { count: failed })}
              </span>
            )}
            {skipped > 0 && (
              <span className="cv-test-results__count" data-tone="skipped">
                {t("testResults.skipped", { count: skipped })}
              </span>
            )}
          </>
        )}
      </div>
      {look === "bar" && total > 0 && (
        <div className="cv-test-results__bar" aria-hidden="true">
          <span data-tone="passed" style={{ flexGrow: passed }} />
          <span data-tone="failed" style={{ flexGrow: failed }} />
          <span data-tone="skipped" style={{ flexGrow: skipped }} />
        </div>
      )}
      {failures.length > 0 && (
        <ul className="cv-test-results__failures">
          {failures.map((failure, index) => (
            <li key={`${failure.name}:${index}`} className="cv-test-results__failure">
              <span className="cv-test-results__name">{failure.name}</span>
              {failure.path && <PathChip path={failure.path} line={failure.line} />}
              {failure.message && <span className="cv-test-results__message">{failure.message}</span>}
            </li>
          ))}
          {!!moreFailures && (
            <li className="cv-test-results__more">{t("testResults.more", { count: moreFailures })}</li>
          )}
        </ul>
      )}
    </Surface>
  );
}
