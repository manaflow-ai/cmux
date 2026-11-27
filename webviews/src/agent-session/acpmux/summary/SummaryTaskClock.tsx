import { Clock } from "../../../ui/Typography";
import { formatDuration } from "../conversation/turns";
import { useNow } from "../subagents/subagentGroupModel";

export function RunningElapsed({ startedAt }: { startedAt: number }) {
  const now = useNow(true);
  return <Clock text={formatDuration(Math.max(0, now - startedAt))} />;
}
