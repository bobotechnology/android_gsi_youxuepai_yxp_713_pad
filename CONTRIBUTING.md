# 贡献指南

## 范围

本仓库只服务**优学派 U90（`yxp_713_pad`，MT6779）**这一个机型。

这不是一个通用 GSI 构建框架，也不打算变成通用框架。把机型专属内容抽象成配置项、加多机型支持矩阵、让其他设备也能用 —— 这些**不在**本仓库的范围内。针对其他机型的改动会被拒绝，因为本仓库里几乎每一条取值（分区几何、相机 id、马达协议、bootprof 闸门）都是在这台机器上实测出来的，脱离这台机器就没有证据支撑。

明确不在范围内：

- root 方案（Magisk / SuperSU / `phh-su`）的集成
- 内核与 vendor 分区的修改
- 其他机型的适配
- 把本仓库改造成通用构建框架

## 报告问题

请使用仓库的 [Issue 模板](https://github.com/bobotechnology/android_gsi_youxuepai_yxp_713_pad/issues/new/choose)。缺少现场信息的问题无法定位，会被要求补充。

必须附上：

| 项目 | 怎么取 |
| --- | --- |
| 设备与固件版本 | 设备型号，以及原厂固件包名（形如 `P713mt6779_20221129_2216`） |
| 镜像来源 | 本地构建的 `-BuildName`，以及该 `system` 镜像的 SHA-256 |
| 相机枚举 | `adb shell dumpsys media.camera` |
| 马达位置 | `adb shell cat /sys/devices/platform/noah_motor/motor_position` |
| 日志 | `adb logcat -G 16M` 之后再复现，然后抓全量 logcat |

`logcat -G 16M` 不是可选项。默认缓冲区只有 256 KiB，相机预览几秒就会刷满并挤掉关键行，`U90 front camera lift` 这类记录会直接丢失，导致问题无法复现。

若问题与开机、fastboot 或 AVB 有关，另外附上：

```powershell
.\tools\collect-u90-recovery-state.ps1 -FullLogicalHashes
```

## 提交改动

### 硬性门槛

1. `bash gsi/scripts/validate-recipe.sh` 必须通过。本地每次构建都会先跑它，PR 里请贴出它的输出。
2. 补丁必须干净可用：

   ```bash
   git -C <android-tree> apply --check --whitespace=error-all <patch>
   git -C <android-tree> diff --check
   ```

3. 补丁命名遵守 `gsi/patches/<android-tree>/NNNN-u90-<描述>.patch`，四位序号，`<android-tree>` 用仓库里已有的写法（`frameworks-av`、`frameworks-base`、`frameworks-native`、`system-core`、`device-phh-treble`、`packages-apps-launcher3`、`packages-modules-networkstack`）。
4. 改了补丁就要同步 `gsi/config/u90-a11-v313.env` 里对应的 `*_REV`，以及 `gsi/scripts/apply-u90-patches.sh` 里的 revision 断言。

### 单变量原则

本仓库的历史是这么写出来的：一次只改一个变量，刷进去，读到前后读数，再改下一个。请沿用。

涉及真实设备行为的改动，请在 PR 里给出**改动前**和**改动后**的读数，例如：

```text
position_before_open  = position_bottom
position_after_open   = position_selfie
position_after_close  = position_bottom
```

只给"现在能用了"的结论、不给读数的 PR 无法复核，会被要求补充。

### 提交信息

用英文，格式 `type: subject`，`type` 取 `feat` / `fix` / `docs` / `build` / `refactor`。正文说明**为什么**，以及这个改动排除了哪种可能。

### 不要提交

- 原厂固件包与任何构建产物（`artifacts/`、`output/`、`android/`、`manifest/` 已被 gitignore）
- `.env`（本地代理配置）
- 设备序列号、USB 序列号
- 带用户名的本地绝对路径（用 `<repo>`、`<stock-firmware-dir>` 这类占位符）

## 校验脚本

```bash
bash gsi/scripts/validate-recipe.sh          # 配方自检，几秒钟
bash gsi/scripts/apply-u90-patches.sh <dir>  # 对已同步的源码树应用补丁
```

本仓库没有在线 CI，所有校验与构建都在本地跑。构建只产出 `system`，`super` 必须单独打包（需要原厂 `product` 与 `vendor`）。脚本不会自动刷写任何设备。
