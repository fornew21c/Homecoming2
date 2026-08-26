# 버스 실시간 도착 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 다음에 탈 버스가 언제 오는지를 노선도와 잠금화면에 **절대시각**으로 적는다.

**Architecture:** 서버가 TAGO 버스도착정보를 불러 `지금 + arrtime` 을 절대시각으로 굽고
`content_state()` 에 실어 보낸다. 앱은 그 시각까지 스스로 센다 — `expectedArrival` 이
이미 쓰는 방식이라 갱신이 끊겨도 화면이 안 멈춘다. 호출은 승차 15분 전부터, 30초 캐시.

**Tech Stack:** Python 3 표준 라이브러리(서버, 의존성 없음) · unittest · SwiftUI(앱·위젯)

설계문서: [`docs/superpowers/specs/2026-08-26-bus-arrival-design.md`](../specs/2026-08-26-bus-arrival-design.md)

---

## 미리 알아야 할 것

**용어는 `귀가` 다.** 퇴근이 아니다.

**값을 짐작해서 넣지 않는다.** 이 저장소의 주석은 "실제로 이렇게 틀렸다" 를 적는
자리다. 새로 재서 알게 된 값이 있으면 날짜와 함께 적는다.

**와이어 프로토콜은 추가만 한다.** `ContentState` 에 필드를 더하면
`CodingKeys` · `init(from:)` · `encode(to:)` **세 곳**을 같이 고쳐야 한다. 빠뜨리면
값이 조용히 사라진다(`Shared/HomecomingAttributes.swift` 의 경고 주석).

**시험은 `Server` 에서 돌린다.** `cd Server && python3 -m unittest discover` — 지금 61개다.
`cd Server` 에서 돌리면 `Server/Server/` 가 생기는데 `.gitignore` 에 이미 들어 있다.

**실호출 검증은 키가 필요하다.** `source Server/.env.local` 로 `HOMECOMING_TAGO_KEY` 를
넣는다. 사내망 TLS 때문에 `Tools/hc_tls.py` 의 `context()` 를 써야 한다 — 서버 본체는
`outbound_tls()` 라는 이름으로 같은 일을 한다.

**파일을 더하면** `ruby Tools/generate_project.rb` 로 Xcode 프로젝트를 재생성한다.
이 계획은 **새 파일을 만들지 않는다** — 재생성이 필요 없다.

---

## 파일 구조

| 파일 | 하는 일 | 이 계획에서 |
|---|---|---|
| `Server/homecoming_server.py` | 서버 전부(단일 파일) | 함수 넷 추가, `nearby_stops` · `content_state` 수정 |
| `Server/test_bus_arrival.py` | 새 시험 | 생성 |
| `Shared/HomecomingAttributes.swift` | 와이어 계약 | `ContentState` 에 필드 셋 |
| `Shared/HomecomingViewParts.swift` | 노선도(`RouteStripView`) | 버스 칸에 한 줄 |
| `Widget/HomecomingViews.swift` | 잠금화면 | 진행 바 아래 한 줄 |

**서버는 단일 파일이다.** 이 저장소의 방침이니 쪼개지 않는다. 새 코드는 버스 관련
함수들(`bus_leg_waypoints` 부근) 옆에 둔다.

---

### Task 1: 정류장 조회가 `nodeid` 를 같이 준다

도착정보 API 는 `nodeId` 를 받는데 `nearby_stops()` 가 그걸 안 돌려준다. 응답에는
들어 있다(`nodeid`) — 버리고 있을 뿐이다.

**Files:**
- Modify: `Server/homecoming_server.py:1084-1092` (`nearby_stops` 의 반환 부분)
- Test: `Server/test_bus_arrival.py` (생성)

- [ ] **Step 1: 실패하는 시험을 쓴다**

`Server/test_bus_arrival.py` 를 만든다.

