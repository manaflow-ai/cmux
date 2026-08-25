import { PROVIDER_IDS, type ProviderId } from "../drivers/types";

export const MACHINE_CONNECTABLE_MUX_PROTOCOL_VERSION = 12;

export const MACHINE_RUNTIME_READINESS = [
  "legacy",
  "built",
  "boot_checked",
  "attach_checked",
  "resume_checked",
  "approved",
] as const;

export type MachineRuntimeReadiness = typeof MACHINE_RUNTIME_READINESS[number];
export type MachineArchitecture = "x86_64" | "aarch64";
export type MachineTransport = "ssh-provider-stream" | "websocket-provider-stream";
export type MachineAuthentication = "ssh-edge-ticket" | "server-side-websocket-ticket";

export const MACHINE_CONNECTABLE_BOOTSTRAP_GENERATION = 1;
export const MACHINE_CONNECTABLE_ARCHITECTURE = "x86_64" satisfies MachineArchitecture;
export const MACHINE_CONNECTABLE_SUPERVISOR_VERSION = "cmux-cloud-supervisor-v1";
export const MACHINE_CONNECTABLE_TRANSPORT =
  "websocket-provider-stream" satisfies MachineTransport;
export const MACHINE_CONNECTABLE_AUTHENTICATION =
  "server-side-websocket-ticket" satisfies MachineAuthentication;

export type LegacyMachineRuntime = {
  readonly readiness: "legacy";
};

type MachineRuntimeIdentity = {
  readonly cmuxCommit: string;
  readonly cmuxVersion: string;
  readonly binarySha256: string;
  readonly protocolVersion: number;
  readonly bootstrapGeneration: number;
  readonly architecture: MachineArchitecture;
  readonly supervisorVersion: string;
  readonly transport: MachineTransport;
  readonly authentication: MachineAuthentication;
};

export type BuiltMachineRuntime = MachineRuntimeIdentity & {
  readonly readiness: "built";
  readonly verifiedAt?: never;
};

export type CheckedMachineRuntime = MachineRuntimeIdentity & {
  readonly readiness: "boot_checked" | "attach_checked" | "resume_checked";
  readonly verifiedAt: string;
};

type ApprovedMachineRuntimeRecord = MachineRuntimeIdentity & {
  readonly readiness: "approved";
  readonly verifiedAt: string;
};

export type StagedMachineRuntime =
  | BuiltMachineRuntime
  | CheckedMachineRuntime
  | ApprovedMachineRuntimeRecord;

export type ApprovedMachineRuntime = ApprovedMachineRuntimeRecord & {
  readonly protocolVersion: typeof MACHINE_CONNECTABLE_MUX_PROTOCOL_VERSION;
  readonly bootstrapGeneration: typeof MACHINE_CONNECTABLE_BOOTSTRAP_GENERATION;
  readonly architecture: typeof MACHINE_CONNECTABLE_ARCHITECTURE;
  readonly supervisorVersion: typeof MACHINE_CONNECTABLE_SUPERVISOR_VERSION;
  readonly transport: typeof MACHINE_CONNECTABLE_TRANSPORT;
  readonly authentication: typeof MACHINE_CONNECTABLE_AUTHENTICATION;
};

export type MachineRuntime = LegacyMachineRuntime | StagedMachineRuntime;

export type VmImageManifestEntry = {
  readonly provider: ProviderId;
  readonly version: string;
  readonly imageId: string;
  readonly envVar: string;
  readonly defaultForLocalDev?: boolean;
  readonly features?: {
    readonly bakedFreestyleSignedAdmin?: boolean;
  };
  readonly cmuxdRemoteCommit: string;
  readonly builtAt: string;
  readonly builderScriptVersion: string;
  readonly agentToolResolvedVersions?: Record<string, string>;
  readonly validationStatus: "passed" | "failed" | "unknown";
  readonly machineRuntime: MachineRuntime;
  readonly notes?: string;
};

