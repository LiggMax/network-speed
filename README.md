# NetSpeedStatus

一个面向 Dopamine rootless（iOS 15+）的 Theos tweak，在 SpringBoard 状态栏区域显示 Wi‑Fi 和蜂窝网络的实时上下行速度。

## 构建

需要在安装了 Theos 的 macOS/Linux 环境执行：

```sh
THEOS_PACKAGE_SCHEME=rootless make clean package
```

安装生成的 `packages/*.deb` 后重启 SpringBoard。
