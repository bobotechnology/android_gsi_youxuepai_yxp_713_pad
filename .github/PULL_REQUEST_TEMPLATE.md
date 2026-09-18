# 拉取请求

## 这个改动做什么

<!-- 一两句话说清楚。 -->

## 验证

```text
bash gsi/scripts/validate-recipe.sh
```

<!-- 贴输出。 -->

改动了 `gsi/patches/` 的话，另外贴：

```text
git -C <android-tree> apply --check --whitespace=error-all <patch>
git -C <android-tree> diff --check
```

涉及真实设备行为的改动，给出改动前后的读数：

```text
改动前：

改动后：
```

## 确认

- [ ] 这个 PR 只改动了一个变量
- [ ] 改动了补丁时，`gsi/config/u90-a11-v313.env` 里对应的 `*_REV` 已同步
- [ ] 新增补丁目录时，`gsi/scripts/validate-recipe.sh` 的清单已更新
- [ ] 没有提交固件包、构建产物、`.env`、设备序列号或本地绝对路径
- [ ] 这是 U90 / `yxp_713_pad` 相关的改动，没有引入多机型通用化
