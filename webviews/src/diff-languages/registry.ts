// The diff viewer's language state: which languages can load (every bundled Shiki language,
// fetched lazily as its own chunk on first use, plus the user's grammars) and the detector that
// picks one per file. Highlighting runs in the worker pool; Pierre resolves a language's grammar
// on the main thread through the loaders registered here and posts it to the workers, so a user
// grammar needs no worker code.
import {
  EXTENSION_TO_FILE_FORMAT,
  registerCustomLanguage,
  RegisteredCustomLanguages,
  resolveLanguages,
  type SupportedLanguages,
} from "@pierre/diffs";
import { bundledLanguages } from "shiki";
import {
  createLanguageDetector,
  type CustomLanguageMapping,
  type LanguageDetectionInput,
  type LanguageDetector,
} from "./detect";
import { parseDiffLanguagePack, type CustomGrammar } from "./pack";

export type DiffLanguageReport = {
  /// The user language ids that applied.
  languages: string[];
  warnings: string[];
  /// A grammar the page already loaded changed. Shiki caches grammars by `scopeName` for the
  /// life of the page (and of each highlight worker), so the host reloads the page to apply it.
  /// New languages and override changes apply without a reload.
  reloadRequired?: boolean;
};

type RegistryDependencies = {
  isBundled: (language: string) => boolean;
  extensionMap: Readonly<Record<string, string>>;
  register: (id: string, loader: () => Promise<{ default: unknown }>) => void;
  isRegistered: (id: string) => boolean;
  resolveEmbedded: (languages: string[]) => Promise<Array<{ data: unknown[] }>>;
  warn: (message: string) => void;
};

const pierreDependencies: RegistryDependencies = {
  isBundled: (language) => Object.prototype.hasOwnProperty.call(bundledLanguages, language),
  extensionMap: EXTENSION_TO_FILE_FORMAT as Readonly<Record<string, string>>,
  register: (id, loader) => registerCustomLanguage(id, loader as never),
  isRegistered: (id) => RegisteredCustomLanguages.has(id),
  resolveEmbedded: (languages) => resolveLanguages(languages as SupportedLanguages[]),
  warn: (message) => console.warn(`cmux diff languages: ${message}`),
};

export function createDiffLanguageRegistry(dependencies: RegistryDependencies = pierreDependencies) {
  const userLanguageIds = new Set<string>();
  const fingerprintByScope = new Map<string, string>();
  const listeners = new Set<() => void>();
  let version = 0;
  let detector: LanguageDetector = createLanguageDetector({
    isLoadable: dependencies.isBundled,
    extensionMap: dependencies.extensionMap,
  });

  /// Replaces the user languages and overrides with the folder's current contents.
  function install(pack: unknown): DiffLanguageReport {
    const parsed = parseDiffLanguagePack(pack);
    const warnings = [...parsed.warnings];
    let reloadRequired = false;
    // Internal ids carry the grammar's content hash: an edited grammar gets a fresh id, so no
    // cached copy of the old one (main thread or worker) is ever reused, and a user grammar
    // named like a bundled one ("swift") replaces it only through the detector's mapping.
    const internalIdByUserId = new Map(
      parsed.languages.map((language) => [language.id.toLowerCase(), internalLanguageId(language)]),
    );
    const mappings: CustomLanguageMapping[] = [];
    for (const language of parsed.languages) {
      const internalId = internalIdByUserId.get(language.id.toLowerCase())!;
      const embedded: string[] = [];
      for (const name of language.embeddedLanguages) {
        const resolved = internalIdByUserId.get(name.toLowerCase()) ?? (dependencies.isBundled(name) ? name : null);
        if (resolved == null) {
          warnings.push(`${language.id}: embedded language "${name}" is unknown; ignored`);
        } else if (resolved !== internalId) {
          embedded.push(resolved);
        }
      }
      const loadedFingerprint = fingerprintByScope.get(language.scopeName);
      if (loadedFingerprint != null && loadedFingerprint !== language.fingerprint) reloadRequired = true;
      fingerprintByScope.set(language.scopeName, language.fingerprint);
      if (!dependencies.isRegistered(internalId)) {
        dependencies.register(internalId, () => loadGrammar(language, internalId, embedded));
      }
      userLanguageIds.add(internalId);
      mappings.push({
        id: internalId,
        aliases: [language.id, ...language.aliases],
        extensions: language.extensions,
        filenames: language.filenames,
      });
    }
    const active = new Set(mappings.map((mapping) => mapping.id));
    detector = createLanguageDetector({
      isLoadable: (language) => active.has(language) || dependencies.isBundled(language),
      extensionMap: dependencies.extensionMap,
      custom: mappings,
      overrides: parsed.overrides,
    });
    for (const warning of warnings) dependencies.warn(warning);
    version += 1;
    for (const listener of listeners) listener();
    const languages = parsed.languages.map((language) => language.id);
    return reloadRequired ? { languages, warnings, reloadRequired } : { languages, warnings };
  }

  async function loadGrammar(language: CustomGrammar, internalId: string, embedded: string[]) {
    const embeddedData = embedded.length > 0 ? await dependencies.resolveEmbedded(embedded) : [];
    const registration = { ...language.grammar, name: internalId, scopeName: language.scopeName };
    delete (registration as { aliases?: unknown }).aliases;
    return { default: [...embeddedData.flatMap((resolved) => resolved.data), registration] };
  }

  return {
    install,
    detect: (input: LanguageDetectionInput) => detector(input),
    isUserLanguage: (language: string) => userLanguageIds.has(language),
    getVersion: () => version,
    subscribe(listener: () => void) {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
  };
}

export type DiffLanguageRegistry = ReturnType<typeof createDiffLanguageRegistry>;

function internalLanguageId(language: CustomGrammar): string {
  return `cmux-user-${language.id.toLowerCase()}-${language.fingerprint}`;
}

/// The page's registry. Kept on `globalThis` so a Vite hot update of this module does not lose
/// languages the host already installed.
export const diffLanguages: DiffLanguageRegistry = ((
  globalThis as { __cmuxDiffLanguages?: DiffLanguageRegistry }
).__cmuxDiffLanguages ??= createDiffLanguageRegistry());