export type VmImageManifest = {
  readonly schemaVersion: 2;
  readonly images: readonly VmImageManifestEntry[];
};

const COMMIT_RE = /^[0-9a-f]{40}$/;
const SHA256_RE = /^[0-9a-f]{64}$/;
const EXACT_SEMVER_RE =
  /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/;
const ISO_TIMESTAMP_RE =
  /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?(?:Z|([+-])(\d{2}):(\d{2}))$/;
const VERIFIED_READINESS = new Set<MachineRuntimeReadiness>([
  "boot_checked",
  "attach_checked",
  "resume_checked",
  "approved",
]);
const STAGED_MACHINE_RUNTIME_KEYS = [
  "readiness",
  "cmuxCommit",
  "cmuxVersion",
  "binarySha256",
  "protocolVersion",
  "bootstrapGeneration",
  "architecture",
  "supervisorVersion",
  "transport",
  "authentication",
] as const;
const MACHINE_CONNECTABLE_PROVIDER_CONTRACTS = {
  e2b: {
    architecture: MACHINE_CONNECTABLE_ARCHITECTURE,
    transport: MACHINE_CONNECTABLE_TRANSPORT,
    authentication: MACHINE_CONNECTABLE_AUTHENTICATION,
  },
  freestyle: {
    architecture: MACHINE_CONNECTABLE_ARCHITECTURE,
    transport: MACHINE_CONNECTABLE_TRANSPORT,
    authentication: MACHINE_CONNECTABLE_AUTHENTICATION,
  },
  daytona: {
    architecture: MACHINE_CONNECTABLE_ARCHITECTURE,
    transport: MACHINE_CONNECTABLE_TRANSPORT,
    authentication: MACHINE_CONNECTABLE_AUTHENTICATION,
  },
} as const satisfies Record<ProviderId, {
  readonly architecture: MachineArchitecture;
  readonly transport: MachineTransport;
  readonly authentication: MachineAuthentication;
}>;

export function parseVmImageManifest(value: unknown): VmImageManifest {
  const manifest = requireRecord(value, "Cloud VM image manifest");
  if (manifest.schemaVersion !== 2) {
    throw new Error("Cloud VM image manifest schemaVersion must be 2");
  }
  if (!Array.isArray(manifest.images)) {
    throw new Error("Cloud VM image manifest images must be an array");
  }
  return {
    schemaVersion: 2,
    images: manifest.images.map((entry, index) => parseManifestEntry(entry, index)),
  };
}

