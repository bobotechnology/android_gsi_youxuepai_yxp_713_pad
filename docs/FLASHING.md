# 刷机指南

本文覆盖优学派 U90（`yxp_713_pad`，MT6779）刷入 GSI 的完整流程与回滚方式。

> 刷机需要解锁 bootloader，并关闭 AVB 校验。产物没有经过任何安全审计，风险自负。

## 前置条件

| 项目 | 要求 |
| --- | --- |
| bootloader | 已解锁。`fastboot getvar unlocked` 返回 `yes` |
| 校验状态 | `ro.boot.verifiedbootstate=orange` |
| 分区布局 | 非 A/B，动态分区。`super` 物理大小 `0x200000000`（8 GiB），`misc` 为 `0x80000`（512 KiB） |
| Recovery | TWRP 3.7.1_12-0 或更高。动态分区操作需要 `bobotechnology/twrp_device_youxuepai_yxp_713_pad` 的 `61810b9` 及以后的提交，该提交修正了 `super` 大小 |
| 原厂固件包 | 形如 `P713mt6779_20221129_2216`，回滚时必需 |

**不要**刷入 `boot`、`dtbo`、`recovery`、`userdata`。本流程只替换 `super` 与 `vbmeta` 系列，内核、`dtbo` 与 `vendor` 保持不变。

## 需要哪些文件

### 方案一：用已有的 system 镜像

如果手上已有解压好的 system-as-root 镜像（例如上次构建留下的
`artifacts/local/<BuildName>/system_gsi.img`），直接打包：

```powershell
.\gsi\scripts\run-local-docker.ps1 `
  -Mode package `
  -SystemImage C:\path\to\system_gsi.img `
  -FirmwareDir C:\path\to\P713mt6779_20221129_2216 `
  -PackageName u90-gsi-package
```

`super` 需要和原厂 `product`、`vendor` 一起打，因此打包只能在本地执行。

### 方案二：完整本地构建后打包

```powershell
.\gsi\scripts\run-local-docker.ps1 `
  -FrontSensorOrientation 90 `
  -BuildName u90-a11-sourcefixed-v5

.\gsi\scripts\run-local-docker.ps1 `
  -Mode package `
  -BuildName u90-a11-sourcefixed-v5 `
  -PackageName u90-a11-sourcefixed-v5-package
