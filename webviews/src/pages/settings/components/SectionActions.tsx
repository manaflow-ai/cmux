// The registry buttons at the end of a section (Welcome Checklist, Make Default Terminal, Import
// from Browser, Reload Configuration, ...), as the Swift window showed them. The app gives their
// titles and availability; a press runs the action (cmux.app.action.run).
import { useCallback, useState } from "react";
import { useStore } from "../context";

type SectionAction = { id: string; title: string; enabled: boolean };

export function SectionActions({ section }: { section: string }) {
  // A new section is a new list (its own read on mount).
  return <SectionActionList key={section} section={section} />;
}

function SectionActionList({ section }: { section: string }) {
  const store = useStore();
  const [actions, setActions] = useState<SectionAction[]>([]);
  const mounted = useCallback(
    (node: HTMLDivElement | null) => {
      if (node) void store.sectionActions(section).then(setActions);
    },
    [store, section],
  );
  return (
    <div ref={mounted} data-section-actions={section}>
      {actions.length > 0 && (
        <section className="group">
          <div className="section-actions">
            {actions.map((action) => (
              <button
                type="button"
                key={action.id}
                className="button"
                data-action={action.id}
                disabled={!action.enabled}
                onClick={() => store.runSectionAction(action.id)}
              >
                {action.title}
              </button>
            ))}
          </div>
        </section>
      )}
    </div>
  );
}
