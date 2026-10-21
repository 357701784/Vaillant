# 威能热水器自用 App

直连威能中国区云端，显示官方 App 不提供的运行数据，并提供生活热水温度调节。

自用工具，不上架 App Store。

---

## 这是什么

一个 iOS 原生 App（SwiftUI），登录威能账号后直连 `vicapi.vaillant.com.cn`：

- **生活热水温度调节**（0.5°C 步进）+ 独立开关
- 出水 / 回水温度对比，温差过大自动标色
- 燃气消耗、运行状态、故障码等分组展示
- 设备共上报 **157 个属性**，其中 59 个做了中文映射分组显示，
  其余在「原始数据」页里完整可见（官方 App 只显示其中一小部分）

---

## 快速开始

```bash
git clone git@github.com:357701784/Vaillant.git
cd Vaillant
```

推送到 GitHub 即触发构建，Actions 会产出未签名的 `.ipa`（见下方「构建」）。

**安装**：`ipa` 未签名，需用 AltStore / SideStore 重签后安装。

---

## 构建

用 GitHub Actions 的 macOS runner，**不需要自己有 Mac**。

```
.github/workflows/build.yml
```

流程：`xcodegen generate` → 注入构建时间戳 → `xcodebuild` → 打包 ipa → 上传 artifact。

工程文件由 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 从 `project.yml` 生成，`.xcodeproj` 不入库。

> **注意**：`project.yml` 里刻意**没有**用 XcodeGen 的 `info:` 块。
> 那个块会让 XcodeGen 每次生成工程时**重写** `Resources/Info.plist`，
> 导致 `CFBundleDisplayName`、`UILaunchScreen`、屏幕方向等键全部丢失
> （表现为 App 在主屏显示成 "Vaillant" 而非「威能」）。
> 现在改为 `INFOPLIST_FILE` + `GENERATE_INFOPLIST_FILE: NO` 直接引用手写文件。

### 改图标

```bash
python3 Tools/make_icon.py /path/to/icon.png
```

自动裁白边、缩放居中、补正方形白底、去掉 alpha，输出到
`Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`。
iOS 要求 1024×1024 正方形且不带透明通道。

---

## 代码结构

```
Sources/Vaillant/
  VaillantApp.swift      入口 + RootView（TabView 两页）
  APIClient.swift         HTTP 客户端、Api 常量、可写属性定义
  MonitorClient.swift    WebSocket 订阅、轮询、乐观更新与待确认值保护
  AppStore.swift         全局状态、Keychain、发送队列（pump）
  AttributeCatalog.swift 59 个字段的中文映射、格式化、哨兵值识别
  Views.swift            全部界面

Resources/
  Info.plist             手写，不让 XcodeGen 覆盖
  Assets.xcassets        App 图标

Tools/
  make_icon.py           图标生成
  probe_cloud.py         云端探测工具（见下）
```

约 2100 行 Swift。

---

## 云端 API

协议逆自两个开源项目（它们是本 App 的信息来源）：