```

两种方案的结果都在 `artifacts/local/<PackageName>/`，含：

| 文件 | 用途 |
| --- | --- |
| `super_u90_gsi.sparse.img` | 给 fastboot 或 SP Flash Tool 用。**不要 `dd`** |
| `super_u90_gsi.raw.img` | 8 GiB 原始镜像，**仅供 TWRP `dd`** |
| `vbmeta_u90_avb_disabled.img` | 只能刷到 `vbmeta` |
| `vbmeta_system_u90_avb_disabled.img` | 只能刷到 `vbmeta_system` |
| `vbmeta_vendor_u90_avb_disabled.img` | 只能刷到 `vbmeta_vendor` |
| `PACKAGE-MANIFEST.txt` | 输入与输出的哈希、AVB 信息、`lpdump` 输出 |
| `FLASH-PLAN.txt` | 需要写入的分区、偏移、不可变分区清单 |

三个 vbmeta 镜像各 4096 字节，由 `avbtool make_vbmeta_image --flags 3` 生成，签名算法为 `NONE`。`flags 3` 关闭 hashtree 与校验，**只能在已解锁的设备上使用**，且设备必须保持解锁。

## 刷入

### 完整刷入（首次）

设备进入 fastboot 后：

```bash
fastboot flash vbmeta         vbmeta_u90_avb_disabled.img
fastboot flash vbmeta_system  vbmeta_system_u90_avb_disabled.img
fastboot flash vbmeta_vendor  vbmeta_vendor_u90_avb_disabled.img
fastboot flash super          super_u90_gsi.sparse.img
fastboot reboot
```

`super` 是稀疏镜像，fastboot 会分块写入（实测 21 块，约 94 秒），期间不要拔线。

也可以用原厂 scatter 走 SP Flash Tool 的 **Download Only** 模式，要写的四行见 `FLASH-PLAN.txt`。

### 只更新 super（已实测的最小改动）

AVB 关闭的三件套只需刷一次，之后更新镜像只刷 `super` 即可：

```bash
fastboot flash super super_u90_gsi.sparse.img
fastboot reboot
```

2026-09-18 在真机上验证过这条路径：只刷 `super`、不清 `misc`，设备正常进入 Android 11。刷写前后 `misc` 逐字节相同，说明这条流程不会改写 BCB。

## 首次开机

首次启动约需数分钟。开机后：

```bash
adb shell getprop sys.boot_completed   # 期望 1
adb shell getprop ro.build.version.release  # 期望 11
```

前摄相关需要手动确认一次：设备的物理前摄是 **camera id 1**。

```bash
adb shell dumpsys media.camera | grep 'Camera ID'
```

马达位置可以独立读回：

```bash
adb shell cat /sys/devices/platform/noah_motor/motor_position
```

期望值：收起时为 `position_bottom`，前摄会话期间为 `position_selfie`。

中文输入法（Fcitx5）需要手动启用一次：**设置 > 系统 > 语言和输入法 > 屏幕键盘 > 管理屏幕键盘**，开启 Fcitx5，再从键盘切换器里选中它。

## 回滚到原厂

用原厂固件包里的镜像写回，`boot` 与 `dtbo` 不需要动（本流程从未改过它们）：

```bash
fastboot flash super   <stock-firmware-dir>/super.img
fastboot flash vbmeta         <stock-firmware-dir>/vbmeta.img
fastboot flash vbmeta_system  <stock-firmware-dir>/vbmeta_system.img
fastboot flash vbmeta_vendor  <stock-firmware-dir>/vbmeta_vendor.img
fastboot reboot
```

刷完先别急着开机，按下面的「刷后校验」确认一遍。

### 清理 misc

`misc` 里的 bootloader 命令如果非空（例如 `bootonce-bootloader`、`boot-fastboot`），设备会被引导进 fastboot 而不是 Android。**本流程不会改写它**，但如果校验脚本报告非空，在 TWRP 终端里只清前 4 KiB：

```sh
dd if=/dev/zero of=/dev/block/by-name/misc bs=4096 count=1
sync
```

## 刷后校验

在 TWRP 里采集一次只读状态：

```powershell
.\tools\collect-u90-recovery-state.ps1 -FullLogicalHashes
```

然后与打包目录比对：

```powershell
.\tools\verify-u90-recovery-state.ps1 `
  -RecoveryState C:\path\to\recovery-state.txt `
  -PackageDir .\artifacts\local\u90-gsi-package `
  -RequireDynamicPartitionProof
```

校验通过后再开机。若开机失败回到 fastboot，**不要先重刷**：回 TWRP 再采一次状态，用下面的脚本与刷写前的采集对比，先确定是 `misc` 被改写、AVB 状态变化，还是逻辑分区哈希不符。

```powershell
.\tools\compare-u90-boot-attempt.ps1 `
  -BeforeRecoveryState C:\path\to\before\recovery-state.txt `
  -AfterRecoveryState  C:\path\to\after\recovery-state.txt
```

## 禁止事项

- **不要用 `dd` 写 `super_u90_gsi.sparse.img`。** 它的开头是 Android 稀疏镜像头，不是 ext4。TWRP 要用 `dd` 只能写 8 GiB 的 `super_u90_gsi.raw.img`。
- **不要把三个 vbmeta 镜像刷错分区。** 文件名已经写明目标分区，一一对应。
- **不要在 fastboot 里刷 `boot`、`dtbo`、`recovery`、`userdata`，也不要刷原始 8 GiB 的 `super`。**
- **不要在设备重新锁定 bootloader 之后使用 `--flags 3` 的 vbmeta。**
- 每次只改一个变量。换镜像、改 `misc`、改 VBmeta 不要在同一次尝试里一起做，否则失败后无法归因。

## 实测状态

已验证：只刷 `super` 可正常开机；前摄（id 1）出图；前摄会话自动抬起马达、断开后收回；触屏可用；Fcitx5 可启用。

验证阶梯的逐级读数与内核逆向证据在 [u90-vendor-gate-and-motor-design.md](u90-vendor-gate-and-motor-design.md)，失败尝试与当时的归因在 [records/](records/) 下。
