# NFCCardLab — iOS NFC 读 / 写 / 复制 工具链

一套能真正编译、签名、装机的 iOS 工程 + PC 侧配套脚本。目标是把「读卡 → 存卡 → 复制/写卡 → 模拟」这条链路在 iPhone 上跑通，并且把每层的能力边界写在代码里，不糊弄。

```
nfc-card-tool/
├── NFCCardLab.xcodeproj        已生成的工程（含共享 scheme，可直接 open）
├── project.yml                 XcodeGen 备用定义
├── Sources/
│   ├── NFCCardLabApp.swift     入口
│   ├── Models.swift            CardDump / APDURecord / MemoryPage
│   ├── CardStore.swift         卡片库（Documents/cards/*.json）
│   ├── NFCReader.swift         CoreNFC 读卡 / 写 NDEF / 写页 / APDU
│   ├── PageScript.swift        解析 PC 侧生成的 pages.txt
│   ├── Crypto.swift            AES/3DES/CMAC（CommonCrypto）
│   ├── DESFire.swift           DESFire EV1/EV2 认证与读文件
│   ├── Emulation.swift         APDU 应答表 + HCE 桥接位
│   └── ContentView.swift       SwiftUI 界面
├── Resources/Info.plist        NFC 权限声明（AID / FeliCa 系统码）
├── Entitlements/               NFC Tag Reading，HCE 段默认注释
├── .github/workflows/build.yml 云端 macOS 编译出 IPA（没 Mac 时用）
├── sample/example-card.json    示例卡片，可直接丢进 App 看界面
└── tools/
    ├── gen_xcodeproj.py        零依赖生成 .xcodeproj + scheme
    ├── build.sh                编译 + 可选重签 → IPA
    ├── pack_ipa.py             .app → .ipa（纯 Python，保留权限位）
    ├── prep_cert.sh            p12 → pem + 描述文件检查
    ├── mfd2json.py             .mfd 镜像 → App 卡片 JSON
    ├── ntag_build.py           NTAG21x 页镜像构造 / 反解
    ├── crypto1.py              Classic 密钥表 / dump 完整性检查 / 恢复计划
    └── ship.py                 推 GitHub → 云端编译 → 自动取回 IPA
```

---

## 一、先看清 iPhone 到底能做什么

这张表决定了整个方案，先读完再动手。

| 动作 | iPhone 能做到 | 硬限制 |
|---|---|---|
| 读 UID / ATQA / SAK / ATS | ✅ 全部 | 无 |
| 读 NDEF 文本 / URL / vCard | ✅ 全部 | 无 |
| 读 NTAG / Ultralight 全部明文页 | ✅ 231 页以内 | 无 |
| 读 MiFare Classic 加密扇区 | ❌ | CoreNFC 不给 A/B key，只暴露 0 扇区 |
| 读 CPU 卡（银行卡 / 门禁 CPU）受保护文件 | ❌ | 只能发 APDU 给白名单 AID，且卡端有密钥 |
| 写 NDEF（任意文本 / URL） | ✅ | 标签需 readWrite 且容量够 |
| 写 NTAG 明文页 | ✅ | 不碰 OTP / lock / 配置页 |
| 写 MiFare Classic 扇区 | ❌ | 同上，没有 key |
| **复制 UID 做门禁克隆** | ❌ | **UID 是芯片在 14443-3 防冲突阶段回的，App 层物理上碰不到** |
| 卡模拟（HCE，回 APDU） | ⚠️ 需 Apple 单独审批 | `com.apple.developer.nfc.hce` entitlement，普通账号申请不到 |

**结论**：iPhone 能完整复制的是 **NDEF 标签**（NTAG213/215/216 这类）和 **Ultralight 明文卡**。MiFare Classic 门禁卡只能读 UID，写不了；想在手机上「刷卡进门」，除非那张卡本身走 APDU 且你拿到了 HCE 权限，否则做不到。这是苹果的限制，不是代码问题。

---

## 一之二、加密卡到底能到什么程度

「加密卡」是三种完全不同的东西，能力差一个数量级：

### ① NTAG / Ultralight 带密码保护（PWD_AUTH）—— 手机能完整处理 ✅

