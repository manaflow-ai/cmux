// The pane's one-click harness install (cmux#38191), for the composer chips' model picker. The pane
// provides it only for a chat on this Mac: a harness installs into this Mac's login shell, and
// acpmux on this Mac looks for it again, so a chat on a peer or in the cloud keeps the Harnesses
// page's Install… instead.
import { createContext, useContext } from "react";
import type { Native } from "./harnessInstall";

export type HarnessInstaller = {
  /// The host calls an install makes (`shell.run`, `shell.read`, `shell.stop`, `tab.open`), with
  /// `harness.health` answered by this Mac's acpmux (App.tsx's `harnessesNative`).
  native: Native;
  /// Reads the harness catalog again once acpmux has looked for harnesses again.
  refreshCatalog?(): Promise<void>;
};

export const HarnessInstallContext = createContext<HarnessInstaller | undefined>(undefined);

export const useHarnessInstaller = () => useContext(HarnessInstallContext);
