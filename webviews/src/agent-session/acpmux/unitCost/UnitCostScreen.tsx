import { useEffect, useRef, useState } from "react";
import { Button } from "../../../ui/Button";
import { Input } from "../../../ui/Input";
import { currentLanguage, useT } from "../i18n";
import { isOlderDaemon } from "../queue/queueModel";
import "../ledger/ledger.css";
import "./unitCost.css";

export type UnitCostProps = { load(params: Record<string, unknown>): Promise<unknown> };
export function UnitCostScreen({ load }: UnitCostProps) {
  const t = useT();
  const [values, setValues] = useState({ seconds: "", hourlyUsd: "", busyPercent: "" });
  const [state, setState] = useState<"idle" | "loading" | "ready" | "failed" | "older">("idle");
  const [cost, setCost] = useState<number>();
  const request = useRef(0);
  useEffect(
    () => () => {
      request.current++;
    },
    [],
  );
  const edit = (key: keyof typeof values, value: string) => {
    request.current++;
    setValues((old) => ({ ...old, [key]: value }));
    setState("idle");
    setCost(undefined);
  };
  const calculate = async () => {
    const id = ++request.current;
    setCost(undefined);
    setState("loading");
    try {
      const answer = (await load(values)) as { costUsd?: unknown } | null;
      if (id !== request.current) return;
      if (typeof answer?.costUsd !== "number" || !Number.isFinite(answer.costUsd) || answer.costUsd < 0) {
        setState("failed");
        return;
      }
      setCost(answer.costUsd);
      setState("ready");
    } catch (error) {
      if (id === request.current) setState(isOlderDaemon(error) ? "older" : "failed");
    }
  };
  return (
    <form
      className="cst ucs"
      onSubmit={(event) => {
        event.preventDefault();
        void calculate();
      }}
    >
      <p className="ucs-note">{t("unitCost.note")}</p>
      <label>
        {t("unitCost.seconds")}
        <Input
          required
          inputMode="decimal"
          value={values.seconds}
          onChange={(event) => edit("seconds", event.target.value)}
        />
      </label>
      <label>
        {t("unitCost.hourlyUsd")}
        <Input
          required
          inputMode="decimal"
          value={values.hourlyUsd}
          onChange={(event) => edit("hourlyUsd", event.target.value)}
        />
      </label>
      <label>
        {t("unitCost.busyPercent")}
        <Input
          required
          inputMode="decimal"
          value={values.busyPercent}
          onChange={(event) => edit("busyPercent", event.target.value)}
        />
      </label>
      <div>
        <Button type="submit" disabled={state === "loading"}>
          {t("unitCost.calculate")}
        </Button>
      </div>
      <output aria-live="polite">
        {state === "loading"
          ? t("ledger.loading")
          : state === "older"
            ? t("unitCost.older")
            : state === "failed"
              ? t("unitCost.failed")
              : cost !== undefined
                ? new Intl.NumberFormat(currentLanguage(), {
                    style: "currency",
                    currency: "USD",
                    minimumFractionDigits: 2,
                    maximumFractionDigits: 4,
                  }).format(cost)
                : ""}
      </output>
    </form>
  );
}
