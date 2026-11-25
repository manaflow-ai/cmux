// The sign-in card's words (Localizable.xcstrings beside it, generated/strings.json by
// scripts/pages/gen-strings.mjs `signIn`). Settings and Onboarding also read the same catalog
// through their own tables, so their rows and the card speak one language.
import { useEffect, useState } from "react";
import { createStrings, type Strings } from "../i18n";
import table from "./generated/strings.json";

export function signInStrings(languages?: readonly string[]): Strings {
  return createStrings(table, languages);
}

/** The card's strings, again after each app language change. */
export function useSignInStrings(): Strings {
  const [strings, setStrings] = useState(() => signInStrings());
  useEffect(() => {
    const view = globalThis.window;
    const follow = () => setStrings(signInStrings());
    view?.addEventListener("languagechange", follow);
    return () => view?.removeEventListener("languagechange", follow);
  }, []);
  return strings;
}
