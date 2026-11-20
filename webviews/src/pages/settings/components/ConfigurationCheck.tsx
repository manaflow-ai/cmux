// Re-read the same owner snapshot Settings uses. No validation rules live in the page.
import { useEffect, useState } from "react";
import { Button } from "../../../ui/Button";
import { useStore } from "../context";
import { t } from "../strings";

export function ConfigurationCheck({
  problems,
  fileName,
  readable,
}: {
  problems: ReadonlyArray<{ path: string; message: string }>;
  fileName: string;
  readable: boolean;
}) {
  const store = useStore();
  const [request, setRequest] = useState(0);
  const [result, setResult] = useState<{ request: number; error?: string }>();
  const checking = request > 0 && result?.request !== request;
  useEffect(() => {
    if (!request) return;
    let active = true;
    void store.queryClient
      .fetchQuery({ ...store.scopeQuery(), staleTime: 0 })
      .then(() => {
        if (active) setResult({ request });
      })
      .catch((error: unknown) => {
        if (active) setResult({ request, error: error instanceof Error ? error.message : String(error) });
      });
    return () => {
      active = false;
    };
  }, [store, request]);
  return (
    <div className="rows" data-config-check="">
      <div className="row">
        <Button type="button" className="button" disabled={checking} onClick={() => setRequest((value) => value + 1)}>
          {t("settingsWindow.checkConfiguration")}
        </Button>
      </div>
      {checking ? (
        <output className="row">{t("settingsWindow.checkingConfiguration")}</output>
      ) : (
        <>
          {result?.error ? (
            <div className="row" role="alert">
              {result.error}
            </div>
          ) : !readable ? null : problems.length === 0 ? (
            <output className="row">{t("settingsWindow.noProblems")}</output>
          ) : (
            problems.map((problem, index) => (
              <div className="row selectable" key={index} data-problem="">
                <div className="row-title">{problem.path || fileName}</div>
                <div className="row-help">{problem.message}</div>
              </div>
            ))
          )}
        </>
      )}
    </div>
  );
}
