import CmuxHomeCore
import UIKit

/// Home's one list header: the active banner cards stacked top to bottom
/// (update required, then the Chief that does not answer, then offline). A
/// single boundary item, because compositional layout overlaps boundary
/// items that share an alignment.
@MainActor
final class HomeBannersView: UICollectionReusableView {
    /// One element kind per set of cards: a header whose cards change gets a
    /// new kind, so the layout measures it again instead of keeping the old
    /// self-sized height. Every non-empty combination of the cards; the
    /// Chief card's Try Again and unavailable texts are cards of their own
    /// (other heights).
    nonisolated static let elementKinds: [String] = [false, true].flatMap { update in
        [nil, "chief", "chief-failed", "chief-unavailable"].flatMap { chief in
            [false, true].compactMap { offline in kind(update: update, chief: chief, offline: offline) }
        }
    }

    /// The kind for one set of cards, in stacking order; nil for no card.
    nonisolated static func kind(update: Bool, chief: String?, offline: Bool) -> String? {
        let names = [update ? "update" : nil, chief, offline ? "offline" : nil].compactMap { $0 }
        return names.isEmpty ? nil : "home.banners." + names.joined(separator: "-")
    }

    struct State: Equatable {
        var updateRequired: HomeUpdateRequired?
        /// The Hosted Chief does not answer (``HomeChiefBanner``).
        var chief: HomeChiefBanner?
        var isOffline = false

        /// The element kind for these cards; nil when no card shows. Turn On
        /// and its progress share a kind (same text), so the card re-renders
        /// in place while the answer is out.
        var elementKind: String? {
            let chiefKind = chief.map { banner in
                switch banner {
                case .off, .turningOn: "chief"
                case .failed: "chief-failed"
                case .unavailable: "chief-unavailable"
                }
            }
            return HomeBannersView.kind(update: updateRequired != nil, chief: chiefKind, offline: isOffline)
        }
    }

    var onTurnOnChief: (() -> Void)? {
        get { chief.onTurnOn }
        set { chief.onTurnOn = newValue }
    }

    private let updateRequired = UpdateRequiredBannerView()
    private let chief = ChiefOffBannerView()
    private let offline = OfflineBannerView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        let stack = UIStackView(arrangedSubviews: [updateRequired, chief, offline])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        configure(State())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ state: State) {
        if let requirement = state.updateRequired { updateRequired.configure(requirement) }
        updateRequired.isHidden = state.updateRequired == nil
        if let banner = state.chief { chief.configure(banner) }
        chief.isHidden = state.chief == nil
        offline.isHidden = !state.isOffline
    }
}
