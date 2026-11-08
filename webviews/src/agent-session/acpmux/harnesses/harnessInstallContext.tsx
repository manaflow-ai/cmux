// The pane's one-click harness install (cmux#38191), for the composer chips' model picker. The pane
// provides it only for a chat on this Mac: a harness installs into this Mac's login shell, and
// acpmux on this Mac looks for it again, so a chat on a peer or in the cloud keeps the Harnesses
// page's Install… instead. The install and its prompt belong to the pane, not to the composer that
// asked: a hidden install keeps running when the composer goes away (a New Tab that became a chat,
// the Harnesses page over it), and its pick still lands.
import { createContext, type ReactNode, useContext, useMemo } from "react";
import type { Native } from "./harnessInstall";
import { HarnessInstallDialog } from "./HarnessInstallDialog";
import { type HarnessInstallTarget, useHarnessInstall } from "./useHarnessInstall";

export type HarnessInstaller = {
  /// Opens the install prompt for `target`; `pick` runs once it is installed. `cwd`: where the
  /// command runs (the chat's folder).
  request(target: HarnessInstallTarget, pick?: () => void, cwd?: string): void;
  /// Another pick was made: a hidden install no longer makes its pick when it ends.
  cancelPick(): void;
};

export const HarnessInstallContext = createContext<HarnessInstaller | undefined>(undefined);

export const useHarnessInstaller = () => useContext(HarnessInstallContext);

/// The pane's installer and its prompt. `native`: the host calls an install makes (`shell.run`,
/// `shell.read`, `shell.stop`, `tab.open`), with `harness.health` answered by this Mac's acpmux
/// (App.tsx's `harnessesNative`). `refreshCatalog` reads the harness catalog again once acpmux
/// has looked for harnesses again. No `native`: no installer (a chat on another machine).
export function HarnessInstallProvider({
  native,
  refreshCatalog,
  children,
}: {
  native?: Native;
  refreshCatalog?(): Promise<void>;
  children: ReactNode;
}) {
  const install = useHarnessInstall({ callNative: native ?? noInstaller, refreshCatalog });
  const { request, cancelPick } = install;
  const value = useMemo(() => (native ? { request, cancelPick } : undefined), [native, request, cancelPick]);
  return (
    <HarnessInstallContext.Provider value={value}>
      {children}
      {install.state && (
        <HarnessInstallDialog
          state={install.state}
          onInstall={install.install}
          onCancel={install.dismiss}
          {...(install.state.target.docsUrl ? { onSetupGuide: install.setupGuide } : {})}
        />
      )}
    </HarnessInstallContext.Provider>
  );
}

/// The host calls with no installer: never reached, since the picker then offers no install pick.
// l10n-allow: a developer error, never shown
const noInstaller = () => Promise.reject(new Error("no harness installer"));
