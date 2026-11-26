# Mac 上出 IPA —— 照着做

全程约 15 分钟（第一次装 Xcode 慢，后面只要 2 分钟）。

---

## 第 0 步：拿到代码

代码在你 GitHub 仓库里，Mac 上克隆下来：

```bash
cd ~/Desktop
git clone https://github.com/someyhj-collab/nfc-card-lab.git
cd nfc-card-lab
```

没装 git 的话，Mac 自带，直接能用。

---

## 第 1 步：装 Xcode

**从 App Store 装**（最简单）：

1. 打开 App Store，搜 `Xcode`
2. 点安装（约 12 GB，慢，去泡杯茶）
3. 装完后**打开一次 Xcode**，让它装组件、同意协议

**或者**只装命令行工具（省空间，但没法用图形界面签名）：

```bash
xcode-select --install
```

⚠️ 建议装完整 Xcode —— 后面签名要用它的图形界面，省事很多。

装完验证：

```bash
xcodebuild -version
# 应该输出 Xcode 15.x 或 16.x
```

如果提示 `xcode-select: error`，跑这个：

```bash
sudo xcode-select -s /Applications/Xcode.app
sudo xcodebuild -license accept
```

---

## 第 2 步：打开工程

```bash
open NFCCardLab.xcodeproj
```

如果双击没反应，说明 Xcode 没装好，回第 1 步。

---

## 第 3 步：填 Team（关键）

工程打开后，左侧点最上面的蓝色项目图标 `NFCCardLab`：

1. 中间选 **Signing & Capabilities** 标签
2. **Team** 下拉框 → 选你的 Apple ID
   - 没有的话点 `Add Account...` → 用 Apple ID 登录（这一步只能你自己输密码）
3. **Bundle Identifier** 改成唯一的，比如 `com.你的名字.nfclab`
   - 不能跟别人重复，加个随机后缀最保险

---

## 第 4 步：开 NFC 能力

**同一页**，左上角点 **+ Capability**：

1. 搜 `Near Field Communication Tag Reading`
2. 双击添加
3. 添加后会多出一栏，确认里面有 `NDEF` 和 `TAG`

⚠️ **这一步是成败关键**：
- 付费开发者账号（$99/年）→ 能加成功
- 免费 Apple ID → 加的时候会报错 `Personal Team does not support the Near Field Communication Tag Reading capability`

如果报这个错，说明免费账号用不了 NFC。这时你有两个选择：

**A. 继续，只是验证 App 能跑**
把 `Entitlements/NFCCardLab.entitlements` 里的 NFC 段删掉，App 能装能开，但点读卡会提示不支持。

**B. 去买开发者账号**
[developer.apple.com/programs](https://developer.apple.com/programs) → 注册 → ¥688/年 → 等 24~48 小时审核通过。

---

## 第 5 步：插上 iPhone 编译

1. 用数据线把 iPhone 连到 Mac
2. iPhone 上弹「信任此电脑」→ 点信任
3. Xcode 顶部工具栏，设备选择那里选你的 iPhone（不是模拟器）
4. 按 **⌘R**（或点左上角 ▶️）

第一次会报错 `Failed to register bundle identifier` 或 `No profiles for ...`，正常，处理方式：

- 报 `Failed to register bundle identifier` → Bundle ID 撞了，改个后缀
- 报 `No profiles` → 回第 3 步确认 Team 选对了
- 报 `device not registered` → Xcode 会自动注册，等它跑完；不行就 ⌘R 再按一次

---

## 第 6 步：信任证书（iPhone 上）

App 装上去后，第一次点开会被拦：

**设置 → 通用 → VPN 与设备管理 → 开发者 App → 点你的 Apple ID → 信任**

然后再点开 App。

---

## 第 7 步：导出 IPA（可选）

如果只是自己手机用，第 5 步装完就行了，**不需要 IPA**。

确实要 IPA 文件（比如发给别人、或者用 Sideloadly 重签）：

1. Xcode 顶部菜单 **Product → Archive**
2. 等打包完，会弹出 Organizer 窗口
3. 右侧点 **Distribute App**
4. 选 **Custom** → **Copy App**
5. 选个保存位置，得到一个 `.app` 文件夹

然后把 `.app` 打成 IPA：

```bash
cd ~/Desktop/nfc-card-lab
python3 tools/pack_ipa.py /路径/NFCCardLab.app ~/Desktop/NFCCardLab.ipa
```

会输出：
```
✓ /Users/你/Desktop/NFCCardLab.ipa  (1234 个条目, 8.2 MB)
```

---

## 常见报错对照

| 报错 | 原因 | 解决 |
|---|---|---|
| `xcodebuild: command not found` | Xcode 没装或没选 | `sudo xcode-select -s /Applications/Xcode.app` |
| `Personal Team does not support...NFC` | 免费账号 | 删掉 entitlement，或买付费账号 |
| `Failed to register bundle identifier` | Bundle ID 被别人占了 | 改成 `com.xxx.nfclab2026` 之类 |
| `No profiles for 'com.xxx' were found` | Team 没选 | Signing 页选 Team |
| `Untrusted Developer` | 没信任证书 | 设置里信任（第 6 步） |
| `The device is locked` | 手机锁屏 | 解锁再按 ⌘R |
| 编译卡住 `Indexing` | Xcode 在索引 | 等 1~2 分钟，别急着按第二次 |

---

## 如果只想快速试一下，不想装完整 Xcode

用命令行编译（需要 Xcode 的命令行工具，约 2 GB）：

```bash
cd ~/Desktop/nfc-card-lab
TEAM_ID=你的TeamID ./tools/build.sh
# 产出 build/NFCCardLab-unsigned.ipa
```

但这只出**未签名**包，装不上手机。要用的话还得配证书：

```bash
# 从钥匙串导出 p12，然后
./tools/prep_cert.sh cert.p12 'p12密码' app.mobileprovision
./tools/build.sh --sign
```

---

## 我需要你确认的

编译时如果报错，**把 Xcode 底部的红色报错文字发给我**（不是截图，文字就行），我直接改代码。

最可能出问题的是 Swift 语法细节 —— 我这边没有编译器，只能静态检查，真编译可能有一两处要调。
