import { AgentMark } from "../../../agent-session/shared/AgentMark";
import { Icon } from "../icons";
import type { CatalogProvider } from "../providerCatalog";

/** A provider's mark with no tile: 16 px in a row and in the picker (the + Connect glyph's box), 24 px in a dialog. */
export function ModelProviderMark({ mark, large = false }: { mark: CatalogProvider["mark"]; large?: boolean }) {
  const size = large ? 24 : 16;
  return (
    <span className="models-provider-mark" data-large={large ? "" : undefined} aria-hidden="true">
      {"agent" in mark ? <AgentMark agent={mark.agent} size={size} /> : <Icon name={mark.icon} />}
    </span>
  );
}
