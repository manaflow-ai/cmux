import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct SidebarFooterPresentationTests {
    @Test
    @MainActor
    func minimalModeSidebarFooterRevealsOnHoverAndDuringActiveUpdate() {
        let hoveredControls = SidebarFooterControl.allCases.filter {
            SidebarFooterPresentationPolicy.isVisible(
                $0,
                presentationMode: .minimal,
                isHovered: true
            )
        }
        #expect(hoveredControls == SidebarFooterControl.allCases)

        let activeUpdateControls = SidebarFooterControl.allCases.filter {
            SidebarFooterPresentationPolicy.isVisible(
                $0,
                presentationMode: .minimal,
                isUpdateActive: true
            )
        }
        #expect(activeUpdateControls == [.update])
        #expect(
            !SidebarFooterPresentationPolicy.isVisible(
                .update,
                presentationMode: .minimal
            )
        )
    }

}