```python
"""버스 실시간 도착 시험 — 노선을 고르고 절대시각을 굽는다.

    cd Server && python3 -m unittest test_bus_arrival -v

**절대시각인 것이 핵심이다.** `10분 후` 로 적으면 갱신이 와야 글자가 변하는데,
정류장에 서서 기다리는 동안은 위치 보고가 멈춘다(`distanceFilter` 가 150m 인데
풍산역에서 정류장까지가 78m 다). 그 몇 분이 하필 이 값이 가장 필요한 순간이다.

의존성 없음. 표준 unittest 다.
"""

import datetime
import pathlib
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import homecoming_server as hs   # noqa: E402


def stop_row(node_id, name, lat, lon, city=31100):
    """`getCrdntPrxmtSttnList` 응답 한 줄."""
    return {"nodeid": node_id, "nodenm": name, "gpslati": lat,
            "gpslong": lon, "nodeno": None, "citycode": city}


class NearbyStopsTests(unittest.TestCase):

    def test_정류장_id_를_같이_준다(self):
        body = {"items": {"item": [stop_row("GGB219000638", "풍산역",
                                            37.67315, 126.7872167)]}}
        # **키를 같이 붙잡아야 한다.** `nearby_stops` 는 `TAGO_KEY` 가 없으면
        # 조회를 하지 않고 빈 목록으로 먼저 빠져나간다. 시험 환경에는 키가 없다.
        with mock.patch.object(hs, "TAGO_KEY", "시험용"), \
             mock.patch.object(hs, "tago_stop_body", lambda lat, lon, limit: body):
            stops = hs.nearby_stops(37.673072, 126.786906)
        self.assertEqual(stops[0]["id"], "GGB219000638")
        self.assertEqual(stops[0]["city"], 31100)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 시험이 실패하는 것을 본다**

```bash
cd Server && python3 -m unittest test_bus_arrival -v
```

기대: `AttributeError: module 'homecoming_server' has no attribute 'tago_stop_body'`

- [ ] **Step 3: HTTP 부분을 떼어내고 `id` 를 더한다**

`nearby_stops()` 안의 재시도 루프를 `tago_stop_body()` 로 뽑는다. 시험이 붙잡을
자리를 만들기 위해서다 — `bus_route_stop_names` 시험이 `new_style_get` 을 붙잡는
것과 같은 방식이다.

`Server/homecoming_server.py` 의 `nearby_stops` 를 이렇게 바꾼다.

```python
def tago_stop_body(lat, lon, limit):
    """좌표 근접 정류소 조회의 응답 본문. 실패하면 None.

    **한 번 실패로 포기하지 않는다.** 이 API 는 정상 요청에도 오류 봉투를
    섞어 보낸다(`KeyError('response')` 로 드러난다). 한 번 실패하면 정류장이
    통째로 안 보이고, 사용자에게는 "그 자리에 정류장이 없다" 로 읽힌다.

    **HTTP 를 따로 뗀 이유는 시험이다.** 시험이 이 함수만 갈아 끼우면 나머지
    고르기 로직을 망 없이 잴 수 있다.
    """
    query = urllib.parse.urlencode({
        "serviceKey": TAGO_KEY, "gpsLati": lat, "gpsLong": lon,
        # 20 미만을 넣으면 간헐적으로 오류 봉투가 온다(실측). 반경이 고정이라
        # 크게 넣어도 결과가 늘지 않으니(17개가 상한이었다) 손해가 없다.
        "numOfRows": max(20, limit), "pageNo": 1, "_type": "json",
    })
    for attempt in range(3):
        try:
            with urllib.request.urlopen(f"{TAGO_STOPS}?{query}", timeout=8,
                                        context=outbound_tls()) as response:
                return json.loads(response.read().decode("utf-8"))["response"]["body"]
        except Exception as error:                          # noqa: BLE001
            if attempt == 2:
                log(f"  정류소 조회 실패({attempt + 1}회): {error!r}")
                return None
            time.sleep(0.5)
    return None


def nearby_stops(lat, lon, limit=8):
    """이 좌표 근처의 버스정류장. 이름과 좌표를 그대로 준다.

    `cityCode` 를 안 넣어도 된다 — 좌표만으로 찾아 준다. 도시코드 표를 들고 다닐
    필요가 없다는 뜻이라, 이 API 를 쓸 수 있게 만드는 결정적인 성질이다.

    서울 시내버스 정류장은 이 데이터에 없다(서울은 별도 TOPIS 를 쓴다). 다만 서울을
    지나는 광역·경기 버스 정류장은 들어 있어서, 서울 좌표로 물어도 쓸 만한 것이 나온다.
    """
    if not TAGO_KEY:
        return []
    body = tago_stop_body(lat, lon, limit)
    if body is None:
        return []

    items = body.get("items") or {}
    rows = items.get("item") if isinstance(items, dict) else None
    if rows is None:
        return []
    rows = rows if isinstance(rows, list) else [rows]
    return [
        {"name": r["nodenm"], "lat": r["gpslati"], "lon": r["gpslong"],
         "no": r.get("nodeno"),
         # **정류장 id.** 도착정보 API(`ArvlInfoInqireService`)가 `nodeId` 로 받는다.
         # 응답에 늘 있었는데 버리고 있었다.
         "id": r.get("nodeid"),
         # 도시코드. 이름으로 정류장을 다시 찾을 때 필요하다 — 좌표만으로 찾는
         # 근접 조회는 반경이 좁아서(실측 17개) 500m 옆 정류장이 안 잡힌다.
         "city": r.get("citycode")}
        for r in rows if r.get("nodenm") and r.get("gpslati")
    ]
```

- [ ] **Step 4: 시험이 통과하는 것을 본다**

```bash
cd Server && python3 -m unittest test_bus_arrival -v
```

기대: `test_정류장_id_를_같이_준다 ... ok`

- [ ] **Step 5: 기존 시험이 그대로인지 본다**

```bash
cd Server && python3 -m unittest discover
```

기대: `OK` — 62개(기존 61 + 새 1). 실패 0.

- [ ] **Step 6: 커밋**

```bash
git add Server/homecoming_server.py Server/test_bus_arrival.py
git commit -m "정류장 조회가 nodeid 를 같이 준다 — 도착정보가 그걸로 묻는다"
```

---

### Task 2: `bus_arrival()` — 도착정보를 절대시각으로

**Files:**
- Modify: `Server/homecoming_server.py` (`bus_leg_waypoints` 뒤, `load_seoul_stops` 앞)
- Test: `Server/test_bus_arrival.py`

- [ ] **Step 1: 실패하는 시험을 쓴다**

`Server/test_bus_arrival.py` 의 `NearbyStopsTests` 아래에 붙인다.

```python
def arrival_row(route_no, seconds, stops_left):
    """`getSttnAcctoArvlPrearngeInfoList` 응답 한 줄."""
    return {"routeno": route_no, "arrtime": seconds,
            "arrprevstationcnt": stops_left, "routetp": "일반버스"}


# 2026-08-26 실측. 풍산역(GGB219000638, 고양 31100)에 오는 버스들.
PUNGSAN_ROWS = [
    arrival_row("999", 582, 6),
    arrival_row("81", 1217, 14),
    arrival_row("81", 1790, 21),
    arrival_row("87", 197, 3),
    arrival_row("96", 2326, 20),
    arrival_row("96", 402, 6),
]

# 999번을 타는 자리. `Tools/routes/commute-sample.json` 의 버스 구간 첫 점이다.
BOARD_LAT, BOARD_LON = 37.673130, 126.787047

NOW = datetime.datetime(2026, 8, 26, 18, 32, 18, tzinfo=datetime.timezone.utc)


