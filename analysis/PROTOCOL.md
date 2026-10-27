# VK99 TFT 协议调查记录

目标：`local-research/windows/extracted-tft/app/DeviceDriver.exe`（SHA-256 `530037a8999d7c6e54ebb4eda988aee04278a80773bfc83f6b8cf3a792d56096`）及 `mui.dll`（SHA-256 `a90d91af1d03fa61e239b925ea247a9b8e7127c96c750119bc50c780a40f4984`）。REA 记录保存在 `rea-evidence.json`、`rea-evidence-time.json`、`rea-evidence-time-followup.json`、`rea-snapshot.json` 和 `rea-evidence-mui.json`、`rea-snapshot-mui.json`；这些原始导出文件仅供本机研究，已被 Git 忽略。

## 已观察到

| 事实 | 静态证据 |
| --- | --- |
| Windows 程序动态加载 `hid.dll`，获取 `HidD_SetFeature` 等入口。 | `ev_23b3073d2dc6f290d0cb46abc36b4e6a37285066e042d3c2351926027aaee6e5`，`0x4511a0` |
| Feature Report 调用长度为 `0x41`（65）字节；调用者把 64 字节数据复制到全零缓冲区的第 1 字节起，首字节为 Report ID 0。 | `ev_7d1c91ed0aefe8bc0a03fac5e9926aee3aed06a9d84abb22dc5d73302bb84548`，`ev_5d4af5b535cbfd0b8b1ab047075cdf1068d33dd6b6668bcb8862d3bf68307032` |
| 屏幕上传前发送以 `04 18`、`04 72` 开头的 64 字节 Feature 载荷，图像数据分块发送，最后发送 `04 02`。`04 72` 载荷的第 8、9 字节存放小端分块数量，第 2 字节取 Windows 对象的模式值。 | `ev_be5eebcb7aa433f66cfb27609f2370678354aebcbbf07341422116e013457180`，`0x4227e0`，`0x422d89`–`0x422daa` |
| 屏幕数据块为 4096 字节。Windows `WriteFile` 前添加 1 字节 0 Report ID，总长度 `0x1001`。 | `ev_623d5daa005f545134173d57ab1c7be0e104c3c6ce3d93602d17a94ba74c4c81`，`ev_5ffb7dffbc15ac16d35efc77e695d3f5ebc4761e8f2f12be346dc7c19004c120` |
| 图像帧头长 256 字节：第 0 字节为帧数，随后是各帧时长；帧图像从偏移 256 开始。缓冲区初值为 `FF`。 | `ev_be5eebcb7aa433f66cfb27609f2370678354aebcbbf07341422116e013457180`，`0x4227e0` |
| `mui.dll` 把图像等比例居中绘制到 160×96，使用自上而下 DIB，逐像素转小端 RGB565。 | `ev_56da68ecd6daeb8398678b3b4dcd10b60046126dee83cca14ed203ee0dee38c7`、`ev_969e58817ceb66aea4615650caa2d262487dbb2561368aced5fab5d59a37650e`、`ev_730d2bed177fdff3058233756ab2afed7a9dac6e0bdaf1f38c94e8d26b93f942` |
| USB 校时依次发送 `04 18`、`04 28`（第 8 字节为 1）、64 字节时间载荷、`04 02`。时间载荷含 `5A` 标记、年份减 2000、月日时分秒、星期和末尾 `AA 55`。 | `ev_ee7165363967fe8fb519fede339075e8faff89163709b779e12640f0db25c395`，`0x423790` |
| Windows 程序在连接初始化及界面校时操作中调用相同的校时发送路径；另一条路径对应不同连接模式。 | `ev_15c8fd0f410f8122346e2f0cc2b8c775768bec3ffbb7c7f411d5b188b96a38f5`，`ev_935ed0cff204a13433bb1741e1d15af639bb56e4dcfdb6096e34543d24eb0ea7` |

## macOS 对应实现

