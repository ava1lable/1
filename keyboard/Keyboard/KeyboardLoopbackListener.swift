// SPDX-License-Identifier: BSD-3-Clause
import Foundation
import Network

// All methods and callbacks run on the main queue. Stop is asynchronous: a new
// listener must wait for the old listener's cancellation acknowledgement.
final class KeyboardLoopbackListener {
    enum Phase { case stopped, starting, ready, stopping }
    private(set) var phase: Phase = .stopped
    private var server: NWListener?
    private var wanted = false
    private var timer: DispatchWorkItem?
    private var waitingCode: String?
    private let port: NWEndpoint.Port
    var onReady: (() -> Void)?
    var onWaiting: ((String) -> Void)?
    var onFailure: ((String) -> Void)?
    var onConnection: ((NWConnection) -> Void)?

    init(port: NWEndpoint.Port = 9031) { self.port = port }

    static func parameters() -> NWParameters {
        let parameters = NWParameters.tcp
        // Select the loopback interface without also specifying a second local
        // address/port in requiredLocalEndpoint. No Wi-Fi/LAN listener is used.
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        return parameters
    }

    static func errorCode(_ error: Error) -> String {
        guard let error = error as? NWError else { return "listener_setup_failed" }
        switch error {
        case .posix(let code): return "POSIX_\(code.rawValue)"
        case .dns(let code): return "DNS_\(code)"
        case .tls(let code): return "TLS_\(code)"
        @unknown default: return "listener_failed"
        }
    }

    func start() {
        precondition(Thread.isMainThread)
        wanted = true
        if server == nil { create() } else { cancelCurrent() }
    }

    func stop() {
        precondition(Thread.isMainThread)
        wanted = false
        if server != nil { cancelCurrent() }
        else { timer?.cancel(); timer = nil; phase = .stopped }
    }

    private func cancelCurrent() {
        guard let old = server, phase != .stopping else { return }
        timer?.cancel()
        phase = .stopping
        let deadline = DispatchWorkItem { [weak self, weak old] in
            guard let self = self, let old = old, self.server === old, self.phase == .stopping else { return }
            // Do not bind another listener when cancellation is unconfirmed.
            self.wanted = false
            self.onFailure?("listener_close_timeout")
        }
        timer = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: deadline)
        old.cancel()
    }

    private func create() {
        guard wanted, server == nil else { return }
        do {
            let current = try NWListener(using: Self.parameters(), on: port)
            server = current; phase = .starting; waitingCode = nil
            current.stateUpdateHandler = { [weak self, weak current] state in
                guard let self = self, let current = current, self.server === current else { return }
                switch state {
                case .cancelled:
                    self.timer?.cancel(); self.timer = nil
                    self.server = nil; self.phase = .stopped
                    if self.wanted { self.create() }
                case .ready where self.phase != .stopping && self.wanted:
                    self.timer?.cancel(); self.timer = nil; self.phase = .ready
                    self.onReady?()
                case .waiting(let error) where self.phase != .stopping && self.wanted:
                    self.waitingCode = Self.errorCode(error)
                    self.onWaiting?(self.waitingCode!)
                case .failed(let error) where self.phase != .stopping && self.wanted:
                    self.wanted = false; self.cancelCurrent()
                    self.onFailure?(Self.errorCode(error))
                default: break
                }
            }
            current.newConnectionHandler = { [weak self, weak current] connection in
                guard let self = self, let current = current, self.server === current,
                      self.wanted, self.phase == .ready, let handler = self.onConnection else {
                    connection.cancel(); return
                }
                handler(connection)
            }
            let deadline = DispatchWorkItem { [weak self, weak current] in
                guard let self = self, let current = current, self.server === current,
                      self.wanted, self.phase == .starting else { return }
                let code = self.waitingCode.map { "listener_start_timeout:\($0)" } ?? "listener_start_timeout"
                self.wanted = false; self.cancelCurrent(); self.onFailure?(code)
            }
            timer = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: deadline)
            current.start(queue: .main)
        } catch {
            wanted = false; server = nil; phase = .stopped
            onFailure?(Self.errorCode(error))
        }
    }
}
