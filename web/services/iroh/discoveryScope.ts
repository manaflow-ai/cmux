import { IrohInvalidInputError } from "./errors";

const MAX_DISCOVERY_SCOPE_TAGS = 8;

export type IrohDiscoveryScope = {
  readonly localBinding: {
    readonly deviceId: string;
    readonly appInstanceId: string;
    readonly tag: string;
    readonly platform: "mac" | "ios";
  };
  readonly peerBindings: {
    readonly platform: "mac" | "ios";
    readonly tags?: readonly string[];
    readonly pairingEnabled?: boolean;
  };
};

export function parseIrohDiscoveryScope(value: unknown): IrohDiscoveryScope {
  const scope = record(value);
  rejectUnknownKeys(scope, ["local_binding", "peer_bindings"]);
  const local = record(scope.local_binding);
  rejectUnknownKeys(local, ["device_id", "app_instance_id", "tag", "platform"]);
  const peers = record(scope.peer_bindings);
  rejectUnknownKeys(peers, ["platform", "tags", "pairing_enabled"]);

  const localPlatform = platform(local.platform);
  const peerPlatform = platform(peers.platform);
  if (localPlatform === peerPlatform) {
    throw new IrohInvalidInputError({ code: "invalid_discovery_scope" });
  }

  const tags = peers.tags === undefined ? undefined : peerTags(peers.tags);
  const pairingEnabled = peers.pairing_enabled;
  if (pairingEnabled !== undefined && typeof pairingEnabled !== "boolean") {
    throw new IrohInvalidInputError({ code: "invalid_discovery_scope" });
  }

  return {
    localBinding: {
      deviceId: canonicalUuid(local.device_id),
      appInstanceId: canonicalUuid(local.app_instance_id),
      tag: safeTag(local.tag),
      platform: localPlatform,
    },
    peerBindings: {
      platform: peerPlatform,
      ...(tags ? { tags } : {}),
      ...(pairingEnabled === undefined ? {} : { pairingEnabled }),
    },
  };
}

export function irohDiscoveryScopeJSON(
  scope: IrohDiscoveryScope,
): Record<string, unknown> {
  return {
    local_binding: {
      device_id: scope.localBinding.deviceId,
      app_instance_id: scope.localBinding.appInstanceId,
      tag: scope.localBinding.tag,
      platform: scope.localBinding.platform,
    },
    peer_bindings: {
      platform: scope.peerBindings.platform,
      ...(scope.peerBindings.tags ? { tags: scope.peerBindings.tags } : {}),
      ...(scope.peerBindings.pairingEnabled === undefined
        ? {}
        : { pairing_enabled: scope.peerBindings.pairingEnabled }),
    },
  };
}

export function discoveryScopeMatchesRegistration(
  scope: IrohDiscoveryScope,
  registration: {
    readonly deviceId: string;
    readonly appInstanceId: string;
    readonly tag: string;
    readonly platform: "mac" | "ios";
  },
): boolean {
  return scope.localBinding.deviceId === registration.deviceId
    && scope.localBinding.appInstanceId === registration.appInstanceId
    && scope.localBinding.tag === registration.tag
    && scope.localBinding.platform === registration.platform;
}

export function bindingMatchesDiscoveryScope(
  binding: {
    readonly deviceUuid: string;
    readonly appInstanceId: string;
    readonly tag: string;
    readonly platform: string;
    readonly pairingEnabled: boolean;
  },
  scope: IrohDiscoveryScope,
): boolean {
  const local = scope.localBinding;
  if (
    binding.deviceUuid === local.deviceId
    && binding.appInstanceId === local.appInstanceId
    && binding.tag === local.tag
    && binding.platform === local.platform
  ) {
    return true;
  }
  const peers = scope.peerBindings;
  return binding.platform === peers.platform
    && (
      peers.tags === undefined
      || peers.tags.includes(binding.tag.toLowerCase())
    )
    && (
      peers.pairingEnabled === undefined
      || binding.pairingEnabled === peers.pairingEnabled
    );
}

function peerTags(value: unknown): readonly string[] {
  if (
    !Array.isArray(value)
    || value.length === 0
    || value.length > MAX_DISCOVERY_SCOPE_TAGS
  ) {
    throw new IrohInvalidInputError({ code: "invalid_discovery_scope" });
  }
  const tags = value.map(safeTag).map((tag) => tag.toLowerCase());
  if (new Set(tags).size !== tags.length) {
    throw new IrohInvalidInputError({ code: "invalid_discovery_scope" });
  }
  return [...tags].sort();
}

function canonicalUuid(value: unknown): string {
  if (
    typeof value !== "string"
    || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(value)
  ) {
    throw new IrohInvalidInputError({ code: "invalid_discovery_scope" });
  }
  return value;
}

function safeTag(value: unknown): string {
  if (
    typeof value !== "string"
    || !/^[A-Za-z0-9._-]{1,64}$/.test(value)
  ) {
    throw new IrohInvalidInputError({ code: "invalid_discovery_scope" });
  }
  return value;
}

function platform(value: unknown): "mac" | "ios" {
  if (value !== "mac" && value !== "ios") {
    throw new IrohInvalidInputError({ code: "invalid_discovery_scope" });
  }
  return value;
}

function record(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new IrohInvalidInputError({ code: "invalid_discovery_scope" });
  }
  return value as Record<string, unknown>;
}

function rejectUnknownKeys(
  value: Record<string, unknown>,
  allowed: readonly string[],
): void {
  const allowedKeys = new Set(allowed);
  if (Object.keys(value).some((key) => !allowedKeys.has(key))) {
    throw new IrohInvalidInputError({ code: "invalid_discovery_scope" });
  }
}
