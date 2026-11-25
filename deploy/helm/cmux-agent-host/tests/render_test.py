#!/usr/bin/env python3
"""Render the cmux-agent-host chart with helm and check what RFD 0100 section 9 asks of it.

    python3 deploy/helm/cmux-agent-host/tests/render_test.py [--helm PATH]

Needs helm 3 and PyYAML. No cluster: `helm template` only.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import unittest
from pathlib import Path

import yaml

CHART = Path(__file__).resolve().parents[1]
HELM = "helm"
NAMESPACED = {"ServiceAccount", "Role", "RoleBinding", "Secret", "ConfigMap", "Deployment", "NetworkPolicy"}


def render(*values: str, sets: tuple[str, ...] = ()) -> list[dict]:
    args = [HELM, "template", "t", str(CHART), "--namespace", "agents"]
    for v in values:
        args += ["-f", str(CHART / "ci" / v)]
    for s in sets:
        args += ["--set", s]
    out = subprocess.run(args, check=True, capture_output=True, text=True).stdout
    return [d for d in yaml.safe_load_all(out) if d]


def render_fails(*sets: str) -> str:
    args = [HELM, "template", "t", str(CHART), "--namespace", "agents"]
    for s in sets:
        args += ["--set", s]
    p = subprocess.run(args, capture_output=True, text=True)
    assert p.returncode != 0, "render should have failed"
    return p.stderr


def one(docs: list[dict], kind: str, name: str | None = None) -> dict:
    hits = [d for d in docs if d["kind"] == kind and (name is None or d["metadata"]["name"] == name)]
    assert len(hits) == 1, f"{kind} {name or ''}: {len(hits)} objects"
    return hits[0]


def slot_pod(docs: list[dict]) -> dict:
    return yaml.safe_load(one(docs, "ConfigMap")["data"]["slot-pod.yaml"])


def config(docs: list[dict]) -> dict:
    return json.loads(one(docs, "ConfigMap")["data"]["config.json"])


class PlainPods(unittest.TestCase):
    docs: list[dict]

    @classmethod
    def setUpClass(cls) -> None:
        cls.docs = render("plain-pods-values.yaml")

    def test_only_namespaced_objects_no_crds_no_cluster_role(self) -> None:
        kinds = {d["kind"] for d in self.docs}
        self.assertLessEqual(kinds, NAMESPACED, kinds - NAMESPACED)
        for d in self.docs:
            self.assertEqual(d["metadata"]["namespace"], "agents", d["kind"])

    def test_no_service_or_ingress(self) -> None:
        kinds = {d["kind"] for d in self.docs}
        self.assertFalse(kinds & {"Service", "Ingress"})

    def test_one_host_agent_recreated_not_rolled(self) -> None:
        dep = one(self.docs, "Deployment")
        self.assertEqual(dep["spec"]["replicas"], 1)
        self.assertEqual(dep["spec"]["strategy"]["type"], "Recreate")
        c = dep["spec"]["template"]["spec"]["containers"][0]
        self.assertEqual(c["image"], "ghcr.io/example/acpmux:0.1.0")
        self.assertEqual(c["args"][:3], ["machine", "hypervisor", "serve"])
        self.assertTrue(c["securityContext"]["readOnlyRootFilesystem"])
        self.assertEqual(dep["spec"]["template"]["spec"]["serviceAccountName"], "t-cmux-agent-host")

    def test_role_scoped_to_slots_and_its_one_secret(self) -> None:
        rules = one(self.docs, "Role")["rules"]
        groups = {g for r in rules for g in r["apiGroups"]}
        self.assertEqual(groups, {""}, "no KubeVirt or snapshot rules unless enabled")
        pods = next(r for r in rules if "pods" in r["resources"])
        self.assertEqual(set(pods["verbs"]), {"create", "get", "list", "watch", "delete"})
        self.assertNotIn("pods/exec", pods["resources"])
        secrets = next(r for r in rules if r["resources"] == ["secrets"])
        self.assertEqual(secrets["resourceNames"], ["t-cmux-agent-host-host-credential"])
        self.assertEqual(set(secrets["verbs"]), {"get", "update"})
        binding = one(self.docs, "RoleBinding")
        self.assertEqual(binding["roleRef"]["kind"], "Role")

    def test_join_token_secret_and_kept_credential_secret(self) -> None:
        join = one(self.docs, "Secret", "t-cmux-agent-host-join")
        self.assertEqual(join["stringData"], {"token": "cmj_test_only"})
        cred = one(self.docs, "Secret", "t-cmux-agent-host-host-credential")
        self.assertNotIn("data", cred)
        self.assertEqual(cred["metadata"]["annotations"]["helm.sh/resource-policy"], "keep")

    def test_plain_slot_pod_is_no_vm_boundary(self) -> None:
        pod = slot_pod(self.docs)
        self.assertEqual(pod["kind"], "Pod")
        self.assertNotIn("runtimeClassName", pod["spec"])
        self.assertFalse(pod["spec"]["automountServiceAccountToken"])
        env = {e["name"]: e["value"] for e in pod["spec"]["containers"][0]["env"]}
        self.assertEqual(env["CMUX_VM_BOUNDARY"], "false")
        self.assertFalse(config(self.docs)["slot"]["vmBoundary"])
        self.assertEqual(pod["spec"]["containers"][0]["resources"]["requests"], {"cpu": "2", "memory": "4Gi"})

    def test_slots_get_no_ingress_and_no_private_egress(self) -> None:
        np = one(self.docs, "NetworkPolicy")
        self.assertEqual(np["spec"]["ingress"], [])
        self.assertEqual(np["spec"]["podSelector"]["matchLabels"]["app.kubernetes.io/component"], "agent-slot")
        block = np["spec"]["egress"][1]["to"][0]["ipBlock"]
        self.assertIn("169.254.0.0/16", block["except"])
        self.assertIn("10.0.0.0/8", block["except"])


class Kata(unittest.TestCase):
    docs: list[dict]

    @classmethod
    def setUpClass(cls) -> None:
        cls.docs = render("kata-values.yaml")

    def test_slot_pod_runs_under_kata_and_is_a_vm_boundary(self) -> None:
        pod = slot_pod(self.docs)
        self.assertEqual(pod["spec"]["runtimeClassName"], "kata")
        self.assertEqual(pod["spec"]["containers"][0]["image"], "ghcr.io/example/cmux-guest@sha256:" + "1" * 64)
        self.assertTrue(config(self.docs)["slot"]["vmBoundary"])

    def test_existing_join_secret_is_used_not_created(self) -> None:
        names = [d["metadata"]["name"] for d in self.docs if d["kind"] == "Secret"]
        self.assertEqual(names, ["t-cmux-agent-host-host-credential"])
        env = one(self.docs, "Deployment")["spec"]["template"]["spec"]["containers"][0]["env"]
        token = next(e for e in env if e["name"] == "CMUX_JOIN_TOKEN")
        self.assertEqual(token["valueFrom"]["secretKeyRef"]["name"], "cmux-join")

    def test_digest_pins_the_agent_image(self) -> None:
        c = one(self.docs, "Deployment")["spec"]["template"]["spec"]["containers"][0]
        self.assertEqual(c["image"], "ghcr.io/example/acpmux@sha256:" + "0" * 64)

    def test_kubevirt_and_snapshot_rules_only_when_enabled(self) -> None:
        groups = {g for r in one(self.docs, "Role")["rules"] for g in r["apiGroups"]}
        self.assertEqual(groups, {"", "kubevirt.io", "subresources.kubevirt.io", "snapshot.kubevirt.io",
                                  "clone.kubevirt.io", "snapshot.storage.k8s.io"})

    def test_vm_boundary_can_be_forced_off(self) -> None:
        docs = render("kata-values.yaml", sets=("slot.vmBoundary=false",))
        self.assertFalse(config(docs)["slot"]["vmBoundary"])


class Refusals(unittest.TestCase):
    def test_needs_a_join_token(self) -> None:
        self.assertIn("join.existingSecret", render_fails("image.repository=r", "image.tag=1"))

    def test_needs_an_image(self) -> None:
        self.assertIn("image.repository is required", render_fails("join.token=x"))

    def test_rejects_a_bad_vm_boundary(self) -> None:
        err = render_fails("image.repository=r", "image.tag=1", "join.token=x", "slot.vmBoundary=maybe")
        self.assertIn("slot.vmBoundary", err)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--helm", default="helm")
    ns, rest = parser.parse_known_args()
    HELM = ns.helm
    unittest.main(argv=[sys.argv[0], *rest], verbosity=2)
