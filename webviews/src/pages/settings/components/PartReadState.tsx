// A host-part card's place before its part is read, and its error when the read failed
// (store.ts `partRead`). A card whose part is not read yet holds its space with a placeholder row
// instead of drawing nothing; a failed read says so with Try Again instead of a silently missing
// card. A part that is read and none (the host has no such part) draws nothing: `null`.
import { Button } from "../../../ui/Button";
import type { PartRead } from "../store";
import { t } from "../strings";

type Props = {
  card: string;
  read: PartRead;
  onRetry: () => void;
  /** The failure's text; default "cmux didn't answer." (the host read itself failed). */
  message?: string;
  /** Try Again's title; default the page's own. */
  retryLabel?: string;
};

export function PartReadState(props: Props) {
  const { card, read } = props;
  if (read === "read") return null;
  return (
    <section
      className="group part-read"
      data-card-read={card}
      data-read={read}
      aria-busy={read === "pending" ? "true" : undefined}
    >
      <PartReadRows {...props} />
    </section>
  );
}

/** The placeholder row or the error row with Try Again, inside a group that already exists (a
 *  card's section whose own list is not read: Devices' Other Devices). */
export function PartReadRows({ card, read, onRetry, message, retryLabel }: Props) {
  if (read === "read") return null;
  if (read === "pending")
    return (
      <div className="rows">
        <div className="row" aria-hidden="true">
          <div className="row-label">
            <span className="part-read-bar part-read-title" />
            <span className="part-read-bar part-read-help" />
          </div>
        </div>
      </div>
    );
  return (
    <div className="rows">
      <div className="row">
        <div className="row-main">
          <div className="row-label">
            <div className="row-error" role="alert">
              {message ?? t("settingsPage.partRead.noAnswer")}
            </div>
          </div>
          <div className="row-control action-row-control">
            <Button type="button" className="button" data-part-retry={card} onClick={onRetry}>
              {retryLabel ?? t("settingsPage.tailnet.tryAgain")}
            </Button>
          </div>
        </div>
      </div>
    </div>
  );
}
