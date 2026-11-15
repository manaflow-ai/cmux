// The endpoint fields the Chief editor's Bring your own and Settings > Agents > Add > Endpoint
// share (byoEndpoint.ts): base URL, models and key, in that order, each with the attributes acpmux's
// checks expect (a URL, words without spell check, a password field that is never filled in). Each
// surface draws a field its own way through `field`, so the form looks like the page it is on.
import { Fragment, type InputHTMLAttributes, type ReactNode } from "react";
import type { EndpointDraft } from "./byoEndpoint";

export type EndpointFieldName = "baseUrl" | "models" | "apiKey";

export interface EndpointFieldSpec {
  name: EndpointFieldName;
  label: string;
  value: string;
  set(value: string): void;
  attrs: InputHTMLAttributes<HTMLInputElement>;
}

export function EndpointFields({
  draft,
  change,
  labels,
  placeholders = {},
  field,
}: {
  draft: EndpointDraft;
  change(patch: Partial<EndpointDraft>): void;
  labels: Record<EndpointFieldName, string>;
  placeholders?: Partial<Record<EndpointFieldName, string>>;
  field(spec: EndpointFieldSpec): ReactNode;
}) {
  const specs: EndpointFieldSpec[] = [
    {
      name: "baseUrl",
      label: labels.baseUrl,
      value: draft.baseUrl,
      set: (baseUrl) => change({ baseUrl }),
      attrs: { type: "url", spellCheck: false, placeholder: placeholders.baseUrl },
    },
    {
      name: "models",
      label: labels.models,
      value: draft.models,
      set: (models) => change({ models }),
      attrs: { spellCheck: false, maxLength: 2000, placeholder: placeholders.models },
    },
    {
      name: "apiKey",
      label: labels.apiKey,
      value: draft.apiKey,
      set: (apiKey) => change({ apiKey }),
      attrs: { type: "password", autoComplete: "off", spellCheck: false, placeholder: placeholders.apiKey },
    },
  ];
  return specs.map((spec) => <Fragment key={spec.name}>{field(spec)}</Fragment>);
}
