// The composer right-click's choice of where every attachment shows (Leo, 2026-11-09: "In the
// right-click menu for the composer ... all attachments in line, or all attachments at the top like
// normal"): two checked items over `agentPane.attachmentView` (composerSettings.ts), the same
// setting Settings shows as Attachment View. "Attachments Inline" is `inline`, the default: each
// attachment in the text where it was added. "Attachments at Top" is `strip`: every attachment in
// one row over the text, as common chat apps draw it. Either way every kind (an image, a video, a
// file, a screenshot, a Pasted text chip) is in the same one place. The "both" view a cmux-next.json
// can still set checks neither item; picking one replaces it.
import type { ContextMenuItem } from "../../../ui/ContextMenu";
import { COMPOSER_LABELS } from "../composerModel";
import { type AttachmentView, setAttachmentView } from "../composerSettings";
import type { Translate } from "../i18n";

export function attachmentViewMenu(
  view: AttachmentView,
  t: Translate,
  pick: (next: AttachmentView) => void = setAttachmentView,
): ContextMenuItem[] {
  return [
    {
      id: "attachmentsInline",
      label: t(COMPOSER_LABELS.attachmentsInline),
      checked: view === "inline",
      separatorBefore: true,
      onSelect: () => pick("inline"),
    },
    {
      id: "attachmentsTop",
      label: t(COMPOSER_LABELS.attachmentsTop),
      checked: view === "strip",
      onSelect: () => pick("strip"),
    },
  ];
}
