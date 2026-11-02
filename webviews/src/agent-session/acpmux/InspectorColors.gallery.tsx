// l10n-allow-file: public-safe gallery fixtures, not shipped UI.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import { chat } from "../../gallery/fixtures/acpmux";
import { Inspector } from "./Inspector";
import { AcpWireLog } from "./wire";

function InspectorColours() {
  const [wire] = useState(() => {
    const log = new AcpWireLog(
      () => 0,
      () => 0,
    );
    log.sent('{"id":1,"method":"session/load"}', "session/load", 1);
    log.received('{"id":1,"error":{"message":"Session unavailable"}}');
    log.received("Invalid fixture response");
    return log;
  });
  return <Inspector snapshot={chat([])} sessionEvents={() => []} onClose={() => undefined} wire={wire} />;
}

export default componentEntry({
  id: "agent-pane.inspector-colours",
  title: "ACP inspector error colours",
  area: "Agent pane",
  height: 360,
  widths: { narrow: 380, normal: 760, wide: 980 },
  covers: ["agent-session/acpmux/Inspector.tsx#Inspector"],
  load: async () => InspectorColours,
  styles: () => Promise.all([import("../shared/styles.css"), import("./styles.css")]),
  variants: {
    errors: {
      props: {},
      note: "Last error, error and invalid rows share the status failure colour. Hover Export and a row to inspect their shared tint.",
    },
  },
});
