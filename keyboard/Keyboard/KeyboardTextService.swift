// SPDX-License-Identifier: BSD-3-Clause
import Foundation
import Network

// A UIKit controller is a short-lived editing target, never a socket owner.
// The process owns exactly one service, including peers, authentication and PIN.
protocol KeyboardInputTarget: AnyObject {
    var keyboardDocument: String { get }
    var keyboardHasFullAccess: Bool { get }
    func keyboardInsert(_ text: String)
    func keyboardDelete()
    func keyboardServiceMessage(_ message: String)
}

final class KeyboardTextService {
    static let shared = KeyboardTextService()
    private let listener: KeyboardLoopbackListener
    private weak var target: KeyboardInputTarget?
    private var ownerGeneration = UUID().uuidString
    private var lastDocument = ""
    private var message = "正在启动 USB 文字服务…\n镜好好键盘 · 端口修复2"
    private var peers: [UUID: NWConnection] = [:]
    private var buffers: [UUID: Data] = [:]
    private var authenticated = Set<UUID>()
    private var sequences: [UUID: Int] = [:]
    private var pin = ""
    private var session = UUID().uuidString
    private var active = false
    private var inputVisible = false
    private var failures = 0
    private var document: String {
        if let target = target { lastDocument = ownerGeneration + ":" + target.keyboardDocument }
        return lastDocument
    }

    // Production uses only shared. Injection allows real TCP lifecycle tests.
    init(listener: KeyboardLoopbackListener = KeyboardLoopbackListener()) {
        self.listener = listener
        listener.onReady = { [weak self] in
            guard let self = self, self.active else { return }
            self.show("镜好好键盘 · USB · 端口修复2\n电脑配对码：\(self.pin)\n请在电脑选词，确认后文字写入这里。")
        }
        listener.onWaiting = { [weak self] code in
            guard let self = self, self.active else { return }
            self.show("文字服务正在等待（\(code)）\n如持续失败，请记录错误码。")
        }
        listener.onFailure = { [weak self] code in
            guard let self = self, self.active else { return }
            self.stop()
            let advice = code.contains("POSIX_48")
                ? "端口仍被另一进程占用。请关闭正在输入的 App 后重开，再切回镜好好键盘；仍失败可重启手机。"
                : "请记录错误码，再点重新连接。"
            self.show("文字服务无法启动（\(code)）\n\(advice)")
        }
        listener.onConnection = { [weak self] connection in
            guard let self = self, self.active, self.peers.count < 2 else { connection.cancel(); return }
            let id = UUID(); let generation = self.session
            self.peers[id] = connection; self.buffers[id] = Data()
            connection.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.remove(id) }
                if case .cancelled = state { self?.remove(id) }
            }
            connection.start(queue: .main); self.receive(id, generation)
        }
    }

    func activate(_ owner: KeyboardInputTarget) {
        precondition(Thread.isMainThread)
        if target !== owner { ownerGeneration = UUID().uuidString }
        target = owner; inputVisible = true
        guard owner.keyboardHasFullAccess else {
            stop()
            show("请在设置 → 通用 → 键盘中\n为镜好好键盘开启“允许完全访问”，再点重新连接。")
            return
        }
        if !active { start() } else { owner.keyboardServiceMessage(message) }
    }
    func hide(_ owner: KeyboardInputTarget) {
        precondition(Thread.isMainThread)
        guard target === owner else { return }
        // A stale controller disappearing must not hide the replacement owner.
        inputVisible = false
    }
    func disconnect(_ owner: KeyboardInputTarget) {
        precondition(Thread.isMainThread)
        guard target === owner else { return }
        inputVisible = false; stop(); target = nil
    }
    func restart(_ owner: KeyboardInputTarget) {
        precondition(Thread.isMainThread)
        guard target === owner, inputVisible else { return }
        stop(); activate(owner)
    }
    private func show(_ value: String) {
        message = value; target?.keyboardServiceMessage(value)
    }
    private func stop() {
        active = false; listener.stop()
        for peer in peers.values { peer.cancel() }
        peers.removeAll(); buffers.removeAll(); authenticated.removeAll(); sequences.removeAll()
        pin = ""; session = UUID().uuidString
    }
    private func start() {
        active = true; failures = 0
        pin = String(format: "%06d", Int.random(in: 0...999999))
        session = UUID().uuidString
        show("正在启动 USB 文字服务…\n镜好好键盘 · 端口修复2")
        listener.start()
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
            reply(id, request, ok: true, extra: ["session": session, "document": document])
            return
        }
        guard authenticated.contains(id), frame["session"] as? String == session, active else {
            reply(id, request, ok: false, code: "keyboard_inactive"); return
        }
        if action == "status" {
            reply(id, request, ok: true, extra: ["document": document]); return
        }
        guard inputVisible, let target = target, target.keyboardHasFullAccess else { reply(id, request, ok: false, code: "keyboard_hidden"); return }
        if action == "focus" {
            reply(id, request, ok: true, extra: ["document": document]); return
        }
        guard frame["document"] as? String == document else {
            reply(id, request, ok: false, code: "document_changed"); return
        }
        switch action {
        case "text":
            guard let text = frame["text"] as? String, !text.isEmpty, text.utf16.count <= 4096,
                  !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
                reply(id, request, ok: false, code: "invalid_text"); return
            }
            target.keyboardInsert(text)
        case "delete": target.keyboardDelete()
        // Return is deliberate only; it is never synthesized during pairing/health/reconnect.
        case "return": target.keyboardInsert("\n")
        default: reply(id, request, ok: false, code: "unsupported_action"); return
        }
        // UIKit has no general cross-app visual receipt. This means the API was invoked,
        // not that a third-party app displayed or sent the text.
        reply(id, request, ok: true, extra: ["receipt": "proxy_invoked"])
    }
}
