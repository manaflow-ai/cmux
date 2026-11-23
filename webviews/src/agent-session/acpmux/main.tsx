// First: the pane asks the host for its handshake before the rest of its modules evaluate and
// React's first commit (earlyHandshake.ts). Keep this import first and its graph light.
import "./earlyHandshake";
import { installBrowserHost } from "./browser/host";
import { mountAcpmux } from "./mountModel";

installBrowserHost();
mountAcpmux();