NTAG21x 可以设 4 字节密码 + 2 字节 PACK，设了之后读用户区要先发 `0x1B + PWD`。
密码和 PACK 存在芯片配置页里（page 43/133/229 和 44/134/230）。

手机端能力：
- **知道密码** → 完整认证 + 读全卡 + 写全卡。App 里「加密卡 → 输入密码并读全卡」直接做
- **不知道密码** → 只能读 UID 和 NDEF 之外的公开区，用户区读不到

密码从哪来：PC 上 `nfcpy` / `proxmark3 hf mf rdbl` 读配置页，或者出厂默认 `00000000`（大量空白卡没改）。

### ② DESFire EV1/EV2（AES / 3DES）—— 手机能认证并读文件 ✅

这是唯一一种「加密卡」在 iPhone 上能真正解开的。原因很实在：

DESFire 是 ISO7816-4 应用，认证就是一个普通 APDU（`90 71 00 00` AuthenticateEV2）。
密钥算法是标准 AES-128 / 2K3DES / 3K3DES，`CommonCrypto` 全支持。所以只要**你知道密钥**，
iPhone 上可以完整走完 challenge-response、拿到会话密钥、读受保护文件，甚至改密钥。

`Sources/DESFire.swift` 实现了：
- `AuthenticateEV2First` (0x71) / `AuthenticateISO` (0x1A) —— AES / 3DES 双轮认证
- 会话密钥派生（EV1 兼容的 sv1 派生 + EV2 的 CMAC 派生）
- `GetVersion` / `GetApplicationIDs` / `SelectApplication` / `ReadData`
- 每次交互都记进 transcript，可在卡片详情里逐步回看

密钥从哪来：DESFire 的密钥**不能暴力**（AES-128 密钥空间）。只能是：
出厂默认（全 0 / `0000000000000000`）、系统集成商文档、或者你自己就是发卡方。
拿不到密钥，DESFire 和 Classic 一样是黑盒。

### ③ MiFare Classic（Crypto1）—— 手机只能读 UID ❌

Crypto1 认证在硬件层完成，CoreNFC 不暴露任何加密原语，也发不了认证帧。
App 拿不到 key 是其次，**根本没有发 Crypto1 认证的接口**才是根本原因。

所以 Classic 的完整流程只能在 PC 上走：

```bash
# 1. 找 key + dump（二选一）
proxmark3> hf mf autopwn              # 一条龙
mfoc -O card.mfd                     # ACR122U

# 2. 检查是不是真 dump 全了（这一步很关键）
python3 tools/crypto1.py check --mfd card.mfd

# 3. 转成 App 能读的格式
python3 tools/mfd2json.py card.mfd --label "门禁卡" -o cards/门禁.json
```

`crypto1.py check` 会逐扇区告诉你哪些解开了、哪些是 dump 工具留的全 0 空壳。
**这一步别跳过** —— 很多 dump 看着有 1024 字节，实际一半扇区是空的，拿去写卡会把门禁写坏。

### 一句话对照

| 卡类型 | 手机读 | 手机写 | 手机认证 |
|---|---|---|---|
| NTAG/Ultralight 无密码 | ✅ | ✅ | — |
| NTAG/Ultralight 有密码 | ✅（知道密码） | ✅（知道密码） | ✅ PWD_AUTH |
| DESFire EV1/EV2 | ✅（知道密钥） | ⚠️ 需 Secure Messaging | ✅ AES/3DES |
| MiFare Classic | 仅 UID | ❌ | ❌ 无接口 |
| CPU 卡（银行卡/身份证） | 仅公开 ADF | ❌ | ❌ 卡端密钥 |

---

## 二、拿 IPA 的三条路

IPA 里的那个 Mach-O 必须由 Xcode 编译，任何非 Mac 环境都产不出来。三条路按省事程度排：

### 路线 A：GitHub Actions（没有 Mac 走这条，一条命令）

```bash
cd nfc-card-tool
python3 tools/ship.py --repo nfc-card-lab --token ghp_你的token
```

它会：建仓库 → 推代码 → 触发 workflow → 等编译 → 下载并解出
`NFCCardLab-unsigned.ipa` 到当前目录。首次约 3–6 分钟。

