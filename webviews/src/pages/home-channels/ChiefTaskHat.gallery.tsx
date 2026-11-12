// l10n-allow-file: synthetic Chief task fixtures, not shipped copy.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { ChiefTaskHat, type ChiefTaskHatLook } from "./ChiefTaskHat";
import { HAT_NOW, hatRuns } from "./chiefTasksFixtures";
import { RunBook } from "./runs";
import type { HomeRunChange } from "./types";

type Props = { look: ChiefTaskHatLook; runs: HomeRunChange[]; now?: number };
function HatGallery({ look, runs, now = HAT_NOW }: Props) {
  const [strings] = useState(() => createStrings(table));
  const [book] = useState(() => {
    const book = new RunBook();
    book.apply(runs);
    return book;
  });
  return (
    <div style={{ container: "lg-page / inline-size", height: "100%", width: "100%" }}>
      <div className="lg-main" style={{ height: "100%", justifyContent: "flex-end" }}>
        <div className="lg-stage" style={{ justifyContent: "flex-end" }}>
          <ChiefTaskHat book={book} conversation="c1" strings={strings} look={look} now={now} />
          <div className="lg-main-compose">
            <div style={{ height: 44, borderRadius: 12, border: "1px solid var(--page-text-3)", opacity: 0.4 }} />
          </div>
        </div>
      </div>
    </div>
  );
}

export default componentEntry<Props>({
  id: "pages.home-chief-task-hat",
  title: "Chief background tasks in the composer hat",
  area: "Home and Chief",
  height: 360,
  widths: { narrow: 390, normal: 768, wide: 1280 },
  covers: ["pages/home-channels/ChiefTaskHat.tsx"],
  load: async () => HatGallery,
  styles: () => Promise.all([import("./styles.css"), import("./ledger.css")]),
  variants: {
    rows: {
      note: "Selected: one quiet row per task, running first with elapsed time, then each finished one's one-line result until it expires.",
      props: { look: "rows", runs: hatRuns },
    },
    chips: {
      note: "Considered: one row of chips, titles only; the result is in the tooltip.",
      props: { look: "chips", runs: hatRuns },
    },
    summary: {
      note: "Considered: one folded count; the tasks are behind it.",
      props: { look: "summary", runs: hatRuns },
    },
    expired: {
      note: "Twelve minutes later: the finished rows expired, only running ones stay.",
      props: { look: "rows", runs: hatRuns, now: HAT_NOW + 12 * 60_000 },
    },
    before: {
      note: "Before: no hat; the Chief's background helpers showed nowhere over the composer.",
      props: { look: "rows", runs: [] },
    },
    empty: {
      note: "No background task: no hat, the composer does not move.",
      props: { look: "rows", runs: [] },
    },
  },
});
