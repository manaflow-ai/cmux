// A prompt's bubble, with Copy and Edit under it (cx-ncc.60).
import type { AcpmuxRow } from "../model";

export function UserBubble({ row, text }: { row: AcpmuxRow; text: string }) {
  void row;
  return <div className="cv-user__bubble selectable">{text}</div>;
}
