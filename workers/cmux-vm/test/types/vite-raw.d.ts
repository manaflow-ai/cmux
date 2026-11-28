// Vite features the node tests use to read checked-in files without node:fs.
declare module "*.json?raw" {
  const text: string;
  export default text;
}

interface ImportMeta {
  glob(pattern: string, options: { readonly query: "?raw"; readonly import: "default"; readonly eager: true }): Record<string, string>;
}
