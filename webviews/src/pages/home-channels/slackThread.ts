/** Display metadata on the root's `thread`, supplied by the hosted Slack bridge. */
export interface SlackThreadSource {
  source: "slack";
  channelName: string;
  permalink?: string;
}

/** Read only Slack display fields; transport ids and authorization remain with the owner. */
export function slackThreadSource(raw: unknown): SlackThreadSource | undefined {
  if (!raw || typeof raw !== "object") return undefined;
  const thread = raw as Record<string, unknown>;
  if (thread.source !== "slack" || typeof thread.channelName !== "string") return undefined;
  const channelName = thread.channelName.trim().replace(/^#/, "");
  if (!channelName) return undefined;
  const result: SlackThreadSource = { source: "slack", channelName };
  if (typeof thread.permalink !== "string") return result;
  try {
    const url = new URL(thread.permalink);
    if (
      url.protocol === "https:" &&
      (url.hostname === "slack.com" || url.hostname.endsWith(".slack.com")) &&
      !url.username &&
      !url.password &&
      !url.port
    )
      result.permalink = url.href;
  } catch {
    // Older or malformed metadata still names its source, without an unsafe link.
  }
  return result;
}
