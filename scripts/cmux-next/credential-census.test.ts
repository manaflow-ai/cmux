import { describe, expect, test } from "bun:test"
import { mkdtempSync, mkdirSync, writeFileSync, symlinkSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import path from "node:path"
import { census, kindByName, kindByText, markdown, readKind } from "./credential-census.ts"

// Fake values shaped like the real ones; none is a real credential.
const FAKE_KEY = "-----BEGIN OPENSSH PRIVATE KEY-----\nZmFrZS1rZXktYnl0ZXM=\n-----END OPENSSH PRIVATE KEY-----\n"
const FAKE_PEM = "-----BEGIN RSA PRIVATE KEY-----\nZmFrZQ==\n-----END RSA PRIVATE KEY-----\n"
const FAKE_SECRET = "fake-secret-value-for-census-test"

function home(files: Record<string, string>): string {
  const dir = mkdtempSync(path.join(tmpdir(), "census-"))
  for (const [rel, body] of Object.entries(files)) {
    mkdirSync(path.dirname(path.join(dir, rel)), { recursive: true })
    writeFileSync(path.join(dir, rel), body)
  }
  return dir
}

describe("credential census", () => {
  test("an empty home holds nothing", () => {
    const h = home({})
    try {
      expect(census([h]).rows).toEqual([])
    } finally {
      rmSync(h, { recursive: true })
    }
  })

  test("a joined machine's own credential, node key and egress CA are allowed", () => {
    const h = home({
      ".acpmux/machine-credential.json": `{"credential":"${FAKE_SECRET}"}`,
      ".acpmux/node.wg.key": "ZmFrZQ==",
      ".acpmux/machine-join.node-key-made.json": "{}",
      ".acpmux/vault-egress/ca-key.pem": FAKE_PEM,
    })
    try {
      const c = census([h])
      expect(c.rows.map((r) => [r.path, r.kind, r.allowed])).toEqual([
        ["~/.acpmux/machine-credential.json", "join-credential", true],
        ["~/.acpmux/node.wg.key", "node-key", true],
        ["~/.acpmux/vault-egress/ca-key.pem", "private-key", true],
      ])
      expect(c.foreign).toBe(0)
    } finally {
      rmSync(h, { recursive: true })
    }
  })

  test("a node key the join did not make (copied there) is foreign", () => {
    const h = home({ ".acpmux/node.wg.key": "ZmFrZQ==" })
    try {
      const c = census([h])
      expect(c.rows).toHaveLength(1)
      expect(c.rows[0]!.allowed).toBe(false)
      expect(c.foreign).toBe(1)
    } finally {
      rmSync(h, { recursive: true })
    }
  })

  test("every copied login kind is found and foreign", () => {
    const h = home({
      ".config/gh/hosts.yml": `github.com:\n    oauth_token: ${FAKE_SECRET}\n    user: someone\n`,
      ".claude/.credentials.json": `{"claudeAiOauth":{"accessToken":"${FAKE_SECRET}"}}`,
      ".codex/auth.json": `{"tokens":{"access_token":"${FAKE_SECRET}"}}`,
      ".ssh/id_ed25519": FAKE_KEY,
      ".ssh/id_ed25519.pub": "ssh-ed25519 AAAAfake someone",
      ".ssh/known_hosts": "github.com ssh-ed25519 AAAAfake",
      "work/deploy.pem": FAKE_PEM,
      "work/cert.pem": "-----BEGIN CERTIFICATE-----\nZmFrZQ==\n-----END CERTIFICATE-----\n",
      ".config/gcloud/application_default_credentials.json": "{}",
      ".config/gcloud/configurations/config_default": "[core]\n",
      ".netrc": `machine github.com login x password ${FAKE_SECRET}\n`,
      ".git-credentials": `https://x:${FAKE_SECRET}@github.com\n`,
      ".docker/config.json": `{"auths":{"ghcr.io":{"auth":"${FAKE_SECRET}"}}}`,
      "proj/.env": `DEBUG=1\nGITHUB_TOKEN=${FAKE_SECRET}\n`,
      "proj/.env.example": "GITHUB_TOKEN=\nNAME=x\n",
    })
    try {
      const c = census([h])
      const kinds = Object.fromEntries(c.rows.map((r) => [r.path, r.kind]))
      expect(kinds).toEqual({
        "~/.claude/.credentials.json": "claude-login",
        "~/.codex/auth.json": "codex-login",
        "~/.config/gcloud/application_default_credentials.json": "gcloud-credentials",
        "~/.config/gh/hosts.yml": "gh-login",
        "~/.docker/config.json": "docker-login",
        "~/.git-credentials": "git-credentials",
        "~/.netrc": "netrc",
        "~/.ssh/id_ed25519": "ssh-private-key",
        "~/proj/.env": "env-token",
        "~/work/deploy.pem": "private-key",
      })
      expect(c.rows.every((r) => !r.allowed)).toBe(true)
      expect(c.foreign).toBe(10)
    } finally {
      rmSync(h, { recursive: true })
    }
  })

  test("no row and no table line ever holds a file's contents", () => {
    const h = home({ ".netrc": `password ${FAKE_SECRET}`, "a/.env": `API_KEY=${FAKE_SECRET}`, ".ssh/id_rsa": FAKE_KEY })
    try {
      const c = census([h])
      const out = JSON.stringify(c) + markdown(c)
      expect(out).not.toContain(FAKE_SECRET)
      expect(out).not.toContain("ZmFrZS1rZXktYnl0ZXM=")
    } finally {
      rmSync(h, { recursive: true })
    }
  })

  test("a symlink is never followed", () => {
    const outside = home({ ".netrc": "password x" })
    const h = home({})
    try {
      symlinkSync(outside, path.join(h, "link"))
      expect(census([h]).rows).toEqual([])
    } finally {
      rmSync(h, { recursive: true })
      rmSync(outside, { recursive: true })
    }
  })

  test("names and texts classify as documented", () => {
    expect(kindByName(".config/gh/hosts.yml")).toBe("gh-login")
    expect(kindByName(".config/gcloud/legacy_credentials/a@b/adc.json")).toBe("gcloud-credentials")
    expect(kindByName("notes.txt")).toBeNull()
    expect(readKind("x/server.key")).toBe("key")
    expect(readKind("x/prod.env")).toBe("env")
    expect(readKind("x/readme.md")).toBeNull()
    expect(kindByText("env", "# TOKEN=abc\n")).toBeNull()
    expect(kindByText("env", "export NPM_TOKEN='abc'\n")).toBe("env-token")
    expect(kindByText("docker", '{"auths":{"x":{}}}')).toBeNull()
  })

  test("markdown says when nothing was found", () => {
    expect(markdown({ roots: ["/h"], scannedFiles: 3, truncated: false, rows: [], foreign: 0 })).toContain("| (none) |")
  })
})
