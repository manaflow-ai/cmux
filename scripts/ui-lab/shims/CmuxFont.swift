import SwiftUI

// Stand-in for CmuxFoundation's View.cmuxFont: the base text-style size
// without the global font magnification.
extension View {
    func cmuxFont(_ style: Font.TextStyle) -> some View {
        font(.system(style))
    }
}
