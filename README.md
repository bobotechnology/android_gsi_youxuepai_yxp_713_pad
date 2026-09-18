# 优学派 U90（yxp_713_pad）Android 11 GSI

[English](README.en-US.md) | **简体中文**

[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

面向优学派 U90（`yxp_713_pad`，MT6779）的 Android 11 PHH/Treble GSI 构建配方。只服务这一个机型。

原厂把触屏和前摄锁在私有行为上：内核要等到 `/proc/bootprof` 出现 `BOOT_Animation:END` 才给 Himax 触屏上电，前摄模组装在一个由 `/dev/NOAH_MOTOR` 驱动的升降马达上、靠应用启动广播抬起来。AOSP 两件都不做，所以通用 GSI 刷上去会得到一个触屏无响应、前摄不出现的系统。本仓库补齐这些行为，只替换 `super` 与 `vbmeta` 系列，保留原厂 `boot`、`dtbo`、内核与 `vendor`，不提供 root，也不含固件与签名材料。

## 状态

已实测：触屏、前摄出图（物理前摄是 id 1）、前摄自动升降、马达手动控制、Fcitx5 中文输入、平板 UI、大陆网络校验、完整 `super` 打包。

未逐一验证：后摄，以及 Wi-Fi、蓝牙、音频、传感器等其余子系统。

## 前置条件

| 项目 | 要求 |
| --- | --- |
| 机型 | 优学派 U90 / `yxp_713_pad`（MT6779） |
| 分区 | 非 A/B 动态分区；`super` 8 GiB，`misc` 512 KiB |
| bootloader | 已解锁，`ro.boot.verifiedbootstate=orange` |
| Recovery | TWRP 3.7.1_12-0 或更新，设备树 `61810b9` 及以后 |
| 原厂固件包 | 形如 `P713mt6779_20221129_2216`，打包 `super` 与回滚时必需 |

## 构建与打包

全部在本地 Docker 内完成。AOSP 11 的同步与编译跑不进 GitHub-hosted runner 的预算，所以本仓库没有 CI。

```powershell
# 构建 system
.\gsi\scripts\run-local-docker.ps1 -FrontSensorOrientation 90 -Jobs 12 -BuildName u90-a11-v5

# 用原厂 product 与 vendor 打成完整 super
.\gsi\scripts\run-local-docker.ps1 `
  -Mode package `
  -BuildName u90-a11-v5 `
  -FirmwareDir C:\path\to\P713mt6779_20221129_2216 `
  -PackageName u90-a11-v5-package
```

另有 `-Mode validate`（只校验配方，秒级）与 `-Mode sync`（只同步源码与 Fcitx5 APK）。产物写在 `artifacts/local/`，参数与产物格式见 [gsi/README.md](gsi/README.md)。

需要代理时在仓库根目录建一个 `.env`（已 gitignore）：

```text
HTTP_PROXY=http://host.docker.internal:<port>
HTTPS_PROXY=http://host.docker.internal:<port>
```

## 刷入

```bash
fastboot flash vbmeta         vbmeta_u90_avb_disabled.img
fastboot flash vbmeta_system  vbmeta_system_u90_avb_disabled.img
fastboot flash vbmeta_vendor  vbmeta_vendor_u90_avb_disabled.img
fastboot flash super          super_u90_gsi.sparse.img
fastboot reboot
```

三条规则：稀疏镜像**不要 `dd`**；三个 vbmeta **不要刷错分区**；**每次只改一个变量**。完整流程、刷后校验与回滚见 [docs/FLASHING.md](docs/FLASHING.md)。

## 补丁做了什么

| 现象 | 根因 | 做法 |
| --- | --- | --- |
| 触屏完全无响应 | 内核要等 `/proc/bootprof` 出现 `BOOT_Animation:END` 才给 Himax 触屏上电；原厂 MTK SurfaceFlinger 会写这个标记，AOSP 不会 | 在 AOSP SurfaceFlinger 里写该标记 |
| 前摄不出现 | 前摄模组装在升降马达上，原厂靠应用启动广播抬起来 | `CameraService` 在前摄 `connect`/`disconnect` 时通过 `/dev/NOAH_MOTOR` 抬起与收回 |
| 前摄画面方向不对 | vendor HAL 上报 `270`，实际需要 `90` | `ro.u90.camera.front.orientation`（默认 90）覆写 metadata 与 API1 camera info |
| 刷完 GSI 反复回到 fastboot | `sas-creator` 的 A-only 产物没有 `/system/bin/init`，而原厂 ramdisk 的一阶段 init 无条件 exec 它 | 直接导出 raw system-as-root 构建产物，不做 A-only 转换 |
| 网络"已连接但无法访问" | NetworkStack 用 Google 校验端点，国内不可达 | 换成国内可达端点，并替换 MCC 460 资源默认值 |
| 中文与默认项不合用 | 默认英文、60 秒息屏、不自动旋转 | `zh-CN`、`Asia/Shanghai`、24 小时制、自动旋转、息屏 5 分钟 |
| 界面不像平板 | 默认手机布局 | `PRODUCT_CHARACTERISTICS := tablet`，配 Material 配色与 `6 x 5` 桌面 |
| 无中文输入法 | 未预置 | Fcitx5 Android `0.1.3`，校验 SHA-256 后作为普通系统应用装入（首次需手动启用） |

马达的协议值得单说。驱动把整个命令字减去 `0x40c44d00` 后查一张 17 项跳转表，表中只有一个真实位移命令 `0x40c44d01`，目标位置由入参给出（`1` 顶部 / `2` 收回 / `3` 前摄）。原厂工厂测试库给下面两个模式用的是 `nr 2` 和 `nr 8`，两者在这颗内核里都是空壳：返回 0 但什么都不做。踩过这个坑之后，`validate-recipe.sh` 里加了守卫防止回退。推导过程见 [docs/u90-vendor-gate-and-motor-design.md](docs/u90-vendor-gate-and-motor-design.md)。

## 已知问题

- 前摄抬起约需 1.3 秒，钩子挂在 `connect()` 上，传感器打开的同时马达才开始动，因此会话最初几帧可能拍到还没升到位。原厂靠应用启动广播提前抬起，这里没有复刻那套启发式。
- 无 root。`N` 变体不含 `phh-su` 与 root 管理器；需要的话自行处理 boot 镜像。
- `screencap` 抓不到硬件 overlay 层，截图会是黑的，不是显示故障。暗光下前摄出黑帧同样属正常。
- 若 Launcher3 保留了旧数据目录，原地升级后可能仍是旧网格，清一次 Launcher3 存储再回桌面即可。

## 目录

```text
gsi/
├── config/u90-a11-v313.env     # 钉死的源码 revision
├── patches/<tree>/NNNN-*.patch # 设备补丁
├── scripts/                    # 校验、打补丁、构建、打包
├── templates/                  # Fcitx5 预置与 SELinux 规则
├── tools/u90-motor/            # 升降马达手动控制工具
└── README.md                   # 配方细节：基线、产物格式、打包流程
docs/
├── FLASHING.md                 # 解锁、刷入、首启校验、回滚
├── u90-vendor-gate-and-motor-design.md  # 触屏闸门与马达升降的设计与内核逆向证据
├── stock-firmware-baseline.md  # 原厂固件、分区表与 LK 取证
└── records/                    # 构建记录与 fastboot 控制变量实验（含失败尝试）
tools/                          # 设备状态采集与比对脚本
docker/  docker-compose.yml     # 本地构建环境
```

## 许可与致谢

本仓库以 Apache-2.0 授权，见 [LICENSE](LICENSE)。

构建产物另含：[AOSP Android 11](https://source.android.com/) `android-11.0.0_r48`（Apache-2.0）；[PHH treble_experimentations](https://github.com/phhusson/treble_experimentations) `v313`（上游未声明许可）；[Fcitx5 Android](https://github.com/fcitx5-android/fcitx5-android) `0.1.3`（LGPL-2.1，按固定 URL 下载校验后原样并入）。原厂 `product` 与 `vendor` 的所有权归厂商，不随本仓库分发。分发自行构建的镜像时，上述组件的许可义务由分发者承担。

TWRP 设备树 [bobotechnology/twrp_device_youxuepai_yxp_713_pad](https://github.com/bobotechnology/twrp_device_youxuepai_yxp_713_pad) 提供了修正后的 `super` 分区几何。
