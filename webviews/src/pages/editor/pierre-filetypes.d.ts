// Pierre's built-in `extension -> language` map, the diff viewer's detection table. The module is not
// in @pierre/diffs' package exports; vite.config.ts aliases `cmux:pierre-filetypes` to its file with a
// query, so the editor bundles its own copy and the diff viewer's chunks stay as they are.
declare module "cmux:pierre-filetypes" {
  export const EXTENSION_TO_FILE_FORMAT: Readonly<Record<string, string>>;
}
