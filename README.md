# 优学派 U90（yxp_713_pad）Android 11 GSI

[English](README.en-US.md) | **简体中文**

[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
![Android](https://img.shields.io/badge/Android-11-green.svg)
![Device](https://img.shields.io/badge/device-yxp__713__pad%20%2F%20MT6779-lightgrey.svg)

面向优学派 U90（`yxp_713_pad`，MT6779）的 Android 11 PHH/Treble GSI 构建配方。

这台机器的触屏与前摄被原厂组件的私有行为锁住，直接刷通用 GSI 会得到一个触屏无响应、前摄不工作的系统。本仓库把这部分行为补齐，并保留了原厂 `boot`、`dtbo`、内核与 `vendor`。

## 这是什么

- 一份**可复现的构建配方**：固定到 PHH v313 / `android-11.0.0_r48`，每个源码树都钉死 revision，构建前会校验 release manifest 的 SHA-256。
- 一套**设备专属补丁**：作用于 `frameworks/*`、`system/core`、`device/phh/treble` 等树，每一条都有实测依据。
- 一个**本地打包工具链**：把构建出的 `system` 与原厂 `product`、`vendor` 合成完整 `super`，并生成配套的 vbmeta 与刷写计划。

## 这不是什么

- **不是通用 GSI 框架。** 只服务 `yxp_713_pad`。仓库里几乎每个取值（分区几何、相机 id、马达协议、bootprof 标记）都是在这台设备上实测出来的，脱离它就失去依据。
- **不是固件包。** 仓库不含原厂镜像、不含任何分区 dump、不含签名材料。
- **不提供 root。** 构建目标是 `N` 变体，不含 `phh-su`、Magisk 或任何 root 管理器。
- **不碰内核与 `vendor`。** 只替换 `super` 与 `vbmeta` 系列。

## 当前状态

| 功能 | 状态 | 说明 |
| --- | --- | --- |
| 触屏 | 已实测 | 需要 bootprof 闸门补丁，否则完全无响应 |
| 前摄出图（camera id 1） | 已实测 | 物理前摄是 id 1，不是 id 0 |
| 前摄自动升降 | 已实测 | 前摄会话开始时抬起，断开后收回 |
| 马达手动控制 | 已实测 | `u90-motor` 的 `status` / `up` / `ar` / `down` / `stop` |
| 中文输入法 | 已实测 | Fcitx5，需手动启用一次 |
| 平板 UI | 已实测 | tablet 特性 + Material 配色 + `6 x 5` 桌面 |
| 大陆网络校验 | 已实测 | 校验端点已换为国内可达地址 |
| 完整 `super` 打包 | 已实测 | 与原厂 `product`/`vendor` 合成，校验字节一致 |
| 后摄 | 未验证 | 未做过针对性验证 |
| Wi-Fi / 蓝牙 / 音频 / 传感器 | 未验证 | 未逐一验证 |
| root | 不提供 | 需要的话请自行处理 boot 镜像 |

## 兼容性与前置条件

| 项目 | 要求 |
| --- | --- |
| 机型 | 优学派 U90 / `yxp_713_pad` |
| SoC | MediaTek MT6779 |
| 分区 | 非 A/B 动态分区；`super` 物理大小 8 GiB，`misc` 512 KiB |
| bootloader | 必须已解锁，`ro.boot.verifiedbootstate=orange` |
| Recovery | TWRP 3.7.1_12-0 或更高，设备树 `61810b9` 及以后 |
| 原厂固件包 | 形如 `P713mt6779_20221129_2216`，打包 `super` 与回滚时必需 |

## 快速上手

本仓库没有在线 CI。AOSP 11 的源码同步与编译超出 GitHub-hosted runner 的时间与磁盘预算，构建、打包与校验全部在本地 Docker 内完成。

### 1. 构建 `system` 镜像

```powershell
.\gsi\scripts\run-local-docker.ps1 -FrontSensorOrientation 90 -Jobs 12 -BuildName u90-a11-v5
```

产物在 `artifacts/local/u90-a11-v5/`，其中 `system_gsi.img` 就是下一步要用的镜像。

### 2. 打成本地 `super` 包

`super` 需要你自备的原厂 `product` 与 `vendor`：

```powershell
.\gsi\scripts\run-local-docker.ps1 `
  -Mode package `
  -BuildName u90-a11-v5 `
  -FirmwareDir C:\path\to\P713mt6779_20221129_2216 `
  -PackageName u90-a11-v5-package
```

### 3. 刷入

```bash
fastboot flash vbmeta         vbmeta_u90_avb_disabled.img
fastboot flash vbmeta_system  vbmeta_system_u90_avb_disabled.img
fastboot flash vbmeta_vendor  vbmeta_vendor_u90_avb_disabled.img
fastboot flash super          super_u90_gsi.sparse.img
fastboot reboot
```

完整步骤、刷后校验与回滚见 **[docs/FLASHING.md](docs/FLASHING.md)**。三条硬规则先说在那里：**不要 `dd` 稀疏镜像**、**三个 vbmeta 不要刷错分区**、**每次只改一个变量**。

## 本地构建选项

Android 源码、`out/`、ccache 与 manifest 缓存都是 Docker named volume，因此重复构建是增量的。除上面的完整构建外还有三种模式：

```powershell
# 只校验容器配方，不下载源码，秒级完成
.\gsi\scripts\run-local-docker.ps1 -Mode validate

# 只同步源码、manifest 与 Fcitx5 APK，不编译
.\gsi\scripts\run-local-docker.ps1 -Mode sync

# 只打包 super
.\gsi\scripts\run-local-docker.ps1 `
  -Mode package `
  -BuildName u90-a11-v5 `
  -PackageName u90-a11-v5-package
```

默认不使用代理。需要代理时，在仓库根目录建一个 `.env`（已被 gitignore）：

```text
HTTP_PROXY=http://host.docker.internal:<port>
HTTPS_PROXY=http://host.docker.internal:<port>
```

或单次指定 `-Proxy <url>`；用直连时加 `-NoProxy`。注意不要把 Android 源码放在 `C:\` 的 bind mount 上，只有 `artifacts/local` 会挂回 Windows。

参数与产物格式详见 [gsi/README.md](gsi/README.md)。

## 补齐了哪些原厂专有行为

| 现象 | 根因 | 做法 |
| --- | --- | --- |
| 触屏完全无响应 | 内核等 `/proc/bootprof` 出现 `BOOT_Animation:END` 才给 Himax 触屏上电；原厂 MTK SurfaceFlinger 会写这个标记，AOSP 不会 | 在 AOSP SurfaceFlinger 里写该标记（`frameworks/native` 补丁） |
| 前摄不工作 | 前摄模组装在一个升降马达上，原厂靠应用启动广播抬起来 | `CameraService` 在前摄 `connect`/`disconnect` 时通过 `/dev/NOAH_MOTOR` 抬升与收回（`frameworks/av` 补丁） |
| 前摄画面方向不对 | vendor HAL 上报 `270`，实际需要 `90` | `ro.u90.camera.front.orientation`（默认 90）覆写 metadata 与 API1 camera info |
| 刷完 GSI 反复回到 fastboot | `sas-creator` 的 A-only 产物没有 `/system/bin/init`，而原厂 ramdisk 的一阶段 init 无条件 exec 它 | 直接导出 raw system-as-root 构建产物，不做 A-only 转换 |
| 网络显示"已连接但无法访问" | NetworkStack 用 Google 校验端点，国内不可达 | 换成国内可达端点，并替换 MCC 460 资源默认值 |
| 中文与默认项不合用 | 默认英文、60 秒息屏、不自动旋转 | `zh-CN`、`Asia/Shanghai`、24 小时制、自动旋转、息屏 5 分钟 |
| 界面不像平板 | 默认手机布局 | `PRODUCT_CHARACTERISTICS := tablet` + Material 配色 + `6 x 5` 桌面 |
| 中文输入 | 无自带输入法 | 固定 Fcitx5 Android `0.1.3`，校验 SHA-256 后作为预签名系统应用装入 |

马达协议的做法值得单说：驱动把整个命令字减去 `0x40c44d00` 后查一张 17 项的跳转表，表中**只有一个**真实位移命令 `0x40c44d01`，目标位置由入参给出（`1` 顶部 / `2` 收回 / `3` 前摄）。原厂工厂测试库用的 `nr 2` 与 `nr 8` 都是空壳，返回 0 但什么都不做 —— 这是本项目踩过的最大一个坑，`validate-recipe.sh` 里加了守卫防止回退。推导过程见 [docs/u90-vendor-gate-and-motor-design.md](docs/u90-vendor-gate-and-motor-design.md)。

## 已知限制

- **前摄首帧可能未到位。** 升降行程约 1.3 秒，钩子挂在 `connect()` 上，传感器打开的同时马达才开始动，因此会话最初几帧可能拍到尚未升起的画面。原厂靠应用启动广播提前抬起，本仓库没有复刻那套启发式。
- **无 root。** `N` 变体不含 `phh-su` 与 root 管理器。基线需要 `userdebug`（PHH v313 设置了 `SELINUX_IGNORE_NEVERALLOWS := true`），因此 `adb root` 可能可用，但没有持久化的 `su`。
- **`screencap` 抓不到硬件 overlay 层**，截图会是黑的。这不代表显示异常。
- **前摄在暗光下出黑帧属正常**，不是故障。
- 若 Launcher3 保留了旧的数据目录，原地升级后可能仍是旧网格，清一次 Launcher3 存储再回桌面即可。

## 目录结构

```text
.
├── .github/
│   ├── ISSUE_TEMPLATE/            # 问题与功能请求表单
│   └── PULL_REQUEST_TEMPLATE.md
├── docker/Dockerfile              # 本地构建镜像
├── docker-compose.yml             # 源码/out/ccache 走 named volume
├── docs/
│   ├── FLASHING.md                # 刷机与回滚
│   ├── stock-firmware-baseline.md # 原厂固件与分区几何取证
│   ├── u90-vendor-gate-and-motor-design.md
│   └── records/                   # 过程记录
├── gsi/
│   ├── config/u90-a11-v313.env    # 钉死的源码 revision
│   ├── patches/<tree>/NNNN-*.patch
│   ├── scripts/                   # 校验、打补丁、构建、打包
│   ├── templates/                 # Fcitx5 预置与 SELinux 规则
│   ├── tools/u90-motor/           # 升降马达手动控制工具
│   └── README.md                  # 配方细节
└── tools/                         # 设备状态采集与比对脚本
```

## 文档索引

| 文档 | 内容 |
| --- | --- |
| [docs/FLASHING.md](docs/FLASHING.md) | 解锁、刷入、首启、刷后校验、回滚原厂 |
| [gsi/README.md](gsi/README.md) | 基线、补丁清单、产物格式、runner 模式、打包流程 |
| [docs/u90-vendor-gate-and-motor-design.md](docs/u90-vendor-gate-and-motor-design.md) | 触屏闸门与马达升降的设计、内核逆向证据、验证阶梯 |
| [docs/stock-firmware-baseline.md](docs/stock-firmware-baseline.md) | 原厂固件包、分区表与 LK 的取证记录 |
| [docs/records/](docs/records/) | 构建记录与 fastboot 控制变量实验（含失败尝试） |
| [CHANGELOG.md](CHANGELOG.md) | 变更记录 |
| [CONTRIBUTING.md](CONTRIBUTING.md) | 贡献方式与范围边界 |

## 第三方组件与许可

本仓库以 **Apache-2.0** 授权，见 [LICENSE](LICENSE)。

构建产物包含以下第三方组件：

| 组件 | 许可 | 说明 |
| --- | --- | --- |
| AOSP Android 11（`android-11.0.0_r48`） | Apache-2.0 | 补丁作用其上 |
| PHH treble_experimentations `v313` | 上游**未声明**许可 | 只引用其发布 manifest 与补丁目标，未复制其代码；但产物会包含 PHH 的组件 |
| Fcitx5 Android `0.1.3` | LGPL-2.1 | 构建时按固定 URL 下载并校验 SHA-256，作为预签名系统应用**原样**并入，未做修改 |
| 原厂 `product` / `vendor` | 厂商所有 | **不随本仓库分发**，打包时需你自备固件包 |

分发自建镜像时，LGPL 与 PHH 部分的许可与源码可获取性由分发者自行承担。

## 致谢

- [phhusson/treble_experimentations](https://github.com/phhusson/treble_experimentations) —— 本项目所基于的 GSI 与补丁树
- [fcitx5-android](https://github.com/fcitx5-android/fcitx5-android) —— 中文输入法
- TWRP 设备树 [bobotechnology/twrp_device_youxuepai_yxp_713_pad](https://github.com/bobotechnology/twrp_device_youxuepai_yxp_713_pad) —— 修正后的 `super` 分区几何
