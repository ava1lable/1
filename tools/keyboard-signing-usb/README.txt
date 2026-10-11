镜好好键盘：USB 签名安装对照验证1

这是 iloader 2.3.6 的非官方 USB 验证构建，用于定位键盘扩展在个人签名后启动失败的问题，不是已验证的修复版。
官方项目：https://github.com/nab138/iloader
官方网站：https://iloader.app/
固定上游提交：dc396af059fd46982062cd8fc90252d7e27085e9
本构建不代表或获得上游作者背书。

原因：官方 Windows 版本在选择本机 USB 手机时强制设置 EnableWifiDebugging，设备返回 MissingValue 后阻止选择；USB 安装不需要这个设置。
调整：仅列出 USB 设备；不自动更改 Wi-Fi 调试；USB 路径不启动无线远程配对；安装前核对同一 USB 连接编号及设备身份；失败时清空之前的安装目标。签名库、Apple 登录、证书授权和受保护存储仍采用上游实现。

操作：保持投屏停止、手机通过数据线连接并解锁。自行打开验证程序，选择 USB 手机，自行登录原 Apple 账号；Import IPA 选择原签名测试2 IPA，保留键盘扩展。该操作不需要先安装 SideStore 或 LiveContainer。账号、密码、验证码、配对码不要发送到聊天中。
若提示撤销已有开发证书，先取消，避免让已有 WDA 失效。不要点证书撤销、清理配对或更新官方版本的按钮。
安装成功后仅在备忘录普通正文中选中“镜好好键盘”，先观察能否保持显示及出现配对码；不要先输入测试文字或发送消息。显示配对码以后，才继续电脑端配对及实际输入验证。

当前结论：Sideloadly 与 AltServer 安装的1.0.2/build3均出现 CODESIGNING/2/Invalid Page。还未取得这两次最终签名二进制，不能断言某个签名字段就是根因。更换签名实现的效果待实机验证。
既有手机 IPA、完整包及工作台功能不作变动。本工具只辅助本轮签名诊断，不集成进完整商业交付包。

复现：按照 build-iloader-usb.yml 获取固定上游源码，运行 patch.py，再用其 Cargo.lock 和 bun.lock 编译。保留上游 LICENSE、LICENSE-BRANDING、源码和签名依赖源码。不得将这个测试构建描述为官方发布。
