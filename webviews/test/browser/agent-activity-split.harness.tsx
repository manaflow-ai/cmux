// Browser harness for test/agent-activity-split.test.ts: the Agent Activity page's split view over
// the gallery's three-agent fixture (pages.agent-activity, variant `split`), with the page's styles.
import "../../src/pages/shared/desktop";
import "../../src/agent-activity/styles.css";
import { createRoot } from "react-dom/client";
import entry from "../../src/agent-activity/agent-activity.gallery";

const Gallery = await entry.load();
createRoot(document.getElementById("root")!).render(<Gallery {...entry.variants.split!.props!} />);
