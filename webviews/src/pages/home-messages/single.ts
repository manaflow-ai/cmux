// A conversation tab and the Chief panel host the Messages page for one conversation: the host's page
// route names it (`#/conversation/<id>`, HomeConversationPage.swift), and the page draws no list.

/** The one conversation of a conversation tab or the Chief panel (`#/conversation/<id>`, set by the
 * host's page route), or undefined: the docked Home's list and its open conversation. */
export function singleConversation(hash: string): string | undefined {
  const match = /^#\/conversation\/([^/?#]+)$/.exec(hash);
  if (!match?.[1]) return undefined;
  try {
    const id = decodeURIComponent(match[1]);
    return /^[A-Za-z0-9_.:-]{1,256}$/.test(id) ? id : undefined;
  } catch {
    return undefined;
  }
}
