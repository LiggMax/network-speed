# NetSpeedStatus

一个面向 Dopamine rootless 的 Theos tweak，在 SpringBoard 原生状态栏层级中显示 Wi‑Fi 和蜂窝网络的实时上下行速度。

当前实现针对 iPadOS 18，Hook 原生状态栏布局，并将速度标签插入状态栏前景视图；不创建独立悬浮窗口。

由于使用 iOS 私有状态栏类，其他 iOS/iPadOS 版本需要单独验证。


## 构建

需要在安装了 Theos 的 macOS/Linux 环境执行：

```sh
THEOS_PACKAGE_SCHEME=rootless make clean package
```

安装生成的 `packages/*.deb` 后重启 SpringBoard。
