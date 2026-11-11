// A host-part card's place before its part is read, and its error when the read failed
// (store.ts `partRead`). A card whose part is not read yet holds its space with a placeholder row
// instead of drawing nothing; a failed read says so with Try Again instead of a silently missing
// card. A part that is read and none (the host has no such part) draws nothing: `null`.
import { Button } from "../../../ui/Button";
import type { PartRead } from "../store";
import { t } from "../strings";

export function PartReadState({ card, read, onRetry }: { card: string; read: PartRead; onRetry: () => void }) {
  if (read === "read") return null;
  if (read === "pending")
    return (
      <section className="group part-read" data-card-read={card} data-read="pending" aria-busy="true">
        <div className="rows">
          <div className="row" aria-hidden="true">
            <div className="row-label">
              <span className="part-read-bar part-read-title" />
              <span className="part-read-bar part-read-help" />
            </div>
          </div>
        </div>
      </section>
    );
  return (
    <section className="group part-read" data-card-read={card} data-read="failed">
      <div className="rows">
        <div className="row">
          <div className="row-main">
            <div className="row-label">
              <div className="row-error" role="alert">
                {t("settingsPage.partRead.noAnswer")}
              </div>
            </div>
            <div className="row-control action-row-control">
              <Button type="button" className="button" data-part-retry={card} onClick={onRetry}>
                {t("settingsPage.tailnet.tryAgain")}
              </Button>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}
