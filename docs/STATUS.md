# 本机验证记录

2026-11-15（America/Denver）。验证环境：Windows 11 x64；尚未验证其他电脑。

## 任务栏图标

- 原因：WPF 窗口由 PowerShell 进程承载。替换窗口 Icon 和启动器内嵌图标后，任务栏仍可能按宿主进程分组。
- 修复：窗口显示前设置进程 AppUserModelID；窗口创建时设置独立 ID、重启命令与 Logo 图标；桌面快捷方式使用相同 ID。
- 结果：实际窗口读回 `Zhizhiniao.FrameFlow`，重启图标指向帧流 ICO；完整窗口与任务栏截图均看到橙色新 Logo。
- 原生检查入口：`tests/Brand.Check.ps1`。Microsoft 依据：[AppUserModelID](https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nf-shobjidl_core-setcurrentprocessexplicitappusermodelid)、[任务栏图标属性](https://learn.microsoft.com/en-us/windows/win32/properties/props-system-appusermodel-relaunchiconresource)。

## 自动更新

- 通过：语义版本比较、五种危险路径拒绝、清单校验、覆盖安装、用户额外文件保留、文件占用时回退、损坏包拒绝。
- 当前 0.3.1 完整界面运行正常；原视频库可见。正式 Release 上传与实网检查正在完成，不能把离线测试等同于完整升级通过。
- 0.2.x 不含更新器，需要手动换成包含更新器的版本一次；之后仅跟随正式 Release，离线时无法即时收到提示。

## 经验候选（未经确认）

- 行动：同时设置进程、窗口和快捷方式的应用身份；结果：本机任务栏新 Logo 可见。
- 原因：窗口图标与宿主进程任务栏身份属于不同层；验收：原生属性读回加实际任务栏截图。
- 反例：只看标题栏或 EXE 资源，就宣称任务栏已修复。边界：本机 Windows 11，其他电脑及旧固定项缓存尚未逐一测试。