- 当前 USB 设备有页 `0xFF13` 的 64 字节 Feature Report 接口，及页 `0xFF68` 的 4096 字节 Output Report 接口。`vk99 scan` 可重现这项实机观察。
- `VK99Transport` 按 HID 页和用途选择接口，用 `IOHIDDeviceSetReport`/`GetReport` 访问。macOS API 把 Report ID 作为独立参数，因此发送的是 64 或 4096 字节载荷，没有 Windows 缓冲区最前面的 0 字节。单帧上传目前将 `04 72` 的模式字节设为 0，分块数量按打包结果填写。
- `TFTImage` 实现单帧的 256 字节帧头、等比例居中、小端 RGB565、补齐到 4096 字节倍数。时长字节固定为 1，是当前单帧实现的选择。
- `vk99 read-feature` 在当前设备上成功打开接口并读取 64 字节，全为零。这验证了读取路径，不证明屏幕写入已成功。
- `VK99Transport.syncClock` 使用 Gregorian 本地时间构造上述校时报文；用户的 USB 连接实测所有 `IOHIDDeviceSetReport` 调用返回成功。校时后 Feature 读取返回了所发送的时间载荷本身，不能当作独立的设备时钟回读。
- 图形应用在启动及设备重新连接后自动尝试同步，并以 macOS 登录项保持运行；菜单栏可重新打开窗口或手动同步。图片预览由实际打包后的 RGB565 数据还原，上传后由用户对照实体屏幕确认。

## 仍待实机确认

- `tft-upload` 的 Feature 命令与输出分块已经按静态证据实现，但本次没有写入用户键盘屏幕，因此模式字节 0 是否适用于此设备、屏幕实际显示、持久化行为和应答仍未验证。
- Windows 程序在每个 4096 字节写入后还调用 `ReadFile` 等待应答；当前 macOS 实现以 `SetReport` 的返回值判断写入成功，尚未复现该应答检查。
- Windows 的 Feature 发送函数会尝试读取确认状态（`ev_193b33151f965526a38dc87d64e3f3789d3ad8c3a9f598bd46c296d3c7d3e01b`）。macOS 实测读取返回写入载荷本身，而非可区分的确认码，因此当前只能确认主机发送成功，不能确认设备内部时间已更新。
- 尚未找到读取键盘当前时钟或屏幕图像的命令；界面显示电脑本地时间、最近发送时间和用户的实体屏幕确认结果。
- GIF 多帧的时长单位、帧数限制，以及灯效、改键、宏、侧灯等功能的完整命令字段仍未确认。不能从设备报告大小推断这些语义。

## 状态与设置可行性复核（2026-10-27）

Windows 包内没有独立的设备协议文档。`layouts/rgb-keyboard.xml` 声明屏幕、灯效、侧灯、宏等页面，并给出灯光亮度与速率的界面最大档位 5；`language/2052.lan` 给出界面名称。这些文件证明 Windows 应用提供相应功能，但不提供 HID 字段映射。

| 项目 | Windows 程序与资源证据 | 当前可实现程度 |
| --- | --- | --- |
| 连接方式 | `config.xml` 有 USB 和 2.4G 接收器产品配置；macOS HID 属性可区分已连接接口 | 可显示当前接口类型，不能由 USB 接口推断键盘无线状态 |
| 电量 | `BatteryCtrl` 和电池图标确实存在。无线分支 `0x435b00` 每约 15 秒构造 65 字节请求（Report ID 0，载荷 `20 01`），调用 `0x44fc90` 的 `WriteFile`/`ReadFile` 流程，并在响应首字节为 `20` 时读取载荷偏移 3 的电量值，最大按 100 处理 | 已找到疑似无线电量查询；当前只有 USB 键盘实机，尚未验证接收器上的报文，USB 页继续显示未知 |
| 充电 | 有 `icon_charge.png`，但上述 `SetBatteryInfo` 路径的第二参数固定为 0 | 无法由该路径证明充电状态可读 |
| 灯效与亮度 | XML、语言文件和 `0x432b00` 等写入路径证实 Windows 有相关功能 | 未建立可靠的当前值读取、原始枚举和 0–100% 换算关系，保持只读 |
| 屏幕和语言 | Windows 有屏幕编辑界面；`language.info` 与 `.lan` 是应用界面语言资源 | 无法证明键盘当前屏幕或键盘语言有可读命令 |
| Caps/Num、系统模式、旋钮 | 标准 HID 键盘接口可提供按键输入；没有在已追踪的厂商报文中确认对应状态字段 | Caps 仅显示 Mac 主机状态，其余保持未知 |

