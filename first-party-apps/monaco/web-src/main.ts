// Monaco app web pane entry: the shared controller with the Monaco adapter.
import "../src/shared/chrome.css"
import { createBridge, hostTransport } from "../src/shared/bridge.ts"
import { startEditor } from "../src/shared/controller.ts"
import { createMonacoAdapter } from "./adapter.ts"

const w = window as unknown as { __cmuxBridgeReceive?: (m: unknown) => void }
// Outside a cmux web pane nothing answers; the pane shows "No document".
const bridge = createBridge(hostTransport() ?? { post: () => undefined })
w.__cmuxBridgeReceive = (m) => bridge.receive(m as never)
startEditor(createMonacoAdapter(), bridge, document.getElementById("app")!, document)
