import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { RowShimmer, ShimmerText } from "../../src/agent-session/acpmux/conversation/ShimmerText";
import { installSpinnerClock } from "../../src/ui/spinnerClock";

installSpinnerClock();

/// Mounts `count` running rows' shimmers (`row`) or Thinking lines, each as React commits it, and
/// answers how many times the page asked an element for its animations during that commit.
(window as unknown as Record<string, unknown>).mountShimmers = (count: number, row: boolean, id: string) => {
  const scope = window as unknown as { asks?: number };
  const before = scope.asks ?? 0;
  const host = document.createElement("div");
  host.id = id;
  document.body.append(host);
  flushSync(() =>
    createRoot(host).render(
      Array.from({ length: count }, (_, at) =>
        row ? (
          <div key={at} className="cv-tool is-live">
            <span className="cv-tool__text">
              Read file {at}
              <RowShimmer>Read file {at}</RowShimmer>
            </span>
          </div>
        ) : (
          <output key={at} className="cv-thinking is-shimmer">
            <ShimmerText text="Thinking" />
          </output>
        ),
      ),
    ),
  );
  return (scope.asks ?? 0) - before;
};
