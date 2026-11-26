#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ntag_build.py — 构造 NTAG21x 页镜像 + 生成写入脚本

用途：
  把一段文本/URL 做成 NTAG213/215/216 的完整页镜像（含 NDEF TLV、能力容器、
  可选密码保护），并输出：
    1. pages.txt   —— 页号 + 4 字节 hex，逐行，供 App「写页」或 nfcpy 使用
    2. ndef.bin    —— 纯 NDEF TLV 字节流
    3. 一份 pn532 写入命令序列（可选）

用法
  python3 ntag_build.py --text "https://example.com" --chip 213 -o out/
  python3 ntag_build.py --text "hello" --chip 215 --pwd 11223344 --pack AABB -o out/
  python3 ntag_build.py --read pages_from_dump.txt -o out/    # 从 dump 反推文本
"""

import argparse
import os
import sys

# NTAG21x 的配置页在**内存末尾**，不在中间：
#   213 (45 页)  用户区 4–39   锁位 40   CFG 41–42   PWD 43   PACK/AUTH0/ACCESS 44
#   215 (135 页) 用户区 4–129  锁位 130  CFG 131–132 PWD 133  PACK/AUTH0/ACCESS 134
#   216 (231 页) 用户区 4–225  锁位 226  CFG 227–228 PWD 229  PACK/AUTH0/ACCESS 230
CHIPS = {
    "213": {"pages": 45,  "user_start": 4, "user_end": 39,  "user_bytes": 144,
            "pwd_page": 43, "pack_page": 44, "lock_page": 40},
    "215": {"pages": 135, "user_start": 4, "user_end": 129, "user_bytes": 504,
            "pwd_page": 133, "pack_page": 134, "lock_page": 130},
    "216": {"pages": 231, "user_start": 4, "user_end": 225, "user_bytes": 888,
            "pwd_page": 229, "pack_page": 230, "lock_page": 226},
}

# 出厂默认（未做 NDEF 格式化）的 capability container
CC_ORIGINAL = bytes.fromhex("E1101200")     # 144 字节，读/写 0x00
CC_NDEF_213  = bytes.fromhex("E1101200")
CC_NDEF_215  = bytes.fromhex("E1103E00")
CC_NDEF_216  = bytes.fromhex("E1106D00")


def build_ndef_text(text: str, lang: str = "en") -> bytes:
    """构造一条 Well-Known Text 记录的 NDEF 消息（含 TLV 包装）"""
    lang_bytes = lang.encode("ascii")[:63]
    payload = bytes([len(lang_bytes)]) + lang_bytes + text.encode("utf-8")

    # NDEF record header: MB|ME|SR|TNF=1(well-known)
    header = 0xD1
    type_field = b"T"
    record = bytes([header, len(type_field), len(payload)]) + type_field + payload
    # 简化：payload < 256，单字节长度即可

    # TLV: 0x03 len message, 0xFE terminator
    tlv = bytes([0x03, len(record)]) + record + bytes([0xFE])
    # 补齐到 4 字节边界（NTAG 页对齐）
    if len(tlv) % 4:
        tlv += b"\x00" * (4 - len(tlv) % 4)
    return tlv


def build_ndef_uri(url: str) -> bytes:
    """URI 记录，用 0x04 前缀压缩 http(s)://"""
    prefixes = {
        "http://www.": 0x01, "https://www.": 0x02, "http://": 0x03,
        "https://": 0x04, "tel:": 0x05, "mailto:": 0x06,
    }
    code, rest = 0x00, url
    for p, c in prefixes.items():
        if url.startswith(p):
            code, rest = c, url[len(p):]
            break
    payload = bytes([code]) + rest.encode("utf-8")
    record = bytes([0xD1, 0x01, len(payload)]) + b"U" + payload
    tlv = bytes([0x03, len(record)]) + record + bytes([0xFE])
    if len(tlv) % 4:
        tlv += b"\x00" * (4 - len(tlv) % 4)
    return tlv


def pages_from_bytes(data: bytes, chip: str, cc: bytes):
    """把用户区字节切成 4 字节页，页 4 开始"""
    info = CHIPS[chip]
    pages = {}

    # page 0-1: UID（出厂值，写入时由芯片决定，这里留 0）
    pages[0] = bytes(4)
    pages[1] = bytes(4)
    pages[2] = bytes.fromhex("00000000")      # lock bytes
    pages[3] = cc                              # capability container

    limit = info["user_end"] - info["user_start"] + 1
    for i in range(limit):
        off = i * 4
        chunk = data[off:off + 4]
        if len(chunk) < 4:
            chunk = chunk + bytes(4 - len(chunk))
        pages[info["user_start"] + i] = chunk

    return pages


def parse_pages_file(path: str):
    """读 pages.txt：每行 `页号  AABBCCDD` 或 `AABBCCDD`"""
    out = {}
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.replace(":", " ").replace("=", " ").split()
        if len(parts) >= 2:
            idx, hx = int(parts[0], 0), parts[1]
        else:
            idx, hx = len(out), parts[0]
        hx = hx.replace("0x", "")
        if len(hx) != 8:
            continue
        out[idx] = bytes.fromhex(hx)
    return out


