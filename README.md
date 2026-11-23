# Luma88 — 狼途（LANGTU）T88 键盘 macOS 版驱动

仓库名 `t88-keyboard-macos`，产品名 `Luma88`（Luma = 灯光，88 = 88 键）。由两部分组成：

- `Luma88.app`：图形界面，双击即用，调灯效、改参数、画逐键颜色、看收发日志。
- `t88ctl`：命令行工具，可脚本化，也能发原始报文做排查。

两者共用同一套协议层 `src/T88Protocol.swift`，纯 Swift 实现，无内核扩展、无第三方依赖。面向 Intel Mac（macOS 15.7.7 / x86_64 实测）。

> **第三方、非官方实现**
>
> 本项目由个人独立编写，与狼途 / LANGTU 官方无隶属或合作关系，不以厂商名义分发，仓库内不含厂商的任何可执行文件或资源。协议参数由本机实测整理，仅供在自有设备上使用。

## 1. 功能

| 功能 | GUI | CLI |
| --- | --- | --- |
| 灯效模式 / 颜色 / 亮度 / 速度 / 方向 | 灯效页，实时预览载荷 | `t88ctl light set` |
| 关灯、恢复首次写入前的状态 | 灯效页 | `t88ctl light off` / `restore` |
| 设备参数（Fn 层、休眠、响应时间、轮询率、磁轴、Rapid Trigger） | 设备参数页 | `t88ctl settings` |
| 逐键灯效（点选按键上色、可落盘） | 逐键灯效页，88 键网格 | `t88ctl keys set` |
| 枚举、描述符、原始报文、输入监听 | 日志页显示状态 | `list` / `descriptor` / `send` / `monitor` |

不需要关闭 SIP、不安装 kext、不修改系统安全设置。

## 2. 两种连接方式

| | 2.4G 接收器 | 有线 USB |
| --- | --- | --- |
| 设备 | `T88-2.4G`，`05AC:024F` | `T88-USB`，`0C45:8006` |
| 配置接口 | Usage Page `0xFF60` / Usage `0x61`，64B Input/Output | Usage Page `0xFF13` / Usage `0x01`，64B Feature |
| 回读 | 只回固定确认帧，读不到状态 | 可回显并带回状态字节 |

**建议用有线调节**：2.4G 通道只做单向确认，写入是否被采纳无法回读；有线有真正的「写-读」闭环，日志里能看到 `04 18 00 01 …` 这样的回显。2.4G 下改灯效没反应，插 USB 数据线重试即可。

## 3. 编译与运行

依赖 Xcode Command Line Tools（自带 `swiftc`）与系统 `IOKit.framework`。

```sh
./scripts/build.sh          # CLI  → bin/t88ctl
./scripts/build-gui.sh      # GUI  → dist/Luma88.app
open dist/Luma88.app        # 打开图形界面
```

GUI 四个标签页：**灯效**（模式、颜色、亮度/速度/方向，右侧实时预览 64B 载荷，底部模式速查）、**设备参数**、**逐键灯效**（点按键上色，可仅应用或写入 EEPROM）、**关于·日志**。日志区显示发出的报文、回帧与状态码，`✓` 表示受理、`✗` 表示失败。

命令行常用：

