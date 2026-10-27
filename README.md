# VK99 键盘驱动 macOS 版

原始驱动在 https://www.valkyrie.com.cn/

驱动基于 Windows 驱动使用 REA 逆向实现，经在 VK 99 机械三模键盘（赵芸）测试通过时间同步功能。

## License / 许可证

本项目采用非商业授权（Non-Commercial License）。

- 允许个人使用、教育使用、研究用途和非商业开发。
- 禁止商业使用，包括但不限于销售、付费分发、商业部署、企业商用或嵌入商业产品。
- 任何修改、再分发或衍生作品，均需保留版权声明并遵守 LICENSE 文件中的条款。
- 如需商业使用，请单独联系版权持有人申请授权。

详细条款请见 [LICENSE](LICENSE)。

## 功能

当前应用聚焦两项功能：**查看电脑本地时间并同步到键盘**，以及**上传自定义图片并对照实体屏幕验证**。连接的 USB VK99 会在应用启动、重新连接和定时校时时自动同步电脑时间。2.4G 设备在支持的场景下也可使用同样的校时逻辑。

## 已确认的信息

- 本地参考目录 `local-research/windows/` 包含两个 Inno Setup Windows 安装包，分别对应按键版和旋钮 TFT 版；没有源代码。该目录已被 Git 忽略。
- 安装包内的 `config.xml` 将两版设备都标识为 VID `05AC`、PID `024F`，并以产品名称区分。USB 通道标作 `MI_00`，2.4G 接收器通道标作 `MI_03`。
- 当前接入的设备自报名称为 `Valkyrie-99pro`，厂商字符串为 `SONiX`，传输方式为 USB。
- 它有四个 HID collection：标准键盘、Consumer Control、厂商页 `0xFF13`（64 字节输入/输出/Feature 报告）及厂商页 `0xFF68`（64 字节输入、4096 字节输出报告）。
- Windows 程序动态调用 `HidD_GetFeature`、`HidD_SetFeature`，并使用 `ReadFile`、`WriteFile`。安装包没有协议文档，因此各功能的命令字段需从程序行为逐项恢复。
- 已用 REA 分析 Windows 核心程序和 `mui.dll`，恢复 TFT 单帧上传的主要命令路径与 RGB565 编码。证据及尚未确认的行为见 [analysis/PROTOCOL.md](analysis/PROTOCOL.md)。
- 已用 REA 恢复 USB 校时的四步 Feature 命令和本地时间字节布局。当前实体键盘上的校时报文写入均返回成功；Feature 读取会回显刚发送的时间报文，说明握手与时间写入已达可用状态。

## 构建与运行

需要 macOS 和 Swift 6。通常可运行：

```sh
swift build
.build/debug/vk99 scan
.build/debug/vk99 gui
```

如果本机同时安装了不匹配的 Command Line Tools SDK，可指定与 Swift 编译器相配的 SDK。例如本机使用：

```sh
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" \
XDG_CACHE_HOME="$PWD/.build/cache" \
swift build --disable-sandbox --scratch-path .build
.build/out/Products/Debug/vk99 scan
```

命令输出 JSON，列出匹配 VID/PID 的 HID 接口及完整报告描述符；它不会打开接口或发送报告。若设备未连接，将输出空数组 `[]`。这也意味着按键版、TFT 版、USB 与 2.4G 设备都可透过相同入口枚举。

## 图形界面与 TFT 图像

运行 `scripts/build-app.sh` 可生成 `dist/VK99 macOS.app`，再运行 `scripts/install-app.sh` 安装到 `~/Applications` 并打开。新安装默认启用登录项；“基本”Tab 中的开关可控制启动时同步与自动校时；“设置”Tab 可直接管理常用配置。

“基本”Tab 显示电脑时间、最近一次成功发送时间、手动同步入口和自动同步策略。连接模式仅在识别到对应 HID 产品和传输方式时显示 USB、2.4G 接收器和键盘型号。

“设置”Tab 提示 Fn＋旋钮操作方法，展示当前设置的可读性和全部选项目录。随应用打包的 [Resources/SettingsCatalog.yaml](Resources/SettingsCatalog.yaml) 保存中间数据和用户偏好。

应用图标源文件为 `Resources/VK99-icon-source.png`，构建时使用 `Resources/VK99.icns`。更换原图后可运行 `scripts/update-icon.sh` 重新生成 `.icns`，然后重新构建应用。

## 提交项目

项目根目录的 `.gitignore` 排除 Swift 构建缓存、`dist/`、本地诊断记录、REA 原始导出和 Windows 安装包。安装包、ZIP、解包出的 Windows 程序及原始示例图像本身不参与源代码仓库。

“设置”Tab 可选择 PNG、JPEG、GIF 的首帧；预览图由最终 160×96 RGB565 数据还原。上传会替换当前屏幕图像，软件在执行前提示一次，发送后需要点击确认后继续。

本地回归可运行 `swift run VK99CoreCheck` 检查 03:00、本地日期去重、睡眠补发条件和目录完整性。已打包应用可用 `VK99_GUI_SELFTEST=1 'dist/VK99 macOS.app/Contents/...` 执行自检。

可以先在不连接键盘的情况下检查编码结果：

```sh
.build/debug/vk99 tft-pack picture.png picture.vk99.bin
```

它生成 32768 字节（8 个 4096 字节分块）；`vk99 tft-preview picture.png preview.png` 可导出由实际 RGB565 数据还原的 160×96 预览。若要通过命令行上传，使用 `vk99 tft-upload ...`。

若键盘时间没有更新，可在观察实体屏幕时运行 `scripts/diagnose-clock.sh --confirm`。脚本将四步校时报文、每一步的 `SetReport`/`GetReport` 返回值及原始回读内容汇总输出，以便逐步确认问题点。

在 2026-10-27 的排查中，用户确认逐步写入并回读的诊断后键盘时间基本同步；改进后的正式手动同步也得到同样的实体观察。启动、重连和定时校时均使用相同的时间写入路径。

## 后续实现所需

要补齐 Windows 软件中的改键、灯效、宏和多帧 GIF，仍需继续静态分析各项命令，或在 Windows 上记录相同操作前后的 HID 报文，并对照设备实测。固件关键行为仍需进一步恢复，以支撑更完整的功能端到端验证。
