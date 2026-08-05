import {
  createHostedSubrouterClient,
  type HostedSubrouterClient,
} from "./hostedClient";

export function createConfiguredHostedSubrouterClient(): HostedSubrouterClient {
  return createHostedSubrouterClient();
}
