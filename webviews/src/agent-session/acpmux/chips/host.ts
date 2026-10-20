// The chips' one way to the host: `postNative`, or a test's stand-in.
import { postNative } from "../native";

type Call = (method: string, params: Record<string, unknown>) => Promise<unknown>;
let call: Call = postNative;

/// Sends `method` to the host. A refusal (outside the roots, no gesture) changes nothing on
/// screen: the host's answer is the boundary, not the page's.
export function callChipHost(method: string, params: Record<string, unknown>): Promise<unknown> {
  // Outside the app (server render, a test without a host) the call itself can throw.
  return Promise.resolve()
    .then(() => call(method, params))
    .catch(() => undefined);
}

/// File reads keep the host's failure so Files and Changes can show their existing error UI.
export function readPathChip(path: string): Promise<unknown> {
  return Promise.resolve().then(() => call("link.readPath", { path }));
}

/// Tests replace the host.
export function setChipHost(next: Call | undefined): void {
  call = next ?? postNative;
}

type PathViewer = (path: string, opener?: HTMLElement) => void | Promise<void>;
let viewer: PathViewer | undefined;

/// A path chip's click: the chat's viewer while one is set (labs `chatViewer`, App.tsx), else the
/// host opens the path (a tab, a folder in Finder).
export function openPathChip(path: string, opener?: HTMLElement): void {
  if (viewer) void Promise.resolve(viewer(path, opener)).catch(() => undefined);
  else void callChipHost("link.openPath", { path });
}

/// The App sets the chat's viewer while `chatViewer` is on, and clears it.
export function setPathViewer(next: PathViewer | undefined): void {
  viewer = next;
}
