import { useSyncExternalStore } from "react";
import { callNative } from "./callNative";
import { AddProjectDialog } from "./AddProjectPanel";
import { machineDirectoryHost, type MachineListing } from "./remoteMachineDirectory";

/// The folder chooser of a new chat on another machine: its Add folder… opens this dialog over that
/// machine's own disk (the host's `machine.folder.list`), never this Mac's open panel. One dialog at a
/// time; `chooseRemoteFolder` resolves with the picked path, or undefined when it is closed.
type Open = { machine: string; settle(path: string | undefined): void };
let open: Open | undefined;
const listeners = new Set<() => void>();
const change = (next: Open | undefined) => {
  open = next;
  listeners.forEach((listener) => listener());
};

export function chooseRemoteFolder(machine: string): Promise<string | undefined> {
  open?.settle(undefined);
  return new Promise((resolve) => {
    const entry: Open = {
      machine,
      settle: (path) => {
        if (open === entry) change(undefined);
        resolve(path);
      },
    };
    change(entry);
  });
}

const host = machineDirectoryHost((method, params) => callNative<MachineListing | undefined>(method, params));

export function RemoteFolderChooser() {
  const current = useSyncExternalStore(
    (listener) => {
      listeners.add(listener);
      return () => void listeners.delete(listener);
    },
    () => open,
  );
  if (!current) return null;
  return (
    <AddProjectDialog
      open
      machine={current.machine}
      host={host}
      onPick={(path) => current.settle(path)}
      onClose={() => current.settle(undefined)}
    />
  );
}
