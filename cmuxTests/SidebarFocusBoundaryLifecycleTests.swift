import AppKit
import Testing
@testable import cmux_DEV

@Suite
@MainActor
struct SidebarFocusBoundaryLifecycleTests {
    @Test
    func visibilityMutationNotifiesBeforePublishedStateChanges() {
        let state = SidebarState(isVisible: true)
        var requestedValues: [Bool] = []
        var valuesDuringNotification: [Bool] = []
        state.installVisibilityWillChangeHandler(ownerId: UUID()) { requestedValue in
            requestedValues.append(requestedValue)
            valuesDuringNotification.append(state.isVisible)
        }

        state.setVisible(false)
        state.setVisible(false)

        #expect(requestedValues == [false])
        #expect(valuesDuringNotification == [true])
        #expect(!state.isVisible)
    }

    @Test
    func windowlessStaleHostCallbackDoesNotEraseMountedReplacement() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 180))
        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = root
        defer { window.close() }

        let reference = SidebarFocusBoundaryReference()
        let firstHost = makeHost(reference: reference, frame: root.bounds)
        root.addSubview(firstHost)
        let replacementHost = makeHost(reference: reference, frame: root.bounds)
        root.addSubview(replacementHost)

        firstHost.removeFromSuperview()
        SidebarPointerEventHost.dismantleNSView(firstHost, coordinator: ())

        #expect(
            reference.contains(replacementHost, in: window),
            "A windowless callback from the stale host must not replace the mounted boundary."
        )
    }

    private func makeHost(
        reference: SidebarFocusBoundaryReference,
        frame: NSRect
    ) -> SidebarPointerEventHostView {
        let host = SidebarPointerEventHostView(frame: frame)
        host.onResolve = { reference.attach($0) }
        host.onDismantle = { reference.detach($0) }
        return host
    }
}

@Suite
@MainActor
struct SidebarStateAnimatedToggleTests {
    /// An animated hide keeps `isVisible` true until its slide lands. The
    /// request is hidden at once, and a second toggle mid-slide asks to show
    /// again instead of repeating the hide.
    @Test
    func toggleDuringAHideSlideReversesIt() {
        let state = SidebarState(isVisible: true)
        var requests: [Bool] = []
        state.animatedVisibilityOrchestrator = { targetVisible in
            requests.append(targetVisible)
            state.pendingVisibility = targetVisible
            return true
        }

        state.toggle()
        #expect(state.isVisible)
        #expect(!state.requestedVisibility)

        state.toggle()
        #expect(requests == [false, true])

        state.setVisible(true)
        #expect(state.pendingVisibility == nil)
        #expect(state.requestedVisibility)
    }

    /// A show slide keeps `isVisible` false until it lands; a hide that
    /// interrupts it, and the press after that, must both register.
    @Test
    func showHideShowMidSlideIsNotSwallowed() {
        let state = SidebarState(isVisible: false)
        var requests: [Bool] = []
        state.animatedVisibilityOrchestrator = { targetVisible in
            requests.append(targetVisible)
            state.pendingVisibility = targetVisible == state.isVisible ? nil : targetVisible
            return true
        }

        state.toggle()
        state.toggle()
        state.toggle()
        #expect(requests == [true, false, true])
        #expect(state.requestedVisibility)
        #expect(!state.isVisible)
    }

    /// The toggle animator drops a running slide when anyone else commits
    /// visibility, so every `setVisible` must report the commit, even one
    /// that repeats the current value, and clear a pending request.
    @Test
    func programmaticSetVisibleAlwaysReportsTheCommit() {
        let state = SidebarState(isVisible: true)
        var commits: [Bool] = []
        state.visibilityDidCommit = { commits.append($0) }
        state.pendingVisibility = false

        state.setVisible(true)
        #expect(commits == [true])
        #expect(state.pendingVisibility == nil)
        #expect(state.requestedVisibility)

        state.setVisible(false)
        state.setVisible(false)
        #expect(commits == [true, false, false])
        #expect(!state.isVisible)
    }
}

/// The toggle's slide machine, driven with a fake clock: the layout commits
/// only at the wide end, a press mid-slide retargets from where the motion
/// is (velocity carried, never overshooting), and any press sequence ends
/// with the layout matching the last request.
@Suite
struct SidebarToggleSlideMachineTests {
    private let width = 240.0

