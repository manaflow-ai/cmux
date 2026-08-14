import UIKit

final class KeyboardDockViewController: UIViewController {
    private let terminal = UIView()
    private let composer = UIView()
    private let field = UITextField()
    private let toggle = UIButton(type: .system)
    private var bottomConstraint: NSLayoutConstraint!
    private var keyboardVisible = false
    private let reproducesSnap: Bool

    init() {
        reproducesSnap = ProcessInfo.processInfo.arguments.contains("--buggy")
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        reproducesSnap = false
        super.init(coder: coder)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        terminal.backgroundColor = UIColor(white: 0.12, alpha: 1)
        composer.backgroundColor = UIColor(white: 0.18, alpha: 1)
        field.placeholder = "Message"
        field.textColor = .white
        field.backgroundColor = UIColor(white: 0.25, alpha: 1)
        field.borderStyle = .roundedRect
        toggle.setTitle(reproducesSnap ? "Toggle keyboard (snap)" : "Toggle keyboard", for: .normal)
        toggle.tintColor = .white
        toggle.addTarget(self, action: #selector(toggleKeyboard), for: .touchUpInside)

        [terminal, composer].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        field.translatesAutoresizingMaskIntoConstraints = false
        toggle.translatesAutoresizingMaskIntoConstraints = false
        composer.addSubview(field)
        composer.addSubview(toggle)
        bottomConstraint = composer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            terminal.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            terminal.bottomAnchor.constraint(equalTo: composer.topAnchor),
            composer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomConstraint,
            composer.heightAnchor.constraint(equalToConstant: 88),
            field.leadingAnchor.constraint(equalTo: composer.leadingAnchor, constant: 16),
            field.centerYAnchor.constraint(equalTo: composer.centerYAnchor),
            field.trailingAnchor.constraint(equalTo: toggle.leadingAnchor, constant: -8),
            toggle.trailingAnchor.constraint(equalTo: composer.trailingAnchor, constant: -16),
            toggle.centerYAnchor.constraint(equalTo: composer.centerYAnchor),
        ])
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
    }

    @objc private func toggleKeyboard() {
        keyboardVisible ? field.resignFirstResponder() : field.becomeFirstResponder()
    }

    @objc private func keyboardWillChange(_ notification: Notification) {
        guard let info = notification.userInfo,
              let frame = info[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let duration = info[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval ?? 0.25
        let curve = (info[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int ?? 7) << 16
        let keyboardFrame = view.convert(frame, from: nil)
        let overlap = max(0, view.bounds.maxY - keyboardFrame.minY)
        keyboardVisible = overlap > 0

        if reproducesSnap {
            // Old path: commit geometry outside the keyboard transaction.
            bottomConstraint.constant = -overlap
            UIView.performWithoutAnimation { view.layoutIfNeeded() }
            return
        }

        // Fixed path: commit dock geometry in the same transaction as the keyboard.
        bottomConstraint.constant = -overlap
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, UIView.AnimationOptions(rawValue: UInt(curve))]
        ) {
            self.view.layoutIfNeeded()
        }
    }
}
