// Pick people and Chiefs: one search field over a list of tall rows (avatar, name, a quiet Chief
// or Agent tag), each a checkbox. The arrow keys move between the field and the rows, Space
// toggles a row, Return submits the sheet. The picked ones stay at the top of the list in the
// order they were picked, so the person sees the choice while searching.
import { useMemo, useRef, useState, type KeyboardEvent } from "react";
import { KeyboardScope } from "../../ui/KeyboardScope";
import type { Strings } from "../shared/i18n";
import { Avatar } from "./Avatar";
import type { HomeParticipant } from "./types";
import "./peoplePickerLoading.css";

export interface PeoplePickerProps {
  people: readonly HomeParticipant[];
  picked: readonly string[];
  onPicked(picked: string[]): void;
  strings: Strings;
  /** Still reading the directory. */
  loading?: boolean;
}

export function PeoplePicker({ people, picked, onPicked, strings, loading }: PeoplePickerProps) {
  const { t, format } = strings;
  const initialLoading = loading === true && people.length === 0;
  const [query, setQuery] = useState("");
  const list = useRef<HTMLDivElement | null>(null);
  const shown = useMemo(() => {
    const needle = query.trim().toLocaleLowerCase();
    const byId = new Map(people.map((person) => [person.id, person]));
    const first = picked.flatMap((id) => (byId.has(id) ? [byId.get(id)!] : []));
    const rest = people.filter((person) => !picked.includes(person.id));
    return [...first, ...rest.filter((person) => !needle || person.name.toLocaleLowerCase().includes(needle))];
  }, [people, picked, query]);
  const toggle = (id: string) => onPicked(picked.includes(id) ? picked.filter((p) => p !== id) : [...picked, id]);
  // Up and Down walk the field and the rows (each row is a checkbox the browser focuses).
  const keys = (event: KeyboardEvent<HTMLDivElement>) => {
    // Return on a row submits the sheet (a checkbox has no implicit submission).
    const target = event.target as HTMLInputElement;
    if (event.key === "Enter" && target.type === "checkbox") {
      event.preventDefault();
      target.form?.requestSubmit();
      return;
    }
    if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
    const stops = [...(list.current?.querySelectorAll<HTMLInputElement>("input") ?? [])];
    const at = stops.indexOf(document.activeElement as HTMLInputElement);
    if (at < 0) return;
    event.preventDefault();
    stops[Math.min(Math.max(at + (event.key === "ArrowDown" ? 1 : -1), 0), stops.length - 1)]?.focus();
  };
  return (
    <KeyboardScope className="lg-picker" handleKeyDown={keys}>
      <div ref={list} className="lg-picker-inner">
        <input
          className="hc-link-field lg-picker-search"
          type="search"
          value={query}
          placeholder={t("sheet.search")}
          aria-label={t("sheet.search")}
          onChange={(event) => setQuery(event.target.value)}
        />
        <p className="lg-picker-count" aria-live="polite">
          {picked.length === 0
            ? ""
            : picked.length === 1
              ? t("sheet.selected.one")
              : format("sheet.selected.many", String(picked.length))}
        </p>
        <fieldset className="lg-picker-rows" aria-label={t("sheet.search")} aria-busy={loading === true || undefined}>
          {initialLoading &&
            Array.from({ length: 4 }, (_, index) => (
              <div key={index} className="lg-picker-row lg-picker-loading-row" aria-hidden="true">
                <span className="lg-picker-placeholder lg-picker-placeholder-check" />
                <span className="lg-picker-placeholder lg-picker-placeholder-avatar" />
                <span className="lg-picker-placeholder lg-picker-placeholder-name" />
              </div>
            ))}
          {shown.map((person) => (
            <label key={person.id} className="lg-picker-row">
              <input
                type="checkbox"
                aria-label={person.name}
                checked={picked.includes(person.id)}
                onChange={() => toggle(person.id)}
              />
              <Avatar participant={person} size={24} />
              <span className="lg-picker-name">{person.name}</span>
              {person.kind === "agent" && (
                <span className="hc-tag">{t(person.chief ? "chief.badge" : "agent.badge")}</span>
              )}
            </label>
          ))}
          {!loading && shown.length === 0 && <p className="lg-picker-none">{t("sheet.noMatch")}</p>}
        </fieldset>
      </div>
    </KeyboardScope>
  );
}
