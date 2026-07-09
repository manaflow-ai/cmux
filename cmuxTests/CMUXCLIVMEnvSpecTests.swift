import Testing

/// Parser + chain-hash tests for the `cmux vm env` spec codec. The hash
/// vectors here are shared byte-for-byte with the TypeScript mirror
/// (`web/tests/vm-env-chainhash.test.ts`); if either side changes, both tests
/// fail together, which is the point.
struct CMUXCLIVMEnvSpecTests {
    @Test
    func parsesFullSpec() throws {
        let text = """
        # ghostty dev environment
        version: 1
        name: ghostty
        base: default
        env:
          FOO: "bar baz"
          A: '1'
        steps:
          - name: system packages
            run: sudo apt-get install -y libgtk-4-dev
            timeoutMinutes: 20
          - name: build
            run: |
              cd ghostty
              zig build
        verify:
          - run: zig version
        """
        let spec = try VMEnvSpecCodec.parse(text)
        #expect(spec.name == "ghostty")
        #expect(spec.base == "default")
        #expect(spec.env == ["FOO": "bar baz", "A": "1"])
        #expect(spec.steps.count == 2)
        #expect(spec.steps[0].name == "system packages")
        #expect(spec.steps[0].run == "sudo apt-get install -y libgtk-4-dev")
        #expect(spec.steps[0].timeoutMinutes == 20)
        #expect(spec.steps[1].run == "cd ghostty\nzig build")
        #expect(spec.steps[1].timeoutMinutes == nil)
        #expect(spec.verify == ["zig version"])
    }

    @Test
    func rejectsMissingVersion() {
        #expect(throws: VMEnvSpecParseError.self) {
            try VMEnvSpecCodec.parse("steps:\n  - run: echo hi\n")
        }
    }

    @Test
    func rejectsStepWithoutRun() {
        #expect(throws: VMEnvSpecParseError.self) {
            try VMEnvSpecCodec.parse("version: 1\nsteps:\n  - name: broken\n")
        }
    }

    @Test
    func rejectsEnvKeyThatIsNotAShellIdentifier() {
        // Env keys are emitted as `export KEY=...` in bash step scripts; a
        // hyphenated key would break every step under `set -e` at runtime.
        #expect(throws: VMEnvSpecParseError.self) {
            try VMEnvSpecCodec.parse("version: 1\nenv:\n  MY-VAR: x\nsteps:\n  - run: echo hi\n")
        }
        #expect(throws: VMEnvSpecParseError.self) {
            try VMEnvSpecCodec.parse("version: 1\nenv:\n  1BAD: x\nsteps:\n  - run: echo hi\n")
        }
    }

    @Test
    func rejectsUnknownTopLevelKey() {
        #expect(throws: VMEnvSpecParseError.self) {
            try VMEnvSpecCodec.parse("version: 1\nsteos:\n  - run: echo hi\n")
        }
    }

    @Test
    func rejectsUnknownStepKey() {
        #expect(throws: VMEnvSpecParseError.self) {
            try VMEnvSpecCodec.parse("version: 1\nsteps:\n  - run: echo hi\n    cache: false\n")
        }
    }

    @Test
    func blockScalarKeepsInteriorBlankLinesAndDropsTrailing() throws {
        let text = """
        version: 1
        steps:
          - name: multi
            run: |
              line one

              line three

        """
        let spec = try VMEnvSpecCodec.parse(text)
        #expect(spec.steps[0].run == "line one\n\nline three")
    }

    @Test
    func canonicalStepJSONMatchesSharedVectors() {
        let env = ["FOO": "bar baz", "A": "1"]
        #expect(
            VMEnvSpecCodec.canonicalStepJSON(run: "echo hello", env: env)
                == #"{"env":{"A":"1","FOO":"bar baz"},"run":"echo hello"}"#
        )
        #expect(
            VMEnvSpecCodec.canonicalStepJSON(run: "apt-get install -y cowsay\nline2", env: env)
                == #"{"env":{"A":"1","FOO":"bar baz"},"run":"apt-get install -y cowsay\nline2"}"#
        )
        #expect(
            VMEnvSpecCodec.canonicalStepJSON(run: "git clone \"https://x\" && echo 'done'", env: [:])
                == #"{"env":{},"run":"git clone \"https://x\" && echo 'done'"}"#
        )
    }

    @Test
    func chainHashesMatchSharedVectors() {
        let spec = VMEnvSpec(
            name: nil,
            base: nil,
            env: ["FOO": "bar baz", "A": "1"],
            steps: [
                VMEnvSpec.Step(name: "one", run: "echo hello", timeoutMinutes: nil),
                VMEnvSpec.Step(name: "two", run: "apt-get install -y cowsay\nline2", timeoutMinutes: nil),
            ],
            verify: []
        )
        let hashes = VMEnvSpecCodec.chainHashes(provider: "freestyle", baseImageId: "img-1", spec: spec)
        #expect(hashes == [
            "14ea949a0303c3de1847fd3bc41d68f30ddf5687783691e662365a8b2f4c9c5d",
            "41a20fb093a240d59ff3f27a7a22c938e2efed46980e585dbdbc0f399cd60db6",
        ])

        let quoting = VMEnvSpec(
            name: nil,
            base: nil,
            env: [:],
            steps: [VMEnvSpec.Step(name: "clone", run: "git clone \"https://x\" && echo 'done'", timeoutMinutes: nil)],
            verify: []
        )
        let quotingHashes = VMEnvSpecCodec.chainHashes(provider: "freestyle", baseImageId: "snap-abc", spec: quoting)
        #expect(quotingHashes == ["66eb63edfbe60da8444f9336652f90433883596d54667162dc95b71132055593"])
    }

    @Test
    func renamingAStepDoesNotChangeItsHash() {
        func spec(name: String) -> VMEnvSpec {
            VMEnvSpec(
                name: nil,
                base: nil,
                env: [:],
                steps: [VMEnvSpec.Step(name: name, run: "echo stable", timeoutMinutes: nil)],
                verify: []
            )
        }
        let a = VMEnvSpecCodec.chainHashes(provider: "freestyle", baseImageId: "img", spec: spec(name: "before"))
        let b = VMEnvSpecCodec.chainHashes(provider: "freestyle", baseImageId: "img", spec: spec(name: "after"))
        #expect(a == b)
    }

    @Test
    func specDigestMatchesSharedVector() {
        #expect(VMEnvSpecCodec.specDigest("version: 1\n") == "09bfcc6a14b83e2192b8673677725c84883ee9cd0c70e45c9ec09daa8f2b2847")
    }
}