    @Test
    func hideCommitsAtTheKeypressAndShowCommitsOnLanding() {
        var machine = SidebarToggleSlideMachine(docked: true)
        let hide = machine.request(visible: false, width: width, now: 0)
        #expect(hide.first == .commitHiddenLayout)
        #expect(!machine.docked)
        guard case let .animate(slide)? = hide.last else {
            Issue.record("hide did not animate")
            return
        }
        #expect(slide.from == width && slide.to == 0)
        // The animation runs exactly until the spring is within its landing
        // tolerance; `springLandsWithinHalfAPoint` bounds that time.
        #expect(slide.duration == machine.spring.landingTime(from: width, to: 0, velocity: 0))
        #expect(machine.land(generation: slide.generation) == [.finishHide])

        let show = machine.request(visible: true, width: width, now: 1)
        #expect(!show.contains(.commitHiddenLayout))
        guard case let .animate(showSlide)? = show.first else {
            Issue.record("show did not animate")
            return
        }
        #expect(!machine.docked)
        #expect(machine.land(generation: showSlide.generation) == [.commitShownLayout])
        #expect(machine.docked)
    }

    @Test
    func reversalRetargetsFromThePresentedOffsetWithoutCommitting() throws {
        var machine = SidebarToggleSlideMachine(docked: true)
        _ = machine.request(visible: false, width: width, now: 0)
        let offset = try #require(machine.offset(at: 0.05))
        let reverse = machine.request(visible: true, width: width, now: 0.05)
        #expect(reverse.count == 1)
        guard case let .animate(slide)? = reverse.first else {
            Issue.record("reversal did not animate")
            return
        }
        #expect(abs(slide.from - offset) < 0.001)
        #expect(slide.to == width)
        // Moving away from the new target: no overshoot past the width.
        for step in 0...400 {
            let position = try #require(machine.offset(at: 0.05 + Double(step) / 1000))
            #expect(position <= width + 0.001 && position >= -0.001)
        }
    }

    /// A reversal hands its velocity to the next spring, so the motion
    /// turns around without a kink.
    @Test
    func reversalCarriesThePresentedVelocity() {
        var machine = SidebarToggleSlideMachine(docked: true)
        guard case let .animate(first)? = machine.request(visible: false, width: width, now: 0).last else {
            Issue.record("hide did not animate")
            return
        }
        let elapsed = 0.04
        let presented = machine.spring.velocity(from: first.from, to: first.to, velocity: first.velocity, at: elapsed)
        #expect(presented < 0, "the hide is moving toward 0")
        guard case let .animate(reverse)? = machine.request(visible: true, width: width, now: elapsed).first else {
            Issue.record("reversal did not animate")
            return
        }
        #expect(abs(reverse.velocity - presented) < 1e-9)
    }

    /// Every Core Animation stop lands, so a landing can arrive twice for
    /// the same slide; only the first may commit.
    @Test
    func repeatedLandingsCommitOnce() {
        var machine = SidebarToggleSlideMachine(docked: false)
        guard case let .animate(slide)? = machine.request(visible: true, width: width, now: 0).first else {
            Issue.record("show did not animate")
            return
        }
        #expect(machine.land(generation: slide.generation) == [.commitShownLayout])
        #expect(machine.land(generation: slide.generation).isEmpty)
        #expect(machine.docked && machine.slide == nil)
    }

    @Test
    func staleLandingsAreIgnored() {
        var machine = SidebarToggleSlideMachine(docked: true)
        guard case let .animate(first)? = machine.request(visible: false, width: width, now: 0).last else {
            Issue.record("hide did not animate")
            return
        }
        _ = machine.request(visible: true, width: width, now: 0.02)
        #expect(machine.land(generation: first.generation).isEmpty)
        #expect(machine.slide != nil)
    }

    @Test
    func spamEndsMatchingTheLastPressWithAtMostTwoCommits() {
        for presses in 1...21 {
            var machine = SidebarToggleSlideMachine(docked: true)
            var visible = true
            var commits = 0
            var now = 0.0
            for _ in 0..<presses {
                visible.toggle()
                let effects = machine.request(visible: visible, width: width, now: now)
                commits += effects.filter { $0 == .commitHiddenLayout || $0 == .commitShownLayout }.count
                now += 0.04
            }
            if let slide = machine.slide {
                let landed = machine.land(generation: slide.generation)
                commits += landed.filter { $0 == .commitHiddenLayout || $0 == .commitShownLayout }.count
            }
            #expect(machine.docked == visible, "\(presses) presses")
            #expect(machine.target == visible)
            #expect(machine.slide == nil)
            #expect(commits <= 2, "\(presses) presses committed \(commits) times")
        }
    }

    @Test
    func resetAbandonsTheSlide() {
        var machine = SidebarToggleSlideMachine(docked: true)
        guard case let .animate(slide)? = machine.request(visible: false, width: width, now: 0).last else {
            Issue.record("hide did not animate")
            return
        }
        machine.reset(visible: true)
        #expect(machine.docked && machine.target && machine.slide == nil)
        #expect(machine.land(generation: slide.generation).isEmpty)
    }

    @Test
    func springLandsWithinHalfAPoint() {
        let spring = SidebarSlideSpring()
        let landing = spring.landingTime(from: width, to: 0, velocity: 0)
        #expect(abs(spring.position(from: width, to: 0, velocity: 0, at: landing)) < 0.5)
        #expect(landing < 0.25)
    }
}
