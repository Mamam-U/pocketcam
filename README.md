# PocketCam 口袋摄像头

iPhone 摄像头工具：插电循环录制 + 有网局域网监看 + 无网继续录（离线录制）。

当前版本：**Phase 0 + Phase 1**（循环录制 / 后台保活 / 局域网 MJPEG 监看）。

> **没有 Mac 也能编译安装**：用 GitHub Actions 云端 macOS 自动编译出 IPA，
> 下载后在 Windows 上用爱思助手签名装进 iPhone。见「二、构建方式 · 方式 A」。

---

## 一、工程结构

```
PocketCam/
├── .github/workflows/build.yml    # GitHub Actions 云编译（无 Mac 用这个）
├── project.yml                    # XcodeGen 工程配置（生成 .xcodeproj 用）
├── README.md
└── PocketCam/
    ├── App/
    │   ├── PocketCamApp.swift     # 入口
    │   └── Info.plist             # UIBackgroundModes=audio + 权限文案
    ├── Config/
    │   └── Config.swift           # 全部可调参数（段长/容量/分辨率/端口）
    ├── Core/
    │   ├── Recorder/
    │   │   ├── CameraRecorder.swift   # 采集 + AVAssetWriter 分段录制
    │   │   └── LoopStorage.swift      # 8GB 环形存储，超量删最老
    │   ├── KeepAlive/
    │   │   └── BackgroundAudioKeepAlive.swift  # 静音音频后台保活
    │   └── Server/
    │       └── MJpegHttpServer.swift    # 零依赖局域网 HTTP/MJPEG 服务器
    └── UI/
        ├── ContentView.swift      # 主界面
        └── PreviewView.swift      # 摄像头预览
```

## 二、构建方式（按你的设备选）

### 方式 A：没有 Mac → GitHub Actions 云编译（免费，推荐）

