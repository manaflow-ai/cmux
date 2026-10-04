import UIKit

/// Home's one list header: the active banner cards stacked top to bottom
/// (update required first, then offline). A single boundary item, because
/// compositional layout overlaps boundary items that share an alignment.
@MainActor
final class HomeBannersView: UICollectionReusableView {
    static let elementKind = "home.banners"

    struct State: Equatable {
        var updateRequired: HomeUpdateRequired?
        var isOffline = false

        var isEmpty: Bool { updateRequired == nil && !isOffline }
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
