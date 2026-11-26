// l10n-allow-file: browser fixture rows and card text, not shipped UI.
// The shared hover surfaces on a transcript row (ui/Tooltip.tsx: a `ui-card` Tooltip as
// SubagentChipPreview draws it, a plain Tooltip; chips/FactsHoverCard.tsx WithFacts, an AnchoredCard),
// on a chip inside a one-line row of a scrolled transcript. A test mounts one case with
// `window.__mount(props)`, scrolls its row to the top or the bottom of the scroll viewport, hovers
// the chip and reads the card's box against the row's text (hover-card-cover.test.ts).
import { createRoot } from "react-dom/client";
import { Tooltip, TooltipProvider } from "../../src/ui/Tooltip";
import { UiProvider } from "../../src/ui/UiProvider";
import { WithFacts } from "../../src/agent-session/acpmux/chips/FactsHoverCard";
import "../../src/pages/shared/desktop.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";

type Kind = "card" | "facts" | "tip";
type Props = { kind: Kind; at: "top" | "bottom"; pane: number; long: boolean };

const ROWS = 40;
const TARGET = 20;
const root = document.getElementById("root")!;
document.body.style.margin = "0";
const view = createRoot(root);

const LINE = "Audit every tool call row for the shared row grammar and list each one that drifts.";
const lines = (long: boolean) => Array.from({ length: long ? 24 : 3 }, (_, index) => `${index + 1}. ${LINE}`);

function Chip({ kind, long }: { kind: Kind; long: boolean }) {
  const chip = (props: Record<string, unknown> = {}) => (
    <button type="button" className="hc-chip" data-hover-chip="" {...props}>
      Tool-call audit
    </button>
  );
  if (kind === "facts")
    return (
      <WithFacts facts={lines(long).map((value, index) => ({ label: `Fact ${index + 1}`, value }))}>
        {(trigger) => chip(trigger as unknown as Record<string, unknown>)}
      </WithFacts>
    );
  if (kind === "tip")
    return <Tooltip label={long ? `Disconnected · 0s · ${LINE}` : "Disconnected · 0s"}>{chip()}</Tooltip>;
  return (
    <Tooltip
      side="top"
      className="ui-card"
      label={
        <span style={{ display: "flex", flexDirection: "column" }}>
          {lines(long).map((line) => (
            <span key={line}>{line}</span>
          ))}
        </span>
      }
    >
      {chip()}
    </Tooltip>
  );
}

function Case({ kind, pane, long }: Props) {
  return (
    <div
      data-scroller=""
      style={{ position: "fixed", inset: 0, overflowY: "auto", width: `${pane}px`, boxSizing: "border-box" }}
    >
      {Array.from({ length: ROWS }, (_, index) => (
        <div
          key={index}
          className="hc-row"
          data-target-row={index === TARGET ? "" : undefined}
          style={{ font: "13px/20px system-ui", padding: "2px 12px", whiteSpace: "nowrap", overflow: "hidden" }}
        >
          {index === TARGET ? (
            <>
              <span>Subagent finished: </span>
              <Chip kind={kind} long={long} />
              <span> and wrote its report back to the parent agent</span>
            </>
          ) : (
            <span>Row {index + 1}: the agent read a file and ran a command in the workspace</span>
          )}
        </div>
      ))}
    </div>
  );
}

const w = window as unknown as {
  __mount(props: Props): Promise<void>;
  __rowText(): Array<{ left: number; top: number; right: number; bottom: number }>;
};
w.__mount = (props) =>
  new Promise((resolve) => {
    view.render(<></>);
    requestAnimationFrame(() => {
      view.render(
        <UiProvider container={document.body}>
          <TooltipProvider>
            <Case key={JSON.stringify(props)} {...props} />
          </TooltipProvider>
        </UiProvider>,
      );
      requestAnimationFrame(() => {
        const scroller = document.querySelector<HTMLElement>("[data-scroller]")!;
        const row = document.querySelector<HTMLElement>("[data-target-row]")!;
        // Its row at the scroll viewport's top edge, or at its bottom edge.
        scroller.scrollTop =
          props.at === "top" ? row.offsetTop - 4 : row.offsetTop + row.offsetHeight + 4 - scroller.clientHeight;
        requestAnimationFrame(() => resolve());
      });
    });
  });
/** The row's text, line by line: what its card must never cover. */
w.__rowText = () => {
  const row = document.querySelector<HTMLElement>("[data-target-row]")!;
  const range = document.createRange();
  range.selectNodeContents(row);
  return [...range.getClientRects()]
    .filter((rect) => rect.width > 0 && rect.height > 0)
    .map((rect) => ({ left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom }));
};
document.documentElement.dataset.harnessReady = "true";
