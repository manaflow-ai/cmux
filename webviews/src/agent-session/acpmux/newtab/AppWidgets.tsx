// The New Tab page's app widgets (`cmux.newtab.widget/1`): each installed, visible app that implements
// one draws its own scene in a quiet card under the composer (a clock, the weather, your pull
// requests). Nothing is drawn when no app implements one, so the page is unchanged by default.
import { useNewTabAppWidgets } from "../../../apps/scene/panels";
import { appSceneIcon } from "../../../apps/scene/SceneSymbol";
import type { PageClient } from "../../../pages/shared/pageClient";
import { Icon } from "../icons/Icon";

export function AppWidgets({ client }: { /** Gallery and test seam; the page host when omitted. */ client?: PageClient | null }) {
  const widgets = useNewTabAppWidgets(client);
  if (!widgets.length) return null;
  return (
    <div className="nt-app-widgets">
      {widgets.map((widget) => (
        <section key={widget.id} className="nt-app-widget" aria-label={widget.title}>
          <header className="nt-app-widget-title">
            {widget.symbol && <Icon name={appSceneIcon(widget.symbol)} size={12} />}
            <span>{widget.title}</span>
          </header>
          {widget.node}
        </section>
      ))}
    </div>
  );
}
