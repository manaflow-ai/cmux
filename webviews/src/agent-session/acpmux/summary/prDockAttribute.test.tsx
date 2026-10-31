// The action rows that hold a turn's or a reply's PR links mark themselves (`data-pr-dock`), and
// summary.css keys the links' visibility to that mark instead of a `:has(> .acpmux-pr-dock)` on the
// row: the `:has()` made every node inserted in the agent pane restyle the whole pane
// (pane-has-restyle.browser.test.ts). The mark is there exactly when the dock draws its links.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxRow } from "../model";
import { ReplyActions } from "../conversation/MessageActions";
import { TurnFooter } from "../conversation/TurnRows";
import { RowPullRequests } from "./PullRequestDock";
import type { SummaryPullRequest } from "./transcriptPullRequests";

const pr: SummaryPullRequest = {
  url: "https://github.com/acme/app/pull/12",
  repo: "acme/app",
  number: 12,
  state: "open",
  opened: true,
};
const summary: AcpmuxRow = {
  id: "summary",
  version: 1,
  at: 1_000,
  kind: "turnSummary",
  status: "completed",
};
const reply: AcpmuxRow = {
  id: "reply",
  version: 1,
  at: 1_000,
  kind: "assistant",
  text: "Done.",
} as AcpmuxRow;

/** The action row's opening tag and whether the dock drew inside it. */
function actionRow(markup: string) {
  const open = /<div class="cv-turn-actions[^"]*"[^>]*>/.exec(markup)?.[0] ?? "";
  return { marked: open.includes("data-pr-dock"), dock: markup.includes('class="acpmux-pr-dock"') };
}

for (const [name, node] of [
  ["a turn's footer", <TurnFooter key="turn" row={summary} />],
  ["a reply's actions", <ReplyActions key="reply" row={reply} />],
] as const) {
  test(`${name} is marked when its PR links draw, and only then`, () => {
    const withLinks = actionRow(
      renderToStaticMarkup(<RowPullRequests.Provider value={[pr]}>{node}</RowPullRequests.Provider>),
    );
    expect(withLinks).toEqual({ marked: true, dock: true });
    for (const value of [undefined, []]) {
      const without = actionRow(
        renderToStaticMarkup(<RowPullRequests.Provider value={value}>{node}</RowPullRequests.Provider>),
      );
      expect(without).toEqual({ marked: false, dock: false });
    }
  });
}
