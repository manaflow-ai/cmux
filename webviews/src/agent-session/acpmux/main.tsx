import { callNative } from "./callNative";
import { watchInputEcho } from "./composerInputEcho";
import { mountAcpmux } from "./mountModel";

mountAcpmux();
// The first typed key that shows in the composer: the app's `agent_pane.input_echoed` launch mark.
watchInputEcho(document, { post: () => void callNative("pane.inputEchoed").catch(() => undefined) });
