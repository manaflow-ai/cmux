import { installBrowserHost } from "./browser/host";
// PROBE import { installHiddenRebuild } from "./hiddenRebuild";
import { mountAcpmux } from "./mountModel";

installBrowserHost();
mountAcpmux();
// HIDDEN-REBUILD: a hidden chat page that grew live rebuilds its document (hiddenRebuild.ts).
// PROBE: off to A/B the bench load (revert next commit).
// installHiddenRebuild();
