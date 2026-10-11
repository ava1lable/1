// SPDX-License-Identifier: BSD-3-Clause
import UIKit
import Network

final class KeyboardViewController: UIInputViewController {
    private let status = UILabel()
    private var listener: NWListener?
    private var peers: [UUID: NWConnection] = [:]
    private var buffers: [UUID: Data] = [:]
    private var authenticated = Set<UUID>()
    private var sequences: [UUID: Int] = [:]
    private var pin = ""
    private var session = UUID().uuidString
    private var active = false
    private var failures = 0
    private let port: NWEndpoint.Port = 9031

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
        if !active { start() }
    }
    override func viewWillDisappear(_ animated: Bool) {
        stop(); super.viewWillDisappear(animated)
    }
    @objc private func nextKeyboard() { stop(); advanceToNextInputMode() }
    @objc private func restartService() { stop(); start() }
    private func stop() {
        active = false; listener?.cancel(); listener = nil
        for peer in peers.values { peer.cancel() }
        peers.removeAll(); buffers.removeAll(); authenticated.removeAll(); sequences.removeAll()
        pin = ""; session = UUID().uuidString
    }
    private func start() {
        guard hasFullAccess else {
            status.text = "请在设置 → 通用 → 键盘中\n为镜好好键盘开启“允许完全访问”，再点重新连接。"
            return
        }
        active = true; failures = 0
        pin = String(format: "%06d", Int.random(in: 0...999999))
        session = UUID().uuidString
        let generation = session
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        do {
            let server = try NWListener(using: parameters, on: port)
            listener = server
            server.stateUpdateHandler = { [weak self] state in
                guard let self = self, self.active, self.session == generation else { return }
                switch state {
                case .ready: self.status.text = "镜好好键盘 · USB\n电脑配对码：\(self.pin)\n请在电脑选词，确认后文字写入这里。"
                case .failed: self.stop(); self.status.text = "文字服务无法启动，请点重新连接。"
                default: break
                }
            }
            server.newConnectionHandler = { [weak self] connection in
                guard let self = self, self.active, self.session == generation, self.peers.count < 2 else {
                    connection.cancel(); return
                }
                let id = UUID(); self.peers[id] = connection; self.buffers[id] = Data()
                connection.stateUpdateHandler = { [weak self] state in
                    if case .failed = state { self?.remove(id) }
                    if case .cancelled = state { self?.remove(id) }
                }
                connection.start(queue: .main); self.receive(id, generation)
            }
            server.start(queue: .main)
        } catch { stop(); status.text = "文字服务无法启动，请点重新连接。" }
    }
    private func remove(_ id: UUID) {
        peers.removeValue(forKey: id)?.cancel(); buffers.removeValue(forKey: id)
        authenticated.remove(id); sequences.removeValue(forKey: id)
    }
    private func receive(_ id: UUID, _ generation: String) {
        guard let peer = peers[id] else { return }
        peer.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            guard let self = self, self.active, self.session == generation, self.peers[id] != nil else { return }
            if let data = data {
                self.buffers[id, default: Data()].append(data)
                guard self.buffers[id]!.count <= 65536 else { self.remove(id); return }
                while let index = self.buffers[id]!.firstIndex(of: 10) {
                    let frame = self.buffers[id]!.prefix(upTo: index)
                    self.buffers[id]!.removeSubrange(...index)
                    self.handle(Data(frame), id)
                    if self.peers[id] == nil { return }
                }
            }
            if done || error != nil { self.remove(id) } else { self.receive(id, generation) }
        }
    }
    private func reply(_ id: UUID, _ request: Int, ok: Bool, code: String = "", extra: [String: Any] = [:]) {
        var response: [String: Any] = ["v": 1, "id": request, "ok": ok, "code": code]
        for (key, value) in extra { response[key] = value }
        guard var bytes = try? JSONSerialization.data(withJSONObject: response), let peer = peers[id] else { remove(id); return }
        bytes.append(10)
        peer.send(content: bytes, completion: .contentProcessed({ [weak self] error in
            if error != nil { self?.remove(id) }
        }))
    }
    private func handle(_ data: Data, _ id: UUID) {
        guard let frame = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let request = frame["id"] as? Int, request > (sequences[id] ?? 0),
              frame["v"] as? Int == 1, let action = frame["action"] as? String else { remove(id); return }
        sequences[id] = request
        if action == "hello" {
            guard !authenticated.contains(id), failures < 5, frame["pin"] as? String == pin else {
                failures += 1; reply(id, request, ok: false, code: "pairing_denied"); return
            }
            guard authenticated.isEmpty else { reply(id, request, ok: false, code: "already_connected"); return }
            authenticated.insert(id)
            reply(id, request, ok: true, extra: ["session": session, "document": textDocumentProxy.documentIdentifier.uuidString])
            return
        }
        guard authenticated.contains(id), frame["session"] as? String == session, active else {
            reply(id, request, ok: false, code: "keyboard_inactive"); return
        }
        if action == "status" || action == "focus" {
            reply(id, request, ok: true, extra: ["document": textDocumentProxy.documentIdentifier.uuidString]); return
        }
        guard frame["document"] as? String == textDocumentProxy.documentIdentifier.uuidString else {
            reply(id, request, ok: false, code: "document_changed"); return
        }
        switch action {
        case "text":
            guard let text = frame["text"] as? String, !text.isEmpty, text.utf16.count <= 4096,
                  !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
                reply(id, request, ok: false, code: "invalid_text"); return
            }
            textDocumentProxy.insertText(text)
        case "delete": textDocumentProxy.deleteBackward()
        // Return is deliberate only; it is never synthesized during pairing/health/reconnect.
        case "return": textDocumentProxy.insertText("\n")
        default: reply(id, request, ok: false, code: "unsupported_action"); return
        }
        // UIKit has no general cross-app visual receipt. This means the API was invoked,
        // not that a third-party app displayed or sent the text.
        reply(id, request, ok: true, extra: ["receipt": "proxy_invoked"])
    }
}
