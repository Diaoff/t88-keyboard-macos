// Luma88 共享协议层
//
// 这份文件被两个目标一起编译：
//   · CLI  src/main.swift      → bin/t88ctl
//   · GUI  gui/Luma88.swift    → dist/Luma88.app
// 只放「命令字节、载荷布局、状态结构」这类纯数据定义，不放 IOKit 通道代码，
// 保证两边永远用同一套编码（灯效 / 参数块 / 逐键数据块）。
//
// 协议来源：本机实测整理，
// 细节见 docs/protocol.md。

import Foundation

// MARK: - 灯效模式表（官方 UI 顺序，取自 1028.lan 的模式名）

let kLightModes: [(Int, String)] = [
    (1, "静态恒亮"), (2, "单点亮"), (3, "单熄灭"), (4, "繁星点点"), (5, "漫天飞雪"),
    (6, "百花争艳"), (7, "动态呼吸"), (8, "光谱循环"), (9, "彩泉涌动"), (10, "多彩纵横"),
    (11, "随波逐流"), (12, "峰回路转"), (13, "一触即发"), (14, "一石二鸟"),
    (15, "涟漪扩散"), (16, "川流不息"), (17, "重峦叠嶂"), (18, "斜风细雨"), (19, "来回穿梭"),
    (20, "关闭背光"),
]

/// 只有这些模式吃自定义颜色，其余按多彩处理（载荷 [8] = colortype）
let kSingleColorModes: Set<Int> = [1, 2, 3, 4, 5, 7]

// MARK: - 灯效状态

struct LightState: Codable {
    var mode = 11          // config.xml: default_mode="11"
    var r = 0xFF, g = 0xFF, b = 0xFF
    var brightness = 5     // config.xml: default_brightness="5"，1...5
    var speed = 3          // config.xml: default_speed="3"，1...5
    var direction = 0      // 0...3

    static func modeName(_ m: Int) -> String {
        kLightModes.first { $0.0 == m }?.1 ?? "未知"
    }

    var isOff: Bool { mode == 20 || brightness == 0 }

    var summary: String {
        let color = String(format: "#%02X%02X%02X", r, g, b)
        let colorNote = kSingleColorModes.contains(mode) ? color : color + "（多彩模式，固件忽略自定义颜色）"
        return "模式 \(mode) \(LightState.modeName(mode))，颜色 \(colorNote)，亮度 \(brightness)/5，速度 \(speed)/5，方向 \(direction)"
    }
}

// MARK: - 灯效载荷（64 字节）
//
// [0]=mode（0x80 = 关灯） [1..3]=R,G,B [8]=colortype [9]=亮度 [10]=速度
// [11]=方向 [14..15]=AA 55。

func lightPayload(_ s: LightState) -> [UInt8] {
    var p = [UInt8](repeating: 0, count: 64)
    p[14] = 0xAA
    p[15] = 0x55
    if s.isOff {
        p[0] = 0x80
        p[10] = 5
        return p
    }
    p[0] = UInt8(s.mode & 0xFF)
    p[1] = UInt8(s.r)
    p[2] = UInt8(s.g)
    p[3] = UInt8(s.b)
    p[8] = kSingleColorModes.contains(s.mode) ? 0 : 1
    p[9] = UInt8(s.brightness)
    p[10] = UInt8(s.speed)
    p[11] = UInt8(s.direction & 0x03)
    return p
}

// MARK: - 设备参数块（00 01，64 字节）
//
// 字段偏移与含义见 docs/protocol.md §3.2。
// 写入序列：04 18 → 00 01 → 04 02（→ 04 F0 落盘）。

struct DeviceSettings: Codable {
    var fnSwitch = 1        // [5]  fn_switch
    var sleepTime = 0       // [6]  sleep_time
    var respondTime = 1     // [8]  key_respondtime
    var tickRate = 1        // [12] tick_rate
    var tachyonMode = 1     // [13] perf_tachyon_mode
    var continuousRT = 1    // [14] perf_continuerapidtrigger_mode
    // [2][3][4] 由 GetCheck_CCheckButton 直接写入（!=0 → 1），是三个复选框开关
    var checkA = 1          // [2]
    var checkB = 1          // [3]
    var checkC = 1          // [4]

    var packet: [UInt8] {
        var p = [UInt8](repeating: 0, count: 64)
        p[0] = 0x00; p[1] = 0x01
        p[2] = UInt8(checkA & 0xFF)
        p[3] = UInt8(checkB & 0xFF)
        p[4] = UInt8(checkC & 0xFF)
        p[5] = UInt8(fnSwitch & 0xFF)
        p[6] = UInt8(sleepTime & 0xFF)
        p[8] = UInt8(respondTime & 0xFF)
        p[12] = UInt8(tickRate & 0xFF)
        p[13] = UInt8(tachyonMode & 0xFF)
        p[14] = UInt8(continuousRT & 0xFF)
        p[62] = 0xAA; p[63] = 0x55
        return p
    }

    var summary: String {
        "fn_switch=\(fnSwitch) sleep_time=\(sleepTime) key_respondtime=\(respondTime) "
            + "tick_rate=\(tickRate) perf_tachyon=\(tachyonMode) continuous_rt=\(continuousRT) "
            + "check=\(checkA)/\(checkB)/\(checkC)"
    }
}

// MARK: - 逐键灯效数据块
//
// 头部帧 [8] 选择布局：8 = 128 键（512 B），9 = 144 键（576 B），3 = 单色（192 B，未用）。
// 每条记录 4 字节：{键序号, R, G, B}；未指定的键保持 0（熄灭）。
// 数据块布局见 docs/protocol.md §3.3。

let kKeyLayouts: [Int: (blockLen: Int, header: UInt8)] = [
    128: (512, 8),
    144: (576, 9),
]

/// 用 light_index（1 起）集合构造逐键数据块；槽位按 0 基（light_index - 1）【推断】。
func keyColorBlock(indexes: Set<Int>, layout: Int, color: (UInt8, UInt8, UInt8)) -> [UInt8] {
    let blockLen = kKeyLayouts[layout]?.blockLen ?? 512
    var block = [UInt8](repeating: 0, count: blockLen)
    for li in indexes {
        let slot = li - 1
        guard slot >= 0 && slot < blockLen / 4 else { continue }
        block[slot * 4] = UInt8(slot & 0xFF)
        block[slot * 4 + 1] = color.0
        block[slot * 4 + 2] = color.1
        block[slot * 4 + 3] = color.2
    }
    return block
}
