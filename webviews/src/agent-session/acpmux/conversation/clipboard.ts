/// Copies `text`: the async clipboard where the page may use it, else a selection copy
/// (a WKWebView page loaded from a file is not always allowed the async clipboard).
export async function copyText(text: string): Promise<void> {
  try {
    await navigator.clipboard.writeText(text);
  } catch {
    const field = document.createElement("textarea");
    field.value = text;
    field.style.position = "fixed";
    field.style.opacity = "0";
    document.body.append(field);
    field.select();
    document.execCommand("copy");
    field.remove();
  }
}
