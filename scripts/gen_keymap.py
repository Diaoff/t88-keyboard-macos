#!/usr/bin/env python3
"""从 data/keymap.json 生成 GUI 用的键位表（纯标准库）。

输出 gui/generated/KeyLayout.swift：
    let kKeyboardWidth / kKeyboardHeight   键位画布尺寸
    struct KeyCap { name, lightIndex, x, y, w, h }
    let kKeyCaps: [KeyCap]

data/keymap.json 是 88 键的坐标与灯位索引，纯数值 + 键名，改键位时直接改它。
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "data/keymap.json"
OUT = ROOT / "gui/generated/KeyLayout.swift"


def main():
    data = json.loads(SRC.read_text(encoding="utf-8"))
    width = int(data.get("canvas", {}).get("width") or 895)
    height = int(data.get("canvas", {}).get("height") or 310)
    keys = sorted(data["keys"], key=lambda k: k["light_index"])

    lines = [
        "// 由 scripts/gen_keymap.py 从 data/keymap.json 生成，勿手改。",
        "import Foundation",
        "",
        "let kKeyboardWidth = %d" % width,
        "let kKeyboardHeight = %d" % height,
        "",
        "struct KeyCap {",
        "    let name: String",
        "    let lightIndex: Int",
        "    let x: Int",
        "    let y: Int",
        "    let w: Int",
        "    let h: Int",
        "}",
        "",
        "let kKeyCaps: [KeyCap] = [",
    ]
    for k in keys:
        name = str(k.get("name") or "?")
        safe = name.replace("\\", "\\\\").replace('"', '\\"')
        lines.append(
            '    KeyCap(name: "%s", lightIndex: %d, x: %d, y: %d, w: %d, h: %d),'
            % (safe, k["light_index"], k["x"], k["y"], k["w"], k["h"])
        )
    lines.append("]")
    lines.append("")

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("\n".join(lines), encoding="utf-8")
    print("生成 %s：%d 个键，画布 %dx%d" % (OUT.relative_to(ROOT), len(keys), width, height))


if __name__ == "__main__":
    sys.exit(main())