class BusArrivalTests(unittest.TestCase):

    def setUp(self):
        hs._arrival_stops.clear()
        hs._arrival_rows.clear()

    def stops(self, *rows):
        return mock.patch.object(hs, "nearby_stops", lambda lat, lon, limit=8: list(rows))

    def near(self):
        """풍산역 정류장 셋. 가까운 순서가 아니라 섞어 둔다."""
        return self.stops(
            {"id": "GGB219001069", "name": "풍산역", "lat": 37.6734167,
             "lon": 126.7872333, "city": 31100},
            {"id": "GGB219000638", "name": "풍산역", "lat": 37.67315,
             "lon": 126.7872167, "city": 31100},
            {"id": "GGB219000608", "name": "풍산역", "lat": 37.67385,
             "lon": 126.7860333, "city": 31100},
        )

    def test_그_노선만_골라_절대시각으로_준다(self):
        with self.near(), mock.patch.object(
                hs, "tago_arrival_rows", lambda city, node: PUNGSAN_ROWS):
            got = hs.bus_arrival(BOARD_LAT, BOARD_LON, "999", now=NOW)
        self.assertEqual(got["no"], "999")
        self.assertEqual(got["stops"], 6)
        # 582초 뒤다.
        self.assertEqual(got["at"], NOW + datetime.timedelta(seconds=582))

    def test_같은_노선이_여러_대면_가장_빠른_것(self):
        with self.near(), mock.patch.object(
                hs, "tago_arrival_rows", lambda city, node: PUNGSAN_ROWS):
            got = hs.bus_arrival(BOARD_LAT, BOARD_LON, "96", now=NOW)
        # 96번은 2326초와 402초 두 대다.
        self.assertEqual(got["at"], NOW + datetime.timedelta(seconds=402))
        self.assertEqual(got["stops"], 6)

    def test_가장_가까운_정류장을_고른다(self):
        seen = []

        def rows(city, node):
            seen.append(node)
            return PUNGSAN_ROWS

        with self.near(), mock.patch.object(hs, "tago_arrival_rows", rows):
            hs.bus_arrival(BOARD_LAT, BOARD_LON, "999", now=NOW)
        # 승차 좌표에서 가장 가까운 것이 GGB219000638 이다(실측 약 15m,
        # 다음 후보가 약 32m). 목록 순서가 아니라 거리로 골라야 한다.
        self.assertEqual(seen[0], "GGB219000638")

    def test_그_노선이_안_오면_아무것도_안_준다(self):
        with self.near(), mock.patch.object(
                hs, "tago_arrival_rows", lambda city, node: PUNGSAN_ROWS):
            got = hs.bus_arrival(BOARD_LAT, BOARD_LON, "163", now=NOW)
        self.assertIsNone(got)

    def test_정류장을_못_찾으면_아무것도_안_준다(self):
        """서울 시내버스가 이 자리다 — 좌표로 물어도 빈 결과가 온다(2026-08-26 실측)."""
        with self.stops(), mock.patch.object(
                hs, "tago_arrival_rows", lambda city, node: PUNGSAN_ROWS):
            got = hs.bus_arrival(37.528330, 126.917660, "163", now=NOW)
        self.assertIsNone(got)

    def test_호출이_실패해도_터지지_않는다(self):
        with self.near(), mock.patch.object(
                hs, "tago_arrival_rows", lambda city, node: []):
            got = hs.bus_arrival(BOARD_LAT, BOARD_LON, "999", now=NOW)
        self.assertIsNone(got)

    def test_이미_지난_차는_버린다(self):
        with self.near(), mock.patch.object(
                hs, "tago_arrival_rows",
                lambda city, node: [arrival_row("999", -30, 0),
                                    arrival_row("999", 240, 2)]):
            got = hs.bus_arrival(BOARD_LAT, BOARD_LON, "999", now=NOW)
        self.assertEqual(got["at"], NOW + datetime.timedelta(seconds=240))

    def test_정류장을_한_번_고르면_다시_안_찾는다(self):
        calls = []

        def stops(lat, lon, limit=8):
            calls.append(1)
            return [{"id": "GGB219000638", "name": "풍산역", "lat": 37.67315,
                     "lon": 126.7872167, "city": 31100}]

        with mock.patch.object(hs, "nearby_stops", stops), mock.patch.object(
                hs, "tago_arrival_rows", lambda city, node: PUNGSAN_ROWS):
            hs.bus_arrival(BOARD_LAT, BOARD_LON, "999", now=NOW)
            hs.bus_arrival(BOARD_LAT, BOARD_LON, "999", now=NOW)
        self.assertEqual(len(calls), 1)
```

- [ ] **Step 2: 시험이 실패하는 것을 본다**

```bash
cd Server && python3 -m unittest test_bus_arrival -v
```

기대: `AttributeError: module 'homecoming_server' has no attribute '_arrival_stops'`

- [ ] **Step 3: 구현한다**

`Server/homecoming_server.py` 에서 `bus_leg_waypoints()` 정의가 끝난 **바로 뒤**에
넣는다(`load_seoul_stops` 위, 대략 1005번째 줄 근처).

```python
# --- 버스 실시간 도착 ------------------------------------------------------
#
# **왜 필요한가** — 경로에 적힌 `버스 10분` 은 저장할 때 잰 예정이다. 지금 그
# 버스가 어디 있다는 뜻이 아니라, 풍산역에 내리면 다른 지도 앱을 켜게 된다.
#
# **서비스가 따로다.** 정류소·노선과 같은 TAGO 인데 활용신청을 따로 받는다.
# 신청 전에는 같은 키로도 `403 SERVICE_KEY_IS_NOT_REGISTERED_ERROR` 가 온다
# (2026-08-26 에 실제로 겪었다 — 키가 죽은 줄 알기 쉽다).
#   https://www.data.go.kr/data/15098530/openapi.do
#
# **한도는 개발계정 10,000/일.** 정류소·노선 서비스(1,000)보다 열 배다.
#
# **서울 시내버스는 없다.** 163번 타는 곳(37.528330,126.917660) 좌표로 정류장을
# 조회하면 빈 결과다(2026-08-26 실측). 노선 자료의 구멍과 같은 자리다. 서울은
# 서울시 TOPIS(`ws.bus.go.kr`)에 있는데 별도 신청이 필요하다 — 지금 키로는 401 이다.
BUS_ARRIVAL = ("https://apis.data.go.kr/1613000/ArvlInfoInqireService"
               "/getSttnAcctoArvlPrearngeInfoList")

