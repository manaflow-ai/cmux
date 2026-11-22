// Where an attachment came from (Leo, 2026-10-29: "Also, I guess it's, like, you know, be
// interesting to add, like, attributions for screenshots and attachments and whatnot, right? I think,
// like, Spotlight has an interesting feature for that, where just at the top right, there's a little
// icon that says, Oh, hey, this came from Cmax, this came from Claude, or whatever."). The host says
// it (AttachmentSource.swift): a paste's pasteboard owner, a drop's dragging app, a file's own
// metadata, cmux's own captures. The page never guesses one: an unknown source is none.
import type { AttachmentSource, SourceKind } from "../attachments";
import { attachmentSource } from "../attachments";
import { postNative } from "../native";

/// How long the host may take to say where a drop's or paste's files came from; past it they have
/// no source (the chips never wait for it).
export const SOURCES_DEADLINE_MS = 1500;

type Call = (method: string, params: Record<string, unknown>) => Promise<unknown>;

/// The host's answer to `method`: the page's direct action when it has one (the gallery, a test), else the bridge.
export const callHost: Call = (method, params) => {
  const direct = window.cmuxAcpmuxActions?.[method];
  return direct ? Promise.resolve(direct(params)) : postNative(method, params);
};

/// The host's `chat.attach.source {kind, names, gestureAt}` answer for `files`: each file's source in
/// order, undefined for one it does not know (and for all of them from an older host, or past the
/// deadline: a late answer is dropped). `gestureAt`: when the page took the gesture (`Date.now()`,
/// the Mac's own clock, as the host's). The host answers only from a record made before it, so an ask
/// that reaches the host late never takes a newer gesture's record (AgentPaneDroppedPaths.swift).
export async function attachSources(
  kind: SourceKind,
  files: readonly File[],
  call: Call = callHost,
  gestureAt: number = Date.now(),
): Promise<(AttachmentSource | undefined)[]> {
  const none = files.map(() => undefined);
  if (files.length === 0) return none;
  let timer: ReturnType<typeof setTimeout> | undefined;
  const late = new Promise<undefined>((resolve) => {
    timer = setTimeout(() => resolve(undefined), SOURCES_DEADLINE_MS);
  });
  try {
    const answer = await Promise.race([
      call("chat.attach.source", { kind, names: files.map((file) => file.name), gestureAt }).catch(() => undefined),
      late,
    ]);
    const sources = (answer as { sources?: unknown } | null | undefined)?.sources;
    if (!Array.isArray(sources) || sources.length !== files.length) return none;
    return sources.map(attachmentSource);
  } finally {
    clearTimeout(timer);
  }
}
