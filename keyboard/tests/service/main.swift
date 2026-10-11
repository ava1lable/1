// SPDX-License-Identifier: BSD-3-Clause
// Real TCP + synthetic editing targets. Not an iOS/UIKit or visual receipt test.
import Foundation
import Network
import Darwin

var checks = 0
func check(_ value: Bool, _ message: String) {
    if !value { fputs("FAIL: \(message)\n", stderr); exit(1) }
    checks += 1
}
final class Target: KeyboardInputTarget {
    let keyboardDocument = "same-document"
    var keyboardHasFullAccess = true
    var inserts = 0
    var deletes = 0
    var pin = ""
    var ready: (() -> Void)?
    func keyboardInsert(_ text: String) { inserts += 1 }
    func keyboardDelete() { deletes += 1 }
    func keyboardServiceMessage(_ message: String) {
        guard let range = message.range(of: "电脑配对码：") else { return }
        pin = String(message[range.upperBound...].prefix(6))
        let callback = ready; ready = nil; callback?()
    }
}
final class Peer {
    let socket = NWConnection(host: "127.0.0.1", port: 9031, using: .tcp)
    var buffer = Data()
    var sequence = 0
    var pending: (([String: Any]) -> Void)?
    func open(_ action: @escaping () -> Void) {
        socket.stateUpdateHandler = { state in
            if case .ready = state { action() }
            if case .failed = state { check(false, "test peer transport failed") }
        }
        socket.start(queue: .main)
    }
    func request(_ action: String, _ extra: [String: Any] = [:], _ callback: @escaping ([String: Any]) -> Void) {
        check(pending == nil, "one request at a time")
        sequence += 1
        var frame: [String: Any] = ["v": 1, "id": sequence, "action": action]
        extra.forEach { frame[$0.key] = $0.value }
        var bytes = try! JSONSerialization.data(withJSONObject: frame); bytes.append(10)
        pending = callback
        socket.send(content: bytes, completion: .contentProcessed { error in
            check(error == nil, "send request")
        })
        receive()
    }
    private func receive() {
        socket.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, done, error in
            check(error == nil && !done && data != nil, "receive reply on original peer")
            self.buffer.append(data!)
            guard let index = self.buffer.firstIndex(of: 10) else { self.receive(); return }
            let frame = self.buffer.prefix(upTo: index); self.buffer.removeSubrange(...index)
            let response = try! JSONSerialization.jsonObject(with: frame) as! [String: Any]
            check(response["id"] as? Int == self.sequence, "matching response sequence")
            let callback = self.pending!; self.pending = nil; callback(response)
        }
    }
}

let service = KeyboardTextService()
var a: Target? = Target()
weak var original = a
let b = Target()
let peer = Peer()
var session = ""
var document = ""
var replacementCount = 0
var replacements: [Target] = [] // Keep old controllers alive, reproducing overlap.
var completed = false
DispatchQueue.main.asyncAfter(deadline: .now() + 35) {
    if !completed { check(false, "shared service checks timed out") }
}
func accepted(_ response: [String: Any]) { check(response["ok"] as? Bool == true, "request accepted") }
func rejected(_ response: [String: Any], _ code: String) {
    check(response["ok"] as? Bool == false && response["code"] as? String == code, "explicit safe rejection: \(code)")
}
func request(_ action: String, _ extra: [String: Any] = [:], _ callback: @escaping ([String: Any]) -> Void) {
    var values = extra; values["session"] = session; values["document"] = document
    peer.request(action, values, callback)
}
func finish() {
    check(original == nil, "destroyed controller is not retained")
    check(b.inserts == 1 && b.deletes == 1, "explicit edits reached only active owner")
    service.disconnect(b); peer.socket.cancel()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
        let listener = KeyboardLoopbackListener()
        listener.onFailure = { _ in check(false, "port not released after disconnect") }
        listener.onReady = {
            check(true, "port released after disconnect")
            listener.stop(); completed = true
            print("{\"shared_service_checks\":\(checks),\"overlapping_owners\":\(replacementCount),\"phone_tested\":false}")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exit(0) }
        }
        // Keep this independent probe alive through its ready callback.
        replacements.removeAll(); listener.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { _ = listener.phase }
    }
}
func returnToB() {
    service.activate(b)
    request("focus") { response in
        accepted(response); document = response["document"] as! String
        request("text", ["text": "synthetic"]) { response in
            accepted(response)
            request("delete") { response in
                accepted(response); finish()
            }
        }
    }
}
func nextOwner() {
    if replacementCount == 40 { returnToB(); return }
    let replacement = Target(); replacements.append(replacement)
    let old = replacements.count > 1 ? replacements[replacements.count - 2] : b
    let stablePin = b.pin
    service.activate(replacement)
    service.hide(old); service.disconnect(old); service.restart(old)
    check(replacement.pin == stablePin, "new controller shares existing pairing")
    replacementCount += 1
    request("text", ["text": "must-not-replay"]) { response in
        rejected(response, "document_changed")
        check(replacement.inserts == 0, "old document never writes into new owner")
        request("focus") { response in
            accepted(response); document = response["document"] as! String
            request("status") { response in accepted(response); nextOwner() }
        }
    }
}
func testReplacement() {
    let originalPin = a!.pin
    service.activate(b)
    service.hide(a!); service.disconnect(a!); service.restart(a!)
    check(b.pin == originalPin, "overlap keeps same listener PIN")
    check(a!.inserts == 1, "original owner received first edit only")
    a = nil
    request("text", ["text": "must-not-go-to-b"]) { response in
        rejected(response, "document_changed"); check(b.inserts == 0, "same proxy ID still needs new focus")
        nextOwner()
    }
}
a!.ready = {
    peer.open {
        peer.request("hello", ["pin": a!.pin]) { response in
            accepted(response); session = response["session"] as! String; document = response["document"] as! String
            request("text", ["text": "synthetic"]) { response in
                accepted(response); check(a!.inserts == 1, "first explicit edit invoked")
                let stablePin = a!.pin
                service.hide(a!)
                request("status") { response in
                    accepted(response)
                    request("text", ["text": "hidden"]) { response in
                        rejected(response, "keyboard_hidden"); check(a!.inserts == 1, "hidden keyboard does not edit")
                        service.activate(a!); check(a!.pin == stablePin, "same owner resume preserves pairing")
                        testReplacement()
                    }
                }
            }
        }
    }
}
service.activate(a!)
RunLoop.main.run()