export function parseMachineRuntime(value: unknown, label = "machineRuntime"): MachineRuntime {
  const runtime = requireRecord(value, label);
  const readiness = runtime.readiness;
  if (!MACHINE_RUNTIME_READINESS.includes(readiness as MachineRuntimeReadiness)) {
    throw new Error(`${label}.readiness is not supported`);
  }
  if (readiness === "legacy") {
    requireOnlyKeys(runtime, ["readiness"], label);
    return { readiness: "legacy" };
  }

  const stagedReadiness = readiness as StagedMachineRuntime["readiness"];
  requireOnlyKeys(
    runtime,
    VERIFIED_READINESS.has(stagedReadiness)
      ? [...STAGED_MACHINE_RUNTIME_KEYS, "verifiedAt"]
      : STAGED_MACHINE_RUNTIME_KEYS,
    label,
  );
  const cmuxCommit = requireMatchingString(runtime.cmuxCommit, COMMIT_RE, `${label}.cmuxCommit`);
  const cmuxVersion = requireMatchingString(
    runtime.cmuxVersion,
    EXACT_SEMVER_RE,
    `${label}.cmuxVersion`,
  );
  const binarySha256 = requireMatchingString(
    runtime.binarySha256,
    SHA256_RE,
    `${label}.binarySha256`,
  );
  const protocolVersion = requirePositiveInteger(runtime.protocolVersion, `${label}.protocolVersion`);
  const bootstrapGeneration = requirePositiveInteger(
    runtime.bootstrapGeneration,
    `${label}.bootstrapGeneration`,
  );
  const architecture = requireEnum(
    runtime.architecture,
    ["x86_64", "aarch64"] as const,
    `${label}.architecture`,
  );
  const supervisorVersion = requireNonemptyString(
    runtime.supervisorVersion,
    `${label}.supervisorVersion`,
  );
  const transport = requireEnum(
    runtime.transport,
    ["ssh-provider-stream", "websocket-provider-stream"] as const,
    `${label}.transport`,
  );
  const authentication = requireEnum(
    runtime.authentication,
    ["ssh-edge-ticket", "server-side-websocket-ticket"] as const,
    `${label}.authentication`,
  );
  if (
    (transport === "ssh-provider-stream" && authentication !== "ssh-edge-ticket") ||
    (transport === "websocket-provider-stream" &&
      authentication !== "server-side-websocket-ticket")
  ) {
    throw new Error(`${label} transport and authentication do not match`);
  }

  let verifiedAt: string | undefined;
  if (VERIFIED_READINESS.has(stagedReadiness)) {
    verifiedAt = requireIsoTimestamp(runtime.verifiedAt, `${label}.verifiedAt`);
  } else if (runtime.verifiedAt !== undefined) {
    throw new Error(`${label}.verifiedAt is only valid after a runtime check`);
  }

  return {
    readiness: stagedReadiness,
    cmuxCommit,
    cmuxVersion,
    binarySha256,
    protocolVersion,
    bootstrapGeneration,
    architecture,
    supervisorVersion,
    transport,
    authentication,
    ...(verifiedAt === undefined ? {} : { verifiedAt }),
  } as StagedMachineRuntime;
}

export function isMachineRuntimeConnectable(
  value: unknown,
  provider: unknown,
): value is ApprovedMachineRuntime {
  try {
    const runtime = parseMachineRuntime(value);
    const providerId = requireEnum(provider, PROVIDER_IDS, "provider");
    const providerContract = MACHINE_CONNECTABLE_PROVIDER_CONTRACTS[providerId];
    return runtime.readiness === "approved" &&
      runtime.protocolVersion === MACHINE_CONNECTABLE_MUX_PROTOCOL_VERSION &&
      runtime.bootstrapGeneration === MACHINE_CONNECTABLE_BOOTSTRAP_GENERATION &&
      runtime.supervisorVersion === MACHINE_CONNECTABLE_SUPERVISOR_VERSION &&
      runtime.architecture === providerContract.architecture &&
      runtime.transport === providerContract.transport &&
      runtime.authentication === providerContract.authentication;
  } catch {
    return false;
  }
}

function parseManifestEntry(value: unknown, index: number): VmImageManifestEntry {
  const label = `Cloud VM image manifest images[${index}]`;
  const entry = requireRecord(value, label);
  const provider = requireEnum(entry.provider, PROVIDER_IDS, `${label}.provider`);
  const defaultForLocalDev = optionalBoolean(entry.defaultForLocalDev, `${label}.defaultForLocalDev`);
  const features = parseFeatures(entry.features, `${label}.features`);
  const agentToolResolvedVersions = parseStringRecord(
    entry.agentToolResolvedVersions,
    `${label}.agentToolResolvedVersions`,
  );
  const notes = optionalString(entry.notes, `${label}.notes`);

  return {
    provider,
    version: requireNonemptyString(entry.version, `${label}.version`),
    imageId: requireNonemptyString(entry.imageId, `${label}.imageId`),
    envVar: requireNonemptyString(entry.envVar, `${label}.envVar`),
    ...(defaultForLocalDev === undefined ? {} : { defaultForLocalDev }),
    ...(features === undefined ? {} : { features }),
    cmuxdRemoteCommit: requireNonemptyString(entry.cmuxdRemoteCommit, `${label}.cmuxdRemoteCommit`),
    builtAt: requireIsoTimestamp(entry.builtAt, `${label}.builtAt`),
    builderScriptVersion: requireNonemptyString(
      entry.builderScriptVersion,
      `${label}.builderScriptVersion`,
    ),
    ...(agentToolResolvedVersions === undefined ? {} : { agentToolResolvedVersions }),
    validationStatus: requireEnum(
      entry.validationStatus,
      ["passed", "failed", "unknown"] as const,
      `${label}.validationStatus`,
    ),
    machineRuntime: parseMachineRuntime(entry.machineRuntime, `${label}.machineRuntime`),
    ...(notes === undefined ? {} : { notes }),
  };
}

