import { installBrowserHost } from "./browser/host";
import { mountAcpmux } from "./mountModel";
import { startEarlyConnect } from "./earlyConnect";

installBrowserHost();
// Before the first render: the host's `ready` and the bridge open run beside the mount (earlyConnect.ts).
startEarlyConnect();
mountAcpmux();
