import { t } from "../strings";
import { isSearchTemplate } from "../validate";
import { TextEditor } from "./TextEditor";
import type { EditorProps } from "./types";

const check = (input: string) => (isSearchTemplate(input) ? null : t("settingsPage.invalidSearchTemplate"));

/**
 * A custom search engine address: refused without %s or {searchTerms}, so it never becomes the
 * active engine, and a stored address without one shows the same message.
 */
export function SearchTemplateEditor(props: EditorProps) {
  return <TextEditor {...props} check={check} checkStored />;
}