# 승차 좌표 → (도시코드, 정류장 id). 정류장은 세션 중에 바뀌지 않으니 영구 캐시다.
_arrival_stops = {}

# (도시코드, 정류장 id) → (잰 시각, 응답 줄들). 30초.
_arrival_rows = {}

# 도착정보를 얼마나 오래 재사용하는가. 짧을수록 정확하지만 호출이 는다.
# 30초면 승차 15분 전부터 한 구간에 최대 30회다(아래 `ARRIVAL_LEAD_SECONDS` 참고).
ARRIVAL_CACHE_SECONDS = 30


def tago_arrival_rows(city_code, node_id):
    """그 정류장에 오는 버스들. 실패하면 빈 목록.

    **빈 목록은 실패가 아니다.** 막차가 끊겼거나, 자료에 없는 정류장이거나,
    호출이 실패한 것이다. 부르는 쪽은 그때 값을 안 싣고 화면은 줄을 안 그린다 —
    `/bus/leg` · `/subway/leg` 와 같은 계약이다.
    """
    if not TAGO_KEY:
        return []
    query = urllib.parse.urlencode({
        "serviceKey": TAGO_KEY, "cityCode": city_code, "nodeId": node_id,
        "numOfRows": 100, "pageNo": 1, "_type": "json",
    })
    try:
        with urllib.request.urlopen(f"{BUS_ARRIVAL}?{query}", timeout=8,
                                    context=outbound_tls()) as response:
            body = json.loads(response.read().decode("utf-8"))["response"]["body"]
    except Exception as error:                              # noqa: BLE001
        log(f"  버스 도착정보 조회 실패: {error!r}")
        return []
    items = body.get("items") or {}
    rows = items.get("item") if isinstance(items, dict) else None
    if rows is None:
        return []
    return rows if isinstance(rows, list) else [rows]


def arrival_rows_cached(city_code, node_id, at):
    """`tago_arrival_rows` 를 30초 동안 재사용한다."""
    key = (city_code, node_id)
    cached = _arrival_rows.get(key)
    if cached and (at - cached[0]).total_seconds() < ARRIVAL_CACHE_SECONDS:
        return cached[1]
    rows = tago_arrival_rows(city_code, node_id)
    _arrival_rows[key] = (at, rows)
    return rows


def arrival_stop(lat, lon):
    """승차 좌표에 가장 가까운 정류장 → (도시코드, id). 못 찾으면 None.

    **같은 이름이 여럿이다.** 풍산역이라는 이름의 정류장이 다섯 곳이고 방향별로
    갈린다(2026-08-26 실측). 목록 순서를 믿지 않고 거리로 고른다 — 승차 좌표에서
    `GGB219000638` 이 약 15m, 다음 후보가 약 32m 다. `bus_leg_waypoints` 가
    좌표를 고르는 방식과 같은 규율이다.
    """
    key = (round(lat, 5), round(lon, 5))
    if key in _arrival_stops:
        return _arrival_stops[key]
    best = None
    for stop in nearby_stops(lat, lon, 20):
        if not stop.get("id") or stop.get("city") is None:
            continue
        gap = haversine(lat, lon, float(stop["lat"]), float(stop["lon"]))
        if best is None or gap < best[0]:
            best = (gap, (stop["city"], stop["id"]))
    found = best[1] if best else None
    if found:
        _arrival_stops[key] = found
    return found


def bus_arrival(lat, lon, route_no, now=None):
    """그 자리에서 탈 `route_no` 버스가 언제 오는가. 모르면 None.

    **절대시각을 돌려준다.** `몇 초 뒤` 가 아니다 — 화면이 그 글자를 그대로 들고
    있으면 갱신이 끊긴 동안 거짓말이 되기 때문이다. 정류장에 서서 기다리는 동안은
    위치 보고가 멈춘다(`distanceFilter` 가 150m 인데 풍산역에서 정류장까지가
    78m 다). 그 몇 분이 하필 이 값이 가장 필요한 순간이다.

    `expectedArrival` 이 이미 같은 규율로 쓰인다 — 절대시각을 주면 위젯이 스스로
    센다.
    """
    # 인자 이름이 모듈의 `now()` 를 가린다. 인자 이름을 바꾸면 부르는 쪽이
    # 헷갈리므로 여기서 `datetime` 을 직접 쓴다.
    at = now or datetime.now(timezone.utc)
    stop = arrival_stop(lat, lon)
    if not stop:
        return None
    city_code, node_id = stop
    want = str(route_no).strip()
    best = None
    for row in arrival_rows_cached(city_code, node_id, at):
        if str(row.get("routeno") or "").strip() != want:
            continue
        try:
            seconds = int(row.get("arrtime"))
        except (TypeError, ValueError):
            continue
        # 이미 지난 차다. 음수를 그대로 더하면 과거 시각이 나가고 화면이 0 에서
        # 멈춘 채로 남는다.
        if seconds < 0:
            continue
        if best is None or seconds < best[0]:
            best = (seconds, row)
    if best is None:
        return None
    seconds, row = best
    try:
        stops_left = int(row.get("arrprevstationcnt"))
    except (TypeError, ValueError):
        stops_left = None
    return {"no": want, "at": at + timedelta(seconds=seconds), "stops": stops_left}
