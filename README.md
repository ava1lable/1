# 镜好好 WDA 相册组件 · v1.11.15 预览

在同一个 WDA IPA 内增加数据线收图和 PhotoKit 相册入库接口。保留 WDA 的文字与控制接口；无需再打开 LocalSend。此目录只有源码和构建工具，**不是已编译或已签名的 IPA**。

## GitHub 云端构建

1. 创建并授权一个专用的 GitHub 仓库，建议私有。将本目录的文件放到仓库根目录，包含隐藏的 `.github` 文件夹。
2. 打开 Actions，运行 `Build unsigned MirrorGoodGood IPA`。源码提交也会触发构建。
3. 成功后下载 `MirrorGoodGood-WDA-Photos-unsigned` 构建产物，解压取得 `.ipa`、`build-result.json` 和 `SHA256SUMS.txt`。
4. 在 Windows 的 Sideloadly 中自行签名安装该 IPA。Apple 账号、密码、验证码和签名证书不上传 GitHub。
5. 停止目标手机投屏后安装；安装完成后重新连接投屏、鼠标键盘及 WDA 文字。在镜好好相册窗口选“镜好好 IPA 组件”，首次发送时在手机允许添加照片。

云端使用 macOS 15 / Xcode 16.4、固定 WebDriverAgent 12.0.0 源码及 SHA256；不需要 Apple 开发者付费账号即可生成未签名文件。签名和手机安装仍由使用者完成。仓库 Actions 的可用额度以账号为准。

## 本机 Mac 构建

在本目录执行 `python3 build.py`。输出在 `artifacts`。Windows 可以执行 `python build.py --prepare-only` 核对并准备源码，不能代替 Xcode 编译。

## 接口与验证边界

- `/wda/jhh/photos/status` 报告协议版本、照片权限和大小限制；旧版 WDA 不支持时明确提示升级，不自动切换 LocalSend。
- `authorize` 只请求“添加照片”权限，不读取相册，也不自动接受手机弹窗。
- `uploads`、`chunk`、`commit`、任务查询和 `cancel`；单图 64 MiB，分块 256 KiB，SHA256 和 ImageIO 验证后通过 PhotoKit 入库。
- 只有 PhotoKit 的成功回调才标记 `saved`。未完成临时文件可以取消；已入库图片不会删除。提交失联或重启后不重复入库，结果不明要求人工核对。
- 组件 HTTP 服务仅绑定手机回环地址，通过 USB 转发访问；不监听手机 Wi-Fi。请求日志只记接口路径，不记录文字、图片或签名资料。
- 电脑端每个相册窗口固定一台手机。它不另起 WDA，也不结束现有文字进程。断控或 USB 重置时拒绝继续收图。

必须在签名安装后实测照片权限、JPG/PNG/GIF/HEIC、投屏同时收图、多机目标、取消/断线和 WDA 文字保持。离线测试与云端编译成功不代表上述实机通过。

## 来源与许可

WebDriverAgent 12.0.0：<https://github.com/appium/WebDriverAgent/releases/tag/v12.0.0>，BSD-3-Clause；保留上游源码中的 LICENSE。
新增手机端代码使用 BSD-3-Clause，见 LICENSE。镜好好 Windows 工作台继续使用 GPL-3.0-only。
