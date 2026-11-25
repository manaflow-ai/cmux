import { createRoot } from "react-dom/client";
import { Thinking } from "../../src/agent-session/acpmux/conversation/Thinking";
import "../../src/pages/shared/desktop.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "../../src/agent-session/acpmux/conversation/spinner.css";
import "../../src/agent-session/acpmux/conversation/conversation.css";
const now = Date.now();
createRoot(document.getElementById("root")!).render(
  <div style={{ padding: 16 }}>
    <Thinking since={now - 9000} doing="Ran git log --format=%H origin/main | head -1 | sha[0:10] and a longer tail of words" doingAt={now - 5000} untimed below />
  </div>,
);
const st = document.createElement("style");
st.textContent = `.cv-shimmer__band{animation:none!important;transform:none!important;-webkit-mask-image:none!important;mask-image:none!important}.cv-shimmer__lit{animation:none!important;transform:none!important}` + (location.search.includes("before") ? `.cv-shimmer__row > .cv-thinking.is-shimmer{position:static!important}` : "");
document.head.append(st);
