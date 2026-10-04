// The first-party pages the shell can mount, by host page id (PageDescriptor.id in Swift). Each
// entry is its own chunk; the shell preloads them after its first idle moment. Third-party pages
// never load in the shell.
import type { ShellPage } from "./shell";

export const SHELL_PAGES: readonly ShellPage[] = [
  { id: "cmux.icon-picker", load: () => import("../icon-picker/shellEntry") },
  // A page that only exposes its context (the host's reset and claim tests and the claim bench).
  { id: "cmux.shell.probe", load: () => import("./probe") },
];
