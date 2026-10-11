// SPDX-License-Identifier: BSD-3-Clause
import UIKit

@main final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let controller = UIViewController()
        controller.view.backgroundColor = .systemBackground
        let text = UILabel()
        text.numberOfLines = 0; text.font = .systemFont(ofSize: 19)
        text.text = "镜好好键盘 · 签名测试2\n\n① 设置 → 通用 → 键盘 → 键盘 → 添加新键盘，添加“镜好好键盘”。\n\n② 点镜好好键盘，开启“允许完全访问”。文字服务仅使用手机回环接口，经 USB 数据线连接，不连接互联网、不读取输入框正文。\n\n③ 打开目标 App 的输入框，长按 🌐 切到镜好好键盘，等待显示配对码。如失败，请记录括号中的错误码。\n\n④ 在电脑修订10工作台点“连接手机键盘”，输入当前配对码。随后点击投屏内输入框，直接使用电脑输入法。\n\n本版增加构建后代码完整性签名检查，仍需个人签名安装和手机验证。密码框和禁止第三方键盘的 App 不支持。切换键盘或退出输入框后可能需要重新连接；失败文字不会自动重发。"
        text.translatesAutoresizingMaskIntoConstraints = false; controller.view.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            text.trailingAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            text.topAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.topAnchor, constant: 24),
            text.bottomAnchor.constraint(lessThanOrEqualTo: controller.view.safeAreaLayoutGuide.bottomAnchor, constant: -24)
        ])
        window = UIWindow(frame: UIScreen.main.bounds); window?.rootViewController = controller; window?.makeKeyAndVisible()
        return true
    }
}