```

`datetime` · `timedelta` · `timezone` 은 이미 import 되어 있다
(`homecoming_server.py:38`). 더 넣을 것이 없다.

- [ ] **Step 4: 시험이 통과하는 것을 본다**

```bash
cd Server && python3 -m unittest test_bus_arrival -v
```

기대: 9개 전부 `ok`.

- [ ] **Step 5: 전체 시험**

```bash
cd Server && python3 -m unittest discover
```

기대: `OK`, 실패 0.

- [ ] **Step 6: 실제로 한 번 불러 본다**

```bash
source Server/.env.local && python3 - <<'PY'
import pathlib, sys
sys.path.insert(0, "Server"); sys.path.insert(0, "Tools")
import homecoming_server as hs
print(hs.bus_arrival(37.673130, 126.787047, "999"))
PY
```

기대: `{'no': '999', 'at': datetime(...), 'stops': N}` 또는 막차 후면 `None`.
`403` 이 뜨면 활용신청이 안 된 것이다.

- [ ] **Step 7: 커밋**

```bash
git add Server/homecoming_server.py Server/test_bus_arrival.py
git commit -m "버스 실시간 도착을 절대시각으로 굽는다 — bus_arrival()"
```

---

### Task 3: `content_state()` 에 얹는다 — 다음 버스 구간, 15분 창

**Files:**
- Modify: `Server/homecoming_server.py:1264-1330` (`content_state`)
- Test: `Server/test_bus_arrival.py`

- [ ] **Step 1: 실패하는 시험을 쓴다**

`Server/test_bus_arrival.py` 에 붙인다.

```python
def leg(mode, starts_at, seconds, to_name, bus_no=None, lat=37.0, lon=127.0):
    out = {"mode": mode, "startsAt": starts_at, "seconds": seconds,
           "toName": to_name, "points": [[lat, lon]]}
    if bus_no:
        out["busNo"] = bus_no
    return out


# 실제 경로의 모양이다 — 도보·대기·버스·도보·지하철·도보·대기·버스·도보.
LEGS = [
    leg("walk", 0, 360, "출발역.은행앞"),
    leg("wait", 360, 180, None),
    leg("bus", 540, 540, "환승로터리", bus_no="163", lat=37.528458, lon=126.917876),
    leg("walk", 1080, 420, "서강대역"),
    leg("wait", 1500, 270, None),
    leg("subway", 1770, 1860, "풍산역"),
    leg("walk", 3630, 390, "풍산역 정류장"),
    leg("wait", 4020, 120, None),
    leg("bus", 4140, 600, "아파트단지", bus_no="999",
        lat=37.673130, lon=126.787047),
    leg("walk", 4740, 180, "집"),
]


class NextBusLegTests(unittest.TestCase):

    def test_지금_뒤의_첫_버스_구간을_고른다(self):
        # 지하철을 타는 중(progress 2000초)이면 다음 버스는 999번이다.
        found = hs.next_bus_leg(LEGS, 2000)
        self.assertEqual(found["busNo"], "999")

    def test_출발_전에는_첫_버스_구간이다(self):
        found = hs.next_bus_leg(LEGS, 0)
        self.assertEqual(found["busNo"], "163")

    def test_타고_있는_버스는_다음이_아니다(self):
        # 999번을 타는 중(progress 4300초)이면 뒤에 버스 구간이 없다.
        self.assertIsNone(hs.next_bus_leg(LEGS, 4300))

    def test_버스가_없는_경로면_없다(self):
        walk_only = [leg("walk", 0, 600, "집")]
        self.assertIsNone(hs.next_bus_leg(walk_only, 0))


class ArrivalWindowTests(unittest.TestCase):

    def setUp(self):
        hs._arrival_stops.clear()
        hs._arrival_rows.clear()

    def test_승차까지_15분_넘게_남으면_안_묻는다(self):
        asked = []
        with mock.patch.object(hs, "bus_arrival",
                               lambda *a, **k: asked.append(1)):
            # 999번 승차가 4140초인데 지금 2000초다 — 2140초(35분) 남았다.
            got = hs.bus_arrival_for(LEGS, 2000, now=NOW)
        self.assertEqual(asked, [])
        self.assertIsNone(got)

    def test_15분_안으로_들어오면_묻는다(self):
        with mock.patch.object(
                hs, "bus_arrival",
                lambda lat, lon, no, now=None: {"no": no, "at": NOW, "stops": 3}):
            # 3300초면 승차까지 840초(14분) 남았다.
            got = hs.bus_arrival_for(LEGS, 3300, now=NOW)
        self.assertEqual(got["no"], "999")
```

- [ ] **Step 2: 시험이 실패하는 것을 본다**

```bash
cd Server && python3 -m unittest test_bus_arrival -v
```

기대: `AttributeError: module 'homecoming_server' has no attribute 'next_bus_leg'`

- [ ] **Step 3: 구현한다**

`Server/homecoming_server.py` 에서 `leg_at()` 정의 **바로 뒤**(대략 1836번째 줄)에
넣는다. `leg_index_at` 옆자리가 맞다.

```python
# 승차 몇 초 전부터 도착정보를 묻는가.
#
# **그 전에는 값이 쓸모없다.** 실측에서 999번이 582초(9.7분) 뒤였고, 15분이면 그
# 앞의 다음 차까지 들어온다. 창을 넓히면 호출만 늘고 화면에는 "아직 멀었다" 만 뜬다.
#
# 호출 예산: 창 15분 × 30초 캐시 = 한 구간에 최대 30회, 버스 두 구간이면 60회.
# 한도가 10,000/일 이라 여유롭다.
ARRIVAL_LEAD_SECONDS = 15 * 60


