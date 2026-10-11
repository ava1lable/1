// SPDX-License-Identifier: BSD-3-Clause
import UIKit

final class KeyboardViewController: UIInputViewController, KeyboardInputTarget {
    private let status = UILabel()
    private let service = KeyboardTextService.shared
    var keyboardDocument: String { textDocumentProxy.documentIdentifier.uuidString }
    var keyboardHasFullAccess: Bool { hasFullAccess }
    func keyboardInsert(_ text: String) { textDocumentProxy.insertText(text) }
    func keyboardDelete() { textDocumentProxy.deleteBackward() }
    func keyboardServiceMessage(_ message: String) { status.text = message }
    override func viewDidLoad() {
        super.viewDidLoad()
        status.numberOfLines = 0
        status.textAlignment = .center
        status.font = .systemFont(ofSize: 15)
        let next = UIButton(type: .system)
        next.setTitle("切换键盘 🌐", for: .normal)
        next.addTarget(self, action: #selector(nextKeyboard), for: .touchUpInside)
        let restart = UIButton(type: .system)
        restart.setTitle("重新连接", for: .normal)
        restart.addTarget(self, action: #selector(restartService), for: .touchUpInside)
        let buttons = UIStackView(arrangedSubviews: [next, restart])
        buttons.distribution = .fillEqually
        let stack = UIStackView(arrangedSubviews: [status, buttons])
        stack.axis = .vertical; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 150)
        ])
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        service.activate(self)
    }
    override func viewWillDisappear(_ animated: Bool) {
        service.hide(self)
        super.viewWillDisappear(animated)
    }
    @objc private func nextKeyboard() { service.disconnect(self); advanceToNextInputMode() }
    @objc private func restartService() { service.restart(self) }
}