def extract_text(pages: dict, chip: str) -> str:
    """从页镜像里把 NDEF TLV 抽出来，还原文本"""
    info = CHIPS[chip]
    raw = b"".join(pages.get(p, bytes(4)) for p in range(info["user_start"], info["user_end"] + 1))

    i = 0
    while i < len(raw):
        t = raw[i]
        if t == 0x00: i += 1; continue
        if t == 0xFE: break
        if i + 1 >= len(raw): break
        ln = raw[i + 1]
        if ln == 0xFF:                      # 3 字节长度
            if i + 3 >= len(raw): break
            ln = (raw[i + 2] << 8) | raw[i + 3]
            body = raw[i + 4:i + 4 + ln]
            i += 4 + ln
        else:
            body = raw[i + 2:i + 2 + ln]
            i += 2 + ln
        if t != 0x03 or len(body) < 3:
            continue
        tnf = body[0]
        tlen = body[1]
        plen = body[2]
        rtype = body[3:3 + tlen]
        payload = body[3 + tlen:3 + tlen + plen]
        if rtype == b"T" and payload:
            lang_len = payload[0]
            return payload[1 + lang_len:].decode("utf-8", errors="replace")
        if rtype == b"U" and payload:
            codes = {0x01: "http://www.", 0x02: "https://www.", 0x03: "http://",
                     0x04: "https://", 0x05: "tel:", 0x06: "mailto:"}
            prefix = codes.get(payload[0], "")
            return prefix + payload[1:].decode("utf-8", errors="replace")
    return ""


def main():
    ap = argparse.ArgumentParser(description="NTAG21x 页镜像构造 / 解析")
    ap.add_argument("--text", help="要写入的文本")
    ap.add_argument("--uri", action="store_true", help="按 URI 记录编码（http/https 会压缩）")
    ap.add_argument("--chip", default="213", choices=list(CHIPS), help="芯片型号")
    ap.add_argument("--read", help="从 pages.txt 反解文本")
    ap.add_argument("--pwd", help="设置读保护密码（8 hex），仅 NTAG21x")
    ap.add_argument("--pack", help="PACK 应答（4 hex）")
    ap.add_argument("-o", "--outdir", default="out")
    a = ap.parse_args()

    os.makedirs(a.outdir, exist_ok=True)
    info = CHIPS[a.chip]

    # ── 反解模式 ──────────────────────────────────────────
    if a.read:
        pages = parse_pages_file(a.read)
        print(f"· 读到 {len(pages)} 页")
        text = extract_text(pages, a.chip)
        print(f"  NDEF 文本: {text!r}" if text else "  没找到 NDEF 文本记录")
        if a.pwd:
            pp = info["pack_page"]
            print(f"  page {pp} (PACK/AUTH0/ACCESS): {pages.get(pp, b'').hex().upper()}")
        return 0 if text else 1

    if not a.text:
        ap.error("需要 --text 或 --read")

    # ── 构造模式 ──────────────────────────────────────────
    ndef = build_ndef_uri(a.text) if a.uri else build_ndef_text(a.text)
    print(f"· NDEF TLV: {len(ndef)} 字节")
    if len(ndef) > info["user_bytes"]:
        print(f"✗ 超出 {a.chip} 容量 ({len(ndef)} > {info['user_bytes']})")
        return 1

    cc = {"213": CC_NDEF_213, "215": CC_NDEF_215, "216": CC_NDEF_216}[a.chip]
    pages = pages_from_bytes(ndef, a.chip, cc)

    # 密码保护：AUTH0 = 起始受保护页，ACCESS = 读写权限
    if a.pwd:
        pwd = bytes.fromhex(a.pwd)
        pack = bytes.fromhex(a.pack or "0000")
        if len(pwd) != 4 or len(pack) != 2:
            print("✗ --pwd 要 4 字节 hex，--pack 要 2 字节 hex")
            return 1
        # PWD 页 + PACK/AUTH0/ACCESS 页，位置随机型不同
        auth0 = info["user_start"]        # 从用户区第一页开始要认证
        pages[info["pwd_page"]] = pwd
        pages[info["pack_page"]] = pack + bytes([auth0, 0x00])
        print(f"  ⚠ 密码保护写入 page {info['pwd_page']}/{info['pack_page']}"
              f"（AUTH0={auth0}）。写错这两页会锁死标签。")

    # 输出
    lines = ["# 页号 4字节hex    (pages.txt，可直接给 App 或 nfcpy)"]
    for idx in sorted(pages):
        lines.append(f"{idx:3d}  {pages[idx].hex().upper()}")
    pages_path = os.path.join(a.outdir, "pages.txt")
    open(pages_path, "w", encoding="utf-8").write("\n".join(lines) + "\n")
    print(f"✓ {pages_path}  ({len(pages)} 页)")

    ndef_path = os.path.join(a.outdir, "ndef.bin")
    open(ndef_path, "wb").write(ndef)
    print(f"✓ {ndef_path}  ({len(ndef)} 字节)")

    # nfcpy 写入脚本
    py = f'''#!/usr/bin/env python3
# 自动生成：nfcpy 写 NTAG{a.chip}（需 ACR122U/PN532 + pip install nfcpy）
import nfc
import nfc.tag.tt2
from nfc.tag.tt2 import Type2Tag

PAGES = {{
{chr(10).join(f"    {i}: bytes.fromhex('{pages[i].hex().upper()}')," for i in sorted(pages) if i >= info['user_start'])}
}}

def on_connect(tag):
    if not isinstance(tag, Type2Tag):
        print("不是 Type2 标签"); return False
    for idx, data in PAGES.items():
        tag.write(idx, data)
        print(f"page {{idx}} <- {{data.hex().upper()}}")
    print("完成")
    return False

with nfc.ContactlessFrontend('usb') as clf:
    clf.connect(rdwr={{'on-connect': on_connect}})
'''
    py_path = os.path.join(a.outdir, "write_nfcpy.py")
    open(py_path, "w", encoding="utf-8").write(py)
    print(f"✓ {py_path}")

    print()
    print("下一步：")
    print(f"  手机：把 pages.txt 丢进 App → 卡片详情 → 写页")
    print(f"  PC ：python3 {py_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
