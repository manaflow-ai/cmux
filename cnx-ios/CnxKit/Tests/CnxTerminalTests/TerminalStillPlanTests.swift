import CoreGraphics
@testable import CnxTerminal
import Testing

/// qa11 grid-composer-in-card (build 246ef796): the stills behind the grid
/// cards and the saved relaunch frame composed the page's chrome layers
/// (composer, key bar, status bar band) over the rows, and the e2e-t2 card
/// showed the composer across its middle over rows. A still holds the
/// terminal's rows only: the rows between the top inset and the composer
/// card's top, on the terminal background; no chrome layer is drawn.
@Suite struct TerminalStillPlanTests {
    let bounds = CGRect(x: 0, y: 0, width: 402, height: 874)

    @Test func theRowsEndAtTheComposersTop() {
        #expect(TerminalStillPlan.rowsClip(bounds: bounds, topInset: 62, composerTop: 700)
                == CGRect(x: 0, y: 62, width: 402, height: 638))
        // Keyboard up: the composer sits higher; the rows under it are not shown.
        #expect(TerminalStillPlan.rowsClip(bounds: bounds, topInset: 62, composerTop: 400)
                == CGRect(x: 0, y: 62, width: 402, height: 338))
    }

    @Test func aComposerOutsideThePageClampsToIt() {
        #expect(TerminalStillPlan.rowsClip(bounds: bounds, topInset: 0, composerTop: 2000) == bounds)
        #expect(TerminalStillPlan.rowsClip(bounds: bounds, topInset: 62, composerTop: 10).isEmpty)
    }

    @Test func aStillDrawsNoChrome() {
        #expect(!TerminalStillPlan.drawsChromeLayers)
    }
}
