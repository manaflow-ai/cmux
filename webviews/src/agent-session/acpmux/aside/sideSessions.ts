import { experimentArm } from "../../../experiments/experiment";
import { sideQuestion } from "./sideQuestion.experiment";

/// Side sessions (`/btw <question>` opens a read-only side session beside the chat): the one gate
/// every entry point reads. Until the Labs registry lands it is the side-question experiment; then
/// it becomes `useLabsFlag("sideSessions")`, a one-line swap here.
export function useSideSessions(): boolean {
  return experimentArm(sideQuestion) === "on";
}
