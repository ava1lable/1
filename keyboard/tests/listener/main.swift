// SPDX-License-Identifier: BSD-3-Clause
// Real macOS TCP checks. These do not simulate a phone keyboard sandbox.
import Foundation
import Network
import Darwin

var checks = 0
func check(_ value: Bool, _ message: String) {
    if !value { fputs("FAIL: \(message)\n", stderr); exit(1) }
    checks += 1
}
let parameters = KeyboardLoopbackListener.parameters()
check(parameters.requiredInterfaceType == .loopback, "loopback interface only")
check(parameters.requiredLocalEndpoint == nil, "one port configuration")
check(parameters.allowLocalEndpointReuse, "endpoint reuse enabled")
check(KeyboardLoopbackListener.errorCode(NWError.posix(.EACCES)) == "POSIX_13", "safe numeric error")

let service = KeyboardLoopbackListener()
var rounds = 0
var peers: [NWConnection] = []
var client: NWConnection?
var completed = false
var blocker: Int32 = -1

DispatchQueue.main.asyncAfter(deadline: .now() + 35) {
    if !completed { fputs("FAIL: listener checks timed out\n", stderr); exit(1) }
}

func finish() {
    service.stop()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        check(service.phase == .stopped, "final cancellation acknowledged")
        completed = true
        print("{\"macos_loopback_checks\":\(checks),\"successful_tcp_rounds\":\(rounds),\"phone_tested\":false}")
        exit(0)
    }
}

func testOccupiedPort() {
    blocker = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    check(blocker >= 0, "create exclusive port owner")
    // Ignore a previous test connection's TIME_WAIT, without enabling the
    // SO_REUSEPORT option that would allow concurrent listening owners.
    var reuse: Int32 = 1
    check(setsockopt(blocker, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size)) == 0, "exclusive listener may reuse TIME_WAIT")
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(9031).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(blocker, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    check(bound == 0 && Darwin.listen(blocker, 2) == 0, "own port after stop")
    service.onReady = { check(false, "occupied port must not become ready") }
    service.onFailure = { code in
        check(code == "POSIX_48", "occupied port reports exact address-in-use error")
        Darwin.close(blocker); blocker = -1
        service.onFailure = { code in fputs("FAIL: recovery \(code)\n", stderr); exit(1) }
        service.onReady = { check(true, "manual restart after failure"); finish() }
        service.start()
    }
    service.start()
}

func nextRound() {
    client?.cancel(); client = nil
    peers.forEach { $0.cancel() }; peers.removeAll()
    if rounds == 12 {
        service.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            check(service.phase == .stopped, "stop closes listener")
            testOccupiedPort()
        }
    } else {
        service.start()
        check(service.phase == .stopping, "restart waits for cancellation")
        service.stop(); service.start(); service.start()
    }
}

service.onFailure = { code in fputs("FAIL: start \(code)\n", stderr); exit(1) }
service.onConnection = { connection in
    peers.append(connection)
    connection.start(queue: .main)
    connection.receive(minimumIncompleteLength: 5, maximumLength: 5) { data, _, _, error in
        check(error == nil && data == Data("probe".utf8), "receive real loopback TCP")
        connection.send(content: Data("ack".utf8), completion: .contentProcessed { error in
            check(error == nil, "send loopback acknowledgement")
        })
    }
}
service.onReady = {
    rounds += 1
    check(service.phase == .ready, "listener ready after cancellation")
    let connection = NWConnection(host: "127.0.0.1", port: 9031, using: .tcp)
    client = connection
    connection.stateUpdateHandler = { state in
        if case .ready = state {
            connection.send(content: Data("probe".utf8), completion: .contentProcessed { error in
                check(error == nil, "send real TCP probe")
            })
            connection.receive(minimumIncompleteLength: 3, maximumLength: 3) { data, _, _, error in
                check(error == nil && data == Data("ack".utf8), "receive real TCP acknowledgement")
                nextRound()
            }
        }
    }
    connection.start(queue: .main)
}
service.start()
// UIKit callbacks stay on the main thread. dispatchMain() exits that thread
// in a command-line process, so retain a run loop to match the host lifecycle.
RunLoop.main.run()
