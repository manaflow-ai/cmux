// The connect card's words (Localizable.xcstrings beside it, generated/strings.json by
// scripts/pages/gen-strings.mjs `connect`). Settings reads the same catalog through its own table.
import { useEffect, useState } from "react";
import { createStrings, type Strings } from "../i18n";
import table from "./generated/strings.json";

export function connectStrings(languages?: readonly string[]): Strings {
  return createStrings(table, languages);
}

/** The card's strings, again after each app language change. */
export function useConnectStrings(): Strings {
  const [strings, setStrings] = useState(() => connectStrings());
  useEffect(() => {
    const view = globalThis.window;
    const follow = () => setStrings(connectStrings());
    view?.addEventListener("languagechange", follow);
    return () => view?.removeEventListener("languagechange", follow);
  }, []);
  return strings;
}
