// The shell probe page: it renders nothing and exposes its context as `__cmuxShellProbe`, so the
// host's tests and the claim bench can act as a page (write storage, make calls, subscribe) and
// check that a reset leaves nothing behind. It has no namespace a provider serves.
import type { ShellContext } from "./shell";

export function mount(root: HTMLElement, ctx: ShellContext): { unmount(): void } {
  root.dataset.probe = "mounted";
  (globalThis as { __cmuxShellProbe?: ShellContext }).__cmuxShellProbe = ctx;
  return { unmount: () => undefined };
}
