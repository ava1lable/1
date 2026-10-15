# MirrorGoodGood Touch Agent 1.4.0

Pinned public Appium WebDriverAgent 12.0.0 with independent USB-only control endpoints. Minimum iOS 16. Compile on macOS 15 / Xcode 16.4, unsigned IPA; sign locally with your own account, retaining the nested XCTest bundle and frameworks. Host bundle remains com.jinghaohao.touch.runner.

The optimized /jhh/v1/keys endpoint takes one fresh system keyboard snapshot per request, matches key labels in memory, validates geometry against XCTest keyboard anchors, and submits a single sequential tap record. Batches are bounded to eight plain letters. Space, deletion, Return, modifiers, numbers and symbols are single-key barriers; the first letter after a layout boundary is also alone. Single-key layout switches use the existing explicit slow path before any fast event is submitted. No uncertain request is retried.

Keyboard coordinates are cached for at most five seconds and only reused when the active app, orientation and fresh keyboard frame match. Key snapshots or input fields are never cached. No input-field search, setValue, typeText, clipboard injection or keyboard extension. Chinese uses the iPhone system 26-key Pinyin keyboard; choose candidates on the mirrored phone.

The desktop collects press transitions without waiting for the phone, preserving every key in a bounded per-device queue. Unsent keys are cleared on device switch, focus loss, geometry change, overflow or expiry. Disconnect never replays old input. Sequence and instance checks apply across gesture and keyboard requests. Only selected-device USB forwarding is used. The service binds 127.0.0.1:8100, has no screenshot broadcaster and exposes only status, gesture, legacy key and bounded keys routes.

Build and simulated throughput checks do not establish real-phone latency. Actual English/Pinyin input, layout mapping and iOS 16 latency must be measured after signing and installation. Desktop GPL-3.0-only, new patches BSD-3-Clause; upstream and dependency licenses ship with corresponding source. No credentials are uploaded.
