import { installBrowserHost } from "./browser/host";
import { mountAcpmux } from "./mountModel";

performance.mark("diag:main-eval");
installBrowserHost();
mountAcpmux();
