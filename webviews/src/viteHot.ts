// Bun's ambient ImportMeta.hot type models callbacks without payloads, while the Vite dev server
// supplies the event payloads used by cmux. Keep the cast at this boundary so dev-only listeners
// remain typed without weakening the rest of the application.
export type CmuxHotContext = {
  on(event: string, callback: (payload: any) => void): void;
  off(event: string, callback: (payload: any) => void): void;
};

export function viteHot(): CmuxHotContext | undefined {
  return import.meta.hot as unknown as CmuxHotContext | undefined;
}
