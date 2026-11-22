// First, so its handshake goes out before the pane's other modules evaluate (earlyHandshake.ts).
import "./earlyStart";
import { mountAcpmux } from "./mountModel";

mountAcpmux();