function parseFeatures(
  value: unknown,
  label: string,
): VmImageManifestEntry["features"] | undefined {
  if (value === undefined) return undefined;
  const features = requireRecord(value, label);
  const bakedFreestyleSignedAdmin = optionalBoolean(
    features.bakedFreestyleSignedAdmin,
    `${label}.bakedFreestyleSignedAdmin`,
  );
  return bakedFreestyleSignedAdmin === undefined ? {} : { bakedFreestyleSignedAdmin };
}

function parseStringRecord(value: unknown, label: string): Record<string, string> | undefined {
  if (value === undefined) return undefined;
  const record = requireRecord(value, label);
  return Object.fromEntries(Object.entries(record).map(([key, item]) => [
    key,
    requireNonemptyString(item, `${label}.${key}`),
  ]));
}

function requireRecord(value: unknown, label: string): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
  return value as Record<string, unknown>;
}

function requireNonemptyString(value: unknown, label: string): string {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new Error(`${label} must be a non-empty string`);
  }
  return value;
}

function requireMatchingString(value: unknown, pattern: RegExp, label: string): string {
  const string = requireNonemptyString(value, label);
  if (!pattern.test(string)) throw new Error(`${label} has an invalid format`);
  return string;
}

function requirePositiveInteger(value: unknown, label: string): number {
  if (!Number.isSafeInteger(value) || (value as number) <= 0) {
    throw new Error(`${label} must be a positive integer`);
  }
  return value as number;
}

function requireIsoTimestamp(value: unknown, label: string): string {
  const timestamp = requireNonemptyString(value, label);
  const match = ISO_TIMESTAMP_RE.exec(timestamp);
  if (!match) {
    throw new Error(`${label} must be an ISO timestamp`);
  }
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const hour = Number(match[4]);
  const minute = Number(match[5]);
  const second = Number(match[6]);
  const offsetHour = Number(match[9] ?? 0);
  const offsetMinute = Number(match[10] ?? 0);
  if (
    month < 1 || month > 12 ||
    day < 1 || day > daysInMonth(year, month) ||
    hour > 23 || minute > 59 || second > 59 ||
    offsetHour > 23 || offsetMinute > 59 ||
    !Number.isFinite(Date.parse(timestamp))
  ) {
    throw new Error(`${label} must be an ISO timestamp`);
  }
  return timestamp;
}

function daysInMonth(year: number, month: number): number {
  if (month === 2) {
    const isLeapYear = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
    return isLeapYear ? 29 : 28;
  }
  return [4, 6, 9, 11].includes(month) ? 30 : 31;
}

function requireOnlyKeys(
  record: Record<string, unknown>,
  allowed: readonly string[],
  label: string,
): void {
  const unknownKey = Object.keys(record).find((key) => !allowed.includes(key));
  if (unknownKey) throw new Error(`${label}.${unknownKey} is not supported`);
}

function requireEnum<const T extends readonly string[]>(
  value: unknown,
  allowed: T,
  label: string,
): T[number] {
  if (typeof value !== "string" || !allowed.includes(value)) {
    throw new Error(`${label} is not supported`);
  }
  return value as T[number];
}

function optionalBoolean(value: unknown, label: string): boolean | undefined {
  if (value === undefined) return undefined;
  if (typeof value !== "boolean") throw new Error(`${label} must be a boolean`);
  return value;
}

function optionalString(value: unknown, label: string): string | undefined {
  if (value === undefined) return undefined;
  if (typeof value !== "string") throw new Error(`${label} must be a string`);
  return value;
}
