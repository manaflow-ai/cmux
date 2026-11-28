import { useState } from "react";
import { Button } from "../../../ui/Button";
import type { ModelConnection } from "../ops";
import { providerCredentials, type KeyProvider } from "../providerCatalog";
import { t } from "../strings";
import { ConnectionError, ConnectionFooter, SecretField, validKey } from "./ModelConnectionFields";
import type { Run } from "./modelConnections";

export function ModelKeyForm({
  provider,
  canCheck,
  cloud,
  busy,
  edit,
  onKeyReplaced,
  error,
  run,
  onClose,
  onCancel,
}: {
  provider: KeyProvider;
  canCheck: boolean;
  cloud: boolean;
  busy: boolean;
  edit?: ModelConnection;
  onKeyReplaced?(): void;
  error: string | null;
  run: Run;
  onClose(): void;
  onCancel(): void;
}) {
  const [key, setKey] = useState("");
  const [submitted, setSubmitted] = useState(false);
  const [verificationFailed, setVerificationFailed] = useState(false);
  const [useVertex, setUseVertex] = useState(false);
  // Match SettingsModels.withoutWhitespace before validating or checking access.
  const apiKey = key.replace(/[\p{White_Space}\u200B-\u200D\u2060\uFEFF]+/gu, "");
  const mayUseVertex = !edit && provider.id === "google" && apiKey.startsWith("AQ.");
  const vertex = provider.id === "vertex-express" || (mayUseVertex && useVertex);
  const valid = validKey(apiKey) || (!!edit && !apiKey);
  const submit = async () => {
    if (busy || !valid) return;
    setSubmitted(true);
    if (
      !apiKey ||
      (await run(
        {
          action: "addKey",
          provider: vertex ? "vertex-express" : provider.id,
          key: apiKey,
          verifyAccess: canCheck && !vertex && !verificationFailed,
          ...(edit
            ? { replace: edit.id, replaceInstance: edit.credentialInstance ?? undefined }
            : { servesCloud: cloud }),
        },
        () => setVerificationFailed(true),
      ))
    ) {
      if (edit && apiKey) onKeyReplaced?.();
      setKey("");
      onClose();
    }
  };
  return (
    <form
      className="models-form"
      data-models-key-form={provider.id}
      aria-busy={busy}
      onSubmit={(event) => {
        event.preventDefault();
        void submit();
      }}
    >
      <SecretField
        label={t("settingsWindow.models.key.field")}
        placeholder={edit ? undefined : providerCredentials(provider).placeholder}
        help={edit ? t("settingsWindow.models.key.keep") : undefined}
        value={key}
        disabled={busy}
        onChange={(value) => {
          setKey(value);
          setSubmitted(false);
          setVerificationFailed(false);
        }}
      />
      {mayUseVertex && (
        <Button
          type="button"
          size="sm"
          aria-pressed={useVertex}
          disabled={busy}
          onClick={() => {
            setUseVertex(!useVertex);
            setSubmitted(false);
            setVerificationFailed(false);
          }}
        >
          {t("settingsWindow.models.key.useVertexExpress")}
        </Button>
      )}
      {submitted && error && <ConnectionError>{error}</ConnectionError>}
      {busy && (
        <output className="visually-hidden" data-models-saving="">
          {t("settingsWindow.models.saving")}
        </output>
      )}
      <ConnectionFooter
        onClose={onCancel}
        disabled={!valid}
        busy={busy}
        loading={busy}
        label={
          verificationFailed
            ? t("settingsWindow.models.key.saveWithoutVerification")
            : edit
              ? t("settingsWindow.density.save")
              : undefined
        }
        failed={submitted && !!error}
        connectAction="addKey"
      />
    </form>
  );
}
