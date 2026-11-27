// PROPOSED embed contract `cmux.ui.embed` (app platform critique C3).
// Vendored copy; identical in first-party-apps/{diffs,codemirror}.
//
// An app asks the shell to mount another app's implementation of an interface
// inside its own pane. The shell picks the implementation (the user's default
// for the interface and type, else `prefer`), passes it handles only, and
// returns an embed handle the caller places with a scene node `Embed`.

export type EmbedHandle = string

export interface EmbedCreateParams {
  /** Interface name with major version, for example `cmux.editor/1`. */
  interface: string
  /** Interface props (for `cmux.editor/1`: EditorProps). Handles only, no paths. */
  props: Record<string, unknown>
  /** Preferred implementation app id; the user's open-with default wins. */
  prefer?: string
  /** Minimum height in points the caller reserves. */
  minHeight?: number
}

export interface EmbedCreateResult {
  embed: EmbedHandle
  /** The app that implements it, for display ("Shown with CodeMirror"). */
  app: string
  capabilities: string[]
}

export interface EmbedUpdateParams { embed: EmbedHandle; props: Record<string, unknown> }
export interface EmbedDestroyParams { embed: EmbedHandle }

/** Stream `ui.embed.event` with filter `{embed}`: the interface's events. */
export interface EmbedEvent { embed: EmbedHandle; event: { type: string; [k: string]: unknown } }

/** `ui.implementations.list {interface}`: installed implementations, for an "Edit with" menu. */
export interface ImplementationInfo { app: string; name: string; isDefault: boolean; capabilities: string[] }
