// PROPOSED platform interface: documents (app platform critique C2).
// Vendored copy. first-party-apps/{diffs,codemirror}/src/interfaces/*.ts
// are identical files (a test in each app checks this) until the platform
// generates them into cmux-app.d.ts.
//
// A document is owned by one writer (the document host on the machine that
// owns the bytes) and edited by any number of views. Views apply edits at once
// and send them with the revision they are based on; the owner rejects a stale
// edit and the view rebases, then resends.

/** Opaque document handle (`doc_…`). Grants edit and view rights for one document only. */
export type DocHandle = string

/** Owner revision: a counter plus a content hash. Compare with `sameRevision`. */
export interface DocRevision {
  counter: number
  hash: string
}

export const sameRevision = (a: DocRevision | null | undefined, b: DocRevision | null | undefined) =>
  !!a && !!b && a.counter === b.counter && a.hash === b.hash

/** UTType identifier plus an editor language id (`typescript`, `markdown`, `plaintext`). */
export interface DocType {
  uti: string
  language: string
}

export interface DocInfo {
  doc: DocHandle
  /** `file://host/path`, `cmux-fs://<provider>/<root>/<path>`, `note://<id>`, `untitled:<n>`. */
  uri: string
  /** Display name (last path component, or the note title). */
  name: string
  type: DocType
  encoding: string
  lineEnding: "lf" | "crlf"
  revision: DocRevision
  /** Owner's dirty flag: the buffer differs from the last saved revision. Same on every device. */
  dirty: boolean
  /** The owner refuses edits (permissions, a read-only provider, or a large file). */
  readOnly: boolean
  readOnlyReason?: "permissions" | "provider" | "largeFile" | "grant"
  /** The disk changed while the buffer was dirty; set until resolved. */
  conflict: DocConflict | null
}

export interface DocConflict {
  diskRevision: DocRevision
  bufferRevision: DocRevision
}

/**
 * One replacement in UTF-16 offsets. A list of edits applies in order, each
 * against the text the previous one produced (the first against the base
 * revision). Insert: from == to. Delete: text == "".
 */
export interface TextEdit {
  from: number
  to: number
  text: string
}

// Operations (catalog family `document`, owner: the document host).

export interface DocumentOpenParams { uri?: string; doc?: DocHandle }
export interface DocumentOpenResult { info: DocInfo; text: string }

export interface DocumentEditParams { doc: DocHandle; base_revision: DocRevision; edits: TextEdit[] }
export interface DocumentEditResult { revision: DocRevision; dirty: boolean }

export interface DocumentSaveParams { doc: DocHandle; revision: DocRevision; overwrite_disk?: boolean }
export interface DocumentSaveResult { revision: DocRevision; dirty: false }

export interface DocumentRevertParams { doc: DocHandle }
export interface DocumentRevertResult { info: DocInfo; text: string }

export interface DocumentCloseParams { doc: DocHandle }

/** Reads the text of an older revision kept by the owner (conflict compare, diff base). */
export interface DocumentReadParams { doc: DocHandle; revision: DocRevision }
export interface DocumentReadResult { text: string }

// Events (stream `document.changed` / `document.conflict`, filter `{doc}`).

export interface DocumentChangedEvent {
  doc: DocHandle
  /** Revision the edits apply to. */
  base_revision: DocRevision
  revision: DocRevision
  edits: TextEdit[]
  dirty: boolean
  /** `view:<id>` for a view's own edits, `disk` for an external change, `agent:<id>`, `app:<id>`. */
  origin: string
}

export interface DocumentConflictEvent {
  doc: DocHandle
  disk_revision: DocRevision
  buffer_revision: DocRevision
}

/** Error codes the owner returns. */
export const DOC_ERRORS = {
  stale: "document.revision_mismatch",
  conflict: "document.conflict",
  readOnly: "document.read_only",
  notFound: "document.not_found",
  tooLarge: "document.too_large"
} as const
