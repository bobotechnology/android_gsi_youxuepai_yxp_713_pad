# 贡献指南

## 范围

本仓库只服务优学派 U90（`yxp_713_pad`，MT6779）。这里几乎每一条取值——分区几何、相机 id、马达协议、bootprof 闸门——都是在这台机器上实测出来的，脱离这台机器就没有依据。

以下方向的改动会被拒绝：多机型适配、把仓库改造成通用构建框架、集成 root 方案、修改内核或 vendor 分区。

## 提交改动

1. `bash gsi/scripts/validate-recipe.sh` 必须通过。本地每次构建都会先跑它。
2. 补丁要干净可用：`git -C <android-tree> apply --check --whitespace=error-all <patch>` 通过，且 `git -C <android-tree> diff --check` 无输出。
3. 补丁命名 `gsi/patches/<tree>/NNNN-u90-<描述>.patch`，`<tree>` 沿用已有写法（`frameworks-av`、`frameworks-base`、`frameworks-native`、`system-core`、`device-phh-treble`、`packages-apps-launcher3`、`packages-modules-networkstack`）。
4. 改了补丁要同步 `gsi/config/u90-a11-v313.env` 里对应的 `*_REV`，以及 `gsi/scripts/apply-u90-patches.sh` 里的 revision 断言。
5. 新增补丁目录要更新 `validate-recipe.sh` 里的清单。

一次只改一个变量：刷进去，读前后读数，再改下一个。涉及真实设备行为的改动要给出改动前后的读数，例如：

```text
position_before_open  = position_bottom
position_after_open   = position_selfie
position_after_close  = position_bottom
```

只给「现在能用了」的结论无法复核。

提交信息用英文，格式 `type: subject`，`type` 取 `feat` / `fix` / `docs` / `build` / `refactor`。

## 不要提交

- 原厂固件包与构建产物（`artifacts/`、`output/`、`android/`、`manifest/` 已 gitignore）
- `.env`
- 设备序列号
- 带用户名的本地绝对路径

## 报告问题

用仓库的 issue 模板。缺现场信息的问题无法定位。抓日志前先 `adb logcat -G 16M`：默认缓冲区只有 256 KiB，相机预览几秒就能刷满并挤掉 `U90 front camera lift` 这类关键行。
