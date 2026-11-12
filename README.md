# DSHPhone — iPhone 控制 DeepSeek Harness

一个极简 iOS 客户端：在同一 Wi-Fi 下自动发现电脑上的 dsh 网关，然后内嵌 WebView 直接操作 dsh。

- **局域网发现**：Bonjour (`_dsh._tcp`) 优先，`/__ping?fmt=json` 的 /24 并发扫描兜底（任一可用即可发现）
- **免 token**：网关把 dsh 的 `/?token=` 一次性登录换成长期 cookie，App 只需要访问密钥
- **无签名 CI**：GitHub Actions 在 macOS runner 上构建未签名 IPA，直接下载安装（自签/巨魔）
- 适配 iPhone / iPad，支持横竖屏、下拉刷新、手动填 IP

## 目录

```
project.yml                     # XcodeGen 工程定义（不提交 .xcodeproj）
DSHPhone/
  DSHPhoneApp.swift             # @main
  ContentView.swift             # 设备列表 / 手动添加
  DiscoveryService.swift        # Bonjour + /24 扫描
  Models.swift                  # DshDevice / PingInfo
  WebPane.swift                 # WKWebView 封装
.github/workflows/ios-unsigned.yml
```

## 构建（本地 / macOS）

```bash
brew install xcodegen
xcodegen generate
open DSHPhone.xcodeproj      # 需要签名的真机调试：在 Signing 里选自己的 Team
```

命令行出未签名 IPA：

```bash
xcodebuild -project DSHPhone.xcodeproj -scheme DSHPhone \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build

mkdir -p out/Payload && cp -R build/Build/Products/Release-iphoneos/DSHPhone.app out/Payload/
(cd out && zip -qry DSHPhone-unsigned.ipa Payload)
```

## 构建（CI，无需 Mac）

推送到 `main` 或手动触发 `build-unsigned-ipa`：

1. Actions 跑完 → Artifacts 里下载 `DSHPhone-unsigned-ipa`
2. 打 `v*` tag 会自动附到 Release

## 安装未签名 IPA

未签名 IPA 不能直接装进未越狱设备，任选其一：

| 方式 | 适用 | 说明 |
|---|---|---|
| **Sideloadly / AltStore / SideStore** | 所有设备 | 用你自己的 Apple ID 重签，7 天（免费）/ 1 年（付费开发者） |
| **TrollStore** | iOS 14.0–16.6.1 特定版本 | 可直接安装未签名 IPA，永久 |
| **Xcode 真机调试** | 有 Mac | 在 Signing 里选 Team 后直接 Run |

## 配对网关（Windows 侧）

网关在 `dsh-phone-proxy.mjs`（本仓库外的运行环境），需要开两个能力：

```bash
# /__ping 返回 JSON（App 扫描用）
curl http://192.168.5.120/__ping?fmt=json
# {"service":"dsh-phone-gateway","name":"...","ports":[80,8080],"key":"..."}

# Bonjour 广播（App 秒发现）
# 网关启动日志里应出现：bonjour = _dsh._tcp  (advertised on port 80)
```

不想让扫描接口回传密钥：

```powershell
$env:DSH_PING_HIDE_KEY = "1"   # 之后 App 里手动填 key
```

访问密钥在电脑上：

```
%USERPROFILE%\.dsh\.phone-key
```

## 发现逻辑

```
启动
 ├─ Bonjour 浏览 _dsh._tcp (NWBrowser) ──> NetService.resolve ──> A 记录
 └─ 取本机 IPv4，扫 <prefix>.1-254 的 80 / 8080
      GET /__ping?fmt=json  (超时 0.9s, 并发 64)
      命中且 service == "dsh-phone-gateway" 才算发现
```

扫描结果按主机名排序并持久化到 `UserDefaults`，下次启动先显示已知设备。

## 权限

首次进入会弹本地网络权限（`NSLocalNetworkUsageDescription` + `NSBonjourServices`）。
iOS 14+ 必须允许，否则 Bonjour 与 HTTP 均被系统拦截。
