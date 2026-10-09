import UIKit

/// One pill in the composer's scroller: a capsule button whose menu is its
/// primary action (HIG: pull-down menus).
struct ComposerPill {
    var id: String
    var symbol: String
    var title: String
    /// What VoiceOver reads before the value ("Agent").
    var label: String
    var menu: UIMenu?
    var isEnabled = true
}
