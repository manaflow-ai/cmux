import UIKit

/// Home's one list header: the active banner cards stacked top to bottom
/// (update required, then offline). A single boundary item, because
/// compositional layout overlaps boundary items that share an alignment.
@MainActor
final class HomeBannersView: UICollectionReusableView {
    /// One element kind per set of cards: a header whose cards change gets a
    /// new kind, so the layout measures it again instead of keeping the old
    /// self-sized height.
    nonisolated static let elementKinds = ["home.banners.update", "home.banners.offline", "home.banners.update-offline"]

    struct State: Equatable {
        var updateRequired: HomeUpdateRequired?
        var isOffline = false

        /// The element kind for these cards; nil when no card shows.
        var elementKind: String? {
            switch (updateRequired != nil, isOffline) {
            case (false, false): nil
            case (true, false): HomeBannersView.elementKinds[0]
            case (false, true): HomeBannersView.elementKinds[1]
            case (true, true): HomeBannersView.elementKinds[2]
            }
        }
    }

    private let updateRequired = UpdateRequiredBannerView()
    private let offline = OfflineBannerView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        let stack = UIStackView(arrangedSubviews: [updateRequired, offline])
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
        offline.isHidden = !state.isOffline
    }
}
