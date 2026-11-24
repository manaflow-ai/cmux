import { Component, type FocusEventHandler, type ReactNode, type RefObject } from "react";
import { focusRoute } from "../../ui/focusRoute";
import type { DashboardItem } from "./checksModel";

interface Props {
  items: readonly DashboardItem[];
  listRef: RefObject<HTMLDivElement | null>;
  onFocus: FocusEventHandler<HTMLElement>;
  children: ReactNode;
}

/** Snapshot the actual focused control before React moves jobs between grid lines. Each line owns
 * its buttons, so moving a job to another line replaces its button even if the job is unchanged. */
export class DashboardList extends Component<Props> {
  getSnapshotBeforeUpdate(previous: Props): HTMLElement | null {
    const list = this.props.listRef.current;
    if (previous.items === this.props.items || !list) return null;
    const active = list.ownerDocument.activeElement;
    return active instanceof HTMLElement && active.dataset.focusKey && list.contains(active) ? active : null;
  }

  componentDidUpdate(_previous: Props, _state: unknown, previousControl: HTMLElement | null) {
    const list = this.props.listRef.current;
    if (!list || !previousControl || previousControl.isConnected) return;
    if (list.ownerDocument.activeElement !== list.ownerDocument.body) return;
    const { focusKey, shard } = previousControl.dataset;
    for (const control of list.querySelectorAll<HTMLElement>("[data-focus-key]")) {
      if (control.dataset.focusKey === focusKey && control.dataset.shard === shard) {
        focusRoute(control, "system", "restore the focused CI job after regrouping", { preventScroll: true });
        return;
      }
    }
  }

  render() {
    return (
      <div className="gh-ci-list" ref={this.props.listRef} onFocus={this.props.onFocus}>
        {this.props.children}
      </div>
    );
  }
}
