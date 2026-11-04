# Yun’s Scanner：3D 重建与端侧采集 Beta

本文件是新电脑上的唯一项目交接总览，包含复制清单、完整计划、功能约定、下一步和文档编写要求。配合根目录 `AGENTS.md` 即可继续开发，不需要之前的对话或旧 `docs/`。

面向 App 使用与真机测试的功能、处理流程和个人 iPhone 安装步骤，见 [App 功能与真机测试指南](docs/App功能与真机测试指南.md)。

场景 ZIP 的两种导出、文件格式、内外参坐标约定和深度读取方式，见 [数据保存格式](docs/数据保存格式.md)。

## 1. 必须复制哪些文件

### 从 GitHub 在新机器继续开发（推荐）

当前开发仓库为 [lys5588/Yun-s-Scanner](https://github.com/lys5588/Yun-s-Scanner)，首次发布包含 1.0（build 7）的完整源码、Xcode 工程、图标、双语资源、验证工具和现有模块文档。项目基于第 8 节列出的非商业科研源码，保留全部授权与来源声明；此仓库不是原作者上游。

```sh
git clone https://github.com/lys5588/Yun-s-Scanner.git
cd Yun-s-Scanner
git switch -c Enhance/next-development
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
bash tools/verify_project.sh source
bash tools/test_beta_scene.sh
bash tools/verify_project.sh ios
open arkit-3dgs-scanner.xcodeproj
```

克隆后的目录就是源码根目录，无需运行 `restore.py`，也无需再建立 `project/`。Git 版使用提交历史校验来源，不携带最初运输包的旧 `TRANSFER_MANIFEST.json`；`verify_transfer.py` 仅用于工具重新生成的源码迁移包。现有验证环境为 Xcode 27.1 / iOS 27 SDK、iPhone 18 Pro 模拟器及 iOS 27.2 真机。先安装兼容的完整 Xcode 和所需组件；`source` 检查也需要 Python 3 和 Swift 编译器。

仅开发 iPhone App 时无需安装 Mac Viewer 依赖。需要完整 Mac 视频重建时，按第 5 节准备 FFmpeg、Node.js/npm 和 Metal Toolchain，运行 `bash tools/setup_project.sh all`、`bash tools/verify_project.sh mac`。第三方 Viewer 由脚本按固定提交恢复，不上传本机依赖缓存。

在 Xcode 的 Signing & Capabilities 中使用新机器自己的 Apple ID 和 Team；工程中的 Team 是本机已有配置，不代表仓库提供签名资格。必要时设置自己的唯一 Bundle ID；同一台手机要保留原 App 数据时应沿用原签名 Team 和 Bundle ID，原位安装，不卸载。仓库不含证书、私钥或描述文件。签名、设备信任和开发者模式需要在新机器与手机上完成。

仓库不包含 `.build/`、`local-data/`、手机场景、原始视频、GPS 实测数据、模型、ZIP、测试截图和 Xcode 用户配置。README 中这些路径是此前验证的本地记录，克隆后不会出现；需要复现时自行提供测试视频或单独迁移数据，并在新机器重新运行验证。`tools/test_beta_management_ui.swift` 只用于具有明确测试副本的模拟器，不能直接对用户真机场景运行删除测试。

后续同步：开发前在干净工作区执行 `git pull --ff-only`，在 `Feature/`、`Bugfix/` 或 `Enhance/` 分支修改并验证，再提交到本仓库；不要向原作者仓库推送。最新功能与未验收项见第 3 节。

### 无法使用 Git 时的文本迁移

**只能逐个复制文字时，使用 5 文件文本迁移版本，所有源码合并在一个 source.txt 中。** 原工作区在修改提交后运行：

```sh
python3 tools/build_text_handoff.py
```

输出目录为 `.build/manual-transfer/<版本前12位>/`，恰好包含 `AGENTS.md`、`to-do.md`、`restore.py`、`manifest.json` 和 `source.txt`。在新电脑建一个空目录，将这 5 个文件的全文按原文件名保存进去，再运行 `python3 restore.py`。全部使用同一新版目录中的文件，不混用旧分段版的恢复脚本与清单。它只需 Python 3.9+ 标准库，将目录恢复到新建的 `project/`，包括源码、工程、图标、脚本权限和许可原文；之后进入 `project/` 执行本文第 5 节。不要把聊天代码围栏复制进去，也不要让 AI 改写编码文本；校验会指出漏拷、截断或损坏的文件。生成工具已内置一次实际还原和逐文件字节比对。

`to-do.md` 携带本文完整计划，运输容器的 `AGENTS.md` 指导新 agent 先恢复、再开发。这两个交接入口只在运输容器中，不新增项目内部的重复文档。旧 `docs/`、实验数据和构建缓存不进入该版本；模块文档按第 7 节继续编写。下面的目录树是**还原后的程序结构**，也是可以直接搬运文件时的复制范围。

保持下面的相对目录结构，目录请整体复制，不能只挑选 Swift 文件：

```text
项目根目录/
├── arkit-3dgs-scanner/             # 全部 Swift、Metal、头文件、图标、语言资源和 entitlements
├── arkit-3dgs-scanner.xcodeproj/   # 工程、workspace、共享 schemes
├── Config/                       # 包括工程引用的 Info.plist
├── tools/                        # Mac 页面、处理/训练入口、构建与验证脚本
├── .gitignore
├── PROTOTYPE_BASELINE.json        # 固定上游版本和目标设备
├── LICENSE
├── NOTICE
├── licenses/                     # 保留 Apache-2.0.txt 等原始授权
├── README.md                     # 本文：完整交接计划
└── AGENTS.md                     # 新 agent 的接手顺序和协作规则
```

Xcode 会同步整个 App 源码目录；资源、`.metal`、`.h`、语言目录和 entitlements 都属于程序依赖。`tools/mac_demo_web/viewer-settings.json` 也是实际 Viewer 配置，不能省略。源码包生成的 `TRANSFER_MANIFEST.json` 用于逐文件 SHA-256 校验，一并保留。

**不用复制：** `docs/`（包括演示媒体）、`.build/`、`.git/`、DerivedData、Python/Node 缓存和 Xcode 用户配置。旧模块文档留在原仓库供参考，不进入精简包。需要保留 Git 历史时可以单独复制 `.git/`，但它不是运行依赖。

`local-data/` 是可选的实验数据：如果已有视频、模型或中间结果需要继续使用，就另行整体复制；它不放进源码包。只复制模型 ZIP 可以查看，不能继续训练。当前交接没有随附真实视频或已验收的重建模型。

原工作区可用以下命令生成精简包（要求修改已提交）：

```sh
python3 tools/package_project.py --minimal
```

输出位于 `.build/handoff/`，保留全部程序与许可证，只带 README、AGENTS 两份项目说明。默认不加 `--minimal` 仍可生成含旧模块文档的完整源码包。

## 2. 项目目的与实施顺序

这是非商业科研 Prototype。先跑通可复现的真实结果，再比较方法和优化界面。第一场景是静态、有纹理的桌面物体或房间一角，建议缓慢绕拍 30–60 秒。

第一阶段：**普通手机视频 → Mac 导入/抽帧 → 相机估计和点云 → Swift/Metal 3DGS → 浏览器查看 → 模型 ZIP。**

第二阶段：**将 Mac 模型包导入 iPhone App → 查看、拖转、缩放 → 关闭后重新打开。**

第三阶段：**iPhone App 内选择仅相机或相机 + LiDAR → 采集与存储 → 手机训练 → 原生/兼容 Viewer。** 拍摄必须保持前台；拍摄结束后的计算按设备能力和系统实际授权申请后台运行。

用户在 2026-10-23 确认新增使用方式：从 iPhone 照片或文件导入已有视频，并完全在手机内完成抽帧、相机估计和高斯训练，不依赖 Mac 服务。原有 Mac 路径继续用于独立验证。

目标是 iPhone 18 Pro / iOS 27；实际设备能力、SDK API 和支持的视频规格必须在测试机与真机核实。原开发 Mac 只有 Command Line Tools，用户已决定停止在该机器安装 Xcode，将完整编译和设备测试转移到新 Mac。

默认保持后置主相机、无变焦。1080p30 是简化实验的建议，不强迫 ARKit 提供它：优先选择后置广角、长边约 1920、30 fps 档位，缺少时使用 ARKit 默认格式并记录实际值，保留原生画幅。

首版不安排额外界面美化、大场景和多算法切换界面。按用户新增要求，本轮实现拍摄前的 LiDAR 选择、处理阶段的条件后台运行与模型分享格式选择；这些新增路径仍需真机验收。Mesh 可作为后续输出，不替代首版必须产生的真实高斯模型。未来方法对比应复用同一份可追溯输入与评价记录。

## 3. 当前真实状态

2026-11-04 双相机导出更新（build 13）：重建包升级 schemaVersion=5，`arkit/poses.jsonl` 和 `realitykit/poses.jsonl` 使用相同有效帧、本次 ARKit 米制世界，默认入口指向 RealityKit。`realitykit/native-cameras.json` 保留筛选后未经配准的原始估计，`alignment.json` 保存已应用的全局旋转、平移、尺度和差异。新估计不再以超过 3 cm 等差异阈值拒绝整组结果，稳健拟合外点也保留有效相机；几何退化仍报错。预览和训练输入继续使用原始 ARKit，完整采集保留，未宣称精度改善。格式与兼容规则见 [数据保存格式](docs/数据保存格式.md)。源码/CPU、相机与归档回归、iPhoneOS / Simulator Debug 顺序构建、Release 签名校验通过，原位安装与设备查询确认为 1.0（13）。

用户先前失败的场景 `scan_20261103_231536_7B954E` 已在手机重新估计并实际保存：44 / 48 组相机，48 张同步深度送入估计，ID 28、41、42、43 未返回相机并从最终两套数据共同排除。真机 UI 用例通过（29.279 秒），显示 3.82 cm 的位置差并成功保存；无需重拍。取回的 ZIP 为 17,501,278 字节、140 个文件，含 44 张图像、两套各 44 组参数、44 对深度/置信度及 44 个原始 RealityKit 返回值。CRC、公共 ID、原始 ARKit K/c2w、尺度/轴转换、K 尺寸换算、GL/OpenCV 逆矩阵、深度大小/有效值和所有来源摘要核对通过；源 poses/frames 与失败前字节一致。首个离线摘要检查使用了重新估计前的旧报告，因报告已更新而不匹配；重新取回手机当前源文件后上述全部摘要检查通过。

另外重放第一次采集的已保存相机/点云，新规则保留 57 / 59 个相机（第 4 帧仅不参与变换拟合，仍保留自己的估计）；Mac 导出 25,554,961 字节、179 个文件。旧 v1 报告兼容导出仍保留原有 56 组，并明确 legacy 策略。原始第一次采集的 1,936 个文件与原归档逐字节摘要一致。证据集中在 `.build/dual-camera-export-20261103/`：`DeviceDualCamera.xcresult`、`device-validation.json`、`mac-validation.json`、`legacy-validation.json`、`original-integrity.json` 及构建/回归日志；签名 App 为 `.build/iphone-release/20261104-1.0-b13-dual-camera/`。本轮未进行独立实物标定、精度排名或端侧训练对照。

2026-11-03 场景视频方向修复（build 12）：Beta 预览为原生传感器方向视频建立内存播放组合，依据首帧重力投影选择显示旋转；本次竖屏视频顺时针转回 90°。普通视频导入和已有轨道方向变换沿用自身方向。MOV/JPEG、K/c2w、深度及导出格式保持不变；重力投影不足时回退竖屏显示，拍摄中途转动手机不逐帧校正。原理与限制见 [采集与存储](docs/采集与存储.md)。

源码/CPU 回归、真机与模拟器 Debug 顺序构建、Release 签名校验通过，已原位安装到 iPhone 18 Pro / iOS 27.2，设备查询确认为 1.0（12）。真实视频经实际播放器组合解码，显示从 1920×1440 转为 1440×1920，原 MOV 和 poses 字节未变；导入分支保持原轨道方向。使用用户新拍场景 `scan_20261103_231536_7B954E` 完成真机预览及播放/暂停复查（14.460 秒），截图确认沙发、窗帘与系统播放控件正向。首条自动化因系统播放按钮未出现在可访问性树中而失败；依据实际界面点按并保存截图的复查通过，首条失败记录保留。证据在 `.build/beta-video-orientation-20261103/`（`verify.log`、`DeviceVideoOrientation.xcresult`、`DeviceVideoPlayback.xcresult`、`playback-attachments/`），签名 App 位于 `.build/iphone-release/20261103-1.0-b12-video-orientation/`。本次没有改动相机估计或配准阈值。

2026-11-03 筛选导出更新（build 11）：Beta 单个/批量保存默认生成“重建结果”包；完整视频、连续索引及全部原始/估计资料通过“原始归档”单独保存。有效帧必须同时有正常跟踪、未丢失的视频帧、有效图像、原始参数和通过米制配准的估计参数；包含 LiDAR 时还要求有效且同帧的深度/置信度。两套相机、图像和可选深度共享同一 ID 名单，不补造缺失结果；失败或零有效帧不回退为原始包。预览及训练输入暂不变，数据格式见 [采集与存储](docs/采集与存储.md)。

已用刚才的真实手机场景在 Mac 回放实际导出代码：最终 ZIP 为 24,644,207 字节、174 个文件，含 56 张图像、两套各 56 组相机、56 对深度/置信度；ID 1、3 缺失估计，ID 4 配准拒绝，19 条连续丢帧仅留审计记录。CRC、同一 ID 集合、原始 K/c2w、逆矩阵、媒体字节、来源摘要及 1,936 个原始文件未变均通过。筛选/归档 CPU 回归、25 项本地化检查、项目检查及顺序执行的 iPhoneOS / iPhoneSimulator Debug 构建通过。测试日志在 `.build/beta-tests/filtered-*`，真实导出与校验在 `.build/metric-camera-device-20261103/exported/exports/`、`filtered-export-validation.json`。

build 11 Release 签名构建、签名校验和原位安装通过，设备查询确认 1.0（11）。真机 UI 用例通过（17.874 秒），验证默认“保存重建结果 ZIP”、实际保存成功和原始归档/重建结果切换；未重拍或重新估计。手机新生成 ZIP 已取回，CRC、UTF-8、全部媒体字节和所有 JSON/JSONL（除导出时间）与已验证的 Mac 回放一致，同为 56 组和 174 个文件。证据为 `.build/metric-camera-device-20261103/DeviceFilteredExport.xcresult`、`filtered-device-validation.json` 及 `scan_20261103_173257_121DEF-reconstruction-E22BF39F.zip`；签名 App 位于 `.build/iphone-release/20261103-1.0-b11-filtered/`。本次验证保存/筛选行为，不新增绝对精度或后台资源压力结论。

2026-11-03 相机参数更新：Beta 拍摄默认开启设备支持的 LiDAR，保留自动对焦。停止采集后，`CapturePhotogrammetry` 为保存的 JPEG 关键帧请求 RealityKit 相机/稀疏点云，有效同步深度作为 `depthDataMap` 输入，再将相机和点云一起配准回本次 ARKit 米制世界。原始 `poses.jsonl`、全帧 `frames.jsonl`、图像及深度保留；新结果和状态位于 `camera-estimation/`、`camera-estimation.json`，随 ZIP 保存。预览仍显示原始采集数据，估计卡片支持重试；此流程尚未自动接入训练输入。

本次在 Mac 重放旧真机场景的 49 张关键帧，实际得到并对齐 45 个相机和 5,043 个点，缺失 ID 为 8、9、14、15；耗时约 16 秒，轨迹位置差异中位数 2.69 cm、P90 3.71 cm，方向差异中位数 0.47°。这些是相对原 ARKit 轨迹的一致性数值，不是独立测量精度。59 个原始文件的 SHA-256、逐图时间/内参尺寸、c2w/w2c/OpenCV 转换及点云共同变换核对通过；实际 RealityKit 取消排空测试通过。数据在 `.build/metric-camera-replay-20261103-d/`，取消日志在 `.build/metric-camera-cancel.log`。样本没有 LiDAR；真实深度输入、手机前后台/内存/温度行为与精度提升尚未验收。合成几何/图像深度对齐、ZIP 回归、`verify_project.sh source` 及最终顺序执行的 iPhoneOS / iPhoneSimulator 无签名构建均通过；仍有项目既有并发/废弃 API 警告。日志为 `.build/metric-camera-tests.log`、`.build/metric-camera-export-tests.log`、`.build/metric-camera-source-final.log`、`.build/metric-camera-ios-final.log`。最终取消回归日志为 `.build/metric-camera-cancel-final.log`；该段记录 Mac 回放；随后真机验证见下条。

2026-11-03 真机验证（build 10）：已使用原 Team / Bundle ID 签名并原位安装到已连接的 iPhone 18 Pro / iOS 27.2，Release 真机与 Debug 模拟器构建通过。用户配合实际移动录制 30.13 秒，默认 LiDAR ON、1920×1440 / 30 fps；场景 `scan_20261103_173257_121DEF` 有 890 条连续记录、871 个真实视频帧和 871 份同步深度，另有 19 条明确标记的 `media_backpressure` 丢帧，全部记录 trackingState 为 normal。59 张关键帧的 256×192 深度/置信度与同时间连续帧逐字节一致，有效 medium/high 置信度深度占比每帧约 76.3%–98.8%。全部 59 张的深度实际送入 RealityKit，约 64.58 秒返回 57 个相机，56 个通过配准，另存 2,629 个米制点；ID 1、3 无估计，ID 4 因配准异常排除，原始 59 个相机均保留。相对 ARKit 位置差异中位数 1.55 cm、P90 3.32 cm、方向差异中位数 0.64°，仅表示配准一致性。原始关键帧 fx 为 1366.549–1388.803 像素；RealityKit 本次返回共享的 fx=1376.773 像素，逐帧输出并不保证逐帧独立优化焦距。

手机生成的 120,543,916 字节 ZIP（1,936 个条目）已取回；CRC、完整视频 PTS/尺寸解码、逐帧参数、同帧深度、原始 poses SHA-256、K 尺寸换算、c2w/w2c/OpenCV 转换及点云共同变换全部核对通过。手机原有 4 个 Beta 场景及其目录元数据保留。数据、验证与日志在 `.build/metric-camera-device-20261103/`，主报告为 `validation.json`。首条完整 UI 用例到最后保存提示检查时发生 `kAXErrorServerNotFound`，不能标为整条 UI 测试通过；实际采集、估计及 ZIP 文件已独立验证。修正测试控件查询并从场景库定位该场景后，独立重开、显示“56 / 59”估计状态及再次保存 ZIP 的真机 UI 复查通过（16.077 秒，`DeviceReopen.xcresult`）；首条用例仍保留失败记录。签名 App 留存于 `.build/iphone-release/20261103-1.0-b10-metric/`。尚未完成已知实物长度/独立标定精度、后台取消重试、温度/内存压力或精度提升对照；本次成功不能证明此前跨 App 相机异常的根因已解决。

交接前程序实现基线是本地提交 `d3396a643ea4f10cfad769e4f1050056a5c182a0`；本次包的完整版本以 `TRANSFER_MANIFEST.json` 为准。该本地提交不是上游 GitHub 提交，重新 clone 上游不能恢复本项目新增功能。

| 模块 | 已写入的代码与已做检查 | 仍未完成的验收 |
| --- | --- | --- |
| Mac 输入/处理 | 用户视频 IMG_0568.MOV 的 SDR 副本已跑通：102 帧全部获得真实相机与内参，8,033 个稀疏点；完整源时间与转换记录保留 | 更多视频的鲁棒性；页面自动 HDR 转换尚未实现 |
| Swift/Metal 训练 | 完整构建及 GPU 回归通过；真实视频 Mac Quick 约 107 秒；模拟器内 UI 启动 Quick 约 184 秒，均完成 4,000 次及 299,708 个高斯 | 更高清晰度与复杂场景质量；真机性能 |
| Mac Viewer | 固定版本 SuperSplat 已构建；真实 SOG/PLY 均已通过 Metal 重载、原相机渲染及图片对照 | 真实模型的浏览器交互与自由视角检查 |
| iPhone 已有视频 | 已增加首页入口、照片/文件选择、预览、原生抽帧及摄影测量，再接入现有训练；Photos／Files 实际选片及预览通过，模拟器系统能力不支持摄影测量；共享原生代码已在 Mac 用真实 HDR 视频验证 | 真实 iPhone 全流程、资源与中断验收 |
| iPhone 采集 | 连续录像、全帧索引、关键帧、深度、收尾与导出；新增拍摄准备页的仅相机／相机 + LiDAR 选择；既有 CPU/视频编解码检查与构建通过 | 两种模式的真机采集、传感器同步、权限与设备异常 |
| 模型包导入 | 真实 ZIP 通过共用导入逻辑；模拟器已实际从 Files 选择、导入并重开同一模型，99 个相机及 8 个文件保留；封面方向正确 | 真机文件选择与模型显示 |
| iPhone Viewer | 8 项数学检查和包含原生 API 的 iPhoneOS 构建通过；模拟器实际 Metal 显示、旋转、捏合、重置和 App 重开通过 | 真机原生显示、原生与回退一致性 |

本机最新验证（2026-10-22 至 2026-10-23）：源码检查、25 项本地化检查、17 项训练配置/实验记录及导出尺度检查、模型导入回归、修复后的 8 项 Viewer 数学检查、14 项 Mac 流程测试、13 项采集包测试及连续录像编解码/收尾回归通过。摄影测量 helper 已重新编译并通过自测。测试包含合成与模拟输入，不代表真实摄影测量成功。此前交接版本还通过了中文且带空格、无 Git/旧缓存副本检查。

本机实测为 Mac mini M4、16 GB、macOS 27.2，已安装 Xcode 27.1（27A9275）、Swift 6.4、macOS 27.0 / iOS 27.1 SDK；使用 FFmpeg/ffprobe 9.0.2、Node.js 22.17.1、Python 3.9.6。SuperSplat Viewer 的固定提交 `5976646dc972e7700fbde3948465795cca0a4ebc` 与构建产物已核对。旧记录中的 macOS 15.5 和“未安装完整 Xcode”已不适用，先前 Command Line Tools 编译器/SDK 不匹配问题在本轮完整 Xcode 的源码回归中未再出现。

迁移包 `beb99d5574d7af13b12398c73b70355484c2c414` 已在此前恢复。本轮修改前重新核对 226 个清单文件，仅 README 的上次环境记录与原包不同，225 个其余文件的字节数和 SHA-256 一致。因此 `verify_transfer.py` 对当前已编辑目录报 README 不一致是预期结果，没有改写原清单或重新覆盖项目。本轮改动前的相关文件保存在 `.build/review-baseline/`。

本轮修复了非零/负起始源视频 PTS 被归零的问题、原生 Viewer 未采用模型包初始相机的问题、原生内存检查重复计入已分配 Metal 内存的问题，以及缺少 Metal 组件时误报缺少 Xcode 的诊断。Apple 官方 Metal Toolchain 27A266a 已安装，相关脚本的版本查询已改为该组件支持的 `--version`。`verify_project.sh source`、`mac`、`ios` 全部通过；iOS 依次执行了包含全部 Metal 文件的 iPhoneOS 和 iPhoneSimulator 无签名构建，真机目标包含 iOS 27 GaussianSplat API。GPU 回归首轮发现 Swift 6.4 优化编译下泛型数组闭包内读取 `MTLBuffer.contents()` 会崩溃，已将地址读取移出闭包，保持复制和空数组语义；完整 `test_gaussian_training.sh` 已以原有 `-O` 优化通过：28 项光栅化、10 项损失/PPISP、85 项训练及 CLI 构建/用法检查，包括检查点、模型导出重载和 1,200 帧合成扫描内存回归。修复证据保留在 `.build/raster-diagnostic/`。iPhone 18 Pro / iOS 27.0 模拟器已安装并启动 App，进程存活检查通过；没有把模拟器当作相机、LiDAR 或手机 GPU 验收。现有 Sendable、主执行器隔离和废弃 API 警告尚未全部清理。

2026-10-23 首次真实视频实验为 `local-data/runs/20261023-002145-0965a5f9/`：下载目录的 `IMG_0568.MOV` 是约 50.73 秒的 HLG/Dolby Vision 视频，先保留原片并将 HLG 兼容基底色调映射为 BT.709 SDR；不是仅改色彩标签，也不声称复现 Apple Dolby Vision 动态呈现。1,522 帧的 PTS 全部逐帧一致，自动旋转后的画面为 1080×1920。转换记录在 `local-data/preprocessing/IMG_0568-94c45a053950/`；该预处理由本次本地验证完成，页面仍拒绝直接输入 HDR。

摄影测量保留全部 102 帧和 8,033 个点；训练选择器去除 3 个相似视角，得到 87 个训练视角和 12 个验证视角。Quick 使用 540×960、SH 2、4,000 次迭代，实际耗时 107.0 秒，299,708 个高斯，训练采样峰值物理内存 419 MiB（导出前进程历史峰值 447 MiB）；验证 PSNR 24.663 dB、SSIM 0.8544。独立重载 PLY 得到相同验证指标；SOG 重载为 24.408 dB、0.8535。两者均以原相机、零新增迭代渲染全部 12 个验证视角，没有测试时相机对齐。对照图片的主要结构、朝向和基础颜色一致，文字、细线及椅子区域仍有模糊和局部缺损。模型 ZIP 约 49.7 MB，详细参数、重载日志、对照图和验收记录均随实验保存，不另建阶段报告。

2026-10-23 模拟器界面验证：在 iPhone 18 Pro／iOS 27.0 上，通过 Xcode UI 自动化实际操作 Files，导入上述模型 ZIP，完成模型旋转、捏合缩放、重置视角、退出 App 后重开。截图确认显示真实桌面模型，实际后端为 Metal；模拟器未编入 RealityKit 高斯原生分支。修复了仅有工程 build setting 时产物缺少 `UIFileSharingEnabled`、导致 Files 看不到 App 文档目录的问题，将该键明确写入 `Config/Info.plist`；导入卡片现在使用模型包预览图并保持正向。修复后源码回归、iPhoneOS／iPhoneSimulator 无签名构建均通过。临时 UI 测试工程、截图、录屏和 `.xcresult` 保存于 `.build/simulator-ui-validation/`，没有向产品工程加入测试专用入口。

同次模拟器训练流程已完成：将原视频在 Mac 上处理得到的 102 张图像、真实相机与点云等 110 个输入文件按 SHA-256 核对后放入测试扫描目录，未复制已有模型；通过界面选择 Quick、关闭位姿微调和 PPISP，再点击开始训练。实际选择 99 个训练视角，540×960、SH 2、4,000 次迭代，183.68 秒、299,708 个高斯，完成 SOG／PLY 保存；App 重启后显示、展开统计、旋转和重置均通过。结果与来源记录保存在该实验的 `simulator-training/`，录屏和 UI 测试结果在上述构建目录。这里没有原生 MOV 导入或 ARKit 采集：仍是 Mac 视频预处理后输入模拟器。App 使用 `holdOutEvery=0`，没有独立验证集，不能与 Mac 留出验证指标直接比较；也不能将宿主 M4 上的模拟器耗时当作手机性能。

2026-10-23 新增手机原生视频流程：原始 HDR 文件经同一 `VideoFrameExtractor` 在 Mac 得到 102 张 899×1600 sRGB JPEG，再经生产 `VideoPhotogrammetry` 得到 102 个有效相机、7,974 个点；全部图像哈希、源 PTS 与来源记录保持一致。原始 SHA、颜色和转换策略完整嵌入模型随附的 `video-import.json.videoPreprocessing`。非零 PTS、帧上限、抽帧取消、摄影测量取消等待停止、几何回放、非法来源及导出非公制尺度回归通过。日志见 `.build/native-video-extraction-timing-check.json` 和 `.build/video-photogrammetry-validation/native-hdr-with-provenance/native-pipeline-validation.json`。这次共享引擎在 Mac 运行，没有将 Mac 结果当作手机直接导入重建成功；当前仅连接 iPhone 18 Pro 模拟器，实际 `PhotogrammetrySession.isSupported=false`，可以选片预览但无法执行相机估计。需要连接支持该能力的 iPhone 真机继续验收。UI 测试已覆盖首页入口、Files 取消和重新选择、Photos 选择原片、SDR 封面解码与实际能力禁用说明；最终 2 项均通过，结果为 `.build/simulator-ui-validation/ExistingVideoVerified.xcresult`，汇总在 `.build/existing-video-validation/validation.json`。模拟器的系统播放器显示原始 HDR 视频有高光截断，预览因此先用原生 `forceSDR` 生成真实封面，点击才播放未改动原片；真机 HDR 播放仍待核对。

2026-10-23 App 语言调整：仅提供“简体中文”和“English”，默认简体中文；670 条中文资源及相机权限说明已转换，并统一视频、文件、图像、内存等用词。语言资源目录和开发语言改为 `zh-Hans`，旧 `zh-Hant` 偏好在启动时迁移，已有英文选择保留。25 项语言回归覆盖整表简体检查、插值、权限说明及偏好迁移；iPhoneOS／iPhoneSimulator 构建通过，安装包均仅含 `zh-Hans.lproj` 和 `en.lproj`。模拟器 UI 测试已实际验证两种语言选项、双向切换、重启后保留选择以及简体首页和视频导入页，结果为 `.build/simplified-chinese/LanguageUI.xcresult`；验证日志位于 `.build/simplified-chinese/`。

2026-10-23 真机测试版本准备：Release / iPhoneOS / arm64 的 1.0（build 1）归档成功，输出到 `.build/iphone-release/20261023-1.0-b1/`，交付压缩包为 `.build/iphone-release/ARKit3DGSScanner-1.0-b1-unsigned.zip`。实际归档仅含简体和英文资源，最低部署 iOS 17.0；已核对没有签名或嵌入描述文件，因此不能直接安装。当前 Team 为空、签名身份为 0、仅连接模拟器。需用户在 Xcode 登录自己的 Apple 账号并选择 Team，连接实体 iPhone、完成信任及开发者模式后再签名安装。功能、pipeline、安装与测试操作已集中写入 [App 功能与真机测试指南](docs/App功能与真机测试指南.md)。归档不代表手机验收，尚未导出可安装 IPA 或上传 TestFlight。

2026-10-23 图标与首次真机安装：用户提供 `3576.pic_hd 2`（实际为 2254×1888 JPEG），已保留完整画面并等比适配为 1024×1024、不含透明通道的 sRGB PNG，上下延展原图边缘背景，替换 `Assets.xcassets/AppIcon.appiconset/AppIcon.png`。原片未修改，旧图标、转换脚本和摘要保存在 `.build/icon-update-20261023/`。iPhoneOS 和 iPhoneSimulator 构建均通过。用户在 Xcode 设置的显示名 `Yun‘s Scanner`、Bundle ID `com.liyunshan.arkit3dgsscanner`、Team 和 target 最低 iOS 27.0 均保留；这与前一份未签名归档的旧配置不同。用户完成系统钥匙串授权后，新的 Release 签名归档成功，位于 `.build/iphone-release/20261023-1.0-b1-new-icon-signed/YunsScanner-1.0-b1.xcarchive`，签名校验通过、描述文件包含目标设备。已通过 `devicectl` 实际安装到 iPhone 18 Pro / iOS 27.2 并成功启动，证据在 `.build/icon-update-20261023/{install,launch}.json` 和 `validation.json`。本次开发描述文件到期时间为 2026-10-30 03:04:43 UTC；需到期前后重新签名安装以继续测试。这里只确认安装启动，视频重建、采集、训练和 Viewer 仍待真机功能验收。

2026-10-23 重建使用方式扩展：拍摄前可选择“仅相机”或“相机 + LiDAR”，记住用户选择，不支持 LiDAR 时禁用该选项；保留一种默认采集画质，优先约 1080p / 30 fps 并记录实际格式。拍摄后的位姿/点云计算申请 CPU 持续后台任务；已有视频摄影测量与 3DGS 训练另检查后台 GPU 能力、签名 entitlement 和系统实际 grant，申请提交成功不等于已获准。未获 GPU 授权而切后台时，视频处理安全停止并保留原片供重试，训练尝试保存检查点后暂停；系统取消或到期时即使 App 在前台也停止该任务。强制结束 App 不能继续计算。模型分享新增 SOG / PLY 显式选择，分别生成只含所选格式与来源记录的 ZIP；仅有单一格式的导入模型明确禁用缺失格式。7 项采集模式 CPU 检查及分享/导入回归通过，日志在 `.build/feature-reconstruction-20261023/`；两种采集闭环和各阶段真实后台执行仍待手机验收，不能由源码或历史构建结果推定成功。

本轮源码版本升为 1.0（build 2）。实际后台 GPU 签名归档被 Xcode 拒绝：当前 Personal Team 不支持 Background GPU Access，证据在 `.build/feature-reconstruction-20261023/archive.log`。因此默认工程保留普通个人签名配置及原内存 entitlement；当前可交付路径是 CPU 阶段申请后台、视频摄影测量前台处理、训练切后台尝试保存检查点后暂停，**不代表已实现当前手机的完整 GPU 后台重建**。可选 `Config/BackgroundGPU.entitlements` 保留完整权限配置，具备相应授权的 Team 可通过 `CODE_SIGN_ENTITLEMENTS=Config/BackgroundGPU.entitlements` 构建，仍须验证设备支持与实际 grant，不能承诺付费或改配置后必定可用。后台诊断在 App `Documents/background-processing.json`；拍摄后处理在扫描内另写 `capture-processing.json`，与视频流完成状态独立。Mac 37 项真实 GPU 暂停、恢复、取消及 CPU 回归通过，日志为同目录 `background-session/tests.log`；这些结果不能代替 iPhone 后台验收。

2026-10-23 build 2 最终构建与安装：源码/语言/CPU 回归通过；最终 Release / iPhoneOS 归档与 Debug / iPhoneSimulator 按序构建通过。个人签名归档为 `.build/iphone-release/20261023-1.0-b2-reconstruction/YunsScanner-1.0-b2.xcarchive`，签名校验通过，版本 1.0（2）、Bundle ID `com.liyunshan.arkit3dgsscanner`、最低 iOS 27.0；已安装到连接的 iPhone 18 Pro / iOS 27.2，并启动、确认进程存活。该版本不携带后台 GPU entitlement；设备当前运行配置返回 `BGTaskScheduler.supportedResources.contains(.gpu) == false`。这不能推出更换 Team 后硬件必然支持。CPU continued-processing 已接入，但真实拍摄后的后台授权、进度与重建质量仍待实机操作验收。构建、签名拒绝原因、安装、能力检测与源文件摘要保存在 `.build/feature-reconstruction-20261023/`；`validation.json` 汇总交付事实。 同轮模拟器 UI 2 项测试通过：拍摄准备的两种模式及模型 SOG/PLY 选择均实际打开，使用已有真实模型验证两格式可选。首次分享测试因 SwiftUI 嵌套按钮产生重复自动化匹配，收紧测试选择器后通过；产品代码未为测试添加入口。结果为 `UIValidation-verified.xcresult`，截图随结果保留。

对应运输目录待办：文件恢复、迁移/源码核对、工具链安装、完整构建、本机 GPU 回归、一次真实视频的 Mac 重建与模型重载、模拟器模型导入及真实输入训练查看已完成；浏览器交互、同一模型真机查看、真机采集训练闭环尚未验收。四份简体中文模块文档和用户使用指南按实际结果维护。构建日志留在 `.build/verification/`；本地视频控制台依赖检查五项均就绪，服务入口为 `http://127.0.0.1:8765`。

**iOS App 已完成无签名编译，真实视频已完成 Mac 高斯重建；尚未完成真机验收。合成模型、CPU 测试、模拟器和 Mac 结果都不能作为手机重建性能或传感器对齐的证据。**

2026-10-27 开始增加独立的端侧采集 Beta：右上角翻转图标翻转进入，单场景拍摄/视频导入 → 位姿与视频预览 → Visualization → ZIP 保存。Beta 不训练 3DGS，数据保存在 `Documents/beta-scenes/`，原重建流程继续使用 `Documents/scans/`。支持原生 1080p/4K 能力选择、可选 LiDAR、宽松运动预设及拍摄时长/路程显示。格式和限制见 [采集与存储](docs/采集与存储.md) 的 Beta 小节，操作见 [App 功能与真机测试指南](docs/App功能与真机测试指南.md)。本次实际工具链是 Xcode 27.1，模拟器是 iPhone 18 Pro / iOS 27.0；未将工程降为 iOS 17。

Beta 验证（2026-10-27）：iPhoneOS / iPhoneSimulator Debug 无签名构建通过；源码、语言与既有 CPU 回归通过；连续视频编码/背压验证及 13 项采集包测试通过；新增 ZIP 回归验证库隔离、深度筛选、源文件不变及失败拒绝。iPhone 18 Pro / iOS 27.0 模拟器 3 项 UI 测试通过（翻转及直接拍摄、视频导入入口、真实既有视频预览/Visualization/保存）。导出的测试 ZIP 含 102 张真实图片、102 个位姿，CRC、引用及原视频 SHA-256 核对通过。该数据来自既有 Mac 处理，不能代表新手机位姿计算验收。日志、截图与 `BetaUI-verified.xcresult`（最终排版补验见 `BetaUI-layout.xcresult`）保存在 `.build/beta-20261027/`；为绕过原工程被 Xcode 占用的文件协调锁，构建使用同目录临时工程引用当前实际源码。真机相机/4K、LiDAR 同步、运动预设与距离显示尚待验收。

2026-10-28 Beta 真机安装：使用现有个人签名完成 Release / iPhoneOS 构建，构建参数指定 1.0（build 3，源工程 build 设置未改变），签名校验通过。已原位更新到连接的 iPhone 18 Pro / iOS 27.2，实际查询确认版本为 1.0（3），启动成功且进程存活；截图确认首页正常、原有 5 条扫描记录可见。本次仅验证安装与启动，Beta 实际拍摄、4K、LiDAR、距离及真机 ZIP 仍需操作验证。签名产物保存在 `.build/iphone-release/20261028-1.0-b3-beta/`，日志、签名信息、安装/启动 JSON、截图及源码摘要在 `.build/beta-device-20261028/`。当前描述文件有效期至北京时间 2026-10-30 11:04:43，届时需重新签名安装。

2026-10-28 Beta 已有视频真机闭环：在 iPhone 18 Pro / iOS 27.2 上，从 Files 选择此前 Mac 3DGS 使用的 IMG_0568 SDR MOV，由手机重新抽帧和运行 RealityKit 摄影测量。首轮发现 `/var` 与 `/private/var` 同一目录的 URL 不相等，导致处理成功后预览误报找不到数据；改为校验库归属后按规范化实际路径查找，新增目录别名与跨库拒绝回归通过。Release 真机及 Debug 模拟器构建通过，版本升为 1.0（build 4），已更新手机。修复后完整真机 UI 测试通过，覆盖导入、位姿处理、预览、Visualization、ZIP 保存及 App 重启后重新打开场景。50.735 秒的输入得到 102 张 899×1600 JPEG、102 个有效位姿、489 个稀疏点；从点击计算到预览约 93 秒（含界面等待）。ZIP 为 92,723,046 字节，含 112 个文件；CRC、原视频 SHA-256、相机矩阵、图像尺寸及抽帧/位姿/源视频 PTS 对应核对通过。普通视频没有 LiDAR 和米制尺度，本次不代表实时相机、4K 或 LiDAR 采集验收。测试日志、失败及修复后的结果、真机截图、ZIP 和校验报告位于 `.build/beta-device-video-20261028/`；签名 App 保留于 `.build/iphone-release/20261028-1.0-b4-beta/`。

2026-10-28 Beta 拍摄问题排查（build 5）：首页入口已改为翻转图标；1080p / 4K 使用相同宽度，真机 UI 检查已验证双向切换宽度和左边界保持一致。采集页补充相机初始化/权限/失败提示，并修正短暂 inactive 状态及返回前台时的渲染恢复。Release 真机、Debug 模拟器构建通过，build 5 已安装。真机拍摄测试仍失败：25 秒内按钮未就绪；相机会话持续返回帧，但采样亮度为 16，追踪停在 initializing。独立结束 App 并重启系统相机后，系统相机取景仍暗；用户反馈拿起移动及重启 iPhone 后系统相机也仍黑屏。当前证据不足以判断系统或硬件根因，不能宣称拍摄已修复，也未验收实时录像、4K 或 LiDAR 导出。结果和日志位于 `.build/beta-camera-fix-20261028/`，最新复测为 `ResumeCheck.xcresult`；需先恢复系统相机正常取景再继续采集验收。


2026-10-28 场景管理更新（build 7）：加入前台 GPS 位置/地址记录、原生地图入口、快速改名、详情删除、卡片/列表切换、多选/全选和按场景名称分目录的批量 ZIP。定位侧文件保留 WGS84 坐标、时间和精度；旧视频不会自动使用当前位置。系统 ZIP 打包器遗漏 UTF-8 标记的问题已修复，覆盖普通 ZIP 与 ZIP64。Release 真机、Debug 模拟器编译、语言检查与场景归档回归通过；模拟器完整管理 UI 测试通过，包含改名持久化、模拟坐标地图入口、取消删除、单个/批量删除测试副本、全选与批量保存。两个真实视频测试副本导出 152,859,120 字节，每个含 102 张图片和 102 个位姿；CRC、中文目录名、原视频 SHA-256 验证通过，原场景保留。

build 7 已原位安装到 iPhone 18 Pro / iOS 27.2，设备查询版本、启动和签名校验通过。Device Hub 实测卡片/列表切换、3 个场景全选及批量保存成功；取回 262,211,421 字节 ZIP，验证 3 个场景各有 49/102/102 张图片及相同数量的位姿，中文目录名和 CRC 均通过。未删除或改名手机原有场景；原重建首页仍显示 5 条记录。新增的 49 帧场景来自手机已有数据，本轮未亲自验证其录制过程。GPS 实拍授权/精度/地址、地图底图加载和实时拍摄联动仍待验收；模拟地图坐标不算实测。用户后续澄清系统相机是所有镜头画面发灰模糊，不能用电脑预览的黑色画面替代手机观察，也未确定异常根因。证据位于 `.build/beta-management-20261028/`（`ManagementUI-utf8.xcresult`、`batch-validation.json`、`device-batch-validation.json`）；签名 App 在 `.build/iphone-release/20261028-1.0-b7-management/`。


2026-10-28 视频前台处理修复（build 8）：设备未开放后台 GPU 时，视频位姿估计继续在前台运行，界面改为明确提示保持 App 打开。修复把短暂 `.inactive` 误当作后台而取消处理的问题；只有实际 `.background` 且未获 grant 时才停止，并保留原视频供重试。未增加或绕过后台 GPU 权限。Release 真机、Debug 模拟器构建及 25 项本地化检查通过，build 8 已原位安装。真机中断测试已通过后台停止/原片保留/重试及控制中心短暂失焦不取消的断言，但该整套长测试随后被系统撤销 UI 自动化授权而终止，不能标为完整通过。独立前台全流程重测通过（110.739 秒，含选片和界面等待）：既有 IMG_0568 SDR 视频得到 102 张图像、102 个有效位姿和 489 个点，进入 Beta 预览；矩阵、图像/位姿时间对应及记录的源视频 SHA-256 核对通过。运行日志确认 `gpuSupported=false` 时仍完成计算。源码回归入口 `tools/test_video_foreground_ui.swift` 需加入真机 UI 测试 target，并预先放入注释指定的测试视频；不删除用户场景。证据在 `.build/video-foreground-fix-20261028/`（最终 `DeviceForeground-complete.xcresult` 与 `validation.json`），签名产物在 `.build/iphone-release/20261028-1.0-b8-foreground/`。

2026-10-28 相机生命周期修复（build 9）：相机失焦、后台、退出、失败和重新配置前恢复连续自动曝光/白平衡/对焦，清除曝光时长上限与实际 EV 偏置；关闭相机会话后的控件回调不再写入设备。Beta 默认使用自动曝光/白平衡，不施加重建模式的 1/60 秒曝光上限；重建模式的自动锁定等待首帧后至少 1 秒、正常追踪及曝光/白平衡调节结束。初始化超过 8 秒提供手动重试，禁止在录制过程中重置世界坐标。Release 真机与 Debug 模拟器编译、25 项本地化检查通过，build 9 已原位安装。真机异常恢复 UI 测试通过（53.231 秒）：初始化重试、后台返回、1080p/4K 等宽切换、退出及重新进入。完整录制回归在第一步等待 ARKit 就绪时失败，未进入录制，也未新建或删除场景；设备帧日志持续亮度采样 Y=16、追踪初始化。用户确认测试前系统相机本身仍发灰/黑屏，因此不能宣称拍摄或系统相机异常已解决。源码测试入口 `tools/test_camera_lifecycle_ui.swift` 分开验证正常拍摄和异常恢复；后者通过不能代替前者。证据在 `.build/camera-session-recovery-20261028/`，含 `DeviceLifecycle.xcresult`（失败）、`DeviceRecovery.xcresult`（通过）及 `device-console.log`。 用户随后要求暂停修复并上传当前代码：本提交是未完成实拍验收的工作快照。独立 AVFoundation 对照程序源文件保存在 `tools/camera_isolation_probe.swift`，已编译但尚未运行验收，需单独 App target，不属于扫描 App 的入口。

2026-11-03 相机参数核验：此前手机 ARKit 场景 `scan_20261028_013740_F40C9E` 的 1,022 条连续帧记录和 49 张关键帧均已保存逐帧内参及原始 c2w。真实 MOV 解码得到 1,020 帧，另 2 帧明确记录媒体背压；帧数、PTS、图像尺寸和关键帧参数对应检查通过。已另存显式 K、ARKit c2w/w2c 和 OpenCV R/t 参数包，详见 [采集与存储](docs/采集与存储.md)。源码检查、13 项采集包回归及连续录像回归通过；本轮没有修改 App 或重新录制，未验收外参绝对精度、LiDAR 对齐及相机异常恢复。旧 `TRANSFER_MANIFEST.json` 对当前已开发目录在 `.gitignore` 报摘要不一致，未覆盖源码或修改旧清单，也未将迁移哈希检查标记为通过。

## 4. 功能安排与数据约定

### 4.1 采集与存储

首页“开始扫描”先打开拍摄准备页，用户选择“仅相机”或“相机 + LiDAR”；选择保存于 `capture.reconstructionMode`，缺少 LiDAR 的设备仅可选相机。两种方式共享默认采集画质，不另设画质分档。仅相机仍使用真实 ARKit 位姿及多视角图像重建点云，关闭 sceneDepth、场景网格和深度写入；相机 + LiDAR 按设备能力使用同步深度。

使用 Apple ARKit 获取同一个 `ARFrame` 的 RGB、时间戳、内参、相机位姿、追踪状态，以及所选模式实际提供的深度与置信度。使用 AVFoundation 编码，不额外启动另一个相机采集会话。`sceneDepth` 是公开 API 深度，不是 LiDAR 原始回波；并非每帧都有深度。

| 输出 | 约定 |
| --- | --- |
| `color.mov`、`color-0001.mov` 等 | H.264 SDR、原生尺寸；续拍新增分段；使用真实帧间时间 |
| `frames.jsonl` | 全帧索引，包含视频写入状态、尺寸、K、c2w、追踪与深度引用 |
| `capture-meta.json` | 格式版本、设备/系统、实际配置、时间和坐标语义、分段及失败状态；读取继续兼容旧 `meta.json` |
| `capture-processing.json` | 拍摄后的处理状态、阶段、进度和 LiDAR 模式；与视频流是否完整分别记录 |
| `depth/continuous/*.f32`、`*.u8` | 米制 Float32 小端紧密行排列深度、UInt8 置信度；记录宽高并关联帧 |
| `images/`、`poses.jsonl`、关键帧 `depth/` | 保留基线训练输入，不与连续深度覆盖 |
| `sparse/0/` | 导出 COLMAP 相机、图像姿态及初始化点云，支持后续研究工具 |

ARFrame 时间戳为系统启动后的秒数；每段视频 PTS 相对该段首个成功写入帧。采集变换为 row-major c2w，ARKit/OpenGL 相机朝 −Z、Y 向上；原生深度单位是米。复制像素和深度使用有界队列，不长期持有 ARFrame。停止后等待编码与文件收尾，缺深度、丢帧、空片段、写入失败和中断必须如实标记。

### 4.2 Mac 数据处理

普通视频没有 ARKit 位姿或 LiDAR 深度，需要重新估计相机，不能补造这些数据。

iPhone 首页“使用已有视频”入口：从照片或文件选择视频，先预览，再点击“在 iPhone 上准备重建”，完成后进入现有训练设置、训练和 Viewer。整个流程在设备内运行；需要 iOS 26+ 和实际支持 `PhotogrammetrySession` 的设备（使用估计相机内参 API）。不支持的设备仍可选片预览，重建按钮禁用并解释原因。历史页的模型 ZIP 导入保持独立；直接拍摄仍使用 ARKit/LiDAR 采集链路。

手机入口限制 2 GB、180 秒，最多 `min(200, 设备图片上限)` 帧、长边 1600；AVFoundation 按真实容器 PTS 抽取、应用一次方向变换，以 `forceSDR` 和色彩管理输出 sRGB 8-bit JPEG。保留原始副本、SHA-256、时间及转换参数。准备从前台启动；只有后台 GPU 能力、签名授权和实际持续后台任务均满足时，才允许抽帧及摄影测量切换到后台继续。未获准时切后台、用户取消或任务到期会等待摄影测量停止，再清理本次未发布输出，保留原片供重新准备；成功才整目录发布到 `Documents/scans/scan_video_*`。严重过热/内存警告仍会停止，重新进入不会并行启动另一个未停止的任务。

Mac 文件流程继续通过页面上传或 `local-data/inbox/` 运行，规则如下：

- 输入：MOV/MP4/M4V；建议 1080p30、1×、关闭 HDR，首版拒绝 HDR 和超过 3 分钟的视频。
- FFmpeg 约每 0.5 秒选取一个真实原始帧，长边最多 1600；不插值、不重复帧，至少需要 8 帧。
- 保存源视频 SHA-256、探测结果和原始时间戳到 `video-source.json`、`video-frames.json`；保留源 PTS 的非零或负起点，要求有限且严格递增，不自动归零。
- 使用 `RealityKit.PhotogrammetrySession` 的相机/点云输出取得实际估计的内参与位姿；缺失或约定不明确时失败，不能生成假相机。
- 检查正深度与图像内投影来判断相机约定，将相机平移和点云共同归一化；在 `video-import.json` 明确标记任意尺度，不能声称为米制。
- 训练输入写入 `scan/images/`、`poses.jsonl`、`points.ply`。图像目录使用相对路径，完整实验位于 `local-data/runs/<实验编号>/`。

ARKit 到 COLMAP 的变换只做一次，图像方向、内参、相机和点云必须一致。原始图片、深度和采集位姿不可覆盖，优化位姿另存。初始化 `points.ply` 不是高斯模型。

### 4.3 高斯重建

直接复用固定上游的 Swift/Metal 训练器。Quick 基础配置为训练图像长边 960、4,000 次迭代、最多 300,000 个高斯；实际数量和迭代受设备预算与现有自动策略影响，必须记录实测值。

Mac 普通视频入口关闭 LiDAR 深度初始化/损失和再次位姿精修，首版关闭 PPISP，便于比较浏览器原始模型颜色。iPhone 的视频新训练同样显式关闭深度初始化/损失和再次位姿精修，PPISP 默认关闭但可在高级设置启用；恢复检查点沿用已有配置。未知曝光不能被当作实测质量依据。iPhone 路径继续保留内存、温度、电量及检查点保护。后台训练要求设备开放后台 GPU、有效签名带有所需 entitlement，且 `BGContinuedProcessingTask` 已实际启动；否则切后台保存检查点并暂停，返回前台后由用户继续。拍摄后仅依赖 CPU 的位姿/点云处理使用独立 CPU 后台申请。请求排队/提交成功不能替代授权，系统取消和到期必须停止任务，强制结束 App 不支持继续运行；真机分别验证正常持续、拒绝和中断恢复。

训练输出在 `scan/gaussian-training/model/`：`gaussians.sog`、标准 `gaussians.ply`、`gaussians.json`、`experiment.json`、`training-report.json`、`training-poses.jsonl`，以及按配置生成的 `ppisp.json`、`preview.jpg`。视频来源的 `video-import.json` 随模型保留。先写临时目录，成功后发布；失败不可标为完成。

`experiment.json` 记录方法版本、配置、输入帧 ID、真实迭代数、耗时与高斯数。iPhone 支持基线检查点恢复；Mac 页面的“继续训练”从准备好的输入重新开始，不承诺恢复到中断的迭代。

### 4.4 查看、导出和手机导入

Mac 页面只监听 `127.0.0.1:8765`。完成训练后，SuperSplat 读取标准 GS PLY，支持旋转、缩放、平移、重置和模型 ZIP 下载。默认 WebGL、关闭额外调色；配置为 `tools/mac_demo_web/viewer-settings.json`。

完成模型后点击“分享 3DGS 模型”选择 SOG（压缩模型）或 PLY（标准 3DGS）。分别生成 `*-3dgs-sog.zip` / `*-3dgs-ply.zip`，只携带所选模型，并保留相机、PPISP、实验与视频尺度来源；包内元数据声明匹配选中格式，源模型文件不改。只有 SOG 的导入模型不会伪造原始 PLY，缺失选项禁用并说明。

手机通过“扫描记录 → 导入 3DGS 模型”选择 ZIP；验证后原子发布，使用 `imported-model.json` 标记来源。初始视角来自包内 `training-poses.jsonl`，不能伪造成手机采集记录或本机训练成功。导入包没有原始照片，所以不提供重新训练/加强模型。SOG 内部结构通过不等于纹理解码和 GPU 显示通过，加载失败保留文件并显示错误。

iOS 优先尝试 `GaussianSplatResource` / `GaussianSplatComponent`，从模型参数构造位置、尺度、旋转、不透明度和球谐缓冲区，不能假设 RealityKit 直接打开 SOG/PLY。现有代码以 Swift 6.4 / iOS 27 条件保护，须在目标 SDK 核对真实 API。

尺度和不透明度分别为对数/原始 logits；四元数是 wxyz；球谐布局、坐标翻转和 sRGB 约定需要一致。原生不可用、资源失败或内存不足时回退 Metal；PPISP 相机校正也使用 Metal。记录 `viewer-backend.txt`，核对重复打开、朝向、基础颜色和手势，不将原始颜色与 PPISP 校正颜色误作相同。

## 5. 新 Mac 的下一步：按这个顺序执行

### 第一步：核对迁移与工具链

先读 `AGENTS.md`，在未修改源码前执行：

```sh
python3 tools/verify_transfer.py
```

手工复制且没有 `TRANSFER_MANIFEST.json` 时跳过该命令；它只验证拷贝完整性，编辑后哈希变化是正常的。

准备完整 Xcode、macOS/iOS SDK、Metal Toolchain、Python 3、FFmpeg（含 ffprobe）、Git、Node.js 20+ 和 npm。确认目标 Mac 系统满足选定 Xcode 的要求，参考 [Apple 安装说明](https://support.apple.com/en-us/149040)；iOS 27 原生分支需相应 SDK。不要沿用旧机器的 `.build/`。

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
bash tools/verify_project.sh source
bash tools/setup_project.sh all
bash tools/verify_project.sh mac
bash tools/test_gaussian_training.sh
```

安装路径不同时调整 `DEVELOPER_DIR`。缺少 Metal Toolchain 时在 Xcode 组件页安装，或在该 Xcode 支持时运行 `xcodebuild -downloadComponent metalToolchain`。工具链指纹会检查架构、SDK、编译器及源码摘要。失败应先修复并记录，不能复用旧二进制冒充通过；日志位于 `.build/verification/`。

### 第二步：完成一次真实 Mac 重建

1. 将用户拍摄的视频放到 `local-data/inbox/`，或通过页面上传。建议使用静态、有纹理的场景，光照稳定、慢速绕拍。
2. 运行 `bash tools/start_mac_demo.sh`，打开 `http://127.0.0.1:8765`。
3. 检查抽帧、实际时间戳、摄影测量位姿/内参与点云；坐标不明确或重建失败时保存日志并修复。
4. 用默认 Quick 配置训练，确认产生可读取的 SOG、标准 GS PLY 和完整实验记录，记录 Mac 型号、实际耗时和内存。
5. 在页面查看、拖转和缩放；重新打开模型；导出 ZIP，确认相机视角和任意尺度声明保留。

### 第三步：部署 App 并导入同一份 Mac 结果

```sh
bash tools/verify_project.sh ios
```

该命令依次编译 iPhoneOS、iPhoneSimulator 目标，关闭签名，不安装 App。随后打开 Xcode 工程，在 Signing & Capabilities 选择自己的 Team，必要时设置唯一 Bundle ID；连接并信任手机、启用开发者模式，再运行 App。

先导入第二步的模型 ZIP，检查 Files 选择、RealityKit/Metal 实际后端、交互和退出后重新打开。`arkit-3dgs-scanner` scheme 用于采集和性能计时；仅调试源码时使用 `arkit-3dgs-scanner-Debug`。安装、Apple ID/签名选择和设备信任需要用户介入。

### 第四步：完成手机完整闭环

在真机分别选择仅相机、相机 + LiDAR，使用同一默认画质采集同类场景 30–60 秒，导出原始包；检查视频播放、帧索引、内参、位姿与实际深度对应关系。拍摄保持前台，之后分别验证 CPU 位姿/点云处理、视频摄影测量和 3DGS 的后台授权提示及切换其他 App 后是否继续。未获准、系统取消或到期应走停止/检查点保护，而非误报后台成功；回前台检查恢复或重新准备。记录真实耗时、峰值内存与热行为，并验证 SOG、PLY 两种分享包及重新导入。检查权限拒绝、跟踪丢失、深度缺失、磁盘不足及强制结束后的持久化数据。

### 第五步：验收后再扩展研究

在同一输入上增加不同方法和配置的切换，对比质量、耗时、内存与失败率；需要 Mesh 时再加入生成/导出。界面美化与大场景不阻塞上述验证；本轮用户要求的后台分支需单独验收。

2026-11-03 新增相机精度研究目标：用户确认只要求单次采集内统一米制坐标，工作距离暂未确定。已核对官方相机控制、标定、摄影测量和深度接口；采集预设建议及现有控制缺口见 [采集与存储](docs/采集与存储.md)，官方接口边界和已有自研位姿精修路径见 [数据处理](docs/数据处理.md)。后续先验证清晰成像、逐帧参数和米制几何，再评估 LiDAR/图像约束对精度的改善；锁焦、内参不变或优化残差下降均不能独自证明标定正确。随后按用户确认实现 Beta 默认启用可用 LiDAR、保留自动对焦，采集后用 RealityKit 重新估计保存的关键帧并单独对齐至原 ARKit 米制世界；不改写全帧原始参数，也不承诺每帧都可解或精度必然提高。新增真机实验仍待完成。

## 6. 关键实现入口与检查

以下路径相对项目根目录；App 内简写路径均在 `arkit-3dgs-scanner/` 下。

| 领域 | 首先查看 |
| --- | --- |
| 采集与文件契约 | `Capture/CaptureController.swift`、`Capture/CaptureSessionConfiguration.swift`、`Capture/CaptureStreamRecorder.swift`、`Capture/Models.swift`、`Capture/ExportManager.swift` |
| Mac 页面与任务 | `tools/mac_demo.py`、`tools/mac_demo_web/` |
| 视频与相机准备 | `tools/prepare_video_scan.swift`、`tools/build_video_preparer.sh`、`arkit-3dgs-scanner/VideoImport/` |
| 数据选择与几何 | `Capture/TrainingFrameSelector.swift`、`History/ScanLibrary.swift`、`Training/TrainingDataset.swift` |
| 训练与持久化 | `tools/train_gaussians.swift`、`Training/GaussianTrainingSession.swift`、`Training/GaussianTrainer.swift`、`Training/TrainingWorkspace.swift`、`Training/GaussianExport.swift` |
| 模型导入 | `History/GaussianModelImport.swift`、`History/ScanHistoryView.swift`、`Training/StoredZip.swift` |
| iPhone Viewer | `Training/GaussianModelViewer.swift`、`Training/GaussianRealityKitViewer.swift`、`Training/UI/GaussianTrainingView.swift` |
| 迁移/验证 | `tools/setup_project.sh`、`tools/verify_project.sh`、`tools/check_project.py`、`tools/package_project.py`、`tools/build_text_handoff.py`、`tools/restore_text_handoff.py`、`tools/verify_transfer.py` |

按改动选择额外检查：`tools/test_capture_stream.sh` 验证连续录像；`tools/test_capture_package.py` 验证文件契约；`tools/test_training_quality.sh` 检查训练帧策略；`tools/validate_capture_package.py <扫描目录>` 检查真实采集包。坐标回归和部分历史分析工具使用 `tools/requirements.txt` 中的可选 Python 依赖。最终仍以真实输入和目标设备为准。

## 7. 新 agent 如何继续编写 docs

**交接只要求 README 和 AGENTS，不要求先补文档才能编译。** 现有源码检查允许缺少 `docs/`。旧仓库中如已有对应文档就直接更新；精简副本中没有文档时，完成相应模块验证后按下表逐步编写，最多四份，均用简体中文。

| 文件 | 必须写明的内容 |
| --- | --- |
| `docs/采集与存储.md` | 真机支持格式及选择规则、同帧同步、目录/字段与类型、时间和深度语义、丢帧/失败/续拍、收尾与导出、真实包检查结果 |
| `docs/数据处理.md` | 视频输入限制与抽帧、摄影测量实际输出、相机约定判断、归一化/任意尺度、ARKit/COLMAP 转换、深度对齐、原始与优化数据的对应关系 |
| `docs/高斯重建.md` | Mac/iPhone 入口、Quick 实际配置和自动调整、内存/温度/检查点、输出格式和实验记录、实测设备/数据/耗时/内存/质量及未通过项 |
| `docs/模型查看.md` | Mac 与 iPhone 后端、模型导入契约、缓冲区/坐标/颜色/激活、初始视角、手势、重开、后端回退、性能及朝向颜色对照 |

每份按“目的与输入输出 → 实现入口与约定 → 验证方法 → 实际结果/限制”组织，先查代码和真实文件再写，不直接把本文计划描述为已完成。总体状态、阶段顺序和验收在 README 维护；按用户要求另维护 [App 功能与真机测试指南](docs/App功能与真机测试指南.md)，集中说明功能、pipeline 和个人 iPhone 安装测试步骤，以及 [数据保存格式](docs/数据保存格式.md)，集中维护对外读取契约。AGENTS 仅保存接手规则和必要上下文。不要另增英文/TW 副本、阶段汇报、重复使用指南或一次性排查文档；具体运行日志留 `.build/`，实验记录随数据保存。

首版验收须同时具备：真实视频重建模型、手机采集可追溯文件、手机实际训练结果、Viewer 可交互且可重开、坐标/深度/颜色核对、异常路径记录。Mac 重建、Mac 模型手机查看、手机端侧训练分别记录，不能互相替代。

## 8. 来源与授权

- 基线：[arkit-3dgs-scanner 固定版本](https://github.com/KuoFengYuan/arkit-3dgs-scanner/tree/ed156e2e468fdd70d33aef68e7c98c6f03718dda)。采用 PolyForm Noncommercial 1.0.0，署名见本地 [NOTICE](NOTICE)，条款见 [LICENSE](LICENSE)，机器可读来源见 [PROTOTYPE_BASELINE.json](PROTOTYPE_BASELINE.json)。
- 历史授权文本：[licenses/Apache-2.0.txt](licenses/Apache-2.0.txt) 原样保留；具体适用范围见 NOTICE，不能据此把当前整个项目改标 Apache 或 MIT。
- Mac Viewer：[SuperSplat 固定版本](https://github.com/playcanvas/supersplat-viewer/tree/5976646dc972e7700fbde3948465795cca0a4ebc)，MIT。`tools/setup_mac_viewer.sh` 自动 clone、固定提交、`npm ci`、构建并检查其 LICENSE；新 Mac 需要联网，iOS App 不依赖该浏览器 Viewer。

**许可证不是待生成的说明文档。** 直接携带 LICENSE、NOTICE、licenses/ 原文及源码版权头；不要翻译、缩写或让模型重写条款。依赖代码如重新下载，也保留其原版权/授权文件。NOTICE 内原有英文或繁体内容属于保留的声明，不受项目说明简体化规则影响。

如需对照上游或核验遗漏的授权，可在独立目录读取固定版本，不能覆盖迁移来的本地实现：

```sh
mkdir -p .build
# 仅在该参考目录不存在时 clone；已有目录先检查其状态。
git clone --no-checkout https://github.com/KuoFengYuan/arkit-3dgs-scanner.git .build/upstream-reference
git -C .build/upstream-reference checkout --detach ed156e2e468fdd70d33aef68e7c98c6f03718dda
```

上游许可原件也可参考 [LICENSE](https://github.com/KuoFengYuan/arkit-3dgs-scanner/blob/ed156e2e468fdd70d33aef68e7c98c6f03718dda/LICENSE) 与 [NOTICE](https://github.com/KuoFengYuan/arkit-3dgs-scanner/blob/ed156e2e468fdd70d33aef68e7c98c6f03718dda/NOTICE)。本地 NOTICE 还包含新增的 Mac Viewer 声明，不要用上游文件整份覆盖。程序和新增功能必须来自本次迁移包。
