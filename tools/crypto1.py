#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
crypto1.py — MiFare Classic 密钥工作流编排

先说清楚边界，这决定了本工具做什么、不做什么：

  Crypto1 是 NXP 的专有流密码（48-bit LFSR + 20-bit 非线性滤波器）。
  「给定一次认证抓包反推 48-bit key」需要精确复现滤波器的布尔函数和卡端的
  suc(nt, nr) 应答函数。这两处只要有一位偏差，解出来的 key 就是错的，而且
  错得很像真的 —— 所以这里**不自己实现密码学**，改用经过大量实卡验证的
  C 实现：proxmark3 的 mfkey32v2 / mfoc。

  本文件负责它前面的和后面的活：
    · 管理密钥表（去重、格式校验、默认 key 表）
    · 从 .mfd 镜像里把扇区尾块提取出来，检查哪些扇区真的解开了
    · 把嗅探日志整理成 mfkey32v2 能吃的格式
    · 生成完整的恢复命令序列（proxmark3 / ACR122U 两条路线）

用法
  python3 crypto1.py keys --wordlist keys.txt              # 规范化密钥表
  python3 crypto1.py check --mfd card.mfd                  # 检查 dump 是否完整
  python3 crypto1.py trace --sniff log.txt -o trace.txt    # 整理嗅探日志
  python3 crypto1.py plan --card 门禁卡                     # 输出恢复命令序列
