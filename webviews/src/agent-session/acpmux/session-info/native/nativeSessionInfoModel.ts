import { type Translate } from "../../i18n";
import { sectionOrder } from "../sectionOrder";
import { type NativeInfoSection } from "./model";

/// Sections retain the person's single order, including drags across the three groups.
export function orderSections(sections: readonly (NativeInfoSection | undefined)[], t: Translate): NativeInfoSection[] {
  const byId = new Map(sections.flatMap((section) => (section ? [[section.id, section] as const] : [])));
  return sectionOrder().flatMap((id) => {
    const section = byId.get(id);
    return section
      ? [
          {
            ...section,
            reorderable: true,
            reorderLabel: t("sessionInfo.reorderSection", { section: section.title }),
          },
        ]
      : [];
  });
}
