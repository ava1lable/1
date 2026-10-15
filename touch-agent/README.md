# MirrorGoodGood Touch Agent 1.3.0

Public-source independent XCTest agent based on pinned Appium WebDriverAgent 12.0.0. Requires iOS 16 or newer. Uses the selected phone USB tunnel and binds only 127.0.0.1:8100. Three endpoints: status, normalized gesture and native keyboard key.

The new keyboard endpoint taps visible keys inside the foreground app system keyboard. It never finds an input field or assigns its value, injects clipboard content, or calls typeText. Use the iPhone system 26-key Pinyin keyboard for Chinese and choose candidates in the mirrored phone image. Basic letters, digits, punctuation, Shift, space, backspace and an explicit Enter are supported when their keys are visible. Ctrl/Alt/Win shortcuts, arrows, Caps Lock and held-key repeat are not supported in this first keyboard revision. Third-party keyboard labels or apps that suppress the system keyboard may not work; these rejected keys do not disconnect touch control.

Every typed key is a complete tap; key-up has no phone action. Sequence/instance validation prevents replay. A key timeout is never automatically retried. Device switch and focus loss cancel unsent input. No screenshot broadcaster or generic WDA API is exposed. Coordinates and swipe behavior are preserved from 1.2.0.

GitHub Actions uses macOS 15 and Xcode 16.4 to compile an unsigned arm64 device IPA. Sign locally with your own account, preserving the nested XCTest package and frameworks. No credentials, private keys or profiles are included. The host bundle identifier remains com.jinghaohao.touch.runner; install over the previous touch agent using the same signer.

Compilation and automated checks do not establish real-device behavior. English/Pinyin input and app keyboard compatibility require phone testing. Desktop is GPL-3.0-only, new patches are BSD-3-Clause; upstream and dependency licenses are included with corresponding source.
