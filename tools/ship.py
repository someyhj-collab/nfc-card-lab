#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ship.py — 一条命令把工程推到 GitHub，触发云端编译，然后取回 IPA

为什么需要这个：
  这台机器上没有任何 Swift/Clang 编译器，IPA 里的 Mach-O 只能由 macOS 的
  Xcode 编出来。所以「给我一个 IPA」这件事只有两条路：
    A. 你有 Mac  →  tools/build.sh --sign
    B. 你没有 Mac → 这个脚本，用 GitHub 的免费 macOS runner 编

用法
  # 第一次：创建仓库 + 推送 + 触发编译 + 等结果 + 下载 IPA
  python3 tools/ship.py --repo nfc-card-lab --token ghp_xxx

  # 之后只要重新编译
  python3 tools/ship.py --repo nfc-card-lab --token ghp_xxx --skip-push

  # 只看状态 / 只下载
  python3 tools/ship.py --repo nfc-card-lab --token ghp_xxx --status
  python3 tools/ship.py --repo nfc-card-lab --token ghp_xxx --download out.ipa

token 需要 repo + workflow 权限（classic PAT 勾 repo 和 workflow）。
没有 token 就先建一个：https://github.com/settings/tokens
"""

import argparse
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

API = "https://api.github.com"


class GH:
    def __init__(self, token, owner=None):
        self.token = token
        self.owner = owner

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
            with urllib.request.urlopen(req, timeout=60) as r:
                payload = r.read()
                if raw:
                    return payload
                return json.loads(payload) if payload else {}
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")[:500]
            raise SystemExit(f"GitHub API {e.code} {method} {path}\n{detail}")

    def whoami(self):
        return self.call("GET", "/user")


def run(cmd, cwd=None, check=True):
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if check and r.returncode != 0:
        raise SystemExit(f"命令失败: {' '.join(cmd)}\n{r.stderr[:800]}")
    return r


def ensure_repo(gh, repo, private):
    me = gh.whoami()
    owner = me["login"]
    print(f"· 账号: {owner}")

    r = subprocess.run(["git", "ls-remote", f"https://x-access-token:{gh.token}@github.com/{owner}/{repo}.git"],
                       capture_output=True, text=True)
    if r.returncode == 0:
        print(f"· 仓库已存在: {owner}/{repo}")
        return owner

    print(f"· 创建仓库 {owner}/{repo} …")
    gh.call("POST", "/user/repos", {
        "name": repo,
        "private": private,
        "auto_init": False,
        "description": "iOS NFC card read/write/emulate lab",
    })
    print("  ✓ 已创建")
    return owner


def push(root, owner, repo, token):
    print("· 推送代码")
    if not os.path.isdir(os.path.join(root, ".git")):
        run(["git", "init", "-b", "main"], cwd=root)
        run(["git", "config", "user.email", "local@example.com"], cwd=root)
        run(["git", "config", "user.name", "NFCCardLab"], cwd=root)

    with open(os.path.join(root, ".gitignore"), "w") as f:
        f.write("build/\nout/\ncert/\n*.ipa\n.DS_Store\n__pycache__/\n")

    run(["git", "add", "-A"], cwd=root)
    r = subprocess.run(["git", "commit", "-m", "nfc card lab"], cwd=root,
                       capture_output=True, text=True)
    if r.returncode != 0 and "nothing to commit" not in r.stdout + r.stderr:
        print("  (无新改动，跳过 commit)")

    remote = f"https://x-access-token:{token}@github.com/{owner}/{repo}.git"
    subprocess.run(["git", "remote", "remove", "origin"], cwd=root, capture_output=True)
    run(["git", "remote", "add", "origin", remote], cwd=root)
    run(["git", "push", "-u", "origin", "main", "--force"], cwd=root)
    print("  ✓ 已推送")


def trigger(gh, owner, repo):
    print("· 触发 workflow")
    gh.call("POST", f"/repos/{owner}/{repo}/actions/workflows/build.yml/dispatches",
            {"ref": "main"})
    print("  ✓ 已触发")
    time.sleep(8)

    runs = gh.call("GET", f"/repos/{owner}/{repo}/actions/runs?per_page=5")
    if not runs.get("workflow_runs"):
        raise SystemExit("没有找到 workflow run，检查 .github/workflows/build.yml 是否推送成功")
    run_id = runs["workflow_runs"][0]["id"]
    print(f"  run id: {run_id}")
    return run_id


def wait(gh, owner, repo, run_id, timeout=1800):
    print("· 等待编译（首次约 3–6 分钟）")
    start = time.time()
    last = ""
    while time.time() - start < timeout:
        r = gh.call("GET", f"/repos/{owner}/{repo}/actions/runs/{run_id}")
        status, concl = r["status"], r.get("conclusion")
        line = f"  {status}" + (f" / {concl}" if concl else "")
        if line != last:
            print(line, flush=True)
            last = line
        if status == "completed":
            if concl == "success":
                print("✓ 编译成功")
                return run_id
            raise SystemExit(f"✗ 编译失败 ({concl})。日志：\n"
                             f"  https://github.com/{owner}/{repo}/actions/runs/{run_id}")
        time.sleep(15)
    raise SystemExit("✗ 等待超时")


def download(gh, owner, repo, run_id, out):
    print("· 下载 artifact")
    arts = gh.call("GET", f"/repos/{owner}/{repo}/actions/runs/{run_id}/artifacts")
    items = arts.get("artifacts", [])
    if not items:
        raise SystemExit("这个 run 没有 artifact")
    art = items[0]
    print(f"  {art['name']} ({art['size_in_bytes']/1024/1024:.1f} MB)")

    blob = gh.call("GET", art["archive_download_url"], raw=True)
    zpath = out + ".zip"
    with open(zpath, "wb") as f:
        f.write(blob)
    print(f"  ✓ {zpath}")

    # 解出里面的 IPA
    import zipfile
    with zipfile.ZipFile(zpath) as z:
        names = z.namelist()
        ipas = [n for n in names if n.endswith(".ipa")]
        print(f"  包内: {names}")
        if ipas:
            z.extract(ipas[0], os.path.dirname(os.path.abspath(out)) or ".")
            src = os.path.join(os.path.dirname(os.path.abspath(out)), ipas[0])
            if os.path.abspath(src) != os.path.abspath(out):
                os.replace(src, out)
            print(f"✓ {out}")
            return out
    raise SystemExit("zip 里没有 .ipa")


def main():
    ap = argparse.ArgumentParser(description="推 GitHub → 云端编译 → 取回 IPA")
    ap.add_argument("--repo", default="nfc-card-lab")
    ap.add_argument("--token", default=os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN"))
    ap.add_argument("--root", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    ap.add_argument("--private", action="store_true", help="建私有仓库")
    ap.add_argument("--skip-push", action="store_true")
    ap.add_argument("--status", action="store_true", help="只看最近一次 run")
    ap.add_argument("--download", metavar="OUT.ipa", help="只下载最近成功的 artifact")
    ap.add_argument("-o", "--out", default="NFCCardLab-unsigned.ipa")
    a = ap.parse_args()

    if not a.token:
        print("✗ 需要 GitHub token", file=sys.stderr)
        print("  1. 打开 https://github.com/settings/tokens → Generate new token (classic)", file=sys.stderr)
        print("  2. 勾选 repo 和 workflow", file=sys.stderr)
        print("  3. python3 tools/ship.py --repo nfc-card-lab --token ghp_xxx", file=sys.stderr)
        return 1

    gh = GH(a.token)

    if a.status:
        owner = gh.whoami()["login"]
        runs = gh.call("GET", f"/repos/{owner}/{a.repo}/actions/runs?per_page=3")
        for r in runs.get("workflow_runs", []):
            print(f"  {r['id']}  {r['status']:12s} {r.get('conclusion') or '-':10s} {r['created_at']}")
        return 0

    if a.download:
        owner = gh.whoami()["login"]
        runs = gh.call("GET", f"/repos/{owner}/{a.repo}/actions/runs?per_page=10")
        ok = [r for r in runs.get("workflow_runs", [])
              if r.get("conclusion") == "success"]
        if not ok:
            raise SystemExit("没有成功的 run")
        download(gh, owner, a.repo, ok[0]["id"], a.download)
        return 0

    owner = ensure_repo(gh, a.repo, a.private)
    if not a.skip_push:
        push(a.root, owner, a.repo, a.token)
    run_id = trigger(gh, owner, a.repo)
    wait(gh, owner, a.repo, run_id)
    download(gh, owner, a.repo, run_id, a.out)

    print()
    print("下一步：用你的证书签这个包")
    print(f"  python3 ../ipa-signer/sign_ipa.py --ipa {a.out} \\")
    print("    --key cert/key.pem --cert cert/cert.pem \\")
    print("    --provision cert/app.mobileprovision --out NFCCardLab-signed.ipa")
    return 0


if __name__ == "__main__":
    sys.exit(main())
