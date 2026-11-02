import type { NativePopupEvent, NativePopupModel, NativePopupRow } from "./popupProtocol";

type Identity = { fingerprint: string; since: number; row: NativePopupRow };

/** One entry per live control, never a history of every descriptor sent while typing. */
export class NativePopupEventFence {
  private rows = new Map<string, Identity>();
  private search?: { fingerprint: string; since: number; field: NonNullable<NativePopupModel["search"]> };

  reset() {
    this.rows.clear();
    this.search = undefined;
  }

  update(model: NativePopupModel) {
    const next = new Map<string, Identity>();
    const visit = (rows: NativePopupRow[], ancestry: string[]) => {
      for (const row of rows) {
        if (row.disabled) continue;
        const fingerprint = JSON.stringify([
          ancestry,
          row.kind,
          row.kind === "action" ? row.value : undefined,
          // A toggle or choice rebuilt with a new state retires changes sent from the old one.
          row.kind === "toggle" ? row.checked : undefined,
          row.kind === "choice" ? row.value : undefined,
          row.completion,
          row.keepOpen,
          row.options?.map((option) => [option.id, option.disabled]),
          row.minimum,
          row.maximum,
          row.step,
          row.slider?.stops.map((stop) => stop.value),
        ]);
        const prior = this.rows.get(row.id);
        next.set(row.id, {
          fingerprint,
          since: prior?.fingerprint === fingerprint ? prior.since : model.revision,
          row,
        });
        for (const action of row.actions ?? []) {
          if (action.disabled) continue;
          const identity = JSON.stringify([fingerprint, row.id, "accessory", action.keepOpen]);
          const old = this.rows.get(action.id);
          next.set(action.id, {
            fingerprint: identity,
            since: old?.fingerprint === identity ? old.since : model.revision,
            row: { ...action, kind: "action" },
          });
        }
        if (row.children) visit(row.children, [...ancestry, row.id]);
      }
    };
    visit([...(model.rail ?? []), ...model.rows, ...(model.footer ?? [])], []);
    this.rows = next;
    if (model.search && !model.search.disabled) {
      const fingerprint = model.search.id;
      this.search = {
        fingerprint,
        since: this.search?.fingerprint === fingerprint ? this.search.since : model.revision,
        field: model.search,
      };
    } else this.search = undefined;
  }

  accepts(event: NativePopupEvent): boolean {
    const search = this.search && event.revision >= this.search.since ? this.search.field : undefined;
    const identity = event.id === undefined ? undefined : this.rows.get(event.id);
    const row = identity && event.revision >= identity.since ? identity.row : undefined;
    if (
      event.editSequence !== undefined &&
      event.type !== "search" &&
      !(event.type === "change" && row?.kind === "textField")
    )
      return false;
    // An edit at or below the sequence the descriptor already acknowledges is stale: newer text won.
    if (event.editSequence !== undefined) {
      const acknowledged = event.type === "search" ? search?.editSequence : row?.editSequence;
      if (acknowledged !== undefined && event.editSequence <= acknowledged) return false;
    }
    switch (event.type) {
      case "search":
        return search !== undefined && search.id === event.id && event.value !== undefined;
      case "submit":
        return (
          search?.submitOnReturn === true && event.value !== undefined && (event.id === undefined || row !== undefined)
        );
      case "complete":
        return (
          search?.completeOnTab === true &&
          row?.kind === "action" &&
          row.completion !== undefined &&
          row.completion === event.value
        );
      case "pick":
        return row?.kind === "action";
      case "highlight":
        return row !== undefined && !["separator", "section", "text"].includes(row.kind);
      case "change":
        if (row?.kind === "choice")
          return row.options?.some((option) => option.id === event.value && !option.disabled) === true;
        return row !== undefined && ["toggle", "slider", "textField"].includes(row.kind);
      case "dismiss":
        return true;
    }
  }
}
