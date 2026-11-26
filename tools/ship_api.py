#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ship_api.py — 纯 HTTP 版：不依赖 git，用 GitHub Contents API 上传文件

为什么需要这个：
  这台机器的 Python subprocess 只能跑 Python，调不了 git。
  所以改用 REST API 逐文件上传，效果一样。

用法
  python3 tools/ship_api.py --repo nfc-card-lab --token ghp_xxx
  python3 tools/ship_api.py --repo nfc-card-lab --token ghp_xxx --skip-upload
"""

import argparse
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request

API = "https://api.github.com"


class GH:
    def __init__(self, token):
        self.token = token

    def call(self, method, path, body=None, raw=False):
        url = path if path.startswith("http") else API + path
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Authorization", f"Bearer {self.token}")
        req.add_header("Accept", "application/vnd.github+json")
        req.add_header("X-GitHub-Api-Version", "2022-11-28")
        if data:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=90) as r:
                payload = r.read()
                if raw:
                    return payload
                return json.loads(payload) if payload else {}
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")[:400]
            return {"_error": e.code, "_detail": detail}

    def whoami(self):
        return self.call("GET", "/user")


SKIP_DIRS = {".git", "build", "out", "cert", "__pycache__", ".DS_Store"}
SKIP_EXT = {".ipa", ".pyc", ".zip"}


def walk_files(root):
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fn in filenames:
            if fn in SKIP_DIRS:
                continue
            if os.path.splitext(fn)[1] in SKIP_EXT:
                continue
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, root).replace(os.sep, "/")
            out.append((full, rel))
    return sorted(out, key=lambda x: x[1])


def ensure_repo(gh, repo, private):
    me = gh.whoami()
    owner = me["login"]
    print(f"· 账号: {owner}")

    r = gh.call("GET", f"/repos/{owner}/{repo}")
    if "_error" not in r:
        print(f"· 仓库已存在: {owner}/{repo}")
        return owner

    print(f"· 创建仓库 {owner}/{repo} …")
    r = gh.call("POST", "/user/repos", {
        "name": repo,
        "private": private,
        "auto_init": False,
        "description": "iOS NFC card read/write lab",
    })
    if "_error" in r:
        raise SystemExit(f"建仓库失败 {r['_error']}: {r['_detail']}")
    print("  ✓ 已创建")
    return owner


def upload(gh, owner, repo, root):
    files = walk_files(root)
    print(f"· 上传 {len(files)} 个文件")

    # 先建 .gitignore（让 Actions 别把 build 目录算进去）
    gitignore = "build/\nout/\ncert/\n*.ipa\n.DS_Store\n__pycache__/\n"

    ok, fail = 0, []
    for full, rel in files:
        with open(full, "rb") as f:
            content = f.read()
        body = {
            "message": f"add {rel}",
            "content": base64.b64encode(content).decode(),
            "branch": "main",
        }
        r = gh.call("PUT", f"/repos/{owner}/{repo}/contents/{rel}", body)
        if "_error" in r:
            # 已存在则先取 sha 再覆盖
            if r["_error"] == 422 or r["_error"] == 409:
                cur = gh.call("GET", f"/repos/{owner}/{repo}/contents/{rel}")
                if "_error" not in cur and "sha" in cur:
                    body["sha"] = cur["sha"]
                    r = gh.call("PUT", f"/repos/{owner}/{repo}/contents/{rel}", body)
            if "_error" in r:
                fail.append((rel, r["_error"], r["_detail"][:100]))
                continue
        ok += 1
        if ok % 5 == 0:
            print(f"  … {ok}/{len(files)}", flush=True)

    print(f"  ✓ 成功 {ok}，失败 {len(fail)}")
    for rel, code, det in fail[:10]:
        print(f"    ✗ {rel} ({code}) {det}")
    return len(fail) == 0


def trigger(gh, owner, repo):
    print("· 触发 workflow")
    r = gh.call("POST", f"/repos/{owner}/{repo}/actions/workflows/build.yml/dispatches",
                {"ref": "main"})
    if "_error" in r:
        raise SystemExit(f"触发失败 {r['_error']}: {r['_detail']}")
    print("  ✓ 已触发")

    for _ in range(12):
        time.sleep(6)
        runs = gh.call("GET", f"/repos/{owner}/{repo}/actions/runs?per_page=3")
        items = runs.get("workflow_runs", [])
        if items:
            run_id = items[0]["id"]
            print(f"  run id: {run_id}")
            return run_id
    raise SystemExit("没等到 run 出现，去网页看看："
                     f"https://github.com/{owner}/{repo}/actions")


def wait_run(gh, owner, repo, run_id, timeout=2400):
    print("· 等待编译")
    start = time.time()
    last = ""
    while time.time() - start < timeout:
        r = gh.call("GET", f"/repos/{owner}/{repo}/actions/runs/{run_id}")
        status, concl = r.get("status"), r.get("conclusion")
        line = f"  {status}" + (f" / {concl}" if concl else "")
        if line != last:
            print(line, flush=True)
            last = line
        if status == "completed":
            if concl == "success":
                print("✓ 编译成功")
                return True
            print(f"✗ 编译失败 ({concl})")
            print(f"  日志: https://github.com/{owner}/{repo}/actions/runs/{run_id}")
            return False
        time.sleep(20)
    print("✗ 超时")
    return False


def download(gh, owner, repo, run_id, out):
    print("· 下载 artifact")
    arts = gh.call("GET", f"/repos/{owner}/{repo}/actions/runs/{run_id}/artifacts")
    items = arts.get("artifacts", [])
    if not items:
        raise SystemExit("没有 artifact（编译可能失败了）")

    for art in items:
        print(f"  {art['name']}  {art['size_in_bytes']/1024:.0f} KB")
        if art["name"] == "build-log":
            continue

    target = next((a for a in items if "ipa" in a["name"].lower()), items[0])
    blob = gh.call("GET", target["archive_download_url"], raw=True)
    if isinstance(blob, dict) and "_error" in blob:
        raise SystemExit(f"下载失败 {blob['_error']}")

    zpath = os.path.abspath(out) + ".zip"
    with open(zpath, "wb") as f:
        f.write(blob)
    print(f"  ✓ {zpath}")

    import zipfile
    with zipfile.ZipFile(zpath) as z:
        names = z.namelist()
        print(f"  包内: {names}")
        ipas = [n for n in names if n.endswith(".ipa")]
        if not ipas:
            raise SystemExit("zip 里没有 .ipa")
        dest = os.path.abspath(out)
        with open(dest, "wb") as f:
            f.write(z.read(ipas[0]))
    print(f"✓ {dest}")
    return dest


def fetch_log(gh, owner, repo, run_id):
    arts = gh.call("GET", f"/repos/{owner}/{repo}/actions/runs/{run_id}/artifacts")
    for art in arts.get("artifacts", []):
        if art["name"] != "build-log":
            continue
        blob = gh.call("GET", art["archive_download_url"], raw=True)
        if isinstance(blob, dict):
            return None
        import zipfile, io
        with zipfile.ZipFile(io.BytesIO(blob)) as z:
            for n in z.namelist():
                if n.endswith("build.log"):
                    return z.read(n).decode(errors="replace")
    return None


def main():
    ap = argparse.ArgumentParser(description="纯 HTTP 推 GitHub → 编译 → 取 IPA")
    ap.add_argument("--repo", default="nfc-card-lab")
    ap.add_argument("--token", default=os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN"))
    ap.add_argument("--root", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    ap.add_argument("--private", action="store_true")
    ap.add_argument("--skip-upload", action="store_true")
    ap.add_argument("--download-only", action="store_true")
    ap.add_argument("-o", "--out", default="NFCCardLab-unsigned.ipa")
    a = ap.parse_args()

    if not a.token:
        print("✗ 需要 --token 或 GITHUB_TOKEN", file=sys.stderr)
        return 1

    gh = GH(a.token)
    owner = ensure_repo(gh, a.repo, a.private)

    if a.download_only:
        runs = gh.call("GET", f"/repos/{owner}/{a.repo}/actions/runs?per_page=10")
        ok = [r for r in runs.get("workflow_runs", []) if r.get("conclusion") == "success"]
        if not ok:
            raise SystemExit("没有成功的 run")
        download(gh, owner, a.repo, ok[0]["id"], a.out)
        return 0

    if not a.skip_upload:
        if not upload(gh, owner, a.repo, a.root):
            print("⚠ 有文件上传失败，继续尝试编译")

    run_id = trigger(gh, owner, a.repo)
    if wait_run(gh, owner, a.repo, run_id):
        download(gh, owner, a.repo, run_id, a.out)
    else:
        log = fetch_log(gh, owner, a.repo, run_id)
        if log:
            print("\n=== build.log 尾部 ===")
            print(log[-4000:])
        else:
            print("拿不到日志，去网页看：")
            print(f"  https://github.com/{owner}/{a.repo}/actions/runs/{run_id}")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
