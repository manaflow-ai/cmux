// l10n-allow-file: gallery fixtures (menu rows, plan usage), not shipped UI.
// The golden screen's menus and popover, under each look (looks.json, and every look the checkout
// carries in the golden contrast test): an open menu with a section label, rows with their shortcut
// column, an open submenu, a disabled row and a red destructive row, beside the composer's plan usage
// popover (a muted header, rows with muted reset times, accent bars on their track). The chat itself is
// looks.golden; menus and popovers portal outside it, so they get a stage of their own. They draw with
// today's menu and popover colors; the look's theme file (its colors and accent) is applied by the
// stage frame (frame/main.ts), its agent pane colors by the pane host.
import { useState } from "react";
import looks from "virtual:cmux-gallery/looks";
import { componentEntry } from "../format";
import type { Play } from "../play";
import { Menu, MenuButton, MenuGroup, MenuItem, MenuPopup, MenuSeparator, Submenu } from "../../ui/Menu";
import { PlanUsageCardBody } from "../../agent-session/acpmux/PlanUsageCard";
import type { AcpmuxUsageLimits } from "../../agent-session/acpmux/model";

/// The gallery's pinned clock, so the reset times read the same in every capture.
const NOW = Date.UTC(2026, 10, 4, 3, 0);
const seconds = NOW / 1000;
const LIMITS: AcpmuxUsageLimits = {
  windows: [
    { id: "session", usedPercent: 22, resetsAt: seconds + 5 * 3600 },
    { id: "weekly", usedPercent: 41, resetsAt: seconds + 4 * 86_400 },
  ],
};

function GoldenMenus() {
  const [, setAction] = useState("");
  return (
    <div className="golden-menus">
      <Menu>
        <MenuButton className="golden-menus__trigger" label="Chat actions">
          Chat actions
        </MenuButton>
        <MenuPopup label="Chat actions" className="golden-menus__popup">
          <MenuGroup label="Chat">
            <MenuItem shortcut="⌘R" onSelect={() => setAction("rename")}>
              Rename
            </MenuItem>
            <MenuItem shortcut="⌘D" onSelect={() => setAction("duplicate")}>
              Duplicate
            </MenuItem>
            <Submenu label="Move to">
              <MenuItem onSelect={() => setAction("atlas")}>atlas-web</MenuItem>
              <MenuItem onSelect={() => setAction("billing")}>billing-api</MenuItem>
              <MenuItem disabled>New project…</MenuItem>
            </Submenu>
            <MenuItem disabled shortcut="⌘L">
              Copy share link
            </MenuItem>
          </MenuGroup>
          <MenuSeparator />
          <MenuItem className="ui-menu-item-destructive" shortcut="⌘⌫" onSelect={() => setAction("delete")}>
            Delete chat
          </MenuItem>
        </MenuPopup>
      </Menu>
      <div className="ui-card ui-glass acpmux-context-card acpmux-plan-pop golden-menus__popover">
        <PlanUsageCardBody limits={LIMITS} family="claude" look="claude-bars" now={() => NOW} onOpenUrl={() => {}} />
      </div>
    </div>
  );
}

/** The menu open with its submenu open beside it (the submenu's first row highlighted). */
const openMenus: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Chat actions" });
  await ctx.waitFor(() => ctx.find({ role: "menu" }));
  await ctx.focus({ role: "menuitem", name: "Move to" });
  await ctx.press("ArrowRight");
  await ctx.waitFor(() => ctx.document.querySelectorAll('[role="menu"]').length === 2);
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-plan-usage"));
};

export default componentEntry<Record<string, never>>({
  id: "looks.golden-menus",
  title: "Golden screen: menus and popover (every look)",
  area: "Agent pane",
  pane: true,
  height: 440,
  covers: ["ui/Menu.tsx", "agent-session/acpmux/PlanUsageCard.tsx#PlanUsageCardBody"],
  styles: () =>
    Promise.all([
      import("../../agent-session/acpmux/styles.css"),
      import("../../agent-session/acpmux/composerControls.css"),
      import("../../agent-session/acpmux/contextCard.css"),
      import("../../agent-session/acpmux/planUsageCard.css"),
      import("./goldenMenus.css"),
    ]),
  load: async () => GoldenMenus,
  variants: Object.fromEntries(
    looks.looks.map((look) => [
      look.id,
      { note: `${look.title}: menus and popover (${look.source})`, look, props: {}, play: openMenus },
    ]),
  ),
});
