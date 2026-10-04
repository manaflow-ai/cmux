// Small parts the detail sections share: the "Not available yet" note, a number field that submits on
// plain Return, and byte sizes.
import { useState, type KeyboardEvent, type ReactNode } from "react";
import type { Strings } from "../shared/i18n";
import { SECTION_OPS, type DetailSection, type MachineDetail } from "./detail";
import { plain } from "./model";
import type { CloudStore } from "./store";
import { format, L } from "./strings";

export interface SectionProps {
  store: CloudStore;
  machine: string;
  detail: MachineDetail;
  /** Ops the owner does not serve yet. */
  unavailable: readonly string[];
  strings: Strings;
}

export const isUnavailable = (unavailable: readonly string[], section: DetailSection) =>
  unavailable.includes(SECTION_OPS[section]);

export function Unavailable({ t }: { t: (key: string) => string }) {
  return <p className="cloud-muted cloud-unavailable">{t(L.unavailable)}</p>;
}

/** Calls `onKey` for plain Return (and Escape when given); chords never act (model.ts `plain`). */
export function plainKeys(onReturn: () => void, onEscape?: () => void) {
  return (event: KeyboardEvent) => {
    if (!plain(event)) return;
    if (event.key === "Enter") onReturn();
    else if (event.key === "Escape" && onEscape) onEscape();
    else return;
    event.preventDefault();
    event.stopPropagation();
  };
}

/** A port number field (1 to 65535) with a submit button; plain Return submits too. */
export function PortField({
  label,
  button,
  inputClass,
  buttonClass,
  before,
  onSubmit,
}: {
  label: string;
  button: string;
  inputClass: string;
  buttonClass: string;
  before?: ReactNode;
  onSubmit: (port: number) => void;
}) {
  const [value, setValue] = useState("");
  const port = Number(value);
  const valid = value !== "" && Number.isInteger(port) && port > 0 && port < 65536;
  const submit = () => {
    if (!valid) return;
    onSubmit(port);
    setValue("");
  };
  return (
    <span className="cloud-inline-form">
      {before}
      <input
        className={`cloud-input cloud-port-input ${inputClass}`}
        inputMode="numeric"
        placeholder={label}
        aria-label={label}
        value={value}
        onChange={(event) => setValue(event.target.value.replace(/[^0-9]/g, ""))}
        onKeyDown={plainKeys(submit)}
      />
      <button
        type="button"
        className={`cloud-button ${buttonClass}`}
        aria-label={label}
        aria-disabled={!valid}
        onClick={submit}
      >
        {button}
      </button>
    </span>
  );
}

export function formatBytes(bytes: number, strings: Strings): string {
  const { t, language } = strings;
  const number = (value: number) => new Intl.NumberFormat(language, { maximumFractionDigits: 1 }).format(value);
  if (bytes < 1024) return format(t(L.bytes), { value: number(bytes) });
  if (bytes < 1024 * 1024) return format(t(L.kilobytes), { value: number(bytes / 1024) });
  return format(t(L.megabytes), { value: number(bytes / (1024 * 1024)) });
}