1. **建 GitHub 仓库**：github.com 注册/登录 → New repository → 名字如 `pocketcam`（Public 免费无限额度；Private 也够用）→ 创建
2. **把工程传上去**（Windows 上操作）：
   - 下载安装 [GitHub Desktop](https://desktop.github.com/)（图形界面），登录后 Clone 刚建的仓库到本地
   - 把 `PocketCam` 文件夹里的**全部内容**（含 `.github` 目录）复制进仓库文件夹
   - GitHub Desktop 里 Commit → Push
3. **触发编译**：仓库页 → Actions → 左侧「Build IPA」→ 右上 Run workflow → 等 3-5 分钟
4. **下载 IPA**：Actions 运行完成后，点这次运行 → 底部 Artifacts → 下载 `PocketCam-ipa.zip`，解压得到 `PocketCam.ipa`
   - （以后每次改代码，Push 上去就会自动重新编译出新的 IPA）
5. **装进 iPhone**（见下方「三、安装到 iPhone」）

> 注意：GitHub Actions 的 macOS 编译机有免费额度（Private 仓库每月约 200 分钟 macOS 用量，一次构建约 4 分钟，够用几十次；Public 仓库免费无限）。用完后下月自动恢复。

### 方式 B：有 Mac → 本地 Xcode

```bash
brew install xcodegen
cd PocketCam
xcodegen generate
open PocketCam.xcodeproj
```

目标设备选你的 iPhone，Signing & Capabilities 选你的 Apple ID Team，⌘R 安装。

### 方式 C：没有 Mac、不想折腾 GitHub → 付费捷径

- 租云 Mac（远程桌面，按小时计费），在云 Mac 上按「方式 B」操作，编译出 IPA 后下载
- 或淘宝/闲鱼搜「iOS IPA 代编译」，把源码发给对方，拿回 IPA

## 三、安装到 iPhone（Windows + 爱思助手，免费签名）

1. Windows 安装 [爱思助手](https://www.i4.cn/) 和「Apple Devices / iTunes」（爱思会提示装驱动）
2. iPhone 用数据线连电脑，手机信任此电脑
3. 爱思助手 → 工具箱 → **IPA 签名** → 导入 `PocketCam.ipa` → 用你的 **Apple ID 登录** → 签名（免费，约几秒钟）
4. 签名完成后点**安装**，iPhone 上出现「口袋摄像头」
5. 首次打开：iPhone → 设置 → 通用 → VPN与设备管理 → 信任你的开发者证书

> **免费 Apple ID 签名的有效期是 7 天**，到期后 App 打不开，重新在爱思签名一次即可（30 秒）。
> 要一劳永逸就用付费开发者账号（Apple Developer，¥688/年）签名一年。

## 四、怎么用（真机验收清单）

1. **开始录制**：App 内点「开始录制」，预览出现画面，状态变「录制中 · 后台保活已开启」。
2. **锁屏后台持续录**：开始录制后按电源键锁屏（或切到别的 App），等 1 分钟后解锁看：
   - 状态是否仍是「录制中」而不是「已暂停/失败」
   - 锁屏期间录制的时长是否正常增长
3. **分段与循环**：默认每 5 分钟一个文件，录满 8GB 自动删最老段。
   - 验收：录 5 分钟以上，到存储里看 `Documents/Recordings/` 是否按段生成 `seg-*.mp4`
4. **无网离线录**：开飞行模式（断开 Wi-Fi 和蜂窝）后继续录，应不受影响。
5. **有网监看（局域网）**：手机和电脑连同一个 Wi-Fi：
   - 手机 App 上会显示 `http://192.168.x.x:8080`
   - 电脑浏览器打开该地址，应看到实时画面（约 0.4 秒一帧）
   - 也可以把地址发给另一台手机，用浏览器打开看
6. **来电中断恢复**：录制中打进来一个电话（或下拉控制中心），挂断后应自动续录，文件不坏。

## 五、已知限制与风险（如实说明）

| 项 | 说明 |
| --- | --- |
| 后台保活原理 | 通过后台播放静音音频让 App 不被挂起。这是 iPhone 行车记录类 App 的标准做法，但**系统仍可能因内存压力杀掉 App**，属平台限制，无解 |
| 发热 | 1080p30 连续录制 + 后台 JPEG 编码会让手机明显发热。夏季车内暴晒可能触发系统降频/过热提示。建议通风、避免直晒 |
| 耗电 | 录制功耗约 1.5–3W。插电可长时间运行；不插电电池约 4–8 小时（视机型/温度） |
| App Store 上架 | 滥用后台音频（background audio）在审核时存在 2.5.4 拒审风险。**自用 / TestFlight / 开发者设备无此问题**；若要上架需准备合理说明 |
| 免费签名 | 7 天有效期，到期需重新签名。适合自测，不影响功能 |
| 分辨率方向 | 当前固定后摄 1080p、竖屏方向录制。方向/码率/前摄切换在 Phase 3 做成设置项 |
| 监看画质 | MJPEG 每 0.4 秒一帧、JPEG 质量 0.6，为省电设计；局域网流畅度可接受，不是 30fps 实时 |

## 六、Phase 2 规划：有网公网监看（本次未实现）

思路：iPhone 推流 → 自建服务器转发 → 任何地方浏览器看。

1. **iPhone 端**：集成 HaishinKit（SPM 包，iOS 最活跃的推流库），把录制画面以 RTMP/SRT 推到服务器
   - `github.com/shogo4405/HaishinKit.swift`（11 年维护，2025-07 发布 2.0.9）
2. **服务器端（任选其一）**：
   - go2rtc（轻量，HLS/WebRTC/MJPEG 全支持）：`github.com/AlexxIT/go2rtc`，docker 一行起
   - SRS 直播服务器（RTMP/WebRTC/HLS）：`github.com/ossrs/srs`
3. **观看端**：浏览器打开服务器地址即可；或手机装 VLC 直接拉流

无网时推流自动断开，本地循环录制照常；有网自动重连推流（Phase 2 实现）。

## 七、开发记录

- 2026-11-02：Phase 0 + Phase 1 首版。Windows 侧完成源码与云编译工作流，**未经 Xcode 编译验证，未经 iPhone 真机验证**。
- 下一步：GitHub Actions 出 IPA → 爱思装真机 → 按第四节清单验收 → 反馈结果再进 Phase 2。
