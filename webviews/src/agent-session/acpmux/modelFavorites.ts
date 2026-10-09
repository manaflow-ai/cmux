// Favorites belong to a provider/model pair. Older picker versions stored only model ids.
const STORAGE = "cmux.model-picker.favorites.v2";
export const favoriteKey = (provider: string, model: string) => JSON.stringify([provider, model]);

export function loadFavorites(providers: { id: string; models: { id: string }[] }[]): Set<string> {
  try {
    const stored = globalThis.localStorage?.getItem(STORAGE);
    const parsed: unknown = JSON.parse(
      stored ?? globalThis.localStorage?.getItem("cmux.model-picker.favorites") ?? "[]",
    );
    const ids = new Set(Array.isArray(parsed) ? parsed.filter((id): id is string => typeof id === "string") : []);
    if (stored) return ids;
    // Preserve every previously starred row during the one-time migration. Subsequent toggles
    // are independent, even when providers expose the same model id (such as "default").
    return new Set(
      providers.flatMap((provider) =>
        provider.models.filter((model) => ids.has(model.id)).map((model) => favoriteKey(provider.id, model.id)),
      ),
    );
  } catch {
    return new Set();
  }
}

export function saveFavorites(favorites: ReadonlySet<string>) {
  try {
    globalThis.localStorage?.setItem(STORAGE, JSON.stringify([...favorites]));
  } catch {
    // Stars still work for this mounted picker if storage is unavailable.
  }
}