def next_bus_leg(legs, progress):
    """지금 자리 **뒤**의 첫 버스 구간. 없으면 None.

    **타고 있는 버스는 다음이 아니다.** 이미 탄 버스가 언제 오는지는 알 필요가
    없다. 그래서 지금 구간을 포함하지 않고 그 뒤부터 본다.
    """
    if not legs:
        return None
    here = leg_index_at(legs, progress)
    for leg in legs[here + 1:]:
        if leg.get("mode") == "bus" and leg.get("busNo"):
            return leg
    return None


def bus_arrival_for(legs, progress, now=None):
    """다음 버스 구간의 실시간 도착. 창 밖이거나 모르면 None."""
    leg = next_bus_leg(legs, progress)
    if not leg:
        return None
    left = leg["startsAt"] - progress
    if left > ARRIVAL_LEAD_SECONDS:
        return None
    points = leg.get("points") or []
    if not points:
        return None
    return bus_arrival(points[0][0], points[0][1], leg["busNo"], now=now)
```

- [ ] **Step 4: 시험이 통과하는 것을 본다**

```bash
cd Server && python3 -m unittest test_bus_arrival -v
```

기대: 전부 `ok`.

- [ ] **Step 5: `content_state()` 에 얹는다**

`Server/homecoming_server.py` 의 `content_state()` 에서 `estimateSource` 를 넣는
블록 **바로 앞**에 넣는다(`return state` 직전).

```python
    # **다음에 탈 버스가 언제 오는가.** 승차 15분 전부터만 싣는다.
    #
    # **절대시각이다.** `몇 분 뒤` 로 보내면 화면이 그 글자를 들고 멈춘다 —
    # 정류장에 서서 기다리는 동안은 위치 보고가 없어서 갱신될 길이 푸시뿐이고,
    # 그 푸시가 늦는 것이 2026-08-25 에 겪은 일이다. 절대시각이면 시계가 흐른다.
    #
    # 셋 다 없을 수 있다. 서울 시내버스는 자료가 없어서 늘 없다(2026-08-26 실측).
    route = route_of(session)
    if route:
        arrival = bus_arrival_for(route["legs"], session["route_progress"] or 0)
        if arrival:
            state["busArrivalNo"] = arrival["no"]
            state["busArrivalAt"] = iso(arrival["at"])
            if arrival["stops"] is not None:
                state["busArrivalStops"] = arrival["stops"]
```

- [ ] **Step 6: 전체 시험**

```bash
cd Server && python3 -m unittest discover
```

기대: `OK`, 실패 0.

- [ ] **Step 7: 커밋**

```bash
git add Server/homecoming_server.py Server/test_bus_arrival.py
git commit -m "다음 버스 도착을 상태에 싣는다 — 승차 15분 전부터, 30초 캐시"
```

---

### Task 4: 앱 — `ContentState` 에 필드 셋

**Files:**
- Modify: `Shared/HomecomingAttributes.swift` (필드 선언 + `CodingKeys` + `init(from:)` + `encode(to:)`)

**와이어는 추가만 한다.** 네 곳을 다 고쳐야 값이 산다.

- [ ] **Step 1: 필드를 선언한다**

`ContentState` 의 `endReason` 선언 **뒤**, 구조체 안에 넣는다.

```swift
        /// 다음에 탈 버스의 노선번호. 예: `"999"`.
        ///
        /// 셋(`busArrivalNo` · `busArrivalAt` · `busArrivalStops`)은 함께 오거나
        /// 함께 없다. 서버는 승차 15분 전부터만 싣는다.
        ///
        /// **없는 것이 기본이다.** 서울 시내버스는 공공데이터에 도착정보가 없어서
        /// 163번 구간에는 영영 안 온다(2026-08-26 실측). 화면은 그때 줄을
        /// 안 그린다 — 틀린 값을 그리는 것보다 안 그리는 것이 낫다.
        var busArrivalNo: String?

        /// 그 버스가 정류장에 닿을 **절대시각**.
        ///
        /// **`몇 분 뒤` 가 아닌 이유가 이 앱의 갱신 방식이다.** 위치 보고를
        /// 일으키는 것은 시간이 아니라 150m 이동이고(`distanceFilter`), 정류장에
        /// 서서 기다리는 동안은 안 움직인다. 그동안 화면을 움직일 길은 푸시뿐인데
        /// 그게 늦으면 `10분 후` 가 8분 뒤에도 `10분 후` 다.
        ///
        /// 절대시각이면 시계가 알아서 흐른다. `expectedArrival` 이 이미 같은
        /// 이유로 절대시각이다.
        var busArrivalAt: Date?

        /// 그 버스가 몇 정류장 앞에 있는지. 모르면 nil.
        var busArrivalStops: Int?
```

- [ ] **Step 2: `CodingKeys` 에 더한다**

`case endReason` 뒤에 넣는다.

```swift
        case busArrivalNo
        case busArrivalAt
        case busArrivalStops
```

- [ ] **Step 3: `init(from:)` 에 더한다**

`endReason = ...` 줄 뒤에 넣는다. 날짜는 **`decodeWireDateIfPresent`** 다 —
`measuredAt` 과 같다.

```swift
        busArrivalNo = try container.decodeIfPresent(String.self, forKey: .busArrivalNo)
        busArrivalAt = try container.decodeWireDateIfPresent(forKey: .busArrivalAt)
        busArrivalStops = try container.decodeIfPresent(Int.self, forKey: .busArrivalStops)
```

- [ ] **Step 4: `encode(to:)` 에 더한다**

`try container.encodeIfPresent(endReason, forKey: .endReason)` 뒤에 넣는다.

```swift
        try container.encodeIfPresent(busArrivalNo, forKey: .busArrivalNo)
        try container.encodeWireIfPresent(busArrivalAt, forKey: .busArrivalAt)
        try container.encodeIfPresent(busArrivalStops, forKey: .busArrivalStops)