- [daxingplay/vaillant-plus-cn-api](https://github.com/daxingplay/vaillant-plus-cn-api) —— API 客户端
- [daxingplay/home-assistant-vaillant-plus](https://github.com/daxingplay/home-assistant-vaillant-plus) —— Home Assistant 集成

### 关键常量

| 项 | 值 | 解码后 |
|---|---|---|
| 主机 | `https://vicapi.vaillant.com.cn` | — |
| appkey | `9109fb3ea6c04cf1be34c71ff82a51ec` | 32 位十六进制应用标识 |
| app 身份 | `Basic YXBwLXc6aW90MlExWDNY` | `app-w:iot2Q1X3X`（用户名:密码）|
| User-Agent | `VaillantPlus/230329005 CFNetwork/1485 Darwin/23.1.0` | 伪装成官方 iOS App |

这些常量来自 `vaillant-plus-cn-api`，它是从官方 App 提取的（源码里是 base64 编码后再解一层）。

**两级凭据**：

| | 内容 | 范围 |
|---|---|---|
| 应用级 | `appkey` + `app_auth` | 所有用户共用，官方 App 的身份 |
| 用户级 | 你的账号密码 → 换来的 token | 只属于你 |

登录时用 `Basic(app_auth)` + form 里放你的账号密码，换来 `access_token`；
之后每个请求带 `appkey` 头 + `Authorization: Bearer <token>`。

### 接口

| 用途 | 方法与路径 |
|---|---|
| 登录 | `POST /auth/oauth/token?grant_type=password`（Basic 认证 + form：`appkey`/`scope=server`/`username`/`password`）|
| 设备列表 | `GET /app/device/getBindList?appKey=…&version=1.0` |
| 读取属性 | `wss://vicapi.vaillant.com.cn/monitor/ws/app` |
| 控制 | `POST /app/device/control/{did}` |

**读属性**：连上后发 `{"type":"msg","productKey":…,"mac":…,"did":…}` 订阅，
服务端推 `{"type":"2","did":…,"data":{…}}`。第一帧是全量，之后是增量。

**控制** body：

```json
{"appKey":"…","data":{"attrs":{"Flow_Temperature_Setpoint":44}},"version":"1.0"}
```

### 可写属性

> **实测结论（2026-10-19，familyCONNECT / LN1GBQ20-VU CN 206/5-5）**
>
> 这台设备**只有一个可写的温度字段**。在地暖开启状态下逐个试写，结果：
>
> | 写入 | 结果 |
> |---|---|
> | `Heating_Enable = 1` | ✅ 生效（0→1）|
> | `CH_readSetPoint = 40` | ❌ 无变化（只读）|
> | `Room_Temperature_Setpoint_Comfort = 40` | ❌ 无变化（只读）|
> | `Heating_Curve = 40` | ❌ 无变化（只读）|
> | `Flow_Temperature_Setpoint = 41` | ✅ 生效（43→41）|
>
> `Flow_Temperature_Setpoint` 是**当前活动回路的水温设定**，
> `Time_slot_type`（`CH` / `DHW`）说明这个值当前归哪个回路。
>
> **推论**：集成 v1.4.0 的地暖温控写 `Room_Temperature_Setpoint_Comfort`，
> 而该字段在本机只读 —— 所以**集成的地暖温控是无效的**，
> 官方 App 之所以能"调水温"，写的就是 `Flow_Temperature_Setpoint`。
>
> 这也解释了「新版只能调体感温度、老版能调水温」：
> 不是集成的差异（v1.2.5 与 v1.4.0 的 climate 代码完全一致），
> 而是同一字段在两版 UI 里被冠以了不同的语义。

| 用途 | 键 |
|---|---|
| 生活热水设定温度 | `Flow_Temperature_Setpoint` |
| 生活热水开关 | `WarmStar_Tank_Loading_Enable`（值 1/0）|
| 地暖设定温度 | `Room_Temperature_Setpoint_Comfort`（⚠️ 本机恒为 0，见「已知问题」）|
| 地暖开关 | `Heating_Enable` |
| 地暖模式 | `Mode_Setting_CH`（开机为 `"Cruising"`）|

> 地暖卡片的温度范围需要区分两套：
> 代码里的 `fallbackMin/fallbackMax` 是 **10–30°C**（室温语义），
> 而设备上报的 `Lower/Upper_Limitation_of_CH_Setpoint` 是 **30–75°C**（水温语义）。
> 运行时优先用设备上报的值，所以实际可选范围是 30–75；
> fallback 只在设备不报限制时兜底。

> ⚠️ **生活热水的设定温度字段和官方 App 显示的不完全一致**。
> 设备同时上报 `DHW_setpoint`(35)、`DHW_readSetPoint`(35)、
> `Flow_Temperature_Setpoint`(43)。实测只有 `Flow_Temperature_Setpoint`
> 是真正生效的那个 —— 写另两个云端返回 200 但值不变（静默失败）。
> 集成源码用的是 `DHW_setpoint`，所以它的生活热水温控大概率是无效的。

---

## 踩过的坑

记录下来避免重蹈覆辙。

### 1. 云端没有 CORS 头

`vicapi.vaillant.com.cn` 不返回任何 `Access-Control-Allow-Origin`。
**网页（LiveContainer / PWA / 浏览器）无法直接调用该 API**，同源策略会拦掉。

这就是为什么最终选择写原生 App 而不是网页版。

### 2. iOS 的长连接会被踢

维持 WebSocket 长连接，实测 **43 秒后被服务端断开**
（`code=53 Software caused connection abort`）。

改成**短连接轮询**：每次新建连接 → 订阅 → 取一帧全量 → 断开，间隔 5 秒。
没有心跳、没有掉线重连、没有重连风暴，行为可预期。

### 3. 服务端对并发连接有限制

实测（`python3 Tools/probe_cloud.py --ratelimit`）：

| 场景 | 结果 |
|---|---|
| 顺序开关连接 8 次 | 全成功，**无限速** |
| 等待 0–8 秒再连 | 全成功，**不需要间隔** |
| 同时开 5 条 | **只有 3 条成功** |

**同一 token 并发上限约 3 条。** 本 App 始终只有 1 条连接（`inFlight` 锁保证），
安全。之前遇到的 `1002 protocol error` 就是并发造成的，不是限流。

### 4. 增量帧不能整体替换

云端推的帧**不保证都是全量** —— 订阅后第一帧是全量，之后只带变化的字段。

用 `attrs = update` 整体替换会导致其余字段全部丢失（界面一片空白）。
必须**合并**。

### 5. 本地乐观值会被轮询覆盖

云端接受指令后，设备要几秒才实际应用并上报。这期间轮询读到的是设备的**旧值**，
会把刚设好的值覆盖掉（界面从 45 跳回 44.5）。

解决：记下「本地已设、设备未确认」的值，在设备回报一致前保护它不被旧值覆盖。

### 6. 控制指令要合并发送，不能丢弃

连续快速按 `+` 时，后发的指令不能被 `guard !sending` 直接丢掉。

用**常驻的「泵」任务**驱动队列：飞行期间的新指令合并进 `pendingPayload`，
泵取走时只发最新值。

> 踩过的具体坑：用 `defer { sendInFlight = false }` 标记空闲，
> 但 `defer` 要等函数**退出**才执行 —— 而退出前还有 3 秒核对等待，
> 那 3 秒里新按压全被挡掉，值卡在队列里**两分钟**才发出去。

### 7. 步进算式的括号

```swift
(current + delta * 10).rounded() / 10   // ❌ 等于 current/10 + delta
((current + delta) * 10).rounded() / 10   // ✅ 保留一位小数
```

写错时会把 43 变成 **5.3**，远低于下限 35，云端直接返回 **500**。
这个 bug 让人误以为是接口或字段的问题，绕了很久。

### 8. 十六进制与哨兵值

- 燃气消耗等累计量是**十六进制字符串**（如 `000080bf` = 32991），
  `Double("000080bf")` 解析失败
- `65535`（`0xFFFF`）是威能设备的**「无内容」占位值** ——
  故障码槽位为空、保养时间未知都用它。显示出来是噪音，应过滤
- `-50` 是「传感器未接」，`127.5` 是无效的 DHW 温度

### 9. XcodeGen 的 `info:` 块会覆盖手写的 Info.plist

见上方「构建」一节。

### 10. `MonitorClient` 必须继承 `ObservableObject`

原本继承的是 `NSObject`，`@Published` 属性**完全不生效** —— 数据正常进来了，
界面却永远停在第一帧。排查这个花了好几轮。

---

## 已知问题 / 待办

- **地暖水温无法调节**。`CH_readSetPoint` 只读（写 45 写不进去），
  `Room_Temperature_Setpoint_Comfort` 恒为 0，`Heating_Curve` 恒为 0。
  官方 App 能设地暖水温（它显示的是「水温」，不是室温），
  但用的字段尚未定位。

  定位方法：`python3 Tools/probe_cloud.py --diff`，
  在官方 App 里改一次**地暖**水温后看差分 —— 变化的那个字段就是答案。

  补充：已对比集成 v1.2.5 与 v1.4.0，**两版的 climate 代码完全一致**
  （读写都用 `Room_Temperature_Setpoint_Comfort`），
  所以「新版不能调水温、老版能调」不是集成代码的差异，
  更可能是云端对该键的解释变了。
- **燃气消耗卡片有 8 个重复字段**（今日/昨日/本月/今年 × 地暖/热水，
  全部等于 `000080bf`）。云端似乎把同一个累计表读数填到了所有时段字段。
  计划改为只保留运行时长、点火次数、功率等真正有信息量的项。
- `gas_consumption` 等值的**单位未知**，集成作者也未解析（名字里带 "raw"）。
  未经确认前不宜标注单位。定位方法：`python3 Tools/probe_cloud.py --gas`
  （放热水后看这些字段有没有变）。
- **故障与维护卡片**已处理：过滤掉 65535 哨兵值后，
  无故障时显示「✓ 无故障」而不是 11 行 65535。

---

## 调试工具

### `Tools/probe_cloud.py`

独立于 App 的云端探测脚本，用来查清「哪些字段可写、写了生效吗、值什么意思」。

```bash
VA_USER=账号 VA_PASS=密码 python3 Tools/probe_cloud.py --help
```

| 参数 | 用途 |
|---|---|
| `--dumpall` | 打印全部 157 个字段 |
| `--diff` | 读两次做差分：在官方 App 里改一次设置，看哪些字段跟着变 |
| `--ratelimit` | 探测连接的并发/频率限制 |
| `--circuits` | 测生活热水与地暖两个回路的写入字段 |
| `--gas` | 探测燃气消耗字段是否是活计数器 |
| `--keys` / `--half` | 逐个试写候选字段（会真实下发，测完自动恢复）|
| `--headers` | 模拟 iOS 请求头，定位 500 的成因 |

依赖：`pip install websockets`

### App 内

- **🐞 调试页** —— 连接事件日志（每次连接、每条指令、云端响应）
- **≡ 原始数据页** —— 全部字段，一键复制全部

「原始数据」页还有一个**排查小技巧**：某项显示为空时，
去这里找它对应的原始字段名和值，往往能发现云端上报的键名和预期不同。

---

## 安全

- 账号密码**仅**用于向威能云换取 token
- token / 密码存 iOS **Keychain**，不用 UserDefaults
- token 尽量复用 —— 每次重新登录都会让官方 App 的登录态失效
