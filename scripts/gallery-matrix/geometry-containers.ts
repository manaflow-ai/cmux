import type { GeometryArtifact, GeometrySource, Rect } from "./geometry";

type Common = { id: string; group: string; tolerancePx: number; minCount?: number; source?: GeometrySource; appliesTo?: string[]; containerGroup: string };
export type ContainerRule =
  | (Common & { kind: "container-peer-alignment"; axis: "x" | "y"; measure: "start" | "center" | "end" })
  | (Common & { kind: "container-center"; axis: "x" | "y" })
  | (Common & { kind: "exclusive-parts"; parts: string[] });
export type ContainerFinding = { ids: string[]; message: string; observed?: number; expected?: number; delta?: number };
const kinds = ["container-peer-alignment", "container-center", "exclusive-parts"];

export function validateContainerRule(value: unknown, file: string): value is ContainerRule {
  const rule = value as ContainerRule;
  if (!kinds.includes(rule.kind)) return false;
  if (typeof rule.containerGroup !== "string" || !rule.containerGroup) throw new Error(`${file}: containerGroup is required`);
  if (rule.source !== undefined && !["dom-rect", "ax-frame", "view-frame"].includes(rule.source)) throw new Error(`${file}: invalid source`);
  if (rule.appliesTo !== undefined && (!Array.isArray(rule.appliesTo) || !rule.appliesTo.length || rule.appliesTo.some((id) => typeof id !== "string" || !id))) throw new Error(`${file}: invalid appliesTo`);
  if (rule.kind === "exclusive-parts") {
    if (!Array.isArray(rule.parts) || new Set(rule.parts).size < 2 || rule.parts.some((part) => typeof part !== "string" || !part)) throw new Error(`${file}: exclusive-parts needs at least two distinct parts`);
  } else {
    if (!["x", "y"].includes(rule.axis)) throw new Error(`${file}: invalid axis`);
    if (rule.kind === "container-peer-alignment" && !["start", "center", "end"].includes(rule.measure)) throw new Error(`${file}: invalid measure`);
  }
  return true;
}
const point = (rect: Rect, axis: "x" | "y", measure: "start" | "center" | "end") => rect[axis] + (measure === "start" ? 0 : rect[axis === "x" ? "width" : "height"] / (measure === "center" ? 2 : 1));

/** Each captured container is checked independently, including nested rows and repeated headers. */
export function checkContainerRule(value: unknown, artifact: GeometryArtifact): ContainerFinding[] | null {
  const rule = value as ContainerRule;
  if (!kinds.includes(rule.kind)) return null;
  const findings: ContainerFinding[] = [];
  const containers = artifact.elements.filter((element) => element.group === rule.containerGroup);
  const children = artifact.elements.filter((element) => element.group === rule.group);
  const byId = new Map(containers.map((element) => [element.id, element]));
  if (!containers.length) return [{ ids: [], message: `missing containers for ${rule.containerGroup}` }];
  for (const child of children) if (!child.containerId || !byId.has(child.containerId)) findings.push({ ids: [child.id], message: "missing measured owning container" });
  for (const container of containers) {
    const peers = children.filter((element) => element.containerId === container.id);
    if (rule.source && [container, ...peers].some((element) => element.source !== rule.source)) {
      findings.push({ ids: [container.id, ...peers.map((element) => element.id)], message: `container and peers must use ${rule.source} evidence` });
      continue;
    }
    if (rule.kind === "exclusive-parts") {
      const minimum = rule.minCount ?? 1;
      if (peers.length < minimum) { findings.push({ ids: [container.id, ...peers.map((element) => element.id)], message: `missing peers in container: expected ${minimum}, got ${peers.length}` }); continue; }
      const unknown = peers.filter((element) => !element.part || !rule.parts.includes(element.part));
      for (const element of unknown) findings.push({ ids: [container.id, element.id], message: "missing or unknown visible part" });
      const visibleParts = new Set(peers.map((element) => element.part).filter((part) => rule.parts.includes(part ?? "")));
      if (visibleParts.size > 1) findings.push({ ids: [container.id, ...peers.map((element) => element.id)], message: `mutually exclusive parts visible: ${[...visibleParts].sort().join(", ")}` });
      continue;
    }
    const minimum = rule.minCount ?? (rule.kind === "container-peer-alignment" ? 2 : 1);
    if (peers.length < minimum) {
      findings.push({ ids: [container.id, ...peers.map((element) => element.id)], message: `missing peers in container: expected ${minimum}, got ${peers.length}` });
      continue;
    }
    if (rule.kind === "container-peer-alignment") {
      const values = peers.map((element) => point(element.rect, rule.axis, rule.measure));
      const span = Math.max(...values) - Math.min(...values);
      if (span > rule.tolerancePx) findings.push({ ids: [container.id, ...peers.map((element) => element.id)], message: `${rule.axis} ${rule.measure} spread within container`, observed: span, expected: 0, delta: span });
    } else {
      const expected = point(container.rect, rule.axis, "center");
      for (const peer of peers) {
        const observed = point(peer.rect, rule.axis, "center");
        if (Math.abs(observed - expected) > rule.tolerancePx) findings.push({ ids: [container.id, peer.id], message: `${rule.axis} center differs from owning row`, observed, expected, delta: Math.abs(observed - expected) });
      }
    }
  }
  return findings;
}