```

- [ ] **Step 5: 네 곳을 다 고쳤는지 센다**

```bash
grep -c "busArrival" Shared/HomecomingAttributes.swift
```

기대: **12** — 선언 3 + `CodingKeys` 3 + `init(from:)` 3 + `encode(to:)` 3.
(주석의 `busArrivalNo` 언급 때문에 더 클 수 있다. 그때는 네 블록에 각각 3개씩
있는지 눈으로 확인한다.)

- [ ] **Step 6: 컴파일된다**

```bash
xcodebuild -project Homecoming.xcodeproj -scheme Homecoming \
  -destination 'generic/platform=iOS' build 2>&1 | tail -5
```

기대: `BUILD SUCCEEDED`

- [ ] **Step 7: 커밋**

```bash
git add Shared/HomecomingAttributes.swift
git commit -m "ContentState 에 버스 도착 셋을 더한다 — 절대시각으로"
```

---

### Task 5: 앱 — 노선도의 버스 칸에 한 줄

**Files:**
- Modify: `Shared/HomecomingViewParts.swift` (`RouteStripView`, `connector(_:)` 부근)

- [ ] **Step 1: 붙일 이음을 고르는 계산값을 더한다**

`RouteStripView` 안, `legLabel(toward:)` 정의 **앞**에 넣는다.

```swift
    /// 버스 도착을 붙일 이음. 지금 자리에서 앞으로 가장 가까운 버스 구간이다.
    ///
    /// **서버가 값을 실을 때만 그린다.** 서울 시내버스는 공공데이터에 도착정보가
    /// 없어서 영영 안 온다 — 그때 이 값은 nil 이고 줄이 안 붙는다.
    ///
    /// 노선번호로 다시 맞추지 않는다. 같은 번호가 한 경로에 두 번 나오는 일이
    /// 없고, 서버는 **다음** 버스 구간의 값만 싣기 때문이다.
    private var busArrivalIndex: Int? {
        guard state.busArrivalAt != nil else { return nil }
        return shape.stops.indices.first {
            $0 >= position.index && shape.stops[$0].mode == "bus"
        }
    }

    /// "999번 18:42 도착 · 6정류장 전"
    ///
    /// **시각으로 적는다.** 남은 분으로 적으면 갱신이 끊긴 동안 그 글자가 멈춘다 —
    /// 정류장에서 기다릴 때가 정확히 그 상황이고, 하필 그때 이 값이 가장 필요하다.
    private var busArrivalNote: String? {
        guard let at = state.busArrivalAt, let no = state.busArrivalNo else { return nil }
        var line = "\(no)번 \(Self.clockText(at)) 도착"
        if let stops = state.busArrivalStops, stops > 0 {
            line += " · \(stops)정류장 전"
        }
        return line
    }

    private static let busClockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static func clockText(_ date: Date) -> String {
        busClockFormatter.string(from: date)
    }
