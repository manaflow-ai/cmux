// The agent pane's own stylesheets, in the order its page applies them. The page ships every sheet
// the pane imports: build-agent-pane-web.sh writes its one <style> from the import graph of this
// module and then main.tsx (scripts/agent-pane/bundle.mjs --css-inputs), in import order, so a
// component's own `import "./x.css"` ships with no list to update. The dev server (dev.tsx) and the
// gallery (dev-server/galleryHost.ts) load this module's sheets in the same order.
//
// Listed here: the sheets no component imports (the desktop layer, the base layer, the transcript
// and composer rules), and the component sheets whose place in the cascade the page held before
// its list came from imports. Leave a new component's sheet out: it ships after these, at its
// first import.
//
// desktop.css first: it defines the popup surface (--surface-popup) and type scale (R139).
import "../../pages/shared/desktop.css";
// The liquid glass next: a surface's own sheet (the composer's queue fill) must come after
// `.ui-glass`, not before it as desktop.ts's import would put it.
import "../../ui/glass/glass.css";
// The shared shimmer wave, which desktop.ts imports too.
import "../../ui/wave.css";
import "../shared/styles.css";
// One surface for every menu and popover (the pane does not load ui.css, which imports it).
import "../../ui/popupSurface.css";
import "../../ui/ghost.css";
import "../../ui/findPill.css";
import "../../ui/importCards.css";
import "../../theme/messages.css";
import "./styles.css";
import "./conversation/conversation.css";
import "./chips/chips.css";
import "./previewCard/previewCard.css";
// changes.css @imports git.css, which the page carries ahead of it (an @import never loads there).
import "./changes/changes.css";
import "./handoff/styles.css";
import "./checkpoints/styles.css";
import "./composerControls.css";
import "./composerStates.css";
import "./composerLocation.css";
import "./savedEnvironments.css";
import "./bottomStack.css";
import "./composerAttachments.css";
import "./composer/dropOverlay.css";
import "./markdownField.css";
import "./modelPicker.css";
import "./keys.css";
import "./summary/summary.css";
import "./subagents/subagents.css";
import "./header/header.css";
import "./needsYou/needsYou.css";
import "./newtab/screen.css";
import "./newtab/history.css";
import "./threadMinimap/threadMinimap.css";
import "./turnChanges/turnChanges.css";
import "./Inspector.css";
import "./inspector/inspector.css";
import "./inspector/ContextSection.css";
import "./dictation.css";
import "./addProject.css";
import "./harnesses/harnesses.css";
import "./replay/replay.css";
import "./offer/suggestedTasks.css";
import "./started/startedSessions.css";
import "./started/sessionHover.css";
import "./conversation/SubsessionCallCard.css";
import "./conversation/AgentMessageRow.css";
import "../../markdown-task-checkbox.css";
