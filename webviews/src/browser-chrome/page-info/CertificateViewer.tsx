// Page Info's certificate viewer window: a General tab (Issued To, Issued By, Validity Period,
// SHA-256 Fingerprints) and a Details tab (hierarchy, fields, field value, Export). The web twin of
// the native CertificateViewerWindow and CertificateDetailsView; Export asks the host
// (PageInfoWindows) for its native save panel.
import { useState } from "react";
import type { Strings } from "../../pages/shared/i18n";
import { Button } from "../../ui/Button";
import { Listbox } from "../../ui/Listbox";
import { Select } from "../../ui/Select";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "../../ui/Tabs";
import {
  certificateFields,
  generalSections,
  hierarchyName,
  type CertificateField,
  type CertificateFormatOptions,
} from "./certificate";
import { WindowFrame } from "./PageInfoWindowParts";
import { pageInfoStrings } from "./strings";
import type { CertificateInfo, CertificateState, PageInfoWindowCommand } from "./windows";

/**
 * - `list` (recommended): General and Details tabs, Details listing every field with its value, so
 *   nothing hides behind a pick and every value can be selected and copied.
 * - `tabs`: today's native viewer (pick a field in Details to read its value under the list).
 * - `sheet`: General and every field on one scrolling sheet, no tabs.
 */
export type CertificateViewerLook = "list" | "tabs" | "sheet";

export type CertificateViewerProps = {
  state: CertificateState;
  onCommand: (command: PageInfoWindowCommand) => void;
  look?: CertificateViewerLook;
  strings?: Strings;
  /** Tests and the gallery pin the zone dates format in. */
  format?: CertificateFormatOptions;
};

function General({
  certificate,
  strings,
  format,
}: {
  certificate: CertificateInfo;
  strings: Strings;
  format: CertificateFormatOptions;
}) {
  return (
    <div className="piw-grid">
      {generalSections(certificate, strings, format).map((section) => (
        <FieldGrid key={section.id} title={section.title} rows={section.rows} monospace={section.monospace} />
      ))}
    </div>
  );
}

function FieldGrid({ title, rows, monospace }: { title?: string; rows: CertificateField[]; monospace?: boolean }) {
  return (
    <>
      {title && <h3 className="piw-title">{title}</h3>}
      {rows.map((row) => (
        <div key={row.id} className="piw-grid-row" data-row-id={row.id}>
          <span className="piw-grid-label">{row.label}</span>
          <span className={monospace ? "piw-grid-value piw-mono" : "piw-grid-value"}>{row.value}</span>
        </div>
      ))}
    </>
  );
}

function Details({
  chain,
  look,
  strings,
  format,
  send,
}: {
  chain: CertificateInfo[];
  look: CertificateViewerLook;
  strings: Strings;
  format: CertificateFormatOptions;
  send: (command: PageInfoWindowCommand) => void;
}) {
  const t = strings.t;
  const [index, setIndex] = useState(0);
  const [field, setField] = useState(0);
  const certificate = chain[Math.min(index, chain.length - 1)]!;
  const fields = certificateFields(certificate, strings, format);
  const chosen = fields[Math.min(field, fields.length - 1)];
  return (
    <div className="piw-details">
      <h3 className="piw-title">{t("pageInfo.viewer.hierarchy")}</h3>
      <Select
        value={String(index)}
        label={t("pageInfo.viewer.hierarchy")}
        closeOnPick
        options={chain.map((entry, depth) => ({
          value: String(depth),
          // Leaf to root, each one step further in (no-break spaces, as the native menu indents).
          label: "\u00a0\u00a0".repeat(depth) + hierarchyName(entry),
        }))}
        onChange={(value) => {
          setIndex(Number(value));
          setField(0);
        }}
      />
      <h3 className="piw-title">{t("pageInfo.viewer.fields")}</h3>
      {look === "tabs" ? (
        <>
          {/* Up and Down (or the pointer) pick the field whose value shows under the list. */}
          <Listbox
            key={index}
            className="piw-fields"
            items={fields}
            getKey={(entry) => entry.id}
            textValue={(entry) => entry.label}
            renderItem={(entry) => entry.label}
            label={t("pageInfo.viewer.fields")}
            autoFocus={false}
            onActiveIndexChange={setField}
            onOpen={(entry) => setField(fields.indexOf(entry))}
          />
          <h3 className="piw-title">{t("pageInfo.viewer.fieldValue")}</h3>
          <pre className="piw-value piw-mono" aria-label={t("pageInfo.viewer.fieldValue")}>
            {chosen?.value ?? ""}
          </pre>
        </>
      ) : (
        <div className="piw-grid">
          <FieldGrid rows={fields} />
        </div>
      )}
      <Button size="sm" onClick={() => send({ type: "exportCertificate", index })}>
        {t("pageInfo.viewer.export")}
      </Button>
    </div>
  );
}

export function CertificateViewer({
  state,
  onCommand,
  look = "list",
  strings = pageInfoStrings(),
  format = {},
}: CertificateViewerProps) {
  const t = strings.t;
  const leaf = state.chain[0];
  const close = () => onCommand({ type: "close" });
  const label = leaf ? hierarchyName(leaf) : t("pageInfo.viewer.none");
  const failure = state.failure && (
    <p className="piw-caption piw-danger">{strings.format("pageInfo.viewer.failed", state.failure)}</p>
  );
  if (!leaf) {
    return (
      <WindowFrame look={look} label={label} onClose={close}>
        <p className="piw-muted">{t("pageInfo.viewer.none")}</p>
        {failure}
      </WindowFrame>
    );
  }
  const general = <General certificate={leaf} strings={strings} format={format} />;
  const details = <Details chain={state.chain} look={look} strings={strings} format={format} send={onCommand} />;
  if (look === "sheet") {
    return (
      <WindowFrame look={look} label={label} onClose={close}>
        {general}
        <div className="piw-section">{details}</div>
        {failure}
      </WindowFrame>
    );
  }
  return (
    <WindowFrame look={look} label={label} onClose={close}>
      <Tabs className="piw-tabs" variant="segmented" defaultValue="general">
        <TabsList>
          <TabsTrigger value="general">{t("pageInfo.viewer.general")}</TabsTrigger>
          <TabsTrigger value="details">{t("pageInfo.viewer.details")}</TabsTrigger>
        </TabsList>
        {/* Both panels share one cell, so switching tabs never resizes the window. */}
        <div className="piw-panels">
          <TabsContent value="general" keepMounted>
            {general}
          </TabsContent>
          <TabsContent value="details" keepMounted>
            {details}
          </TabsContent>
        </div>
      </Tabs>
      {failure}
    </WindowFrame>
  );
}
