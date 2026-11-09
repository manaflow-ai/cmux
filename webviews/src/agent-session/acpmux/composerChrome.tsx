// The composer's hideable controls (ui/HideableChrome.tsx), each hidden from its own right-click
// and shown again from the composer's button row, in every composer (composerSettings.ts): the
// dictation mic and the usage ring at the end of the quiet row. The ring's right-click
// (UsageRingMenu) also picks what it shows, the chat's context or the account's plan usage limits
// (composerRing; Leo 2026-11-04: "i want to be able to right click disable it ... likewise, i guess
// we can turn that into a 5h/weekly usage type thing instead as well for some people").
// Queueing (queueing.ts) is no control, but turned off from a queued row's ⋯ menu it leaves no row
// to turn it back on from once nothing waits, so the button row's right-click offers Turn on
// queueing while it is off.
import { type ReactNode } from "react";
import { ContextMenu } from "../../ui/ContextMenu";

import { setComposerRing, showComposerControl, useComposerSettings } from "./composerSettings";
import { useT } from "./i18n";
/// The usage ring's right-click: what it shows (the context or the plan usage, a checked pick that
/// every composer follows) and Hide Usage Ring. The button row's right-click shows it again
/// (ChromeArea, the `usage-ring` item above).
export function UsageRingMenu({ children }: { children: ReactNode }) {
  const t = useT();
  const { composerRing } = useComposerSettings();
  return (
    <ContextMenu
      className="acpmux-context-usage-menu"
      items={[
        {
          id: "ring-context",
          label: t("ring.menu.context"),
          checked: composerRing === "context",
          onSelect: () => setComposerRing("context"),
        },
        {
          id: "ring-plan-usage",
          label: t("ring.menu.planUsage"),
          checked: composerRing === "planUsage",
          onSelect: () => setComposerRing("planUsage"),
        },
        {
          id: "ring-hide",
          label: t("ring.menu.hide"),
          separatorBefore: true,
          onSelect: () => showComposerControl("showContextUsage", false),
        },
      ]}
    >
      {children}
    </ContextMenu>
  );
}