```

- [ ] **Step 2: 이음에 줄을 그린다**

`connector(_:)` 의 `VStack(alignment: .leading, spacing: 1)` 안, `hereNote` 를
그리는 `if` **뒤**에 넣는다.

```swift
                if index == busArrivalIndex, let note = busArrivalNote {
                    Text(note)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
```

- [ ] **Step 3: 줄이 하나 더 들어갈 높이를 준다**

같은 함수의 `height` 계산을 바꾼다. 지금은 `here ? 30 : 16` 이다.

```swift
        // `here` 인 이음은 `legLabel` 과 `hereNote` 두 줄이 함께 들어갈 수 있어
        // 30, 아니면 한 줄(`legLabel`)뿐이라 16으로 좁힌다.
        //
        // 버스 도착이 붙는 이음은 줄이 하나 더 들어간다. 그 줄은 승차 15분 전부터만
        // 있으므로 평소 높이는 그대로다.
        let hasArrival = index == busArrivalIndex && busArrivalNote != nil
        let height: CGFloat = (here ? 30 : 16) + (hasArrival ? 13 : 0)
```

- [ ] **Step 4: 컴파일된다**

```bash
xcodebuild -project Homecoming.xcodeproj -scheme Homecoming \
  -destination 'generic/platform=iOS' build 2>&1 | tail -5
```

기대: `BUILD SUCCEEDED`

- [ ] **Step 5: 커밋**

```bash
git add Shared/HomecomingViewParts.swift
git commit -m "노선도의 버스 칸에 실시간 도착을 적는다"
```

---

### Task 6: 앱 — 잠금화면에 한 줄

**잠금화면에는 노선도가 없다.** `HomecomingLockScreenView` 는 압축 화면이라
`RouteStripView` 를 안 쓴다. 그래서 줄을 따로 넣는다.

**Files:**
- Modify: `Widget/HomecomingViews.swift` (`HomecomingLockScreenView`)

- [ ] **Step 1: 진행 바 아래에 줄을 넣는다**

`HomecomingLockScreenView` 의 `body` 에서 `HomecomingProgressBar(state: state)`
**바로 뒤**에 넣는다.

```swift
            // **다음에 탈 버스.** 승차 15분 전부터만 값이 오므로 평소에는 이 줄이
            // 없다. 시각으로 적는 이유는 `ContentState.busArrivalAt` 주석에 있다.
            if let no = state.busArrivalNo, let at = state.busArrivalAt {
                HStack(spacing: 4) {
                    Image(systemName: "bus.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text(Self.busArrivalLine(no: no, at: at, stops: state.busArrivalStops))
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .foregroundStyle(.white.opacity(0.75))
            }
```

- [ ] **Step 2: 문구를 만드는 함수를 더한다**

같은 파일의 `HomecomingLockScreenView` 안, `body` 뒤에 넣는다.

```swift
    /// "999번 18:42 도착 · 6정류장 전"
    ///
    /// 노선도(`RouteStripView`)와 **같은 문구**여야 한다. 두 화면이 같은 값을 다르게
    /// 적으면 어느 쪽이 참인지 알 수 없다.
    static func busArrivalLine(no: String, at: Date, stops: Int?) -> String {
        var line = "\(no)번 \(busClockFormatter.string(from: at)) 도착"
        if let stops, stops > 0 {
            line += " · \(stops)정류장 전"
        }
        return line
    }

    private static let busClockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
```

- [ ] **Step 3: 컴파일된다**

```bash
xcodebuild -project Homecoming.xcodeproj -scheme Homecoming \
  -destination 'generic/platform=iOS' build 2>&1 | tail -5
```

기대: `BUILD SUCCEEDED`

- [ ] **Step 4: 커밋**

```bash
git add Widget/HomecomingViews.swift
git commit -m "잠금화면에 다음 버스 도착을 적는다"
```

---

### Task 7: 로컬 서버로 화면을 본다

시뮬레이터는 사내망 TLS 때문에 배포 서버(HTTPS)에 못 붙는다. 로컬 서버를 띄운다.

**주의:** 로컬 서버는 공공데이터를 못 부를 때가 있다 —
`CERTIFICATE_VERIFY_FAILED: self-signed certificate`. 서버의 HTTP 호출이
`Tools/hc_tls.py` 를 안 쓰기 때문이다. 그때는 도착정보가 안 오고 줄이 안 뜬다.
**그건 이 기능의 실패가 아니다.** 배포 서버는 정상이다.

- [ ] **Step 1: 서버를 띄운다**

```bash
source Server/.env.local && python3 Server/homecoming_server.py --port 8811
```

- [ ] **Step 2: 도착정보가 실리는지 직접 본다**

`Server/homecoming_server.py` 를 띄운 채로, 저장된 경로로 세션을 하나 열고
`GET /session/active` 나 위치 보고 응답의 `content_state` 에 `busArrivalNo` 가
있는지 본다. 가장 빠른 길은 서버 로그다 — `bus_arrival` 이 부르는 것이 보인다.

- [ ] **Step 3: 시뮬레이터에서 화면을 본다**

```bash
xcrun simctl launch <device> com.kona.homecoming2 -homecomingBackend http://localhost:8811
```

**`xcrun simctl launch` 가 인자를 씹는 것을 이미 두 번 봤다.** 빠지면 배포
서버(HTTPS)로 붙어 TLS 오류가 난다. 로그에서 `localhost:8811` 을 확인하고,
아니면 다시 띄운다.

- [ ] **Step 4: 확인할 것**

- 999번 구간에 `999번 HH:MM 도착` 이 붙는가
- **163번 구간에는 안 붙는가** — 서울은 자료가 없다. 붙으면 버그다
- 승차까지 15분 넘게 남았을 때는 안 붙는가
- 잠금화면에도 같은 문구가 뜨는가

---

### Task 8: 실기기 실주행으로 잰다

**이 기능은 이 한 번으로 검증된다.** 시뮬레이터에서는 진짜 시각·진짜 버스가 없다.

- [ ] **Step 1: 실기기에 설치한다**

`Woncheol's iphone`(iPhone 14 Pro Max). `c-122` 는 iOS 16.5.1 이라 안 들어간다.

- [ ] **Step 2: 배포한다**

```bash
railway up --detach --service homecoming2
```

- [ ] **Step 3: 귀가하며 본다**

- 풍산역에 가까워질 때 `999번 HH:MM 도착` 이 뜨는가
- **그 시각이 실제 도착과 맞는가.** 어긋나면 몇 분인지 적는다
- 정류장에서 기다리는 동안 **문구가 멈추지 않는가**(시계가 흐르는가)
- 163번 구간에는 안 뜨는가

- [ ] **Step 4: 어긋나면 로그를 되짚는다**

시각을 기억해 두고 배포 로그를 그 창으로 본다. **서버는 UTC 로 찍는다**(KST − 9시간).

```bash
railway logs --service 14494695-8eee-4f32-a4ea-3e0a4bcfd785 \
  --since <ISO> --until <ISO> --lines 5000 --json
```

- [ ] **Step 5: 인계문서를 갱신한다**

`docs/HANDOFF-2026-08-26.md` 옆에 새 인계문서를 쓰거나 이어 적는다. 실주행에서
**잰 값**을 적는다 — 도착 시각이 몇 분 어긋났는지, 호출이 몇 번 나갔는지.

`CLAUDE.md` 의 "먼저 읽을 것" 에 새 문서를 건다.

---

## 나중에 — 서울 버스

키가 열리면 붙는다. 갈아 끼울 자리는 둘이다.

- `arrival_stop(lat, lon)` — 서울은 `ws.bus.go.kr/api/rest/stationinfo/getStationByPos`
  가 `arsId` 를 준다
- `tago_arrival_rows(city, node)` — 서울은
  `ws.bus.go.kr/api/rest/stationinfo/getStationByUid?arsId=` 가 그 정류장에 오는
  버스를 다 준다. 응답이 XML 이고 `rtNm`(노선번호) · `arrmsg1` 를 쓴다

**`arrmsg1` 은 `3분54초후[2번째 전]` 같은 문자열이다.** TAGO 의 `arrtime`(초)과
모양이 다르니 초로 바꾸는 함수가 하나 더 필요하다. 그 값을 재기 전에는 형식을
단정하지 않는다 — 키가 열리면 먼저 한 번 불러 실제 문자열을 본다.

`bus_arrival()` 위쪽 로직(가장 빠른 차 고르기, 절대시각으로 굽기)은 그대로 쓴다.
