#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
mfd2json.py — 把 PC 侧 dump 出来的 MiFare Classic 镜像转成 App 能读的 CardDump JSON

为什么要这一步：
  iPhone 的 CoreNFC 拿不到 Classic 的 A/B key，只能读 0 扇区。完整 dump 必须
  在 PC 上用 PN532 / ACR122U / Proxmark 做（mfoc / proxmark hf mf autopwn），
  产出一个 .mfd / .bin 镜像。这个脚本把它翻译成 App 的卡片 JSON，
  手机端就能看全 16 个扇区、并且用 APDU 回放做本地模拟。

用法
  python3 mfd2json.py card.mfd -o cards/门禁卡.json --label "公司门禁" --uid 11223344
  python3 mfd2json.py card.mfd --print        # 只在终端打印

镜像格式
  .mfd = 1024 字节 (1K 卡) 或 4096 字节 (4K 卡)，按扇区顺序裸排：
    sector 0: block0(UID/BCC/SAK/ATQA) block1 block2 block3(keyA+AC+keyB)
    sector 1..15 同上；4K 卡在 sector 32 之后是 16 字节块
"""

import argparse
import json
import os
import sys
import uuid
from datetime import datetime, timezone

# MiFare Classic 1K: 16 扇区 × 4 块 × 16 字节 = 1024
# MiFare Classic 4K: 前 32 扇区 × 4 块 + 后 8 扇区 × 16 块 = 4096
SECTORS_1K = 16
BLOCK = 16


def parse_1k(data: bytes):
    """返回 [(sector, block_index_in_sector, bytes), ...]"""
    out = []
    for s in range(SECTORS_1K):
        for b in range(4):
            off = (s * 4 + b) * BLOCK
            out.append((s, b, data[off:off + BLOCK]))
    return out


def parse_4k(data: bytes):
    out = []
    # 前 32 扇区：每扇区 4 块
    for s in range(32):
        for b in range(4):
            off = (s * 4 + b) * BLOCK
            out.append((s, b, data[off:off + BLOCK]))
    # 后 8 扇区：每扇区 16 块
    base = 32 * 4 * BLOCK
    for s in range(32, 40):
        for b in range(16):
            off = base + ((s - 32) * 16 + b) * BLOCK
            out.append((s, b, data[off:off + BLOCK]))
    return out


def decode_sector_trailer(block: bytes):
    """扇区尾块：keyA(6) + access bits(4) + keyB(6)"""
    return {
        "keyA": block[:6].hex().upper(),
        "access": block[6:10].hex().upper(),
        "keyB": block[10:16].hex().upper(),
    }


def decode_block0(block: bytes):
    """厂商块：UID(4) BCC(1) SAK(1) ATQA(2) 厂商数据(8)"""
    return {
        "uid": block[:4].hex().upper(),
        "bcc": block[4:5].hex().upper(),
        "sak": block[5:6].hex().upper(),
        "atqa": block[6:8][::-1].hex().upper(),   # 小端 → 常规显示顺序
        "manufacturer": block[8:16].hex().upper(),
    }


def build_card(blocks, label, uid_override=None):
    pages = []
    sectors = {}
    block0 = None

    for s, b, raw in blocks:
        idx = s * 4 + b
        pages.append({
            "index": idx,
            "bytes": raw.hex().upper(),
            "locked": False,
        })
        if s == 0 and b == 0:
            block0 = decode_block0(raw)
        if b == 3:
            sectors[str(s)] = decode_sector_trailer(raw)

    uid = uid_override or (block0["uid"] if block0 else "")
    atqa = block0["atqa"] if block0 else "0004"
    sak = block0["sak"] if block0 else "08"

    # 从 block0 反推一条最小 APDU 记录，让 App 的模拟器有东西可回放
    transcript = []
    if uid:
        transcript.append({
            "request": "9320" + uid,           # PICC CL1 唤醒（示意）
            "response": "9000",
            "note": "由 mfd 镜像生成，非真实抓包",
        })

    return {
        "id": str(uuid.uuid4()),
        "createdAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "label": label,
        "kind": "iso14443A_MiFare",
        "uid": uid,
        "atqa": atqa,
        "sak": sak,
        "historicalBytes": "",
        "ats": "",
        "maxTransceiveLength": 0,
        "ndef": [],
        "ndefWritable": False,
        "pages": pages,
        "transcript": transcript,
        "sectorDump": sectors,
    }


def main():
    ap = argparse.ArgumentParser(description="MiFare Classic 镜像 → App 卡片 JSON")
    ap.add_argument("mfd", help=".mfd / .bin 镜像")
    ap.add_argument("-o", "--out", help="输出 JSON 路径")
    ap.add_argument("--label", default="", help="卡片显示名")
    ap.add_argument("--uid", help="覆盖 UID（hex）")
    ap.add_argument("--print", dest="show", action="store_true", help="打印到终端")
    a = ap.parse_args()

    data = open(a.mfd, "rb").read()
    size = len(data)
    print(f"· 镜像 {a.mfd}: {size} 字节")

    if size == 1024:
        blocks = parse_1k(data); print("  识别为 Classic 1K（16 扇区）")
    elif size == 4096:
        blocks = parse_4k(data); print("  识别为 Classic 4K（40 扇区）")
    elif size < 1024:
        print(f"✗ 镜像不足 1024 字节，可能是读失败的残包")
        return 1
    else:
        # 容忍尾部填充
        blocks = parse_1k(data[:1024]); print("  按 1K 解析（忽略尾部）")

    label = a.label or os.path.splitext(os.path.basename(a.mfd))[0]
    card = build_card(blocks, label, a.uid)

    print(f"  UID  {card['uid']}")
    print(f"  ATQA {card['atqa']}  SAK {card['sak']}")
    print(f"  扇区 {len(card['sectorDump'])}  块 {len(card['pages'])}")

    # key 全是 0 说明该扇区没读开（dump 时留空）
    dead = [s for s, t in card["sectorDump"].items()
            if t["keyA"] == "000000000000" and t["keyB"] == "000000000000"]
    if dead:
        print(f"  ⚠ 扇区 {','.join(sorted(dead, key=int))} 的 key 全 0 —— 当时没认证成功，数据不可信")

    if a.show or not a.out:
        print(json.dumps(card, ensure_ascii=False, indent=2)[:2000])

    if a.out:
        os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
        with open(a.out, "w", encoding="utf-8") as f:
            json.dump(card, f, ensure_ascii=False, indent=2)
        print(f"✓ {a.out}")
        print("  把文件放进 App 的 Documents/cards/ 即可（iTunes 文件共享或 Xcode Devices 拖入）")

    return 0


if __name__ == "__main__":
    sys.exit(main())
