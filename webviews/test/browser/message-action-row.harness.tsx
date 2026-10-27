import { createRoot } from "react-dom/client";
import { MessageActionExamples } from "../../src/agent-session/acpmux/conversation/MessageActionRow.gallery";
import "../../src/pages/shared/desktop.css";
import "../../src/ui/popupSurface.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "../../src/agent-session/acpmux/conversation/conversation.css";
import "../../src/agent-session/acpmux/modelPicker.css";

globalThis.__cmuxPaneStrings = (await import("../../src/agent-session/acpmux/generated/strings.json")).default;

createRoot(document.getElementById("root")!).render(<MessageActionExamples />);