```sh
./bin/t88ctl list                        # 列出 T88 的全部 HID 接口
./bin/t88ctl descriptor --idx 0          # 查看厂商通道的报告描述符

# 灯效（默认只应用、不写 EEPROM）
./bin/t88ctl light state                 # 显示记录的上次灯效
./bin/t88ctl light modes                 # 列出 1..20 模式
./bin/t88ctl light set --mode 1 --color FF0000 --brightness 3 --speed 3
./bin/t88ctl light brightness 5          # 只改亮度，其余沿用记录值
./bin/t88ctl light restore               # 恢复首次写入前的原状态

# 设备参数块
./bin/t88ctl settings show               # 显示记录值与将要发送的报文
./bin/t88ctl settings read               # 尝试回读（有线可看回显）
./bin/t88ctl settings set --fn-switch 1 --sleep 0 --respond 1 --tick 1 --tachyon 1 --continuous-rt 1

# 逐键灯效（04 20 应用 / 04 23 应用并落盘 / 04 F5 回读）
./bin/t88ctl keys set --color FF0000 --keys 0,3,5-10
./bin/t88ctl keys set --all --color 00FF00 --persist
./bin/t88ctl keys read

# 原始报文与监听
./bin/t88ctl send 04 18 00 00 ...        # 发一帧原始报文
./bin/t88ctl monitor --idx 0             # 监听设备 → 主机报文
```

报文布局、字段偏移、逐键数据块格式见 [docs/protocol.md](docs/protocol.md)；完整子命令见 `./bin/t88ctl`（无参数即打印用法）。

## 4. 签名与权限

- **本地编译运行**：`swiftc` 产物可直接运行，无需 Apple 开发者签名。
- **读取键盘类接口**（Usage Page `0x01`）会被 TCC 拦截，需在「系统设置 → 隐私与安全性 → 输入监控」给终端或 `.app` 授权；只访问厂商集合（`0xFF60` / `0xFF13`）实测不需要。遇 `0xE00002E2` / `0xE00002C1` 即权限问题。
- **对外分发**：需要 Developer ID `codesign` + notarization，否则 Gatekeeper 会拦住其他用户。

## 5. 状态与限制

- 键盘没有可用的「读回当前灯效 / 参数」命令，`light state`、`settings show` 显示的是上次写入的值；首次运行按默认值（模式 11 / 亮度 5 / 速度 3）。键盘上手动改过请先调回再用本工具。
- 写入前会在 `~/.config/t88ctl/light.orig.json` 备份原状态，`light restore` 可回滚。
- 逐键灯效与参数块的回读在有线通道尚未完全验证，`04 17` 读请求会返回未受理标记。
- 未实现：改键、宏、DKS、磁轴逐键行程、LCD / GIF、固件升级。这些功能需要分段上传结构化数据块，报文格式未验证，不做猜测性实现。

## 6. 目录结构

```
src/main.swift           CLI 入口、子命令实现、IOKit HID 通道
src/T88Protocol.swift    共享协议层：模式表、载荷构造、参数块、逐键数据块
gui/Luma88.swift         AppKit 界面（纯代码 UI）
gui/generated/           由 scripts/gen_keymap.py 生成的键位表（勿手改）
data/keymap.json         88 键坐标与灯位索引（改键位改这里）
scripts/build.sh         构建 CLI → bin/t88ctl
scripts/build-gui.sh     构建 GUI → dist/Luma88.app
docs/protocol.md         报文格式与字段布局
bin/t88ctl               编译产物（运行 scripts/build.sh 生成）
dist/Luma88.app          编译产物（运行 scripts/build-gui.sh 生成）
```

## 7. 排错

1. **找不到设备**：`./bin/t88ctl list` 看有没有 `0xFF13/0x01`（有线）或 `0xFF60/0x61`（2.4G）接口；换一根能传数据的 USB 线。
2. **发了命令没反应**：先看日志有没有回帧，有线通道 `[2]=01` 才算受理；受理了但键盘没变，先发一次 `04 18` 再重发，或拔插一次让固件重新进入配置态。
3. **2.4G 下灯效不生效**：接收器只确认不转发，改有线。
4. **权限报错**：按 §4 到「输入监控」授权后重启终端 / 重新打开 app。

## 8. 致谢

灯效模式的取值编码与开源项目 [iiaiiappa/lt104-keyboard-linux](https://github.com/iiaiiappa/lt104-keyboard-linux) 交叉核对过；其余参数均为本机实测整理。

## License

MIT，见 [LICENSE](LICENSE)。
