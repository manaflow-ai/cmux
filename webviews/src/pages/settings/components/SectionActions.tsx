// The registry buttons at the end of a section (Welcome Checklist, Make Default Terminal, Import
// from Browser, Reload Configuration, ...), as the Swift window showed them. The app gives their
// titles and availability; a press runs the action (cmux.app.action.run).
import { useQuery } from "@tanstack/react-query";
import { useStore } from "../context";
import { sectionActionsQuery } from "../sectionQueries";

const NONE: never[] = [];

/** The section's buttons, from the query its route's loader (or a hover on its link) filled. */
export function SectionActions({ section }: { section: string }) {
  const store = useStore();
  const actions = useQuery(sectionActionsQuery(store, section)).data ?? NONE;
  return (
    <div data-section-actions={section}>
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
