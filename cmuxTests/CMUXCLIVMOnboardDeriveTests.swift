import Foundation
import Testing

/// Derivation-ladder tests for `cmux vm onboard`: given repo fixtures on disk,
/// the deriver must synthesize a spec the strict env.yaml parser accepts.
struct CMUXCLIVMOnboardDeriveTests {
    private func makeRepo(files: [String: String]) throws -> String {
        let root = NSTemporaryDirectory() + "cmux-onboard-test-\(UUID().uuidString)"
        for (relative, content) in files {
            let path = (root as NSString).appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try content.write(toFile: path, atomically: true, encoding: .utf8)
        }
        if files.isEmpty {
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        }
        return root
    }

    @Test
    func workflowDerivationTranslatesSetupActionsAndRunSteps() throws {
        let workflow = """
        name: CI
        on: [push]
        jobs:
          build:
            runs-on: ubuntu-latest
            steps:
              - uses: actions/checkout@v4
              - name: setup zig
                uses: mlugg/setup-zig@v1
                with:
                  version: 0.13.0
              - name: system deps
                run: sudo apt-get update && sudo apt-get install -y libgtk-4-dev
              - name: build
                run: |
                  zig build
                  zig build test
              - name: upload
                run: echo "result=ok" >> "$GITHUB_OUTPUT"
        """
        let root = try makeRepo(files: [".github/workflows/ci.yml": workflow])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let derivation = try #require(VMOnboardDeriver.derive(
            repoRoot: root,
            cloneURL: "https://github.com/ghostty-org/ghostty",
            repoName: "ghostty"
        ))
        #expect(derivation.sources.map(\.kind) == [.githubWorkflow])
        let names = derivation.steps.map(\.name)
        #expect(names.first == "clone ghostty")
        #expect(names.contains("zig"))
        #expect(names.contains("system deps"))
        #expect(names.contains("build"))
        let zig = try #require(derivation.steps.first { $0.name == "zig" })
        #expect(zig.run == "mise use -g zig@0.13.0")
        let build = try #require(derivation.steps.first { $0.name == "build" })
        #expect(build.run == "cd ghostty\nzig build\nzig build test")
        // GITHUB_OUTPUT step is CI plumbing and must be dropped.
        #expect(!names.contains("upload"))
    }

    @Test
    func workflowDerivationSkipsNonLinuxJobsAndPrefersBuild() throws {
        let workflow = """
        jobs:
          mac-build:
            runs-on: macos-15
            steps:
              - run: xcodebuild build
          lint:
            runs-on: ubuntu-latest
            steps:
              - run: npx eslint .
          build:
            runs-on: ubuntu-latest
            steps:
              - uses: oven-sh/setup-bun@v2
              - run: bun install
              - run: bun test
        """
        let result = try #require(VMOnboardDeriver.deriveFromWorkflow(workflow, repoName: "app"))
        #expect(result.jobName == "build")
        #expect(result.steps.map(\.run).contains("mise use -g bun"))
        #expect(result.steps.map(\.run).contains("cd app\nbun install"))
    }

    @Test
    func devcontainerDerivationMapsFeaturesAndPostCreate() throws {
        let devcontainer = """
        {
          // dev environment
          "image": "mcr.microsoft.com/devcontainers/base:ubuntu",
          "features": {
            "ghcr.io/devcontainers/features/node:1": { "version": "20" },
            "ghcr.io/devcontainers/features/docker-in-docker:2": {}
          },
          "postCreateCommand": "npm install",
        }
        """
        let root = try makeRepo(files: [".devcontainer/devcontainer.json": devcontainer])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let derivation = try #require(VMOnboardDeriver.derive(
            repoRoot: root,
            cloneURL: "https://github.com/o/app",
            repoName: "app"
        ))
        #expect(derivation.sources.map(\.kind) == [.devcontainer])
        let toolStep = try #require(derivation.steps.first { $0.name == "toolchains (devcontainer features)" })
        #expect(toolStep.run == "mise use -g node@20")
        let post = try #require(derivation.steps.first { $0.name == "postCreateCommand" })
        #expect(post.run == "cd app\nnpm install")
    }

    @Test
    func miseAndHeuristicFallbacks() throws {
        let miseStep = try #require(VMOnboardDeriver.deriveFromMise("""
        [tools]
        node = "22"
        zig = "0.13.0"
        """))
        #expect(miseStep.run == "mise use -g node@22\nmise use -g zig@0.13.0")

        let toolVersions = try #require(VMOnboardDeriver.deriveFromToolVersions("nodejs 20.1.0\n# comment\n"))
        #expect(toolVersions.run == "mise use -g nodejs@20.1.0")

        let root = try makeRepo(files: ["Cargo.toml": "[package]\nname = \"x\"\n"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let derivation = try #require(VMOnboardDeriver.derive(
            repoRoot: root,
            cloneURL: "https://github.com/o/x",
            repoName: "x"
        ))
        #expect(derivation.sources.map(\.kind) == [.heuristic])
        #expect(derivation.steps.contains { $0.run.contains("cargo build") })
        #expect(derivation.verify.contains { $0.contains("cargo check") })
    }

    @Test
    func bareRepoStillYieldsCloneSpec() throws {
        let root = try makeRepo(files: ["README.md": "hi"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let derivation = try #require(VMOnboardDeriver.derive(
            repoRoot: root,
            cloneURL: "https://github.com/o/bare",
            repoName: "bare"
        ))
        #expect(derivation.sources.isEmpty)
        #expect(derivation.steps.count == 1)
        #expect(derivation.verify == ["test -d bare"])
    }

    @Test
    func renderedSpecRoundTripsThroughTheStrictParser() throws {
        let workflow = """
        jobs:
          test:
            runs-on: ubuntu-latest
            steps:
              - uses: actions/setup-node@v4
                with:
                  node-version: 22
              - name: install and test
                run: |
                  npm ci
                  npm test
        """
        let root = try makeRepo(files: [
            ".github/workflows/test.yml": workflow,
            "flake.nix": "{}",
        ])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let derivation = try #require(VMOnboardDeriver.derive(
            repoRoot: root,
            cloneURL: "https://github.com/o/app",
            repoName: "app"
        ))
        #expect(derivation.untranslated.contains { $0.contains("flake.nix") })
        let yaml = VMOnboardDeriver.renderSpecYAML(
            name: "app",
            derivation: derivation,
            derivedFrom: derivation.sources.map(\.path)
        )
        let parsed = try VMEnvSpecCodec.parse(yaml)
        #expect(parsed.name == "app")
        #expect(parsed.steps.count == derivation.steps.count)
        #expect(parsed.steps.map(\.run) == derivation.steps.map(\.run))
        #expect(parsed.verify == derivation.verify)
    }

    @Test
    func repoNameAndCloneURLNormalization() {
        #expect(VMOnboardDeriver.repoName(fromURL: "https://github.com/ghostty-org/ghostty.git") == "ghostty")
        #expect(VMOnboardDeriver.repoName(fromURL: "git@github.com:owner/repo.git") == "repo")
        #expect(VMOnboardDeriver.normalizedCloneURL("git@github.com:owner/repo.git") == "https://github.com/owner/repo")
        #expect(VMOnboardDeriver.normalizedCloneURL("https://github.com/owner/repo") == "https://github.com/owner/repo")
    }

    @Test
    func canonicalRepoKeyMatchesTransportsButNotBasenames() {
        // Same repo across transports, credentials, case, .git, trailing slash.
        #expect(
            VMOnboardDeriver.canonicalRepoKey("git@github.com:Owner/Repo.git")
                == VMOnboardDeriver.canonicalRepoKey("https://github.com/owner/repo/")
        )
        #expect(
            VMOnboardDeriver.canonicalRepoKey("https://user@github.com/owner/repo.git")
                == VMOnboardDeriver.canonicalRepoKey("https://github.com/owner/repo")
        )
        // Same basename, different owner: NOT the same repo.
        #expect(
            VMOnboardDeriver.canonicalRepoKey("https://github.com/other/ghostty")
                != VMOnboardDeriver.canonicalRepoKey("https://github.com/ghostty-org/ghostty")
        )
    }

    @Test
    func shellSafetyRejectsMetacharactersInURLAndName() {
        #expect(VMOnboardDeriver.isShellSafeCloneURL("https://github.com/owner/repo.git"))
        #expect(VMOnboardDeriver.isShellSafeCloneURL("git@github.com:owner/repo.git"))
        #expect(!VMOnboardDeriver.isShellSafeCloneURL("https://github.com/o/r;rm -rf ~"))
        #expect(!VMOnboardDeriver.isShellSafeCloneURL("https://github.com/o/$(id)"))
        #expect(!VMOnboardDeriver.isShellSafeCloneURL("https://github.com/o/`id`"))
        #expect(!VMOnboardDeriver.isShellSafeCloneURL("-oProxyCommand=evil"))
        #expect(VMOnboardDeriver.isShellSafeRepoName("my-repo_2.0"))
        #expect(!VMOnboardDeriver.isShellSafeRepoName("repo name"))
        #expect(!VMOnboardDeriver.isShellSafeRepoName("-repo"))
        #expect(!VMOnboardDeriver.isShellSafeRepoName(".."))
        #expect(!VMOnboardDeriver.isShellSafeRepoName("a&&b"))
    }

    @Test
    func workflowDerivationKeepsMatrixJobsAndActionsPaths() throws {
        let workflow = """
        jobs:
          build:
            runs-on: ${{ matrix.os }}
            steps:
              - name: prepare
                run: cp -r custom-actions/ dist/
              - name: build
                run: make build
        """
        let result = try #require(VMOnboardDeriver.deriveFromWorkflow(workflow, repoName: "app"))
        #expect(result.jobName == "build")
        // A run line that merely mentions an `actions/` path is a real command.
        #expect(result.steps.map(\.run).contains("cd app\ncp -r custom-actions/ dist/"))
        #expect(result.steps.map(\.run).contains("cd app\nmake build"))
    }

    @Test
    func workflowDerivationHonorsWorkingDirectories() throws {
        let workflow = """
        jobs:
          build:
            runs-on: ubuntu-latest
            defaults:
              run:
                working-directory: web
            steps:
              - name: install
                run: npm ci
              - name: native build
                working-directory: ./native
                run: make
              - name: escape attempt
                working-directory: ../outside
                run: whoami
        """
        let result = try #require(VMOnboardDeriver.deriveFromWorkflow(workflow, repoName: "app"))
        let runs = result.steps.map(\.run)
        // Job default working-directory applies to plain steps.
        #expect(runs.contains("cd app/web\nnpm ci"))
        // Step-level working-directory overrides the job default.
        #expect(runs.contains("cd app/native\nmake"))
        // Directories that escape the clone are dropped, not run at the root.
        #expect(!runs.contains { $0.contains("whoami") })
    }

    @Test
    func workflowDerivationHandlesFourSpaceIndentAndMiseAction() throws {
        let workflow = """
        name: CI
        jobs:
            build:
                runs-on: ubuntu-latest
                steps:
                    - uses: jdx/mise-action@v2
                    - name: test
                      run: cargo test
        """
        let result = try #require(VMOnboardDeriver.deriveFromWorkflow(workflow, repoName: "app"))
        #expect(result.jobName == "build")
        // mise install must run inside the clone so it reads the repo's mise.toml.
        #expect(result.steps.map(\.run).contains("cd app\nmise install"))
        #expect(result.steps.map(\.run).contains("cd app\ncargo test"))
    }

    @Test
    func miseTomlStillContributesWhenWorkflowInstallsNoToolchains() throws {
        let workflow = """
        jobs:
          test:
            runs-on: ubuntu-latest
            steps:
              - run: make test
        """
        let root = try makeRepo(files: [
            ".github/workflows/test.yml": workflow,
            "mise.toml": "[tools]\nnode = \"22\"\n",
        ])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let derivation = try #require(VMOnboardDeriver.derive(
            repoRoot: root,
            cloneURL: "https://github.com/o/app",
            repoName: "app"
        ))
        // Workflow only ran plain commands (preinstalled runner), so the
        // declared toolchains still get their layer.
        #expect(derivation.sources.map(\.kind).contains(.githubWorkflow))
        #expect(derivation.sources.map(\.kind).contains(.mise))
        // The toolchain layer must come after the clone but before the
        // workflow's project commands.
        let miseIndex = try #require(derivation.steps.firstIndex { $0.run == "mise use -g node@22" })
        let testIndex = try #require(derivation.steps.firstIndex { $0.run == "cd app\nmake test" })
        #expect(miseIndex == 1)
        #expect(miseIndex < testIndex)
    }

    @Test
    func devcontainerFallsBackToRootFileWhenNestedYieldsNothing() throws {
        let root = try makeRepo(files: [
            ".devcontainer/devcontainer.json": "{ \"image\": \"ubuntu\" }",
            ".devcontainer.json": "{ \"postCreateCommand\": \"npm install\" }",
        ])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let derivation = try #require(VMOnboardDeriver.derive(
            repoRoot: root,
            cloneURL: "https://github.com/o/app",
            repoName: "app"
        ))
        #expect(derivation.sources.map(\.path) == [".devcontainer.json"])
        #expect(derivation.steps.contains { $0.run == "cd app\nnpm install" })
    }

    @Test
    func hiddenMiseTomlIsLabeledWithItsActualPath() throws {
        let root = try makeRepo(files: [".mise.toml": "[tools]\nnode = \"22\"\n"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let derivation = try #require(VMOnboardDeriver.derive(
            repoRoot: root,
            cloneURL: "https://github.com/o/app",
            repoName: "app"
        ))
        #expect(derivation.sources.map(\.path) == [".mise.toml"])
        #expect(derivation.steps.contains { $0.run == "mise use -g node@22" })
    }
}
