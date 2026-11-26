#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
pack_ipa.py — 把 .app 打成 IPA

不依赖 zip 命令（macOS 上默认有，但为了在 Linux / CI / 无 zip 环境也能跑，
用 Python 标准库直接写 zip）。保留 Unix 权限位，否则 iOS 拒装。

用法
  python3 tools/pack_ipa.py Payload/NFCCardLab.app out.ipa
  python3 tools/pack_ipa.py --inspect out.ipa        # 只检查已有 IPA
"""

import argparse
import os
import plistlib
import stat
import sys
import zipfile


def add_dir(zf, arc, mode=0o40755):
    zi = zipfile.ZipInfo(arc.rstrip("/") + "/")
    zi.external_attr = (mode << 16) | 0x10
    zi.create_system = 3
    zf.writestr(zi, b"")


def add_file(zf, src, arc, mode):
    zi = zipfile.ZipInfo(arc)
    zi.external_attr = (mode & 0xFFFF) << 16
    zi.create_system = 3
    zi.compress_type = zipfile.ZIP_DEFLATED
    st = os.stat(src)
    zi.date_time = tuple(__import__("time").localtime(st.st_mtime))[:6]
    with open(src, "rb") as f:
        zf.writestr(zi, f.read())


def pack(app_path, out_path):
    app = os.path.abspath(app_path)
    name = os.path.basename(app)
    if not name.endswith(".app"):
        print(f"✗ 不是 .app: {name}", file=sys.stderr)
        return 1
    if not os.path.isdir(app):
        print(f"✗ 目录不存在: {app}", file=sys.stderr)
        return 1

    plist = os.path.join(app, "Info.plist")
    if not os.path.isfile(plist):
        print(f"✗ 缺 Info.plist", file=sys.stderr)
        return 1

    with open(plist, "rb") as f:
        info = plistlib.load(f)
    exe = info.get("CFBundleExecutable", "NFCCardLab")
    exe_path = os.path.join(app, exe)
    if not os.path.isfile(exe_path):
        print(f"✗ 缺可执行文件 {exe}（CFBundleExecutable）", file=sys.stderr)
        return 1

    os.makedirs(os.path.dirname(os.path.abspath(out_path)) or ".", exist_ok=True)
    if os.path.exists(out_path):
        os.remove(out_path)

    count = 0
    with zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED) as zf:
        add_dir(zf, "Payload")
        for root, dirs, files in os.walk(app):
            rel = os.path.relpath(root, os.path.dirname(app))
            arc_root = "Payload/" + rel.replace(os.sep, "/")
            add_dir(zf, arc_root)
            for d in dirs:
                full = os.path.join(root, d)
                if os.path.islink(full):
                    continue
                add_dir(zf, arc_root + "/" + d)
            for fn in files:
                full = os.path.join(root, fn)
                if os.path.islink(full):
                    target = os.readlink(full)
                    zi = zipfile.ZipInfo(arc_root + "/" + fn)
                    zi.create_system = 3
                    zi.external_attr = (0o120777 << 16)
                    zf.writestr(zi, target.encode())
                    count += 1
                    continue
                st = os.stat(full)
                mode = st.st_mode
                add_file(zf, full, arc_root + "/" + fn, mode)
                count += 1

    size = os.path.getsize(out_path)
    print(f"✓ {out_path}  ({count} 个条目, {size/1024:.1f} KB)")
    return 0


def inspect(ipa):
    with zipfile.ZipFile(ipa) as zf:
        names = zf.namelist()
        print(f"· {ipa}: {len(names)} 个条目")
        apps = sorted({n.split("/")[1] for n in names
                       if n.startswith("Payload/") and n.count("/") >= 2 and n.split("/")[1].endswith(".app")})
        if not apps:
            print("✗ Payload 里没有 .app", file=sys.stderr)
            return 1
        for a in apps:
            print(f"  应用: {a}")
            plist_name = f"Payload/{a}/Info.plist"
            if plist_name not in names:
                print("  ✗ 缺 Info.plist", file=sys.stderr)
                return 1
            info = plistlib.loads(zf.read(plist_name))
            exe = info.get("CFBundleExecutable", "")
            print(f"  Bundle ID : {info.get('CFBundleIdentifier')}")
            print(f"  版本      : {info.get('CFBundleShortVersionString')} ({info.get('CFBundleVersion')})")
            print(f"  可执行    : {exe}")
            print(f"  NFC 描述  : {info.get('NFCReaderUsageDescription', '—')[:40]}")
            if f"Payload/{a}/{exe}" not in names:
                print(f"  ✗ 可执行文件不在包里", file=sys.stderr)
                return 1
            # Mach-O magic
            head = zf.read(f"Payload/{a}/{exe}")[:4]
            magic = head.hex()
            kind = {"cffaedfe": "arm64 (thin)", "cafebabe": "fat",
                    "cefaedfe": "armv7 (thin)"}.get(magic, f"未知 {magic}")
            print(f"  Mach-O    : {kind}")
        print("✓ 结构完整")
    return 0


def main():
    ap = argparse.ArgumentParser(description=".app → .ipa（纯 Python，保留权限位）")
    ap.add_argument("app", nargs="?", help=".app 路径")
    ap.add_argument("out", nargs="?", default=None, help="输出 .ipa")
    ap.add_argument("--inspect", metavar="IPA", help="只检查已有 IPA")
    a = ap.parse_args()

    if a.inspect:
        return inspect(a.inspect)
    if not a.app:
        ap.error("需要 .app 路径或 --inspect")
    out = a.out or (os.path.splitext(os.path.basename(a.app))[0] + ".ipa")
    return pack(a.app, out)


if __name__ == "__main__":
    sys.exit(main())
