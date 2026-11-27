import { installBrowserHost } from "./browser/host";
import { installHiddenRebuild } from "./hiddenRebuild";
import { mountAcpmux } from "./mountModel";

installBrowserHost();
mountAcpmux();
// HIDDEN-REBUILD: a hidden chat page that grew live rebuilds its document (hiddenRebuild.ts).
installHiddenRebuild();
