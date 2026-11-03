// l10n-allow-file: gallery fixture (a synthetic avatar letter), not shipped UI.
// A synthetic uploaded agent avatar for gallery variants: the agent pane frame answers
// `agent.avatar` with it (a variant's `native`), as the app answers an upload (agentAvatar.ts).
export const UPLOADED_AVATAR =
  "data:image/svg+xml;base64," +
  btoa(
    '<svg xmlns="http://www.w3.org/2000/svg" width="96" height="96"><rect width="96" height="96" rx="20" fill="#e5734f"/>' +
      '<text x="48" y="64" font-family="Helvetica" font-size="52" font-weight="700" text-anchor="middle" fill="#fff">R</text></svg>',
  );

/// The host's change notice for each session in `ids` (as after Set Avatar… in another pane): the
/// cards and chips that draw them ask again, now that the variant's `native` answers the picture.
export function avatarsChanged(document: Document, ids: readonly string[]): void {
  const bridge = (document.defaultView as unknown as { cmuxAcpmuxBridge?: { agentAvatarChanged?(id: string): void } })
    .cmuxAcpmuxBridge;
  for (const id of ids) bridge?.agentAvatarChanged?.(id);
}
