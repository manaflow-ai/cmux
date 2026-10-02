// Dev server entry (vite.config.acpmux-pane.mjs): the bundled pane inlines
// these stylesheets (scripts/cmux-next/build-agent-pane-web.sh); here Vite
// serves them with hot reload.
import "../shared/styles.css";
import "./styles.css";
import "./conversation/conversation.css";
import "./changes/changes.css";
import "./composerControls.css";
import "./composerStates.css";
import "./searchChats.css";
import "./markdownField.css";
import "./main";
