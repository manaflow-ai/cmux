// Full run details above the reply. Virtualized rows can mount outside the viewport: only read
// their bounded, paginated steps when actually visible. Run events update just this entry.
import { memo, useEffect, useRef, useState } from "react";
import type { Strings } from "../shared/i18n";
import type { RunEntry } from "./runs";
import type { HomeRun } from "./types";
import { RunSteps } from "./RunSteps";

export const RunTranscript = memo(function RunTranscript({
  entry,
  strings,
  onLoad,
  agentNames,
}: {
  entry: RunEntry;
  strings: Strings;
  onLoad(run: HomeRun): void;
  agentNames: ReadonlyMap<string, string>;
}) {
  const element = useRef<HTMLElement>(null);
  const [visible, setVisible] = useState(false);
  useEffect(() => {
    const target = element.current;
    if (!target) return;
    // Older web engines still show the run; the timeline bounds mounted rows.
    if (typeof IntersectionObserver === "undefined") {
      setVisible(true);
      return;
    }
    const observer = new IntersectionObserver(([entry]) => setVisible(entry.isIntersecting));
    observer.observe(target);
    return () => observer.disconnect();
  }, []);
  useEffect(() => {
    if (visible && !entry.complete) onLoad(entry.run);
  }, [visible, entry, onLoad]);
  const { run, steps } = entry;
  return (
    <section ref={element} className="lg-run-transcript" aria-label={run.title || strings.t("run.title")}>
      {steps.length === 0 && <p className="lg-run-empty">{strings.t(entry.complete ? "run.empty" : "run.starting")}</p>}
      <RunSteps run={run} steps={steps} agentNames={agentNames} />
      {run.status === "failed" && run.error && (
        <p className="lg-run-error" role="alert">
          {run.error}
        </p>
      )}
    </section>
  );
});
