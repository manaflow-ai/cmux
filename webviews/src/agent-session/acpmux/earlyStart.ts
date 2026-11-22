// The app pane's entry imports this first: its handshake starts before the rest of the pane's modules
// evaluate (earlyHandshake.ts). A module of its own because imports evaluate before the importer's body.
import { startEarlyHandshake } from "./earlyHandshake";

startEarlyHandshake();
