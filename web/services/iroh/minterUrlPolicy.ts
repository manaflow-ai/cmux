export const IROH_RELAY_MINTER_PATH = "/api/relay-token";

export type IrohMinterUrlPolicy = {
  readonly allowInsecureLoopback: boolean;
  readonly deploymentEnvironment: string;
  readonly isVercelDeployment: boolean;
};

export function insecureLoopbackMinterAllowed(policy: IrohMinterUrlPolicy): boolean {
  return policy.allowInsecureLoopback &&
    !policy.isVercelDeployment &&
    policy.deploymentEnvironment === "development";
}

export function parseIrohMinterUrl(value: string, policy: IrohMinterUrlPolicy): URL {
  const url = new URL(value);
  const secureTransport = url.protocol === "https:";
  const allowedDevelopmentTransport =
    url.protocol === "http:" &&
    insecureLoopbackMinterAllowed(policy) &&
    isCanonicalLoopbackHost(url.hostname);

  if (
    (!secureTransport && !allowedDevelopmentTransport) ||
    url.username ||
    url.password ||
    url.pathname !== IROH_RELAY_MINTER_PATH ||
    url.search ||
    url.hash
  ) {
    throw new Error("invalid Iroh relay minter URL");
  }
  return url;
}

function isCanonicalLoopbackHost(hostname: string): boolean {
  return hostname === "localhost" ||
    hostname === "127.0.0.1" ||
    hostname === "[::1]";
}