token 在 https://github.com/settings/tokens 生成（classic，勾 `repo` + `workflow`）。

也可以手动：

```bash
git init -b main && git add -A && git commit -m "nfc card lab"
git remote add origin https://github.com/你的账号/nfc-card-lab.git
git push -u origin main
# 然后网页上 Actions → Build IPA → Run workflow
```

工作流在 `.github/workflows/build.yml`，`macos-14` + Xcode 15.4。它会：
- 编译日志全程落盘，失败时也上传，能直接看报错
- 打包后自动 `--inspect` 校验 Info.plist 和 Mach-O magic
- 结构不对直接失败，不会给你一个坏包

### 路线 B：手上有 Mac

```bash
cd nfc-card-tool
./tools/prep_cert.sh cert.p12 '证书密码' app.mobileprovision
TEAM_ID=你的TeamID BUNDLE_ID=com.your.nfclab ./tools/build.sh --sign
```

不需要 `xcodegen`——工程已经生成好，`gen_xcodeproj.py` 也能随时重生成。
产物 `build/NFCCardLab-signed.ipa`，`--verify` 自动跑结构校验。

只要未签名包：

```bash
TEAM_ID=你的TeamID ./tools/build.sh
# → build/NFCCardLab-unsigned.ipa
```

### 路线 C：Xcode 图形界面

`open NFCCardLab.xcodeproj` → 选真机 → Signing & Capabilities 里选你的 Team、
勾上 Near Field Communication Tag Reading → Cmd+R 装到手机，
再用 Xcode → Product → Archive → Distribute 导出 IPA。

**证书要求**：`NFC Tag Reading` 能力只在付费开发者账号（$99/年）里开放，免费 Apple ID 签出来的包能装但 `NFCTagReaderSession` 会直接报不支持。到 developer.apple.com → Identifiers → 勾 Near Field Communication Tag Reading → 重新生成描述文件。

装完在 **设置 → 通用 → VPN 与设备管理** 里信任证书。

---

## 三、读卡流程

1. 打开 App → 「读取卡片」→ 贴卡
2. 自动抓：UID、ATQA、SAK、ATS、历史字节、NDEF 记录、NTAG 全部页、APDU 往返
3. 落盘成 `Documents/cards/<uuid>.json`，可在卡片库里回看、删除

**CPU 卡（银行卡 / 身份证）**：`Info.plist` 里的 `iso7816.select-identifiers` 是白名单，不在表里的 AID 系统层就拦掉了。表里预置的是常见公开 AID（PBOC / EMV / NDEF 应用）。读到的只有 ATR、ATS 和公开目录，交易数据需要卡端密钥，拿不到。

**FeliCa（Suica / 八达通）**：`felica.systemcodes` 里预置了 0003/8005/8008/12FC。iPhone 能读到 IDm 和公开系统区，余额类字段在加密区，读不到。

---

## 四、复制 / 写卡

### 4.1 NDEF 标签（最常用，完全可行）

App 内「写入 NDEF」→ 输入文本或 URL → 贴卡。走 `writeNDEF`，一次写整条消息，标签会自动处理 TLV 和页对齐。

命令行批量做：

```bash
# 生成 NTAG213 的页镜像 + nfcpy 写入脚本
python3 tools/ntag_build.py --text "https://example.com" --uri --chip 213 -o out/

# 有 ACR122U / PN532 时直接写
python3 out/write_nfcpy.py
```

`out/pages.txt` 是逐页 hex，也可以直接粘进 App 的「写入页镜像」。

### 4.2 NTAG / Ultralight 整卡克隆

手机端能读全部明文页 → 存成 JSON → 换一张同型号空标签 → 「写入页镜像」把页按原样写回。这就是 NTAG 的完整复制，包括 NDEF 之外的厂商数据。

```bash
# 反向：从 dump 的 pages.txt 还原出原始文本
python3 tools/ntag_build.py --read pages.txt --chip 215
```

### 4.3 MiFare Classic（必须上 PC）

iPhone 拿不到 key，所以流程是 PC 先 dump，再回灌到 App 里做归档和 APDU 回放：

