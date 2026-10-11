import { t } from "../strings";
import { isPageURL } from "../validate";
import { TextEditor } from "./TextEditor";
import type { EditorProps } from "./types";

const check = (input: string) => (isPageURL(input) ? null : t("settingsPage.invalidUrl"));

export function UrlEditor(props: EditorProps) {
  return <TextEditor {...props} check={check} />;
}
