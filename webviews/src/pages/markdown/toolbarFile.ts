// The file name the Markdown page's toolbar shows. With the native omnibar above the page (config
// `omnibar: true`, plans/cmux-next/markdown-omnibar-DESIGN.md section 2) the omnibar already shows
// the full path, so the toolbar names no file; it still says a followed link is loading.

/** What the label needs from the page config. */
export interface ToolbarFileConfig {
  path: string;
  omnibar?: boolean;
}

/** What the label needs from the page state. */
export interface ToolbarFileState {
  loading: boolean;
  navigating: string | null;
}

function fileName(path: string): string {
  return path.split("/").filter(Boolean).pop() ?? path;
}

/** The toolbar's file label: `loading` while a file loads, null when the omnibar names the file. */
export function toolbarFileLabel(
  config: ToolbarFileConfig | null | undefined,
  state: ToolbarFileState,
  loading: string,
): string | null {
  if (state.loading) return loading;
  if (config?.omnibar) return state.navigating ? loading : null;
  return fileName(state.navigating ?? config?.path ?? "");
}
