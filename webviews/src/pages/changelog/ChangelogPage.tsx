// The changelog page (`cmux-page://cmux.changelog/`, R114; What's New, cx-urd.61). The design
// comes from the route (`design=`, Debug Settings `whatsNew.design`): the What's New sheet by default
// (SheetPage, 2026-10-31), the Ledger (u5099: Conductor's changelog, version and date in the margin),
// the journal it grew from, B Rail and C Digest. Colors are the app theme's tokens.
import { useSyncExternalStore } from "react";
import type { Strings } from "../shared/i18n";
import { DigestPage } from "./DigestPage";
import { JournalPage } from "./JournalPage";
import { RailPage } from "./RailPage";
import { SheetPage } from "./SheetPage";
import type { ChangelogStore } from "./store";
import type { ChangelogDesign, NewsLayout } from "./types";

export function ChangelogPage({
  store,
  strings,
  design = "sheet",
  news,
}: {
  store: ChangelogStore;
  strings: Strings;
  design?: ChangelogDesign;
  news?: NewsLayout;
}) {
  const s = useSyncExternalStore(store.subscribe, store.getSnapshot);
  if (s.loading)
    return (
      <div className="cl-empty" aria-busy="true">
        {strings.t("changelog.page.loading")}
      </div>
    );
  if (design === "sheet") return <SheetPage store={store} strings={strings} s={s} />;
  if (design === "rail") return <RailPage store={store} strings={strings} s={s} />;
  if (design === "digest") return <DigestPage store={store} strings={strings} s={s} />;
  return <JournalPage store={store} strings={strings} s={s} ledger={design === "ledger"} news={news} />;
}
