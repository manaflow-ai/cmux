// l10n-allow-file: Slack is a product name; the channel name is user content.
import type { SlackThreadSource } from "./slackThread";

export function SlackThreadLabel({ source }: { source?: SlackThreadSource }) {
  if (!source) return null;
  const label = `Slack · #${source.channelName}`;
  return source.permalink ? (
    <a className="hc-slack-source" href={source.permalink} target="_blank" rel="noopener noreferrer">
      {label}
    </a>
  ) : (
    <span className="hc-slack-source">{label}</span>
  );
}
