// A row's tool lines (`.cv-tools`), with the line the reader opened kept where it is on screen when a
// new call regroups the row's folds (keepOpenedLineModel.ts). A class, for `getSnapshotBeforeUpdate`:
// the one point at which the old lines are still drawn and the regrouped ones are about to be. It
// reads them only when the row's shape (its groups and runs) changed, never for a call's streamed
// output, and only the row's own opened lines.
import { Component, createRef, type ReactNode } from "react";
import { keepOpenedLine, openedLineAt, type OpenedLine } from "./keepOpenedLineModel";

export class KeepOpenedLine extends Component<{ shape: string; children: ReactNode }> {
  private box = createRef<HTMLDivElement>();

  getSnapshotBeforeUpdate(previous: Readonly<{ shape: string }>): OpenedLine | null {
    if (previous.shape === this.props.shape) return null;
    return openedLineAt(this.box.current) ?? null;
  }

  componentDidUpdate(_props: unknown, _state: unknown, line: OpenedLine | null): void {
    if (line) keepOpenedLine(this.box.current, line);
  }

  render() {
    return (
      <div ref={this.box} className="cv-tools">
        {this.props.children}
      </div>
    );
  }
}