REA 新证据：`BatteryCtrl` 引用 `ev_d0b1660d05b98855089c4f68ff41229fdb4c3bf50ab59313f7595608491c4775`、`ev_bb08a35abca2406567e6233fba30b36d0de151a406dd1dca5d555424ab1f47e5`；`SetBatteryInfo` 交叉引用 `ev_025762842283c3ec7eaa6409e1a262c8936e37f195dc741e1d3924fa11daba5c`；无线查询构造和电量解码 `ev_a9f0ff2998964f3bf7c3352a90d33c431486549e3d00489f43f303ed9e4082f6`；写入及读取封装 `ev_0fc70e3c4d8c7f9c4c76dea74e47db3660ed01ad72c00ea0fd288046a8aa5184`、`ev_b0de612810f38a362bee36bf4a31258f719f5cf0de530e693dfe3a24ee48862a`。这些是静态分析，不是无线硬件的运行记录。

开发者模式现可主动读取 USB 厂商页 `0xFF13` 的 Feature Report ID 0，显示原始十六进制和保守解释。该只读操作不发送 `20 01` 或其他未验证的设置命令。本次实体 USB 返回全零 64 字节；此前校时后读到的校时报文可能为写入回显，不能当作当前设备时钟或设置值。

## 校时不生效的诊断（2026-10-27）

用户观察到显示时间再次偏离 Mac 约 4 秒，自动、手动和重启同步未使其恢复。重新核对 Windows `0x423790` 的汇编后，macOS 的四个载荷字段与 Windows USB 路径一致：`04 18`、`04 28`（偏移 8 为 1）、`00 <LCD 选择序号 + 1> 5A <年-2000> <月> <日> <时> <分> <秒> 00 <星期>`，尾部 `AA 55`，最后 `04 02`。Windows `0x44f570` 对 65 字节缓冲区执行 `HidD_SetFeature`，随后执行 `DeviceIoControl(0xB0192)` 读取响应，并检查响应载荷偏移 3 是否为 `01`；该检查在四次调用中均被请求。静态证据见 `rea-evidence-time-followup.json` 的 `0x423790` 和 `0x44f570`。

新 `clock-diagnose` 对实体 USB 依次写入、等待 35 ms、再读取 Feature Report。2026-10-27 17:02 的索引 1、17:03 的索引 2，以及索引 3 均显示：四次 `IOHIDDeviceSetReport` 和读取都返回 `0x00000000`；三个控制包的响应偏移 3 为 `01`，**时间数据包的响应却等于发送数据，偏移 3 为年份值 `1A`（26），不满足 Windows 的 `01` 检查**。这表明接口权限与基本控制命令可用，但不能证明键盘接收了时间数据。页面序号 1–3 没改变这一现象。

诊断尚不能确定时间包回显是否代表固件拒绝、是否要求特定屏幕状态、是否有时间差阈值，或 macOS GET_REPORT 与 Windows IOCTL 的差异。实体屏幕改变必须由用户目视确认。应用“上次发送”记录主机写入及控制报文确认；不要把它当作设备时钟回读。`scripts/diagnose-clock.sh --confirm` 会将接口信息、发送前后 Feature 读取及逐步报文保存到 `analysis/diagnostics/`，便于同屏录像或照片对照。

用户随后确认：运行逐步写入并回读的诊断后，键盘时间“现在基本同步”。这与原正式流程（仅写入四次、没有逐步回读）形成直接对照，提示 Feature GET_REPORT 可能是完成校时序列所需的一步；现有证据尚不能证明具体因果。正式 `syncClock` 已改为每次写入后等待 35 ms 并读取 Feature Report，对 `04 18`、`04 28`、`04 02` 要求响应偏移 3 为 `01`。时间数据包仍按实测允许回显，不把它误判为设备时钟回读。更新后的 `clock-sync --confirm` 在实体 USB 上成功执行，用户也确认正式路径发送后键盘时间基本同步。长期稳定性和次日 03:00 的实体显示仍待观察。
