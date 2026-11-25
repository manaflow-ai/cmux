// The one disclosure caret every composer-hat row ends in: the Goal row's and the hat header's (cmux#51039;
// the person, 2026-11-23: "figure out why these caret icons are not the same": the Goal row drew a plain
// 24-unit ChevronDown at 14px while the hat drew the cropped row glyph, so their ink and stroke differed).
// One glyph, one size rule (subagents.css `.acpmux-hat-chevron`), so the two cannot drift apart again.
import { Icon } from "../icons/Icon";

export function HatChevron() {
  return <Icon name="disclosure.expanded" size={14} row className="acpmux-hat-chevron" />;
}
