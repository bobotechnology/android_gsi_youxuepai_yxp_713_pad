# 拉取请求

## 这个改动做什么

<!-- 一两句话说清楚，以及它排除了哪种可能。 -->

## 改动类型

- [ ] 补丁（`gsi/patches/`）
- [ ] 构建脚本或配置（`gsi/scripts/`、`gsi/config/`、`gsi/templates/`）
- [ ] 工具（`gsi/tools/`、`tools/`）
- [ ] 文档
- [ ] 仓库元数据

## 验证

### 配方自检

```text
bash gsi/scripts/validate-recipe.sh
```

<!-- 贴输出。 -->

### 补丁可用性

改动了 `gsi/patches/` 的话贴这两条的结果：

```text
git -C <android-tree> apply --check --whitespace=error-all <patch>
git -C <android-tree> diff --check
```

### 设备读数

涉及真实设备行为的改动，必须给出**改动前**和**改动后**的读数：

```text
改动前：

改动后：
```

## 单变量确认

- [ ] 这个 PR 只改动了一个变量
- [ ] 若本次也改动了补丁，`gsi/config/u90-a11-v313.env` 里对应的 `*_REV` 已同步
- [ ] 若新增了补丁目录，`gsi/scripts/validate-recipe.sh` 的清单已更新

## 范围确认

- [ ] 这是 U90 / `yxp_713_pad` 相关的改动
- [ ] 没有引入多机型通用化
- [ ] 没有改动内核或 vendor 分区
- [ ] 没有提交固件包、构建产物、`.env`、设备序列号或本地绝对路径
