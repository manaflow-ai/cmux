import { installPageSeen } from "../shared/pageSeen";
import { mountAcpmux } from "./mountModel";

// Before the pane mounts: the host may say at once that nobody sees this page (the New Tab spare).
installPageSeen();
mountAcpmux();
