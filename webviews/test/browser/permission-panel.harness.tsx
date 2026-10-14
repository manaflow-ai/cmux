// The chat's asks as the agent pane lays them out (App.tsx): the transcript fills what the
// permission panel leaves, inside a pane of a fixed height. The test hands it a permission state
// (`window.__showPermissions`), as a chat's snapshots do when an agent asks.
import { createRoot } from "react-dom/client";
import { PermissionPanel } from "../../src/agent-session/acpmux/permissions/Panel";
import type { PermissionClientState } from "../../src/agent-session/acpmux/permissions/protocol";
// The pane's styles, as its dev entry loads them (acpmux/dev.tsx).
import "../../src/pages/shared/desktop.css";
import "../../src/ui/popupSurface.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "katex/dist/katex.min.css";
import "../../src/agent-session/acpmux/conversation/conversation.css";
import "../../src/agent-session/acpmux/chips/chips.css";
import "../../src/agent-session/acpmux/previewCard/previewCard.css";
import "../../src/agent-session/acpmux/changes/changes.css";
import "../../src/agent-session/acpmux/turnChanges/turnChanges.css";
import "../../src/agent-session/acpmux/summary/summary.css";
import "../../src/agent-session/acpmux/subagents/subagents.css";
import "../../src/agent-session/acpmux/header/header.css";
import "../../src/agent-session/acpmux/composerControls.css";
import "../../src/agent-session/acpmux/composerStates.css";
import "../../src/agent-session/acpmux/composerLocation.css";
import "../../src/agent-session/acpmux/composerAttachments.css";
import "../../src/agent-session/acpmux/markdownField.css";
import "../../src/agent-session/acpmux/modelPicker.css";
import "../../src/agent-session/acpmux/keys.css";
import "../../src/agent-session/acpmux/newtab/screen.css";
import "../../src/agent-session/acpmux/newtab/history.css";
import "../../src/agent-session/acpmux/threadMinimap/threadMinimap.css";

const root = document.getElementById("root")!;
document.documentElement.style.height = document.body.style.height = "100%";
document.body.style.margin = "0";
Object.assign(root.style, { height: "100%" });

const view = createRoot(root);
(window as unknown as { __showPermissions: (state: PermissionClientState) => void }).__showPermissions = (state) =>
  view.render(
    <section className="acpmux-shell">
      <div className="acpmux-main">
        <div className="acpmux-scroll" />
        {/* The bottom stack the panel sits in (App.tsx `asks`). */}
        <div className="acpmux-permission acpmux-asks-stack">
          <PermissionPanel
            state={state}
            working
            onRespond={() => {}}
            onRetry={() => {}}
            onRevoke={() => {}}
            onRefresh={() => {}}
          />
        </div>
      </div>
    </section>,
  );
