// The icon a row draws when no harness mark replaces it, in the agent's own stable tone
// (agentTones.ts), so a list of them tells apart (Leo, 2026-10-29: "the fact that there's all of
// these icons that are literally all the same icon, that's terrible ... If you don't have anything
// else, you can just randomize the colors or something"). Rows pass it as AgentMark's `fallback`,
// so a harness whose icon acpmux sends later still swaps it for the mark.
import { Icon } from "../icons/Icon";

export function TonedIcon({ name, size, tone, row }: { name: string; size: number; tone?: number; row?: boolean }) {
  const icon = <Icon name={name} size={size} row={row} />;
  if (tone === undefined) return icon;
  return (
    <span className="acpmux-toned-icon" data-agent-tone={tone}>
      {icon}
    </span>
  );
}
