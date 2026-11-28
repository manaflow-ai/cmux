// RFD 0080's per-agent Computer panel ("Computer details" in the popover): where this agent runs,
// its size and sleep, the minutes it was awake today, the history of its computers and why each
// change happened, and the "What survives what" table. Pure presentation of ComputerPanelProps; the
// daemon decides every value. Words come from the catalog (computerPanel.*), no vendor names.
import "./computerPanel.css";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import {
  awakeRow,
  type ComputerPanelProps,
  historyLine,
  homeText,
  sizeRow,
  sleepRow,
  survivesLine,
  survivesRows,
} from "./computerPanelModel";
import { SURVIVES_COLUMNS } from "./survivesTable";

export type SurvivesLayout = "list" | "table" | "collapsible";
export type ComputerPanelViewProps = ComputerPanelProps & {
  survives_layout?: SurvivesLayout;
  locale?: string;
  time_zone?: string;
};

function PinIcon() {
  return <Icon name="state.pinned" size={12} selected className="computer-panel-pin" />;
}

function Row({ label, pinned, children }: { label: string; pinned?: boolean; children: string }) {
  return (
    <div className="computer-panel-row">
      <dt>{label}</dt>
      <dd>
        {pinned ? <PinIcon /> : null}
        {children}
      </dd>
    </div>
  );
}

function SurvivesTable({ rows }: { rows: ReturnType<typeof survivesRows> }) {
  const t = useT();
  return (
    <table className="computer-panel-table">
      <thead>
        <tr>
          <th scope="col">{t("computerPanel.column.event")}</th>
          {SURVIVES_COLUMNS.map((c) => (
            <th key={c} scope="col">
              {t(`computerPanel.column.${c}`)}
            </th>
          ))}
        </tr>
      </thead>
      <tbody>
        {rows.map((row) => (
          <tr key={row.event}>
            <th scope="row">{t(`computerPanel.event.${row.event}`)}</th>
            {SURVIVES_COLUMNS.map((c) => {
              const cell = row.cells[c];
              return (
                <td key={c} data-value={cell.value}>
                  <span className="computer-panel-value">{t(`computerPanel.value.${cell.value}`)}</span>
                  {cell.note ? <span className="computer-panel-note">{t(cell.note)}</span> : null}
                </td>
              );
            })}
          </tr>
        ))}
      </tbody>
    </table>
  );
}

function SurvivesList({ rows }: { rows: ReturnType<typeof survivesRows> }) {
  const t = useT();
  return (
    <ul className="computer-panel-survives-list">
      {rows.map((row) => (
        <li key={row.event}>
          <strong>{t(`computerPanel.event.${row.event}`)}</strong>
          <span>{survivesLine(row, t)}</span>
        </li>
      ))}
    </ul>
  );
}

function Survives({ layout, rows }: { layout: SurvivesLayout; rows: ReturnType<typeof survivesRows> }) {
  const t = useT();
  const body = layout === "table" ? <SurvivesTable rows={rows} /> : <SurvivesList rows={rows} />;
  if (layout === "collapsible") {
    return (
      <details className="computer-panel-section">
        <summary>{t("computerPanel.survives.title")}</summary>
        {body}
      </details>
    );
  }
  return (
    <section className="computer-panel-section">
      <h3>{t("computerPanel.survives.title")}</h3>
      {body}
    </section>
  );
}

export function ComputerPanel(props: ComputerPanelViewProps) {
  const t = useT();
  const format = { t, locale: props.locale, timeZone: props.time_zone };
  const size = sizeRow(props, t);
  const sleep = sleepRow(props.sleep, format);
  return (
    <section className="computer-panel" aria-label={t("computerPanel.title", { name: props.agent_name })}>
      <h2>{t("computerPanel.title", { name: props.agent_name })}</h2>
      <dl className="computer-panel-rows">
        <Row label={t("computerPanel.row.where")}>{homeText(props.home, t)}</Row>
        <Row label={t("computerPanel.row.size")} pinned={size.pinned}>
          {size.text}
        </Row>
        <Row label={t("computerPanel.row.sleep")} pinned={sleep.pinned}>
          {sleep.text}
        </Row>
        <Row label={t("computerPanel.row.awake")}>{awakeRow(props, t)}</Row>
        <Row label={t("computerPanel.row.session")}>{props.session_id}</Row>
      </dl>
      <section className="computer-panel-section">
        <h3>{t("computerPanel.history.title")}</h3>
        {props.history.length === 0 ? (
          <p className="computer-panel-empty">{t("computerPanel.history.empty")}</p>
        ) : (
          <ol className="computer-panel-history">
            {props.history.map((e) => {
              const line = historyLine(e, format);
              return (
                <li key={`${e.at_ms}-${e.change}`}>
                  <time>{line.time}</time>
                  <span>{line.text}</span>
                  {line.vmId ? (
                    <code className="computer-panel-vm">{t("computerPanel.history.computer", { id: line.vmId })}</code>
                  ) : null}
                </li>
              );
            })}
          </ol>
        )}
      </section>
      <Survives layout={props.survives_layout ?? "list"} rows={survivesRows(props)} />
    </section>
  );
}