"""

import argparse
import os
import sys

# 常见默认密钥。门禁系统出厂不换 key 的比例很高，先试这些能省大量时间。
DEFAULT_KEYS = [
    "FFFFFFFFFFFF",   # 出厂默认
    "A0A1A2A3A4A5",   # NXP 示例 / 大量国产门禁
    "000000000000",   # 全 0
    "D3F7D3F7D3F7",   # MAD key
    "B0B1B2B3B4B5",   # NFC Forum
    "4D3A99C351DD",   # 常见物业系统
    "1A982C7E459A",   # 常见物业系统
    "AABBCCDDEEFF",   # 通用测试
    "714C5C886E97",
    "587EE5F9350F",
    "A0478CC39091",
    "533CB6C723F6",
    "8FD0A4F256E9",
    "0000014B5C31",
    "B7BF5F0F9A37",
    "5C8FF9990DA2",
    "A64598A77478",
    "26940B21FF5D",
    "FC00018778F7",
    "5C598CB0CAC0",
    "E4D2770A89BE",
    "F9B7E7A5B0A0",
]


# ────────────────────────────────────────────────────────────────
# 密钥表
# ────────────────────────────────────────────────────────────────

def normalize_key(raw: str):
    """返回 12 位大写 hex，或 None"""
    h = raw.strip().replace(" ", "").replace("0x", "").replace("0X", "").upper()
    if len(h) != 12:
        return None
    try:
        int(h, 16)
    except ValueError:
        return None
    return h


def cmd_keys(a):
    seen, out, bad = set(), [], 0
    for lineno, line in enumerate(open(a.wordlist, encoding="utf-8", errors="ignore"), 1):
        if not line.strip() or line.strip().startswith("#"):
            continue
        h = normalize_key(line)
        if h is None:
            print(f"  第 {lineno} 行格式不对: {line.strip()}", file=sys.stderr)
            bad += 1
            continue
        if h in seen:
            continue
        seen.add(h)
        out.append(h)

    print(f"· 有效 {len(out)} 把，跳过 {bad} 行")
    for h in out[:20]:
        print(f"  {h}")
    if len(out) > 20:
        print(f"  … 还有 {len(out) - 20} 把")

    if a.out:
        with open(a.out, "w", encoding="utf-8") as f:
            f.write("\n".join(out) + "\n")
        print(f"✓ 写入 {a.out}")
    return 0 if out else 2


def cmd_defaults(a):
    print(f"· 内置默认密钥 {len(DEFAULT_KEYS)} 把")
    for h in DEFAULT_KEYS:
        print(f"  {h}")
    if a.out:
        with open(a.out, "w", encoding="utf-8") as f:
            f.write("\n".join(DEFAULT_KEYS) + "\n")
        print(f"✓ 写入 {a.out}")
    return 0


# ────────────────────────────────────────────────────────────────
# .mfd 完整性检查
# ────────────────────────────────────────────────────────────────

def cmd_check(a):
    """
    检查一个 .mfd 是否真的 dump 成功。

    判据：扇区尾块是 keyA(6) + 访问位(4) + keyB(6)。dump 工具读不开某个扇区时，
    通常留全 0 或全 FF —— 那不是"密钥是 0"，是"没读到"。
    区分方法：真实 key 全 0 的卡存在，但同一张卡上 16 个扇区全部恰好是
    全 0 或全 FF 的概率极低；而且访问位通常不是 0xFF078069 之外的固定值。
    """
    data = open(a.mfd, "rb").read()
    size = len(data)
    print(f"· {a.mfd}: {size} 字节")

    if size == 1024:
        sectors, blocks_per = 16, 4
        print("  型号：Classic 1K")
    elif size == 4096:
        sectors, blocks_per = 40, 4
        print("  型号：Classic 4K（按 1K 布局检查前 16 扇区）")
        sectors = 16
    elif size >= 1024:
        sectors, blocks_per = 16, 4
        print(f"  按 1K 解析（忽略尾部 {size - 1024} 字节）")
    else:
        print("✗ 不足 1024 字节，dump 不完整", file=sys.stderr)
        return 1

    intact, blank, factory, unknown = 0, 0, 0, 0
    rows = []
    for s in range(sectors):
        off = (s * blocks_per + 3) * 16
        trailer = data[off:off + 16]
        key_a = trailer[:6].hex().upper()
        access = trailer[6:10].hex().upper()
        key_b = trailer[10:16].hex().upper()

        # 数据块（本扇区前 3 块，跳过厂商块 0）
        data_blocks = []
        for b in range(blocks_per - 1):
            boff = (s * blocks_per + b) * 16
            data_blocks.append(data[boff:boff + 16])

        has_data = any(
            any(byte not in (0x00, 0xFF) for byte in blk)
            for blk in data_blocks
        )

        if key_a == "000000000000" and key_b == "000000000000":
            # 尾块 16 字节全 0 不可能是合法扇区尾（keyA 全 0 + 访问位全 0 + keyB 全 0
            # 意味着该扇区不可读也不可写）。dump 工具读失败时就是这样留空的。
            state, blank = "✗ 未读开（尾块全 0）", blank + 1
        elif key_a == "FFFFFFFFFFFF" and key_b == "FFFFFFFFFFFF" and access == "FF078069":
            # 出厂默认 key + 标准访问位，这是**真实存在**的常见状态
            if has_data:
                state, factory = "✓ 出厂默认 key（数据已读）", factory + 1
            else:
                state, factory = "✓ 出厂默认 key（扇区为空）", factory + 1
        elif key_a == "FFFFFFFFFFFF" and key_b == "FFFFFFFFFFFF" and not has_data:
            state, unknown = "? 尾块全 FF 且无数据，可能没读开", unknown + 1
        else:
            state, intact = "✓ 已解开", intact + 1

        rows.append((s, key_a, access, key_b, state))

    for s, ka, ac, kb, state in rows:
        print(f"  扇区 {s:2d}  A={ka}  AC={ac}  B={kb}  {state}")

    good = intact + factory
    print()
    print(f"  可用 {good} / {sectors}（自定 key {intact}，出厂默认 {factory}）")
    if blank or unknown:
        print(f"  ✗ 未读开 {blank + unknown}")
    print()
    if good == sectors:
        print("✓ dump 完整，所有扇区都读到了")
        return 0
    print("⚠ 有扇区没读开，那些扇区的数据不可信。")
    print("  先跑 key 恢复（crypto1.py plan）再重新 dump。")
    return 2


# ────────────────────────────────────────────────────────────────
# 嗅探日志整理 → mfkey32v2 输入
# ────────────────────────────────────────────────────────────────

def cmd_trace(a):
    """
    整理成 mfkey32v2 输入：每行 `UID NT NR_enc AR_enc`（8 位 hex × 4）。

    ⚠ 这一步只做格式整理，不做语义猜测。
    原始嗅探日志里 32-bit 块的出现顺序并不能直接映射成 UID/NT/NR/AR ——
    防冲突阶段 UID 会重复出现，加密帧和明文帧混在一起。硬按顺序四分组
    会喂给 mfkey32v2 错误数据，解出的 key 是错的但看起来像真的。

    所以只接受**已经标注好**的输入，两种格式：
      1) proxmark3 `hf mf darkside` / `nested` 的 key 候选行：
             uid=11223344 nt=A1B2C3D4 nr=5E6F7A8B ar=9C0D1E2F
      2) 已经是四元组的行：
             11223344 A1B2C3D4 5E6F7A8B 9C0D1E2F
    其余一律跳过并计数，最后报告有多少行无法识别。
    """
    import re

    kv = re.compile(
        r"uid\s*[=:]\s*([0-9A-Fa-f]{8}).*?"
        r"nt\s*[=:]\s*([0-9A-Fa-f]{8}).*?"
        r"nr\s*[=:]\s*([0-9A-Fa-f]{8}).*?"
        r"ar\s*[=:]\s*([0-9A-Fa-f]{8})", re.I)
    quad = re.compile(
        r"^\s*([0-9A-Fa-f]{8})[\s,]+([0-9A-Fa-f]{8})[\s,]+"
        r"([0-9A-Fa-f]{8})[\s,]+([0-9A-Fa-f]{8})\s*$")

    rows, skipped = [], 0
    for line in open(a.sniff, encoding="utf-8", errors="ignore"):
        if not line.strip() or line.strip().startswith("#"):
            continue
        m = kv.search(line)
        if m:
            rows.append(" ".join(g.upper() for g in m.groups()))
            continue
        m = quad.match(line)
        if m:
            rows.append(" ".join(g.upper() for g in m.groups()))
            continue
        skipped += 1

    print(f"· 识别 {len(rows)} 条认证记录，跳过 {skipped} 行")

    if not rows:
        print("✗ 没有可识别的记录。", file=sys.stderr)
        print()
        print("原始嗅探日志不能直接四分组 —— UID 会在防冲突阶段重复出现，", file=sys.stderr)
        print("硬分组会产出错误的 key。请改用下面任一条：", file=sys.stderr)
        print("  proxmark3> hf mf darkside        # 直接输出 key 候选")
        print("  proxmark3> hf mf nested --1k -a  # 同上")
        print("  proxmark3> hf mf autopwn         # 一条龙")
        print("  mfoc -O card.mfd                 # ACR122U 路线")
        return 1

    out = a.out or "trace.txt"
    with open(out, "w", encoding="utf-8") as f:
        f.write("# UID NT NR_enc AR_enc\n")
        f.write("\n".join(rows) + "\n")
    print(f"✓ {out}  ({len(rows)} 条)")
    print()
    print("下一步：")
    print(f"  mfkey32v2 {out}")
    return 0


# ────────────────────────────────────────────────────────────────
# 命令计划
# ────────────────────────────────────────────────────────────────

def cmd_plan(a):
    card = a.card or "card"
    print(f"""
