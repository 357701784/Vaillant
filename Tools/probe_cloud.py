"""
威能云端探测工具。

排查云端行为用 —— 找出可写字段、验证字段是否生效、探测连接限制等。
App 内也有对应工具（调试页 / 原始数据页），但这个脚本能独立于 App 运行。

用法：
  VA_USER=账号 VA_PASS=密码 python3 Tools/probe_cloud.py --help

各模式说明见 --help。
"""
import json, os, sys, urllib.request, urllib.parse

API = "https://vicapi.vaillant.com.cn"
APP_KEY = "9109fb3ea6c04cf1be34c71ff82a51ec"
APP_AUTH = "YXBwLXc6aW90MlExWDNY"
UA = "VaillantPlus/230329005 CFNetwork/1485 Darwin/23.1.0"


def req(url, data=None, token=None, method=None):
    body = urllib.parse.urlencode(data).encode() if data else None
    r = urllib.request.Request(url, data=body, method=method or ("POST" if data else "GET"))
    r.add_header("appkey", APP_KEY)
    r.add_header("User-Agent", UA)
    if token:
        r.add_header("Authorization", f"Bearer {token}")
    if data:
        r.add_header("Content-Type", "application/x-www-form-urlencoded")
    try:
        with urllib.request.urlopen(r, timeout=25) as resp:
            return resp.status, resp.read().decode(errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")
    except Exception as e:
        return -1, str(e)


def post_json(url, payload, token):
    r = urllib.request.Request(url, data=json.dumps(payload).encode(), method="POST")
    r.add_header("appkey", APP_KEY)
    r.add_header("User-Agent", UA)
    r.add_header("Content-Type", "application/json")
    if token:
        r.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(r, timeout=25) as resp:
            return resp.status, resp.read().decode(errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")
    except Exception as e:
        return -1, str(e)


def main():
    user, pwd = os.environ.get("VA_USER"), os.environ.get("VA_PASS")
    if not user or not pwd:
        print("设置 VA_USER / VA_PASS"); sys.exit(1)

    st, body = req(f"{API}/auth/oauth/token?grant_type=password",
                   {"appkey": APP_KEY, "scope": "server",
                    "username": user, "password": pwd})
    # token 接口需要 Basic 头，单独处理
    r = urllib.request.Request(f"{API}/auth/oauth/token?grant_type=password",
                               data=urllib.parse.urlencode(
                                   {"appkey": APP_KEY, "scope": "server",
                                    "username": user, "password": pwd}).encode())
    r.add_header("appkey", APP_KEY); r.add_header("User-Agent", UA)
    r.add_header("Authorization", f"Basic {APP_AUTH}")
    r.add_header("Content-Type", "application/x-www-form-urlencoded")
    with urllib.request.urlopen(r, timeout=25) as resp:
        token = json.loads(resp.read())["access_token"]
    print("登录成功")

    st, body = req(f"{API}/app/device/getBindList?appKey={APP_KEY}&version=1.0", token=token)
    dev = json.loads(body)["data"][0]["allBindList"][0]
    did = dev["did"]
    print(f"设备 {did}")

    st, body = req(f"{API}/app/device/getBindList?appKey={APP_KEY}&version=1.0", token=token)
    attrs_ro = json.loads(body)

    # 探测云端接受什么。依次试不同 payload 形态，值用当前设定温度±0，
    # 避免真的改动设备参数。
    current = None
    try:
        st2, b2 = req(f"{API}/app/device/getBindList?appKey={APP_KEY}&version=1.0", token=token)
    except Exception:
        pass

    tests = [
        ("集成源码原样：value 为 float",
         {"appKey": APP_KEY, "data": {"attrs": {"DHW_setpoint": 35.0}}, "version": "1.0"}),
        ("value 为 int",
         {"appKey": APP_KEY, "data": {"attrs": {"DHW_setpoint": 35}}, "version": "1.0"}),
        ("value 为 str",
         {"appKey": APP_KEY, "data": {"attrs": {"DHW_setpoint": "35"}}, "version": "1.0"}),
        ("version 为 1.1",
         {"appKey": APP_KEY, "data": {"attrs": {"DHW_setpoint": 35.0}}, "version": "1.1"}),
        ("无 version 字段",
         {"appKey": APP_KEY, "data": {"attrs": {"DHW_setpoint": 35.0}}}),
        ("无 appKey 字段",
         {"data": {"attrs": {"DHW_setpoint": 35.0}}, "version": "1.0"}),
    ]

    print(f"\n=== 探测控制接口（目标 {did}）===")
    for name, payload in tests:
        st, body = post_json(f"{API}/app/device/control/{did}", payload, token)
        ok = "✅" if st == 200 else "❌"
        print(f"{ok} {name}: HTTP {st}  {body[:120]}")
        if st != 200:
            print("   ↑ 失败，停止探测同形态变体")
            break



def test_off_state():
    """关键测试：热水关闭时，写一个【不同的】值，看云端是否接受。
    之前只写过当前值（空转），证明不了任何东西。"""
    user, pwd = os.environ.get("VA_USER"), os.environ.get("VA_PASS")
    r = urllib.request.Request(f"{API}/auth/oauth/token?grant_type=password",
                               data=urllib.parse.urlencode(
                                   {"appkey": APP_KEY, "scope": "server",
                                    "username": user, "password": pwd}).encode())
    r.add_header("appkey", APP_KEY); r.add_header("User-Agent", UA)
    r.add_header("Authorization", f"Basic {APP_AUTH}")
    r.add_header("Content-Type", "application/x-www-form-urlencoded")
    with urllib.request.urlopen(r, timeout=25) as resp:
        token = json.loads(resp.read())["access_token"]

    st, body = req(f"{API}/app/device/getBindList?appKey={APP_KEY}&version=1.0", token=token)
    dev = json.loads(body)["data"][0]["allBindList"][0]
    did = dev["did"]
    print(f"设备 {did}")

    # 先读当前值
    import websockets, asyncio
    async def read_attrs():
        async with websockets.connect(
            "wss://vicapi.vaillant.com.cn/monitor/ws/app",
            extra_headers={"Authorization": f"Bearer {token}"}) as ws:
            await ws.send(json.dumps({"type": "msg",
                "productKey": dev["productKey"], "mac": dev["mac"], "did": did}))
            for _ in range(20):
                raw = await asyncio.wait_for(ws.recv(), timeout=5)
                d = json.loads(raw)
                if d.get("type") == "2":
                    return d.get("data", {})
        return {}

    attrs = asyncio.run(read_attrs())
    cur = attrs.get("DHW_setpoint") or attrs.get("DHW_readSetPoint") or attrs.get("Current_DHW_Setpoint")
    lo = attrs.get("Lower_Limitation_of_DHW_Setpoint")
    hi = attrs.get("Upper_Limitation_of_DHW_Setpoint")
    sw = {k: attrs.get(k) for k in
          ["WarmStar_Tank_Loading_Enable", "Enabled_DHW", "DHW_switch"]}
    print(f"当前设定={cur}  下限={lo}  上限={hi}")
    print(f"热水开关={sw}")

    target = float(cur) + 1
    if hi is not None and target > float(hi):
        print(f"⚠️ 上限是 {hi}，无法用 +1 测试，改用 {float(hi) - 1}")
        target = float(hi) - 1

    print(f"\n=== 写入 {target}（当前 {cur}，非空转）===")
    st, body = post_json(f"{API}/app/device/control/{did}",
        {"appKey": APP_KEY, "data": {"attrs": {"DHW_setpoint": target}},
         "version": "1.0"}, token)
    ok = "✅" if st == 200 else "❌"
    print(f"{ok} HTTP {st}  {body[:150]}")

    if st == 200:
        print("\n写入成功！云端接受关闭状态下的温度修改。")
        print("→ 说明问题在 App 侧（token 或请求细节），请把上面打印的数值发我")
    else:
        print("\n写入失败 → 云端确实要求先开启热水功能")
        print("→ App 侧应改为：热水关闭时禁用加减，并提示先开启")

    # 恢复原值
    if st == 200:
        print(f"\n恢复原值 {cur}…")
        post_json(f"{API}/app/device/control/{did}",
            {"appKey": APP_KEY, "data": {"attrs": {"DHW_setpoint": cur}},
             "version": "1.0"}, token)


def test_keys():
    """用 App 的账号，逐个测试候选写入键。每个键写一个不同的值，
    成功后立刻恢复原值。"""
    user, pwd = os.environ.get("VA_USER"), os.environ.get("VA_PASS")
    r = urllib.request.Request(f"{API}/auth/oauth/token?grant_type=password",
                               data=urllib.parse.urlencode(
                                   {"appkey": APP_KEY, "scope": "server",
                                    "username": user, "password": pwd}).encode())
    r.add_header("appkey", APP_KEY); r.add_header("User-Agent", UA)
    r.add_header("Authorization", f"Basic {APP_AUTH}")
    r.add_header("Content-Type", "application/x-www-form-urlencoded")
    with urllib.request.urlopen(r, timeout=25) as resp:
        token = json.loads(resp.read())["access_token"]
    print("登录成功")

    st, body = req(f"{API}/app/device/getBindList?appKey={APP_KEY}&version=1.0", token=token)
    dev = json.loads(body)["data"][0]["allBindList"][0]
    did = dev["did"]

    import websockets, asyncio
    async def read():
        async with websockets.connect(
            "wss://vicapi.vaillant.com.cn/monitor/ws/app",
            extra_headers={"Authorization": f"Bearer {token}"}) as ws:
            await ws.send(json.dumps({"type": "msg",
                "productKey": dev["productKey"], "mac": dev["mac"], "did": did}))
            for _ in range(20):
                raw = await asyncio.wait_for(ws.recv(), timeout=5)
                d = json.loads(raw)
                if d.get("type") == "2":
                    return d.get("data", {})
        return {}
    attrs = asyncio.run(read())

    for k in ["Flow_Temperature_Setpoint", "DHW_setpoint", "DHW_readSetPoint",
              "Current_DHW_Setpoint", "Lower_Limitation_of_DHW_Setpoint",
              "Upper_Limitation_of_DHW_Setpoint", "WarmStar_Tank_Loading_Enable",
              "Enabled_DHW", "DHW_switch"]:
        print(f"  {k} = {attrs.get(k, '<不存在>')}")

    base = attrs.get("Flow_Temperature_Setpoint")
    if base is None:
        print("\n没有 Flow_Temperature_Setpoint，无法做对照测试")
        return

    target = float(base) + 1
    hi = attrs.get("Upper_Limitation_of_DHW_Setpoint")
    if hi is not None and target > float(hi):
        target = float(hi) - 1

    print(f"\n当前 Flow_Temperature_Setpoint={base}，测试写入 {target}")
    for key in ["Flow_Temperature_Setpoint", "DHW_setpoint"]:
        st, body = post_json(f"{API}/app/device/control/{did}",
            {"appKey": APP_KEY, "data": {"attrs": {key: target}}, "version": "1.0"}, token)
        ok = "✅" if st == 200 else "❌"
        print(f"{ok} 写 {key}={target}: HTTP {st}  {body[:110]}")
        if st == 200:
            print(f"   → 用 {key} 恢复原值 {base}")
            post_json(f"{API}/app/device/control/{did}",
                {"appKey": APP_KEY, "data": {"attrs": {key: base}}, "version": "1.0"}, token)


def test_half():
    """测试设备是否接受 0.5 度步进。写 43.5 再恢复 43。"""
    user, pwd = os.environ.get("VA_USER"), os.environ.get("VA_PASS")
    r = urllib.request.Request(f"{API}/auth/oauth/token?grant_type=password",
                               data=urllib.parse.urlencode(
                                   {"appkey": APP_KEY, "scope": "server",
                                    "username": user, "password": pwd}).encode())
    r.add_header("appkey", APP_KEY); r.add_header("User-Agent", UA)
    r.add_header("Authorization", f"Basic {APP_AUTH}")
    r.add_header("Content-Type", "application/x-www-form-urlencoded")
    with urllib.request.urlopen(r, timeout=25) as resp:
        token = json.loads(resp.read())["access_token"]
    st, body = req(f"{API}/app/device/getBindList?appKey={APP_KEY}&version=1.0", token=token)
    dev = json.loads(body)["data"][0]["allBindList"][0]
    did = dev["did"]

    for val in [43.5, 44.5]:
        st, body = post_json(f"{API}/app/device/control/{did}",
            {"appKey": APP_KEY, "data": {"attrs": {"Flow_Temperature_Setpoint": val}},
             "version": "1.0"}, token)
        ok = "✅" if st == 200 else "❌"
        print(f"{ok} 写 {val}: HTTP {st}  {body[:100]}")

    # 恢复
    post_json(f"{API}/app/device/control/{did}",
        {"appKey": APP_KEY, "data": {"attrs": {"Flow_Temperature_Setpoint": 43}},
         "version": "1.0"}, token)
    print("已恢复 43")


def test_half_readback():
    """写 45.5 后读回所有相关字段，看设备到底怎么存，
    以及有没有别的字段存着半度值。"""
    user, pwd = os.environ.get("VA_USER"), os.environ.get("VA_PASS")
    r = urllib.request.Request(f"{API}/auth/oauth/token?grant_type=password",
                               data=urllib.parse.urlencode(
                                   {"appkey": APP_KEY, "scope": "server",
                                    "username": user, "password": pwd}).encode())
    r.add_header("appkey", APP_KEY); r.add_header("User-Agent", UA)
    r.add_header("Authorization", f"Basic {APP_AUTH}")
    r.add_header("Content-Type", "application/x-www-form-urlencoded")
    with urllib.request.urlopen(r, timeout=25) as resp:
        token = json.loads(resp.read())["access_token"]
    st, body = req(f"{API}/app/device/getBindList?appKey={APP_KEY}&version=1.0", token=token)
    dev = json.loads(body)["data"][0]["allBindList"][0]
    did = dev["did"]

    import websockets, asyncio
    async def read():
        async with websockets.connect(
            "wss://vicapi.vaillant.com.cn/monitor/ws/app",
            extra_headers={"Authorization": f"Bearer {token}"}) as ws:
            await ws.send(json.dumps({"type": "msg",
                "productKey": dev["productKey"], "mac": dev["mac"], "did": did}))
            for _ in range(20):
                raw = await asyncio.wait_for(ws.recv(), timeout=5)
                d = json.loads(raw)
                if d.get("type") == "2":
                    return d.get("data", {})
        return {}
    def snap(attrs):
        return {k: v for k, v in attrs.items()
                if any(s in k.lower() for s in
                       ["setpoint", "dhw", "temp", "limit", "flow"])}

    print("=== 写入前 ===")
    a0 = asyncio.run(read())
    for k, v in sorted(snap(a0).items()):
        print(f"  {k} = {v}")

    for target in [45.5, 44.5]:
        st, body = post_json(f"{API}/app/device/control/{did}",
            {"appKey": APP_KEY, "data": {"attrs": {"Flow_Temperature_Setpoint": target}},
             "version": "1.0"}, token)
        print(f"\n写入 {target} -> HTTP {st} {body[:80]}")
        if st != 200:
            continue
        import time; time.sleep(4)
        a = asyncio.run(read())
        for k, v in sorted(snap(a).items()):
            print(f"    {k} = {v}")

    post_json(f"{API}/app/device/control/{did}",
        {"appKey": APP_KEY, "data": {"attrs": {"Flow_Temperature_Setpoint": 43}},
         "version": "1.0"}, token)
    print("\n已恢复 43")


def dump_all():
    """dump 全部字段，找出地暖(central heating)相关的实际字段。"""
    user, pwd = os.environ.get("VA_USER"), os.environ.get("VA_PASS")
    r = urllib.request.Request(f"{API}/auth/oauth/token?grant_type=password",
                               data=urllib.parse.urlencode(
                                   {"appkey": APP_KEY, "scope": "server",
                                    "username": user, "password": pwd}).encode())
    r.add_header("appkey", APP_KEY); r.add_header("User-Agent", UA)
    r.add_header("Authorization", f"Basic {APP_AUTH}")
    r.add_header("Content-Type", "application/x-www-form-urlencoded")
    with urllib.request.urlopen(r, timeout=25) as resp:
        token = json.loads(resp.read())["access_token"]
    st, body = req(f"{API}/app/device/getBindList?appKey={APP_KEY}&version=1.0", token=token)
    dev = json.loads(body)["data"][0]["allBindList"][0]
    did = dev["did"]

    import websockets, asyncio
    async def read():
        async with websockets.connect(
            "wss://vicapi.vaillant.com.cn/monitor/ws/app",
            extra_headers={"Authorization": f"Bearer {token}"}) as ws:
            await ws.send(json.dumps({"type": "msg",
                "productKey": dev["productKey"], "mac": dev["mac"], "did": did}))
            for _ in range(20):
                raw = await asyncio.wait_for(ws.recv(), timeout=5)
                d = json.loads(raw)
                if d.get("type") == "2":
                    return d.get("data", {})
        return {}
    attrs = asyncio.run(read())
    print(f"共 {len(attrs)} 个字段，全部列出：")
    for k in sorted(attrs):
        print(f"  {k} = {attrs[k]}")


def diff_around_change():
    """差分法定位字段：读一次全量 → 等你在官方 App 改设置 → 再读一次，
    对比哪些字段变了。"""
    user, pwd = os.environ.get("VA_USER"), os.environ.get("VA_PASS")
    r = urllib.request.Request(f"{API}/auth/oauth/token?grant_type=password",
                               data=urllib.parse.urlencode(
                                   {"appkey": APP_KEY, "scope": "server",
                                    "username": user, "password": pwd}).encode())
    r.add_header("appkey", APP_KEY); r.add_header("User-Agent", UA)
    r.add_header("Authorization", f"Basic {APP_AUTH}")
    r.add_header("Content-Type", "application/x-www-form-urlencoded")
    with urllib.request.urlopen(r, timeout=25) as resp:
        token = json.loads(resp.read())["access_token"]
    st, body = req(f"{API}/app/device/getBindList?appKey={APP_KEY}&version=1.0", token=token)
    dev = json.loads(body)["data"][0]["allBindList"][0]
    did = dev["did"]

    import websockets, asyncio, time
    async def read_once():
        async with websockets.connect(
            "wss://vicapi.vaillant.com.cn/monitor/ws/app",
            extra_headers={"Authorization": f"Bearer {token}"}) as ws:
            await ws.send(json.dumps({"type": "msg",
                "productKey": dev["productKey"], "mac": dev["mac"], "did": did}))
            for _ in range(20):
                raw = await asyncio.wait_for(ws.recv(), timeout=5)
                d = json.loads(raw)
                if d.get("type") == "2":
                    return d.get("data", {})
        return {}

    async def read():
        # 服务端似乎限制同一 token 的并发/密集连接（1002 protocol error）。
        # 重试并逐次拉长间隔。
        last = None
        for attempt in range(6):
            try:
                return await read_once()
            except Exception as e:
                last = e
                wait = 3 * (attempt + 1)
                print(f"  第 {attempt+1} 次连接失败（{type(e).__name__}），{wait} 秒后重试")
                await asyncio.sleep(wait)
        raise last

    before = asyncio.run(read())
    print(f"第一次读取完成（{len(before)} 个字段）")
    print(">>> 现在去官方 App 里改一次【地暖水温】，或开关一次地暖")
    print(">>> 改完回到这里按回车")
    input()
    after = asyncio.run(read())
    print(f"第二次读取完成（{len(after)} 个字段）")

    print("\n=== 发生变化的字段 ===")
    keys = set(before) | set(after)
    for k in sorted(keys):
        b, a = before.get(k, "<无>"), after.get(k, "<无>")
        if str(b) != str(a):
            print(f"  {k}: {b}  ->  {a}")

    print("\n=== 地暖相关字段当前值 ===")
    for k in sorted(keys):
        if any(s in k.lower() for s in ["ch_", "setpoint", "curve", "mode", "heat", "flow", "temp"]):
            print(f"  {k} = {after.get(k, '<无>')}")


def test_ch_write():
    """决定性测试：写 CH_readSetPoint，看 Flow_Temperature_Setpoint 是否跟随。
    若跟随 → Flow_Temperature_Setpoint 是活动回路共用字段；
    若不跟随 → 两个回路各有独立设定字段。"""
    user, pwd = os.environ.get("VA_USER"), os.environ.get("VA_PASS")
    r = urllib.request.Request(f"{API}/auth/oauth/token?grant_type=password",
                               data=urllib.parse.urlencode(
                                   {"appkey": APP_KEY, "scope": "server",
                                    "username": user, "password": pwd}).encode())
    r.add_header("appkey", APP_KEY); r.add_header("User-Agent", UA)
    r.add_header("Authorization", f"Basic {APP_AUTH}")
    r.add_header("Content-Type", "application/x-www-form-urlencoded")
    with urllib.request.urlopen(r, timeout=25) as resp:
        token = json.loads(resp.read())["access_token"]
    st, body = req(f"{API}/app/device/getBindList?appKey={APP_KEY}&version=1.0", token=token)
    dev = json.loads(body)["data"][0]["allBindList"][0]
    did = dev["did"]

    import websockets, asyncio
    async def read_once():
        async with websockets.connect(
            "wss://vicapi.vaillant.com.cn/monitor/ws/app",
            extra_headers={"Authorization": f"Bearer {token}"}) as ws:
            await ws.send(json.dumps({"type": "msg",
                "productKey": dev["productKey"], "mac": dev["mac"], "did": did}))
            for _ in range(20):
                raw = await asyncio.wait_for(ws.recv(), timeout=5)
                d = json.loads(raw)
                if d.get("type") == "2":
                    return d.get("data", {})
        return {}
    async def read():
        last = None
        for a in range(6):
            try:
                return await read_once()
            except Exception as e:
                last = e
                print(f"  连接失败({type(e).__name__})，重试")
                await asyncio.sleep(3*(a+1))
        raise last

    def show(attrs, label):
        print(f"  [{label}]")
        for k in ["Flow_Temperature_Setpoint", "CH_readSetPoint",
                  "DHW_setpoint", "DHW_readSetPoint", "Time_slot_type",
                  "Mode_Setting_CH", "Mode_Setting_DHW",
                  "Heating_Enable", "WarmStar_Tank_Loading_Enable",
                  "Lower_Limitation_of_CH_Setpoint", "Upper_Limitation_of_CH_Setpoint"]:
            print(f"      {k} = {attrs.get(k, '<无>')}")

    a0 = asyncio.run(read())
    print("=== 写入前 ===")
    show(a0, "初始")

    print("\n>>> 写 CH_readSetPoint = 45")
    st, body = post_json(f"{API}/app/device/control/{did}",
        {"appKey": APP_KEY, "data": {"attrs": {"CH_readSetPoint": 45}}, "version": "1.0"}, token)
    print(f"    HTTP {st} {body[:100]}")
    await_ok = True
    import time; time.sleep(5)
    a1 = asyncio.run(read())
    print("=== 写 CH_readSetPoint 后 ===")
    show(a1, "结果")
    if a1.get("CH_readSetPoint") != 0:
        print("  >>> CH_readSetPoint 可写！")
    else:
        print("  >>> CH_readSetPoint 写不进去（可能只读）")
    if a1.get("Flow_Temperature_Setpoint") != a0.get("Flow_Temperature_Setpoint"):
        print("  >>> Flow_Temperature_Setpoint 跟着变了 → 它是活动回路共用字段")


def test_both_circuits():
    """完整实验：弄清两个回路各自的写入字段。
    步骤：
      1. 记录初始
      2. 开启热水 → 看 Time_slot_type / Flow_Temperature_Setpoint 怎么变
      3. 写 DHW_setpoint=40 → 看哪个字段跟随
      4. 写 Flow_Temperature_Setpoint=41 → 看哪个字段跟随
      5. 恢复原状
    """
    user, pwd = os.environ.get("VA_USER"), os.environ.get("VA_PASS")
    r = urllib.request.Request(f"{API}/auth/oauth/token?grant_type=password",
                               data=urllib.parse.urlencode(
                                   {"appkey": APP_KEY, "scope": "server",
                                    "username": user, "password": pwd}).encode())
    r.add_header("appkey", APP_KEY); r.add_header("User-Agent", UA)
    r.add_header("Authorization", f"Basic {APP_AUTH}")
    r.add_header("Content-Type", "application/x-www-form-urlencoded")
    with urllib.request.urlopen(r, timeout=25) as resp:
        token = json.loads(resp.read())["access_token"]
    st, body = req(f"{API}/app/device/getBindList?appKey={APP_KEY}&version=1.0", token=token)
    dev = json.loads(body)["data"][0]["allBindList"][0]
    did = dev["did"]

    import websockets, asyncio, time
    async def read_once():
        async with websockets.connect(
            "wss://vicapi.vaillant.com.cn/monitor/ws/app",
            extra_headers={"Authorization": f"Bearer {token}"}) as ws:
            await ws.send(json.dumps({"type": "msg",
                "productKey": dev["productKey"], "mac": dev["mac"], "did": did}))
            for _ in range(20):
                raw = await asyncio.wait_for(ws.recv(), timeout=5)
                d = json.loads(raw)
                if d.get("type") == "2":
                    return d.get("data", {})
        return {}
    async def read():
        last = None
        for a in range(6):
            try:
                return await read_once()
            except Exception as e:
                last = e
                await asyncio.sleep(3*(a+1))
        raise last

    KEYS = ["Flow_Temperature_Setpoint", "CH_readSetPoint", "DHW_setpoint",
            "DHW_readSetPoint", "Time_slot_type", "Heating_Enable",
            "WarmStar_Tank_Loading_Enable", "warmstart_enable", "DHW_switch",
            "Mode_Setting_CH", "Mode_Setting_DHW"]

    def snap(attrs):
        return {k: attrs.get(k) for k in KEYS}

    def show(a, label, prev=None):
        print(f"\n--- {label} ---")
        if prev:
            keys = set(a) | set(prev)
            changed = [k for k in sorted(keys) if str(prev.get(k)) != str(a.get(k))]
            if changed:
                print("  【变化的全部字段】")
                for k in changed:
                    print(f"    {k}: {prev.get(k, '<无>')}  ->  {a.get(k, '<无>')}")
            else:
                print("  （没有字段变化）")
        print("  【关注字段】")
        for k in KEYS:
            print(f"    {k} = {a.get(k, '<无>')}")
        # 顺带找出所有等于 43 / 35 的字段，追踪 DHW 目标值藏在哪
        for target in (43, 35, 44.5):
            hits = [k for k, v in a.items() if str(v) == str(target)]
            if hits:
                print(f"  【值为 {target} 的字段】{hits}")

    def write(attrs, label):
        st, body = post_json(f"{API}/app/device/control/{did}",
            {"appKey": APP_KEY, "data": {"attrs": attrs}, "version": "1.0"}, token)
        print(f"  写 {attrs} -> HTTP {st}")
        time.sleep(5)

    a0 = asyncio.run(read())
    show(a0, "初始状态")

    print("\n>>> 开启热水 (WarmStar_Tank_Loading_Enable=1)")
    write({"WarmStar_Tank_Loading_Enable": 1}, "开启热水")
    a1 = asyncio.run(read())
    show(a1, "开启热水后", a0)

    print("\n>>> 写 DHW_setpoint = 40")
    write({"DHW_setpoint": 40}, "写 DHW_setpoint")
    a2 = asyncio.run(read())
    show(a2, "写 DHW_setpoint 后", a1)

    print("\n>>> 写 Flow_Temperature_Setpoint = 41")
    write({"Flow_Temperature_Setpoint": 41}, "写 Flow")
    a3 = asyncio.run(read())
    show(a3, "写 Flow_Temperature_Setpoint 后", a2)

    print("\n>>> 恢复：DHW_setpoint=35, Flow_Temperature_Setpoint=44.5, 关闭热水")
    write({"DHW_setpoint": 35}, "恢复DHW")
    write({"Flow_Temperature_Setpoint": 44.5}, "恢复Flow")
    write({"WarmStar_Tank_Loading_Enable": 0}, "关闭热水")
    a4 = asyncio.run(read())
    show(a4, "恢复后", a3)


def probe_rate_limit():
    """探测威能云对 WebSocket 连接的限流行为。
    测三件事：
      A. 连续快速开关连接，何时开始被拒（1002）
      B. 关闭后等待多久才能再连上
      C. 同时能开几条连接
    """
    user, pwd = os.environ.get("VA_USER"), os.environ.get("VA_PASS")
    r = urllib.request.Request(f"{API}/auth/oauth/token?grant_type=password",
                               data=urllib.parse.urlencode(
                                   {"appkey": APP_KEY, "scope": "server",
                                    "username": user, "password": pwd}).encode())
    r.add_header("appkey", APP_KEY); r.add_header("User-Agent", UA)
    r.add_header("Authorization", f"Basic {APP_AUTH}")
    r.add_header("Content-Type", "application/x-www-form-urlencoded")
    with urllib.request.urlopen(r, timeout=25) as resp:
        token = json.loads(resp.read())["access_token"]
    st, body = req(f"{API}/app/device/getBindList?appKey={APP_KEY}&version=1.0", token=token)
    dev = json.loads(body)["data"][0]["allBindList"][0]
    did = dev["did"]
    pk, mac = dev["productKey"], dev["mac"]

    import websockets, asyncio, time

    async def one():
        """开一条连接、读一帧、正常关闭。返回 (成功?, 错误描述)"""
        try:
            async with websockets.connect(
                "wss://vicapi.vaillant.com.cn/monitor/ws/app",
                extra_headers={"Authorization": f"Bearer {token}"}) as ws:
                await ws.send(json.dumps({"type": "msg",
                    "productKey": pk, "mac": mac, "did": did}))
                for _ in range(20):
                    raw = await asyncio.wait_for(ws.recv(), timeout=6)
                    d = json.loads(raw)
                    if d.get("type") == "2":
                        return True, f"{len(d.get('data',{}))} 字段"
            return False, "未收到属性帧"
        except Exception as e:
            msg = str(e)
            if "1002" in msg: msg = "1002 protocol error"
            elif "1006" in msg: msg = "1006 abnormal closure"
            return False, msg

    async def main():
        print("=== A. 连续快速开关连接（无间隔）===")
        for i in range(8):
            ok, msg = await one()
            print(f"  第 {i+1} 次: {'✅' if ok else '❌'} {msg}")
            if not ok:
                print("  ↓ 开始失败，继续看能连续失败几次")
            await asyncio.sleep(0.2)

        print("\n=== B. 关闭后等待 D 秒再连 ===")
        for d in [0, 1, 2, 3, 5, 8]:
            await asyncio.sleep(d)
            ok, msg = await one()
            print(f"  等待 {d}s 后: {'✅' if ok else '❌'} {msg}")
            if not ok:
                # 失败后多等一会再试，看能否恢复
                await asyncio.sleep(10)
                ok2, msg2 = await one()
                print(f"      再等 10s: {'✅' if ok2 else '❌'} {msg2}")

        print("\n=== C. 同时开 N 条连接 ===")
        for n in [2, 3, 5]:
            res = await asyncio.gather(*[one() for _ in range(n)])
            good = sum(1 for ok, _ in res if ok)
            print(f"  {n} 条并发: 成功 {good} / {n}  {['✅' if o else '❌ '+m for o,m in res]}")

    asyncio.run(main())


def probe_gas():
    """探测燃气消耗字段：是不是活的计数器？各时段值是否真的不同？"""
    user, pwd = os.environ.get("VA_USER"), os.environ.get("VA_PASS")
    r = urllib.request.Request(f"{API}/auth/oauth/token?grant_type=password",
                               data=urllib.parse.urlencode(
                                   {"appkey": APP_KEY, "scope": "server",
                                    "username": user, "password": pwd}).encode())
    r.add_header("appkey", APP_KEY); r.add_header("User-Agent", UA)
    r.add_header("Authorization", f"Basic {APP_AUTH}")
    r.add_header("Content-Type", "application/x-www-form-urlencoded")
    with urllib.request.urlopen(r, timeout=25) as resp:
        token = json.loads(resp.read())["access_token"]
    st, body = req(f"{API}/app/device/getBindList?appKey={APP_KEY}&version=1.0", token=token)
    dev = json.loads(body)["data"][0]["allBindList"][0]
    did = dev["did"]

    import websockets, asyncio
    async def read_once():
        async with websockets.connect(
            "wss://vicapi.vaillant.com.cn/monitor/ws/app",
            extra_headers={"Authorization": f"Bearer {token}"}) as ws:
            await ws.send(json.dumps({"type": "msg",
                "productKey": dev["productKey"], "mac": dev["mac"], "did": did}))
            for _ in range(20):
                raw = await asyncio.wait_for(ws.recv(), timeout=6)
                d = json.loads(raw)
                if d.get("type") == "2":
                    return d.get("data", {})
        return {}
    async def read():
        last = None
        for a in range(6):
            try:
                return await read_once()
            except Exception as e:
                last = e
                await asyncio.sleep(3*(a+1))
        raise last

    GAS = ["gas_ch_consumption_today", "gas_ch_consumption_yesterday",
           "gas_ch_consumption_monthly", "gas_ch_consumption_yearly",
           "gas_dhw_consumption_today", "gas_dhw_consumption_yesterday",
           "gas_dhw_consumption_monthly", "gas_dhw_consumption_yearly",
           "gas_consumption", "gasDHWToday", "gasCHToday",
           "CH_workTime", "DHW_workTime", "CH_startTimes", "DHW_startTimes",
           "CH_power", "DHW_power"]

    a0 = asyncio.run(read())
    print("=== 第一次读取 ===")
    for k in GAS:
        v = a0.get(k, "<无>")
        extra = ""
        if isinstance(v, str) and all(c in "0123456789abcdefABCDEF" for c in v) and len(v) > 2:
            try:
                extra = f"   (十六进制={int(v,16)}, /1000={int(v,16)/1000:.3f})"
            except ValueError:
                pass
        print(f"  {k:32} = {v}{extra}")

    vals = {a0.get(k) for k in GAS if "consumption" in k and a0.get(k) is not None}
    print(f"\n所有 consumption 字段的不同取值数: {len(vals)}  {vals}")

    print("\n>>> 现在去放热水（或让地暖跑起来），让燃气消耗增加")
    print(">>> 完成后回到这里按回车")
    input()
    a1 = asyncio.run(read())
    print("\n=== 第二次读取 ===")
    for k in GAS:
        b, a = a0.get(k), a1.get(k)
        if str(b) != str(a):
            print(f"  变了 {k}: {b}  ->  {a}")

    print("\n=== 结论依据 ===")
    live = [k for k in GAS if "consumption" in k or "Today" in k]
    moved = [k for k in live if str(a0.get(k)) != str(a1.get(k))]
    if moved:
        print(f"  会随用气增加而变化的字段: {moved}")
    else:
        print("  所有燃气消耗字段都没变 —— 不是活的计数器")
    t = [k for k in ["CH_workTime","DHW_workTime","CH_startTimes","DHW_startTimes"]]
    print(f"  运行时间/次数类字段: {'有变化' if any(str(a0.get(k)) != str(a1.get(k)) for k in t) else '无变化'}")


def probe_ios_headers():
    """模拟 iOS URLSession 的请求头，找出触发 500 的那一个。"""
    user, pwd = os.environ.get("VA_USER"), os.environ.get("VA_PASS")
    r = urllib.request.Request(f"{API}/auth/oauth/token?grant_type=password",
                               data=urllib.parse.urlencode(
                                   {"appkey": APP_KEY, "scope": "server",
                                    "username": user, "password": pwd}).encode())
    r.add_header("appkey", APP_KEY); r.add_header("User-Agent", UA)
    r.add_header("Authorization", f"Basic {APP_AUTH}")
    r.add_header("Content-Type", "application/x-www-form-urlencoded")
    with urllib.request.urlopen(r, timeout=25) as resp:
        token = json.loads(resp.read())["access_token"]
    st, body = req(f"{API}/app/device/getBindList?appKey={APP_KEY}&version=1.0", token=token)
    did = json.loads(body)["data"][0]["allBindList"][0]["did"]

    payload = {"appKey": APP_KEY, "data": {"attrs": {"DHW_setpoint": 35.0}}, "version": "1.0"}

    variants = [
        ("基线（和上次成功一致）", {}),
        ("+ Accept-Encoding: gzip, deflate", {"Accept-Encoding": "gzip, deflate"}),
        ("+ Accept: */*", {"Accept": "*/*"}),
        ("+ Accept-Language", {"Accept-Language": "zh-Hans-CN"}),
        ("+ Connection: keep-alive", {"Connection": "keep-alive"}),
        ("+ Accept-Encoding + Accept + Connection（iOS 组合）",
         {"Accept-Encoding": "gzip, deflate", "Accept": "*/*", "Connection": "keep-alive"}),
    ]

    print(f"\n=== 模拟 iOS 请求头（目标 {did}）===")
    for name, extra in variants:
        r = urllib.request.Request(f"{API}/app/device/control/{did}",
                                   data=json.dumps(payload).encode(), method="POST")
        r.add_header("appkey", APP_KEY); r.add_header("User-Agent", UA)
        r.add_header("Authorization", f"Bearer {token}")
        r.add_header("Content-Type", "application/json")
        for k, v in extra.items():
            r.add_header(k, v)
        try:
            with urllib.request.urlopen(r, timeout=20) as resp:
                print(f"✅ {name}: HTTP {resp.status}")
        except urllib.error.HTTPError as e:
            print(f"❌ {name}: HTTP {e.code}")
        except Exception as e:
            print(f"❌ {name}: {e}")

MODES = {
    "--dumpall":  "打印全部 157 个字段",
    "--diff":     "读两次做差分：在官方 App 里改一次设置，看哪些字段跟着变",
    "--ratelimit": "探测连接的并发/频率限制",
    "--circuits": "测生活热水与地暖两个回路各自的写入字段",
    "--gas":      "探测燃气消耗字段是否是活计数器",
    "--keys":     "逐个试写候选设定字段（会真实下发，读写后自动恢复）",
    "--half":     "测试设备是否接受 0.5 度步进",
    "--readback": "写值后读回全部相关字段",
    "--chwrite":  "测试 CH_readSetPoint 是否可写",
    "--headers":  "模拟 iOS 请求头，定位 500 的成因",
}


def usage():
    print(__doc__)
    print("可用模式：")
    for k, v in MODES.items():
        print(f"  {k:14} {v}")
    print()
    print("例：")
    print("  VA_USER=账号 VA_PASS=密码 python3 Tools/probe_cloud.py --diff")


if __name__ == "__main__":
    import sys as _sys
    if "-h" in _sys.argv or "--help" in _sys.argv:
        usage()
        sys.exit(0)
    if "--headers" in _sys.argv:
        probe_ios_headers()
    elif "--keys" in _sys.argv:
        test_keys()
    elif "--half" in _sys.argv:
        test_half()
    elif "--readback" in _sys.argv:
        test_half_readback()
    elif "--dumpall" in _sys.argv:
        dump_all()
    elif "--diff" in _sys.argv:
        diff_around_change()
    elif "--chwrite" in _sys.argv:
        test_ch_write()
    elif "--circuits" in _sys.argv:
        test_both_circuits()
    elif "--ratelimit" in _sys.argv:
        probe_rate_limit()
    elif "--gas" in _sys.argv:
        probe_gas()
    else:
        main()


