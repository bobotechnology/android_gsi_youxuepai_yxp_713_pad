# 安全说明

## 本仓库包含什么

本仓库是构建配方：脚本、补丁、模板和文档。它**不包含**：

- 原厂固件包或任何分区的镜像
- 签名密钥、AVB 密钥或证书
- 设备的序列号或其他标识信息

脚本不会自动刷写设备。`package-u90-super.sh` 只读取原厂固件并生成打包产物；所有 `fastboot` / `dd` 命令都需要你手动执行。

## 刷机风险

刷入本配方构建的镜像需要**已解锁的 bootloader**，并且需要刷入三个 `--flags 3` 的 vbmeta 镜像来关闭 AVB 校验。这意味着：

- 设备的启动链校验被关闭。任何能写入 `super` 的东西都能被引导执行。
- 解锁 bootloader 通常会使保修失效，并可能清除 `userdata`。
- 本仓库的产物**没有**经过任何安全审计。它们是基于实测的移植工作，不是安全加固的发行版。

具体步骤与回滚方式见 [docs/FLASHING.md](docs/FLASHING.md)。

## 报告安全问题

请通过 GitHub 的[私有漏洞报告](https://github.com/bobotechnology/android_gsi_youxuepai_yxp_713_pad/security/advisories/new)提交，不要在公开 issue 里披露。

## 范围

由本仓库负责修复的：

- 配方脚本、补丁、模板自身的缺陷
- 脚本里的命令注入、路径处理、临时文件等问题
- 会导致刷入错误分区、错误镜像、清错数据的缺陷

不在本仓库范围内的：

- 原厂 `vendor` 分区二进制的漏洞
- 内核、bootloader（LK）或 TrustZone 的漏洞
- MediaTek 闭源组件的漏洞
- 已解锁 bootloader 本身带来的风险

后几类问题不由本仓库引入，也无法通过本仓库修复。请向设备厂商或组件上游报告。