密钥恢复计划 —— {card}

前提：读卡器（PN532 / ACR122U / Proxmark3）+ 一台能跑它的机器。
      iPhone 端拿不到 key，这一步绕不过去。

── 路线 1：Proxmark3（推荐）──────────────────────────────────
  hf 14a info                      确认卡型和 UID
  hf mf fchk --1k                  跑内置字典，命中率约 60%
  hf mf darkside                   全 0 key 的卡用这个
  hf mf nested --1k --blk 0 -a     已有一把 key 时做嵌套
  hf mf autopwn                    一条龙：找 key → dump → 存档
  产物：{card}.mfd、{card}-keys.bin

── 路线 2：ACR122U + libnfc（便宜）──────────────────────────
  mfoc -O {card}.mfd               自动找 key 并 dump
  mfcuk -C -R 0:A -s 250 -v 2      darkside（仅全 0 key 卡）
  nfc-mfclassic r a {card}.mfd     只读，需自己提供 key

── 路线 3：有嗅探日志，离线算 key ───────────────────────────
  hf 14a sniff                     正常刷一次卡
  python3 tools/crypto1.py trace --sniff log.txt -o trace.txt
  mfkey32v2 trace.txt              出 key

── 拿到 .mfd 之后 ───────────────────────────────────────────
  python3 tools/crypto1.py check --mfd {card}.mfd      确认真的 dump 全了
  python3 tools/mfd2json.py {card}.mfd --label "{card}" -o cards/{card}.json
  把 JSON 拖进 App 的 Documents/cards/，手机上看全 16 扇区

── 写回空白卡 ───────────────────────────────────────────────
  hf mf cload {card}.mfd            Proxmark3
  nfc-mfclassic w a {card}.mfd      ACR122U（需 UID 可写的卡）

内置默认密钥（先试这些，覆盖大量未改 key 的门禁）：
  python3 tools/crypto1.py defaults
""")
    return 0


def main():
    ap = argparse.ArgumentParser(description="MiFare Classic 密钥工作流")
    sub = ap.add_subparsers(dest="cmd", required=True)

    k = sub.add_parser("keys", help="校验并去重密钥表")
    k.add_argument("--wordlist", required=True)
    k.add_argument("--out")
    k.set_defaults(func=cmd_keys)

    d = sub.add_parser("defaults", help="输出内置默认密钥")
    d.add_argument("--out")
    d.set_defaults(func=cmd_defaults)

    c = sub.add_parser("check", help="检查 .mfd 是否真的 dump 完整")
    c.add_argument("--mfd", required=True)
    c.set_defaults(func=cmd_check)

    t = sub.add_parser("trace", help="嗅探日志 → mfkey32v2 输入")
    t.add_argument("--sniff", required=True)
    t.add_argument("-o", "--out")
    t.set_defaults(func=cmd_trace)

    p = sub.add_parser("plan", help="输出恢复命令序列")
    p.add_argument("--card")
    p.set_defaults(func=cmd_plan)

    a = ap.parse_args()
    return a.func(a)


if __name__ == "__main__":
    sys.exit(main())
