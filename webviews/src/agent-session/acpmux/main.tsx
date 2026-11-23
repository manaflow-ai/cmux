import { installBrowserHost } from "./browser/host";
import { mountBrowserSignIn } from "./browser/signInGate";
import { mountAcpmux } from "./mountModel";

// A tab at `/app/` signs in as its own device first; the app's pane mounts at once.
const browser = installBrowserHost();
if (browser) mountBrowserSignIn(browser, () => mountAcpmux());
else mountAcpmux();
