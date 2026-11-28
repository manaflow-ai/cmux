// The changelog page (`cmux-page://cmux.changelog/`, R114; What's New, cx-urd.61). The design
// comes from the route (`design=`, Debug Settings `whatsNew.design`): A Journal by default, B Rail
// and C Digest only until the journal has been dogfooded. Colors are the app theme's tokens.
import { useSyncExternalStore } from "react";
import type { Strings } from "../shared/i18n";
import { DigestPage } from "./DigestPage";
import { JournalPage } from "./JournalPage";
import { RailPage } from "./RailPage";
import type { ChangelogStore } from "./store";
import type { ChangelogDesign } from "./types";

export function ChangelogPage({
  store,
  strings,
  design = "journal",
}: {
  store: ChangelogStore;
  strings: Strings;
  design?: ChangelogDesign;
}) {
  const s = useSyncExternalStore(store.subscribe, store.getSnapshot);
  if (s.loading)
    return (
      <div className="cl-empty" aria-busy="true">
        {strings.t("changelog.page.loading")}
      </div>
    );
  if (design === "rail") return <RailPage store={store} strings={strings} s={s} />;
  if (design === "digest") return <DigestPage store={store} strings={strings} s={s} />;
  return <JournalPage store={store} strings={strings} s={s} />;
}
