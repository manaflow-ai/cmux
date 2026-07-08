export type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
export type JsonObject = { [key: string]: Json };

export interface IdentifyResult {
  app: string;
  version: string;
  protocol: number;
  session: string;
  pid: number;
}

export interface EmptyResult {}
export interface SurfaceResult { surface: number }
export interface ReadScreenResult { text: string }
export interface VtStateResult { cols: number; rows: number; data: string }
export interface Size { cols: number; rows: number }

export type Layout =
  | { type: "leaf"; pane: number }
  | { type: "split"; dir: "right" | "down"; ratio: number; a: Layout; b: Layout };

export type Pane =
  | { id: number; name: string | null; active_tab: number; tabs: Tab[]; dead?: false }
  | { id: number; dead: true; name?: null; active_tab?: 0; tabs?: [] };

export interface Tab {
  surface: number;
  kind: "pty" | "browser" | string;
  browser_source: "external" | "launched" | null | string;
  name: string | null;
  title: string;
  size: Size | null;
  dead: boolean;
}

export interface Screen {
  id: number;
  name: string | null;
  active: boolean;
  active_pane: number;
  layout: Layout;
  panes: Pane[];
}

export interface Workspace {
  id: number;
  name: string;
  active: boolean;
  screens: Screen[];
}

export interface Tree {
  workspaces: Workspace[];
}

export type SubscribeEvent =
  | { event: "tree-changed" }
  | { event: "surface-output"; surface: number }
  | { event: "surface-resized"; surface: number; cols: number; rows: number }
  | { event: "surface-exited"; surface: number }
  | { event: "title-changed"; surface: number }
  | { event: "bell"; surface: number }
  | { event: "empty" }
  | UnknownEvent;

export type AttachEvent =
  | { event: "vt-state"; surface: number; cols: number; rows: number; data: string }
  | { event: "output"; surface: number; data: string }
  | { event: "resized"; surface: number; cols: number; rows: number; replay: string }
  | { event: "detached"; surface: number }
  | UnknownEvent;

export interface UnknownEvent {
  event: string;
  [key: string]: unknown;
}

export interface ClientOptions {
  socketPath?: string;
  session?: string;
  timeoutMs?: number;
  allowProtocolV6Attach?: boolean;
}

export interface NewTabOptions { pane?: number; cwd?: string; cols?: number; rows?: number }
export interface NewBrowserTabOptions { pane?: number; cols?: number; rows?: number }
export interface NewWorkspaceOptions { name?: string; cols?: number; rows?: number }
export interface NewScreenOptions { workspace?: number; cols?: number; rows?: number }
export interface SplitOptions { cols?: number; rows?: number }
export interface SendOptions { text?: string; bytes?: string | Uint8Array }
export interface SelectOptions { index?: number; delta?: number }
export interface SelectTabOptions extends SelectOptions { pane?: number }
