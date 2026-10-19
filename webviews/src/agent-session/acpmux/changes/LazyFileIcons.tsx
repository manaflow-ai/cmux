// The file-type and language icons (FileTypeIcon.tsx) for surfaces in the page's first script, the
// pickers and project badges: the icon set loads on first use, and `fallback` draws until it lands.
import { lazy, Suspense, type ReactNode } from "react";

const FileTypeIcon = lazy(() => import("./FileTypeIcon").then((module) => ({ default: module.FileTypeIcon })));
const LanguageIcon = lazy(() => import("./FileTypeIcon").then((module) => ({ default: module.LanguageIcon })));

export function LazyFileTypeIcon({ path, fallback }: { path: string; fallback: ReactNode }) {
  return (
    <Suspense fallback={fallback}>
      <FileTypeIcon path={path} />
    </Suspense>
  );
}

export function LazyLanguageIcon({ language, fallback }: { language: string; fallback: ReactNode }) {
  return (
    <Suspense fallback={fallback}>
      <LanguageIcon language={language} />
    </Suspense>
  );
}
