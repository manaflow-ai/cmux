// l10n-allow-file: gallery fixture (sample ask, tab, workspace and folder), not shipped UI.
//
// Leo's Home, as his NIGHTLY drew it on 2026-11-19 (lane home-cards): a new chat's home with one
// "Needs you" card (a tab an agent marked, its long reason cut mid-line, the tab's title, "In a tab"
// and the workspace, "1d ago"), the agent service's waiting line with Restart agent service, and the
// composer with its Projects and This Mac pickers. The scene is the real components (HomeLists,
// HostWaitingLine, Composer) on gallery data, so any look, theme or setting that changes them shows
// here. Reused by the Home gallery entry (acpmux/HomeState.gallery.tsx) and the golden scene
// (gallery/golden), so both draw the same Home.
import { minutesAgo, GALLERY_NOW } from "../clock";
import { chat } from "./acpmux";
import { Composer } from "../../agent-session/acpmux/Composer";
import { EmptyState } from "../../agent-session/acpmux/EmptyState";
import { HomeLists } from "../../agent-session/acpmux/HomeLists";
import { HostWaitingLine } from "../../agent-session/acpmux/HostError";
import type { AttentionTab } from "../../agent-session/acpmux/needsYou/attentionTabs";

const DAY_MINUTES = 24 * 60;

/// The one marked tab of Leo's screenshot: a reason long enough to cut on one line at the home's
/// width, the tab's title, its workspace, a day old.
export const homeStateTabs: readonly AttentionTab[] = [
  {
    tabId: "home-state-tab",
    reason:
      "Open System Settings › Privacy & Security › Screen Recording, turn on cmux NIGHTLY and click Save so the agent can see the window",
    workspaceTitle: "cmux",
    tabTitle: "System Settings — Screen Recording",
    atMs: minutesAgo(DAY_MINUTES + 12),
  },
];

/// The new chat the home belongs to: no turns yet, in ~/Projects on this Mac.
export const homeStateChat = (() => {
  const snapshot = chat([], { title: "New chat" });
  return {
    ...snapshot,
    sessionId: undefined,
    summary: { ...snapshot.summary!, sessionId: undefined, cwd: "/Users/you/Projects", turnCount: 0 },
  } as typeof snapshot;
})();

const NoChips = () => null;

/// The scene. `waitedMs`: how long the pane has waited for the agent service (26 s in Leo's shot).
export function HomeStateScene({ waitedMs = 26_000 }: { waitedMs?: number }) {
  return (
    <section className="acpmux-shell home-state-scene" aria-label="Home">
      <div className="acpmux-main" data-new-chat="">
        <div className="acpmux-stage">
          <EmptyState project="Projects" />
        </div>
        <div className="acpmux-dock">
          <div className="acpmux-home-area">
            <HomeLists
              sessions={homeStateChat.sessions}
              tabs={homeStateTabs}
              onSelect={() => undefined}
              onAnswer={() => Promise.resolve("answered" as const)}
            />
          </div>
          <HostWaitingLine since={GALLERY_NOW - waitedMs} now={GALLERY_NOW} onRestart={() => undefined} />
          <Composer
            snapshot={homeStateChat}
            chips={NoChips}
            onSend={() => true}
            onStop={() => undefined}
            localName="This Mac"
          />
        </div>
      </div>
    </section>
  );
}