```bash
# PC + PN532 / Proxmark3
proxmark3> hf mf autopwn            # 一条龙：找 key → dump → 存 .mfd
# 或 ACR122U
mfoc -O card.mfd

# 转成 App 的卡片 JSON
python3 tools/mfd2json.py card.mfd --label "公司门禁" -o cards/门禁.json
```

把 JSON 丢进 App 的 `Documents/cards/`（Xcode → Devices → 拖文件，或 iTunes 文件共享）。App 里能看到 16 个扇区的 keyA/AC/keyB 和全部块数据，`sectorDump` 里 key 全 0 的扇区会被标灰——那说明 dump 时没认证成功，数据不可信。

**写回 Classic 卡**：iPhone 做不到（没 key，也发不了 Crypto1 认证）。要在 PC 上用 `nfc-mfclassic w a card.mfd` 或 `proxmark3> hf mf restore`。

---

## 五、卡模拟（HCE）

`Sources/Emulation.swift` 里有完整的数据层：把 `CardDump.transcript` 编译成 APDU 应答表，支持精确匹配 + 前缀规则，未命中回 `6A82`。

真机跑起来需要两步，缺一不可：

1. **申请 entitlement**：Apple 的 NFC & SE Platform 计划（HCE），提交用途说明，审批通过后开发者后台才会给你 `com.apple.developer.nfc.hce` 和对应 SDK
2. **打开编译开关**：取消 `Entitlements/NFCCardLab.entitlements` 里 HCE 段的注释，`project.yml` 加 `OTHER_SWIFT_FLAGS: -DHCE_ENABLED`，把 `Emulation.swift` 里那段桥接换成 Apple 给的实际 API

未获批时整个模块退化成**本地回放**：可以在 App 里喂 APDU 看应答，不碰硬件。这个模式对调试协议很有用。

**再说一次**：HCE 只能模拟 ISO7816 的 APDU 应答，**不能伪装 UID**。所以「拿 iPhone 刷开公司门禁」这件事，除非门禁读头认 APDU 而不认 UID，否则不可能。

---

## 六、PC 侧配套

| 工具 | 用途 |
|---|---|
| `proxmark3` | Classic 全家桶：`hf mf autopwn` 一步 dump |
| `mfoc` / `mfcuk` | ACR122U 路线，默认字典 / darkside |
| `nfcpy` | 通用读写，`ntag_build.py` 生成的脚本用它 |
| `libnfc` | `nfc-mfclassic` / `nfc-list`，底层调试 |
| `Flipper Zero` | 便携替代，能读写 Classic / NTAG / EM4100 |

常见默认 key（先试这些，能开大半门禁卡）：

```
FFFFFFFFFFFF  A0A1A2A3A4A5  000000000000  D3F7D3F7D3F7
B0B1B2B3B4B5  4D3A99C351DD  1A982C7E459A  AABBCCDDEEFF
```

---

## 七、排障

| 现象 | 原因 |
|---|---|
| `xcodebuild: error: The project ... does not contain a scheme named "NFCCardLab"` | 工程是手改过的，重跑 `python3 tools/gen_xcodeproj.py` |
| Actions 里 `No such file: Payload/NFCCardLab.app/NFCCardLab` | 编译阶段失败但被 `\|\|` 吞了，看前一步日志 |
| 点读卡没反应 | 免费证书 → NFC 能力未启用，换付费账号 |
| `readerSessionInvalidationErrorSessionTimeout` | 贴卡位置不对，iPhone 顶部天线在摄像头右侧 |
| 读 CPU 卡只拿到 ATR | AID 不在 `select-identifiers` 白名单，或卡要求认证 |
| 写 NDEF 报容量不足 | NTAG213 只有 144 字节，换 215/216 |
| 写完标签读不出来 | 页写错了保护位，或 NDEF TLV 长度字段没对齐 |
| `ApplicationVerificationFailed` | 描述文件与 Bundle ID 不匹配，`--bundle-id` 要跟描述文件后缀一致 |

---

## 八、文件速查

- 卡片数据：`Documents/cards/*.json`（App 沙盒内，可导出）
- 编译产物：`build/`
- 签名材料：`cert/key.pem`、`cert/cert.pem`、`cert/app.mobileprovision`
