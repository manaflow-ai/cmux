import CmuxiOSFeatureKit
import CmuxiOSFilesCore
import UIKit

/// One transfer: name, status line and a progress bar.
final class TransferCell: UITableViewCell {
    static let reuseID = "TransferCell"

    private let nameLabel = UILabel()
    private let statusLabel = UILabel()
    private let bar = UIProgressView(progressViewStyle: .default)
    private let icon = UIImageView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        nameLabel.font = .preferredFont(forTextStyle: .body)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0
        icon.tintColor = .secondaryLabel
        icon.contentMode = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let text = UIStackView(arrangedSubviews: [nameLabel, statusLabel, bar])
        text.axis = .vertical
        text.spacing = 4
        let row = UIStackView(arrangedSubviews: [icon, text])
        row.spacing = 12
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ item: TransferItem) {
        nameLabel.text = item.request.displayName
        icon.image = UIImage(systemName: item.request.isUpload ? "arrow.up.circle" : "arrow.down.circle")
        statusLabel.text = TransferStatusText(item: item).text
        bar.isHidden = item.progress.state == .finished || item.progress.state == .cancelled
        bar.progress = Float(item.progress.fraction ?? 0)
        // The arrow glyph is the only visual cue for the direction; say it.
        let direction = item.request.isUpload
            ? String(localized: "files.cell.upload", defaultValue: "Upload", bundle: .module)
            : String(localized: "files.cell.download", defaultValue: "Download", bundle: .module)
        accessibilityLabel = [direction, nameLabel.text, statusLabel.text].compactMap { $0 }.joined(separator: ", ")
        accessibilityValue = item.progress.fraction.map { $0.formatted(.percent.precision(.fractionLength(0))) }
    }
}
