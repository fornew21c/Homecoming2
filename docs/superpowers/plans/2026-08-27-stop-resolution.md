# 이름만으로 정류장을 정한다 — 구현 계획 (서버)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 좌표 없이 **노선번호와 정류장 이름만으로** 버스 구간의 승차·하차 정류장을 정하고, `/bus/leg` 응답에 후보로 실어 보낸다.

**Architecture:** 경기도 GBIS 의 `노선 → 경유정류소` 조회(기둥 단위 id·좌표·순서)를 붙여, 이름을 그 목록 안에서 찾는다. 승차 `seq` < 하차 `seq` 로 방향을 가린다. 서울은 이미 있는 TOPIS 목록으로 같은 모양을 만든다. 새 엔드포인트를 만들지 않고 `/bus/leg` 에 얹는다 — 저장소 규칙 `와이어 프로토콜은 추가만 한다`.

**Tech Stack:** Python 3 표준 라이브러리만(`urllib`, `json`, `unittest`). 의존성 추가 없음. 설계 문서는 [`../specs/2026-08-27-stop-resolution-design.md`](../specs/2026-08-27-stop-resolution-design.md).

**범위 밖 (다음 계획):** 앱이 이 값을 쓰는 것. **서버만 고치면 화면은 안 바뀐다** — 그건 이 저장소가 여러 번 당한 함정이라 별도 계획으로 분리했다. 실제 응답을 눈으로 본 뒤에 쓴다.

---

## 파일 구조

| 파일 | 무엇을 맡나 |
|---|---|
| `Server/homecoming_server.py` (수정) | GBIS 호출·캐시, 이름 대조, 구간 정류장 고르기, `/bus/leg` 핸들러 |
| `Server/test_leg_stops.py` (신규) | 위 전부의 시험. 네트워크는 전부 막는다 |

기존 파일에 얹는 이유 — 이 저장소는 서버가 한 파일이다. 새 모듈로 쪼개면 그 관례를 혼자 깬다. 새 코드는 `# --- 경기도 GBIS ---` 구역으로 묶어 `# --- 서울 버스 실시간 도착 ---` 바로 앞에 둔다.

## 실측해 둔 값 (2026-08-27, 이 계획이 기대는 사실)

```
resultCode  0 정상 · 4 "결과가 존재하지 않습니다"(msgBody 자체가 없다)
999 노선   3개 — 218000111(고양) · 200000013(수원,용인,화성) · N999
218000111  경유정류소 92개, stationSeq 1~92, 중복 0개
풍산역     20753 = stationId 219000638 = TAGO GGB219000638, seq 13
반대 기둥   58271 = 219001069, 같은 노선인데 seq 78
이름 표기   자료는 `위시티1.3단지`(점). `위시티1,3단지`(쉼표)로 물으면 0건
```

---

### Task 1: GBIS 호출 껍데기

**Files:**
- Modify: `Server/homecoming_server.py:1092` — `# --- 서울 버스 실시간 도착 ---` 주석 블록 **바로 앞**에 새 구역을 넣는다
- Test: `Server/test_leg_stops.py` (신규)

- [ ] **Step 1: 실패하는 시험을 쓴다**

`Server/test_leg_stops.py` 를 새로 만든다:

```python
"""이름만으로 버스 구간의 승차·하차 정류장을 정하는 것들의 시험.

    cd Server && python3 -m unittest test_leg_stops -v

**네트워크를 타지 않는다.** GBIS 응답을 고정해 두고 고르는 규칙만 본다.
실제로 되는지는 시험이 아니라 실측이 말한다(계획 Task 8).

의존성 없음. 표준 unittest 다.
"""

import pathlib
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import homecoming_server as hs   # noqa: E402


def envelope(code, body=None):
    """GBIS 응답 봉투. `resultCode` 4 는 msgBody 가 아예 없다(2026-08-27 실측)."""
    inner = {"msgHeader": {"resultCode": code, "resultMessage": ""}}
    if body is not None:
        inner["msgBody"] = body
    return {"response": inner}


class GbisGetTests(unittest.TestCase):

    def call(self, payload):
        """`urlopen` 을 막고 정해진 JSON 을 돌려준다."""
        import io
        import json as _json

        def fake(_url, timeout=None, context=None):
            # `BytesIO` 는 그 자체로 컨텍스트 매니저다 — `with` 가 그대로 된다.
            return io.BytesIO(_json.dumps(payload).encode("utf-8"))

        with mock.patch.object(hs.urllib.request, "urlopen", fake):
            return hs.gbis_get("busrouteservice/v2/getBusRouteListv2", {"keyword": "999"})

    def test_정상이면_msgBody_를_준다(self):
        got = self.call(envelope(0, {"busRouteList": [{"routeId": 1}]}))
        self.assertEqual(got, {"busRouteList": [{"routeId": 1}]})

    def test_결과가_없으면_빈_dict_다_실패가_아니다(self):
        self.assertEqual(self.call(envelope(4)), {})

    def test_호출이_터지면_None_이다(self):
        def boom(*_a, **_k):
            raise OSError("끊김")
        with mock.patch.object(hs.urllib.request, "urlopen", boom):
            self.assertIsNone(hs.gbis_get("x", {}))


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 실패를 확인한다**

Run: `cd Server && python3 -m unittest test_leg_stops -v`
Expected: FAIL — `AttributeError: module 'homecoming_server' has no attribute 'gbis_get'`

- [ ] **Step 3: 최소 구현**

`Server/homecoming_server.py`, `# --- 서울 버스 실시간 도착 ---` 블록 바로 앞에 넣는다:

```python
# --- 경기도 GBIS ------------------------------------------------------------
#
# **왜 TAGO 말고 이것인가.** TAGO 에는 "노선 하나로 그 노선 정류장 전부" 라는 호출이
# 없다. 정류장을 주면 거기 오는 노선이 온다 — 방향이 반대다. 그래서 이름만 있을 때
# 어느 기둥인지 정할 근거가 없었다. 풍산역은 기둥이 넷이고 999는 그중 둘에만 선다.
#
# GBIS 에는 그 호출이 있다(`getBusRouteStationListv2`). 게다가 **정류소 id 가 TAGO 와
# 같은 번호다** — TAGO `GGB219000638` = GBIS `219000638`(2026-08-27, 기둥 5개 확인).
# 갈아타는 것이 아니라 덧붙이는 것이다.
#
# 공공데이터포털 같은 키를 쓴다. 활용신청은 서비스마다 따로다(2026-08-27 승인).
GBIS = "https://apis.data.go.kr/6410000"

_gbis_routes = {}         # 노선번호 → [노선id, ...]
_gbis_route_stops = {}    # 노선id → [정류소, ...]


def gbis_get(path, params):
    """GBIS 호출. 실패는 None, 결과 없음은 빈 dict.

    **둘을 갈라야 한다.** 결과 없음을 실패로 읽으면 다음 노선 후보로 안 넘어가고,
    실패를 결과 없음으로 읽으면 캐시에 빈 값이 박힌다.

        resultCode 0   정상. `msgBody` 가 온다
        resultCode 4   "결과가 존재하지 않습니다". **`msgBody` 자체가 없다**
                       (2026-08-27 실측 — `위시티1,3단지` 로 물으면 이렇게 온다)
    """
    query = urllib.parse.urlencode({"serviceKey": TAGO_KEY, "format": "json", **params})
    try:
        with urllib.request.urlopen(f"{GBIS}/{path}?{query}", timeout=15,
                                    context=outbound_tls()) as response:
            body = json.loads(response.read().decode("utf-8"))
    except Exception as error:                                  # noqa: BLE001
        log(f"  GBIS {path} 실패: {error!r}")
        return None
    inner = body.get("response") or {}
    code = str((inner.get("msgHeader") or {}).get("resultCode", ""))
    if code == "4":
        return {}
    if code != "0":
        log(f"  GBIS {path} resultCode={code}")
        return None
    return inner.get("msgBody") or {}
```

- [ ] **Step 4: 통과를 확인한다**

Run: `cd Server && python3 -m unittest test_leg_stops -v`
Expected: PASS — 3개

- [ ] **Step 5: 기존 시험이 안 깨졌는지 본다**

Run: `cd Server && python3 -m unittest discover`
Expected: OK — 107개 + 3개

- [ ] **Step 6: 커밋**

```bash
git add Server/homecoming_server.py Server/test_leg_stops.py
git commit -m "경기도 GBIS 호출을 붙인다 — 결과 없음과 실패를 가른다"
```

---

### Task 2: 노선번호 → 노선 id

**Files:**
- Modify: `Server/homecoming_server.py` — Task 1 이 만든 구역 끝
- Test: `Server/test_leg_stops.py`

- [ ] **Step 1: 실패하는 시험을 쓴다**

`Server/test_leg_stops.py` 의 `GbisGetTests` 아래에 붙인다:

```python
class GbisRouteIdsTests(unittest.TestCase):

    def setUp(self):
        hs._gbis_routes.clear()

    def reply(self, body):
        return mock.patch.object(hs, "gbis_get", lambda _p, _q: body)

    def test_번호가_정확히_같은_것만_받는다(self):
        # `999` 로 물으면 `N999` 도 같이 온다(2026-08-27 실측).
        with self.reply({"busRouteList": [
            {"routeId": 218000111, "routeName": 999},
            {"routeId": 200000013, "routeName": 999},
            {"routeId": 218000168, "routeName": "N999"},
        ]}):
            self.assertEqual(hs.gbis_route_ids("999"), ["218000111", "200000013"])

    def test_결과가_없으면_빈_목록이다(self):
        with self.reply({}):
            self.assertEqual(hs.gbis_route_ids("없는번호"), [])

    def test_한_번_찾은_것은_다시_묻지_않는다(self):
        calls = []

        def get(_p, _q):
            calls.append(1)
            return {"busRouteList": [{"routeId": 1, "routeName": "66"}]}

        with mock.patch.object(hs, "gbis_get", get):
            hs.gbis_route_ids("66")
            hs.gbis_route_ids("66")
        self.assertEqual(len(calls), 1, "두 번째는 요청을 내면 안 된다")

    def test_실패는_캐시하지_않는다(self):
        calls = []

        def get(_p, _q):
            calls.append(1)
            return None

        with mock.patch.object(hs, "gbis_get", get):
            self.assertEqual(hs.gbis_route_ids("66"), [])
            self.assertEqual(hs.gbis_route_ids("66"), [])
        self.assertEqual(len(calls), 2, "실패한 조회는 다음에 다시 물어야 한다")
```

- [ ] **Step 2: 실패를 확인한다**

Run: `cd Server && python3 -m unittest test_leg_stops -v`
Expected: FAIL — `AttributeError: ... 'gbis_route_ids'`

- [ ] **Step 3: 최소 구현**

Task 1 코드 바로 아래에 넣는다:

```python
def gbis_route_ids(route_no):
    """그 번호를 쓰는 경기도 노선 id 들. 순서는 자료가 준 그대로.

    **같은 번호가 여럿이다** — 999 는 고양(218000111)과 수원·용인·화성
    (200000013) 둘이다(2026-08-27 실측). 여기서 고르지 않는다. **고르는 것은
    정류장 이름이 한다** — 두 이름이 다 들어 있는 노선만 뒤에서 살아남는다.
    `bus_route_stop_names` 가 이미 같은 방법을 쓴다.

    `keyword` 는 부분일치라 `999` 로 물으면 `N999` 도 온다. 번호가 정확히
    같은 것만 받는다.
    """
    key = str(route_no).strip()
    if key in _gbis_routes:
        return _gbis_routes[key]
    body = gbis_get("busrouteservice/v2/getBusRouteListv2", {"keyword": key})
    if body is None:
        return []                  # **실패는 캐시하지 않는다.** 다음에 다시 묻는다
    ids = [str(row["routeId"]) for row in body.get("busRouteList") or []
           if row.get("routeId") and str(row.get("routeName") or "").strip() == key]
    _gbis_routes[key] = ids
    return ids
```

- [ ] **Step 4: 통과를 확인한다**

Run: `cd Server && python3 -m unittest test_leg_stops -v`
Expected: PASS — 7개

- [ ] **Step 5: 커밋**

```bash
git add Server/homecoming_server.py Server/test_leg_stops.py
git commit -m "노선번호로 경기도 노선 id 를 찾는다 — N999 를 999 로 읽지 않는다"
```

---

### Task 3: 노선 id → 경유정류소

**Files:**
- Modify: `Server/homecoming_server.py` — Task 2 코드 아래
- Test: `Server/test_leg_stops.py`

- [ ] **Step 1: 실패하는 시험을 쓴다**

```python
class GbisRouteStopsTests(unittest.TestCase):

    def setUp(self):
        hs._gbis_route_stops.clear()

    def test_순서대로_좌표까지_준다(self):
        body = {"busRouteStationList": [
            {"stationSeq": 14, "stationId": 219000605, "mobileNo": " 20576",
             "stationName": "애니골입구", "y": "37.67435", "x": "126.7919667"},
            {"stationSeq": 13, "stationId": 219000638, "mobileNo": " 20753",
             "stationName": "풍산역", "y": "37.67315", "x": "126.7872167"},
        ]}
        with mock.patch.object(hs, "gbis_get", lambda _p, _q: body):
            stops = hs.gbis_route_stops("218000111")
        self.assertEqual([s["seq"] for s in stops], [13, 14])
        self.assertEqual(stops[0], {"id": "GGB219000638", "no": "20753",
                                    "name": "풍산역", "lat": 37.67315,
                                    "lon": 126.7872167, "seq": 13})

    def test_id_는_TAGO_와_같은_모양이다(self):
        # TAGO 는 GGB219000638, GBIS 는 219000638 — 같은 번호다(2026-08-27 확인).
        body = {"busRouteStationList": [
            {"stationSeq": 1, "stationId": 219000638, "mobileNo": "20753",
             "stationName": "풍산역", "y": "37.67315", "x": "126.78722"},
        ]}
        with mock.patch.object(hs, "gbis_get", lambda _p, _q: body):
            self.assertEqual(hs.gbis_route_stops("x")[0]["id"], "GGB219000638")

    def test_망가진_줄은_건너뛴다(self):
        body = {"busRouteStationList": [
            {"stationSeq": 1, "stationId": 219000638, "stationName": "풍산역",
             "y": "37.67315", "x": "126.78722"},
            {"stationSeq": 2, "stationId": 219000605, "stationName": "좌표없음"},
        ]}
        with mock.patch.object(hs, "gbis_get", lambda _p, _q: body):
            stops = hs.gbis_route_stops("x")
        self.assertEqual([s["name"] for s in stops], ["풍산역"])

    def test_한_번_찾은_것은_다시_묻지_않는다(self):
        calls = []

        def get(_p, _q):
            calls.append(1)
            return {"busRouteStationList": []}

        with mock.patch.object(hs, "gbis_get", get):
            hs.gbis_route_stops("x")
            hs.gbis_route_stops("x")
        self.assertEqual(len(calls), 1)
```

- [ ] **Step 2: 실패를 확인한다**

Run: `cd Server && python3 -m unittest test_leg_stops -v`
Expected: FAIL — `AttributeError: ... 'gbis_route_stops'`

- [ ] **Step 3: 최소 구현**

```python
def gbis_route_stops(route_id):
    """그 노선의 경유정류소 — 순서대로, 기둥 단위로, 좌표까지.

    돌려주는 것: `[{"id", "no", "name", "lat", "lon", "seq"}, ...]`

    **`id` 에 `GGB` 를 붙인다.** 저장된 경로와 도착 조회가 TAGO id 를 쓰는데,
    TAGO `GGB219000638` 과 GBIS `219000638` 이 같은 번호다(2026-08-27, 기둥
    5개 확인). 같은 모양으로 맞춰 두면 뒤에서 견줄 수 있다.

    999(218000111)는 92개가 `stationSeq` 1~92 로 온다. **같은 정류소가 두 번
    나오는 노선은 없었다** — 999 · 7770 · 7780 · 7790 등 7개에서 중복 0개
    (2026-08-27). 그래서 `seq` 로 방향을 가려도 무너지지 않는다.
    """
    key = str(route_id)
    if key in _gbis_route_stops:
        return _gbis_route_stops[key]
    body = gbis_get("busrouteservice/v2/getBusRouteStationListv2", {"routeId": key})
    if body is None:
        return []                  # 실패는 캐시하지 않는다
    stops = []
    for row in body.get("busRouteStationList") or []:
        # **줄 하나가 망가졌다고 노선을 버리지 않는다.** 다만 조용히 채우지도
        # 않는다 — 좌표가 없는 정류소는 후보가 될 수 없으므로 빼는 것이 맞다.
        try:
            stops.append({
                "id": f"GGB{row['stationId']}",
                "no": str(row.get("mobileNo") or "").strip() or None,
                "name": row["stationName"],
                "lat": float(row["y"]),
                "lon": float(row["x"]),
                "seq": int(row["stationSeq"]),
            })
        except (KeyError, TypeError, ValueError):
            continue
    stops.sort(key=lambda stop: stop["seq"])
    _gbis_route_stops[key] = stops
    return stops
```

- [ ] **Step 4: 통과를 확인한다**

Run: `cd Server && python3 -m unittest test_leg_stops -v`
Expected: PASS — 11개

- [ ] **Step 5: 커밋**

```bash
git add Server/homecoming_server.py Server/test_leg_stops.py
git commit -m "노선의 경유정류소를 기둥 단위로 받는다 — id 를 TAGO 모양으로 맞춘다"
```

---

### Task 4: 이름 대조

**Files:**
- Modify: `Server/homecoming_server.py:1291` — 기존 `n_eq` 를 `name_key` 위에 다시 세운다
- Modify: `Server/homecoming_server.py` — Task 3 코드 아래에 `stops_named`
- Test: `Server/test_leg_stops.py`

- [ ] **Step 1: 실패하는 시험을 쓴다**

```python
class StopsNamedTests(unittest.TestCase):

    STOPS = [
        {"id": "a", "no": "20572", "name": "저동중고교", "lat": 0, "lon": 0, "seq": 11},
        {"id": "b", "no": "20753", "name": "풍산역", "lat": 0, "lon": 0, "seq": 13},
        {"id": "c", "no": "20486", "name": "풍산역2번출구", "lat": 0, "lon": 0, "seq": 14},
        {"id": "d", "no": "20795", "name": "위시티1.3단지", "lat": 0, "lon": 0, "seq": 20},
    ]

    def test_완전일치가_하나면_그것만(self):
        got = hs.stops_named(self.STOPS, "풍산역")
        self.assertEqual([s["no"] for s in got], ["20753"])

    def test_쉼표와_점을_같게_본다(self):
        # 저장된 이름은 `위시티1,3단지`, 자료는 `위시티1.3단지` 다(2026-08-27).
        got = hs.stops_named(self.STOPS, "위시티1,3단지")
        self.assertEqual([s["no"] for s in got], ["20795"])

    def test_접미어가_붙어도_찾는다(self):
        # 사용자가 `풍산역 버스정류장` 이라고 적는다. 자료는 `풍산역` 이다.
        got = hs.stops_named(self.STOPS, "풍산역 버스정류장")
        self.assertEqual([s["no"] for s in got], ["20753"])

    def test_여럿이면_줄이지_않고_다_준다(self):
        got = hs.stops_named(self.STOPS, "풍산")
        self.assertEqual(sorted(s["no"] for s in got), ["20486", "20753"])

    def test_없으면_빈_목록이다(self):
        self.assertEqual(hs.stops_named(self.STOPS, "서울역"), [])

    def test_빈_이름은_빈_목록이다(self):
        self.assertEqual(hs.stops_named(self.STOPS, ""), [])
        self.assertEqual(hs.stops_named(self.STOPS, None), [])


class NameKeyTests(unittest.TestCase):

    def test_점_쉼표_공백_가운뎃점을_지운다(self):
        self.assertEqual(hs.name_key("위시티1, 3단지"), "위시티13단지")
        self.assertEqual(hs.name_key("밤가시7.8단지·광림교회"), "밤가시78단지광림교회")

    def test_n_eq_는_그대로_동작한다(self):
        self.assertTrue(hs.n_eq("아파트 단지", "아파트단지"))
        self.assertFalse(hs.n_eq("풍산역", "마두역"))
```

- [ ] **Step 2: 실패를 확인한다**

Run: `cd Server && python3 -m unittest test_leg_stops -v`
Expected: FAIL — `AttributeError: ... 'stops_named'`

- [ ] **Step 3: 기존 `n_eq` 를 `name_key` 위에 다시 세운다**

`Server/homecoming_server.py:1291` 의 기존 `n_eq` 를 **통째로 아래로 바꾼다.** 주석은 살린다:

```python
def name_key(name):
    """정류장 이름 비교용 열쇠. 점·쉼표·공백·가운뎃점을 지운다.

    같은 정류장을 자료마다 다르게 적는다 — `아파트 단지` 와 `아파트단지`,
    `위시티1,3단지`(사용자가 적은 것)와 `위시티1.3단지`(자료). 쉼표로 그대로
    물으면 결과가 0건이다(2026-08-27 실측).
    """
    return (name or "").translate(str.maketrans("", "", " .,·"))


def n_eq(a, b):
    """정류장 이름 비교. 표기 차이를 흡수한다."""
    return name_key(a) == name_key(b)
```

- [ ] **Step 4: `stops_named` 를 Task 3 코드 아래에 넣는다**

**정의 순서에 놀라지 말 것.** `stops_named` 는 파일에서 `:1092` 앞에 놓이고
`name_key` 는 `:1291` 에 있다 — 뒤에 정의된 함수를 앞에서 부른다. 파이썬은
부를 때 찾으므로 문제가 없고, 이 파일이 이미 그렇게 되어 있다
(`seoul_bus_arrival` 이 `:1358` 의 `SEOUL_STOPS` 를 쓴다).

```python
def stops_named(stops, name):
    """이름으로 정류소 후보를 고른다. 못 찾으면 빈 목록.

    **하나로 줄이지 않는다.** 완전일치가 정확히 하나면 결과도 하나가 되고,
    그때만 부르는 쪽이 확정으로 쓴다. 그 밖에는 후보를 그대로 준다.

    줄이면 안 되는 이유 — 이름이 세 갈래다. 사용자가 적은 것(`풍산역
    버스정류장`), 자료의 것(`풍산역`), 길찾기 앱의 것. 지금 코드에는 이름
    매칭이 실패하면 **좌표 근처 정류장으로 폴백**하는 안전망이 있는데
    (`bus_leg_waypoints`), 좌표를 안 받는 길에는 그 안전망이 없다. 여기서
    억지로 하나를 고르면 그게 곧 조용히 틀린 값이 된다.
    """
    want = name_key(name)
    if not want:
        return []
    exact = [stop for stop in stops if name_key(stop["name"]) == want]
    if exact:
        return exact
    return [stop for stop in stops
            if want in name_key(stop["name"]) or name_key(stop["name"]) in want]
```

- [ ] **Step 5: 통과를 확인한다**

Run: `cd Server && python3 -m unittest test_leg_stops -v`
Expected: PASS — 19개

- [ ] **Step 6: `n_eq` 를 쓰는 기존 시험이 안 깨졌는지 본다**

Run: `cd Server && python3 -m unittest discover`
Expected: OK — 107개 + 19개

- [ ] **Step 7: 커밋**

```bash
git add Server/homecoming_server.py Server/test_leg_stops.py
git commit -m "이름 대조를 name_key 로 모은다 — 위시티1,3단지 를 위시티1.3단지 로 찾는다"
```

---

### Task 5: 구간의 승차·하차 정류장 (경기)

**Files:**
- Modify: `Server/homecoming_server.py` — Task 4 의 `stops_named` 아래
- Test: `Server/test_leg_stops.py`

- [ ] **Step 1: 실패하는 시험을 쓴다**

```python
def stop(no, name, seq, sid=None):
    return {"id": sid or f"GGB{no}", "no": no, "name": name,
            "lat": 37.0, "lon": 127.0, "seq": seq}


# 999 고양 방면 — 풍산역(20753) seq 13, 위시티1.3단지 seq 20.
GOYANG_999 = [
    stop("20572", "저동중고교", 11),
    stop("58261", "밤가시7.8단지.광림교회", 12),
    stop("20753", "풍산역", 13),
    stop("20576", "애니골입구", 14),
    stop("20795", "위시티1.3단지", 20),
]

# 반대 방향으로만 도는 노선 — 하차가 승차보다 앞이다.
GOYANG_999_REVERSE = [
    stop("20795", "위시티1.3단지", 60),
    stop("58271", "풍산역", 78),
]


class BusLegStopsTests(unittest.TestCase):

    def setUp(self):
        hs._gbis_routes.clear()
        hs._gbis_route_stops.clear()

    def routes(self, table):
        """노선id → 정류소 목록. `gbis_route_ids` 는 그 키들을 순서대로 준다."""
        ids = list(table)
        return [
            mock.patch.object(hs, "gbis_route_ids", lambda _no, _i=ids: _i),
            mock.patch.object(hs, "gbis_route_stops", lambda rid: table[rid]),
        ]

    def run_with(self, table, route_no, from_name, to_name):
        patches = self.routes(table)
        for p in patches:
            p.start()
        try:
            return hs.bus_leg_stops(route_no, from_name, to_name)
        finally:
            for p in patches:
                p.stop()

    def test_승차와_하차를_집는다(self):
        got = self.run_with({"218000111": GOYANG_999}, "999",
                            "풍산역 버스정류장", "위시티1,3단지")
        self.assertEqual([s["no"] for s in got["boarding"]], ["20753"])
        self.assertEqual([s["no"] for s in got["alighting"]], ["20795"])

    def test_반대_방향_기둥은_안_집는다(self):
        # 58271 은 같은 999 인데 하차보다 뒤에 있다(seq 78 > 60). 그 방향이 아니다.
        got = self.run_with({"218000111": GOYANG_999_REVERSE}, "999",
                            "풍산역", "위시티1.3단지")
        self.assertEqual(got, {"boarding": [], "alighting": []})

    def test_두_이름이_다_있는_노선만_받는다(self):
        # 999 는 고양과 수원에 있다. 수원 노선에는 이 이름이 없다.
        suwon = [stop("11111", "수원역", 1), stop("22222", "영통", 2)]
        got = self.run_with({"200000013": suwon, "218000111": GOYANG_999},
                            "999", "풍산역", "위시티1.3단지")
        self.assertEqual([s["no"] for s in got["boarding"]], ["20753"])

    def test_후보가_여럿이면_다_준다(self):
        many = [stop("20753", "풍산역", 13), stop("20486", "풍산역2번출구", 14),
                stop("20795", "위시티1.3단지", 20)]
        got = self.run_with({"218000111": many}, "999", "풍산", "위시티1.3단지")
        self.assertEqual(sorted(s["no"] for s in got["boarding"]),
                         ["20486", "20753"])

    def test_못_찾으면_빈_목록이다_오류가_아니다(self):
        got = self.run_with({"218000111": GOYANG_999}, "999", "163번 대기", "집")
        self.assertEqual(got, {"boarding": [], "alighting": []})
```

- [ ] **Step 2: 실패를 확인한다**

Run: `cd Server && python3 -m unittest test_leg_stops -v`
Expected: FAIL — `AttributeError: ... 'bus_leg_stops'`

- [ ] **Step 3: 최소 구현**

`stops_named` 아래에 넣는다:

```python
def pick_leg_stops(stops, from_name, to_name):
    """정류소 목록에서 승차·하차 후보를 고른다. 방향이 안 맞으면 None.

    **순서가 방향이다.** 길 양쪽 기둥이 같은 노선인데 `seq` 가 다르다 —
    풍산역 20753 은 13(신원중학교행), 58271 은 78(대화역행)이다(2026-08-27
    실측). 승차가 하차보다 앞에 있는 쌍만 그 방향이다. **짐작이 아니라 순서로
    정해진다.**

    None 은 "이 노선이 아니다" 이고, 부르는 쪽이 다음 후보 노선으로 넘어간다.
    """
    boarding = stops_named(stops, from_name)
    alighting = stops_named(stops, to_name)
    pairs = [(b, a) for b in boarding for a in alighting if b["seq"] < a["seq"]]
    if not pairs:
        return None

    def uniq(rows):
        seen, out = set(), []
        for row in rows:
            if row["id"] not in seen:
                seen.add(row["id"])
                out.append(row)
        return out

    return {"boarding": uniq([b for b, _ in pairs]),
            "alighting": uniq([a for _, a in pairs])}


def bus_leg_stops(route_no, from_name, to_name):
    """이름만으로 버스 구간의 승차·하차 정류소를 정한다. **좌표를 안 쓴다.**

    돌려주는 것: `{"boarding": [...], "alighting": [...]}` — 못 찾으면 둘 다 빈
    목록이다. **빈 것은 실패가 아니다.** `toName` 은 원래 표시용 자유 문구라
    (`163번 대기` 같은 것도 들어간다) 못 찾는 것이 정상인 경우가 있다.
    `points: []` 가 이미 "그릴 것이 없다" 로 쓰이는 것과 같은 계약이다.

    **후보가 정확히 하나일 때만 확정이다.** 그 규칙은 부르는 쪽에 있다 —
    여기서는 찾은 것을 그대로 준다.
    """
    empty = {"boarding": [], "alighting": []}
    if not str(route_no or "").strip():
        return empty
    for route_id in gbis_route_ids(route_no):
        stops = gbis_route_stops(route_id)
        if not stops:
            continue
        picked = pick_leg_stops(stops, from_name, to_name)
        if picked:
            return picked
    return empty
```

- [ ] **Step 4: 통과를 확인한다**

Run: `cd Server && python3 -m unittest test_leg_stops -v`
Expected: PASS — 24개

- [ ] **Step 5: 커밋**

```bash
git add Server/homecoming_server.py Server/test_leg_stops.py
git commit -m "이름만으로 승차·하차 정류장을 정한다 — 순서로 방향을 가린다"
```

---

### Task 6: 서울도 같은 모양으로

**Files:**
- Modify: `Server/homecoming_server.py` — `seoul_bus_arrival`(`:1166`) 이 끝나는 자리, `def bus_arrival`(`:1230`) 바로 앞
- Test: `Server/test_leg_stops.py`

- [ ] **Step 1: 실패하는 시험을 쓴다**

```python
class SeoulLegStopsTests(unittest.TestCase):

    # `seoul-stops.json` 의 한 줄 모양: [이름, 위도, 경도, arsId]
    STOPS_TABLE = [
        ["국회의사당역.KB국민은행", 37.528491, 126.918087, "19003"],
        ["신촌로터리", 37.555000, 126.936000, "14204"],
        ["엉뚱한곳", 37.400000, 127.000000, "99999"],
    ]

    def items(self, rows):
        """TOPIS 응답 항목 대신 (arsId, staOrd) 로 흉내낸다."""
        import xml.etree.ElementTree as ET
        out = []
        for ars, order in rows:
            item = ET.Element("itemList")
            ET.SubElement(item, "arsId").text = ars
            ET.SubElement(item, "staOrd").text = str(order)
            out.append(item)
        return out

    def run_with(self, rows, from_name, to_name):
        patches = [
            mock.patch.object(hs, "SEOUL_STOPS", self.STOPS_TABLE),
            mock.patch.object(hs, "seoul_routes", lambda: {"163": ["100100032"]}),
            mock.patch.object(hs, "seoul_arrival_items_cached",
                              lambda _rid, _at: self.items(rows)),
        ]
        for p in patches:
            p.start()
        try:
            return hs.seoul_leg_stops("163", from_name, to_name)
        finally:
            for p in patches:
                p.stop()

    def test_승차와_하차를_집는다(self):
        got = self.run_with([("19003", 5), ("14204", 12), ("99999", 30)],
                            "국회의사당역.KB국민은행", "신촌로터리")
        self.assertEqual([s["no"] for s in got["boarding"]], ["19003"])
        self.assertEqual([s["no"] for s in got["alighting"]], ["14204"])

    def test_방향이_뒤집히면_안_집는다(self):
        got = self.run_with([("14204", 5), ("19003", 12)],
                            "국회의사당역.KB국민은행", "신촌로터리")
        self.assertEqual(got, {"boarding": [], "alighting": []})

    def test_목록이_비면_빈_결과다_오류가_아니다(self):
        # 차가 안 다니는 시간에 도착정보가 빌 수 있다(Task 8 에서 실측한다).
        got = self.run_with([], "국회의사당역.KB국민은행", "신촌로터리")
        self.assertEqual(got, {"boarding": [], "alighting": []})
```

- [ ] **Step 2: 실패를 확인한다**

Run: `cd Server && python3 -m unittest test_leg_stops -v`
Expected: FAIL — `AttributeError: ... 'seoul_leg_stops'`

- [ ] **Step 3: 최소 구현**

`seoul_bus_arrival` 바로 아래에 넣는다:

```python
def seoul_leg_stops(route_no, from_name, to_name):
    """서울 노선의 승차·하차 정류장. `bus_leg_stops` 와 **같은 모양**을 돌려준다.

    **정류장 목록을 도착정보 호출에서 얻는다.** 경기(`getBusRouteStationListv2`)와
    성격이 다르다 — 그쪽은 시간과 무관한 노선 자료인데, 이쪽은 지금 오는 차를
    묻는 김에 정류장이 딸려 오는 것이다. **차가 안 다니는 시간에 비는지는 실측이
    필요하다**(계획 Task 8). 비면 그 시간대에 후보를 못 주고, 그건 빈 결과이지
    틀린 값이 아니다.

    `staOrd` 가 경기의 `seq` 와 같은 자리를 한다 — 노선 안에서의 순서다.
    """
    empty = {"boarding": [], "alighting": []}
    want = str(route_no or "").strip()
    if not want:
        return empty
    at = datetime.now(timezone.utc)
    index = {row[3]: row for row in SEOUL_STOPS if len(row) > 3 and row[3]}
    for route_id in seoul_routes().get(want) or []:
        stops = []
        for item in seoul_arrival_items_cached(route_id, at):
            ars = _tag(item, "arsId")
            row = index.get(ars)
            if not row:
                continue
            try:
                seq = int(_tag(item, "staOrd"))
            except ValueError:
                continue
            stops.append({"id": ars, "no": ars, "name": row[0],
                          "lat": row[1], "lon": row[2], "seq": seq})
        if not stops:
            continue
        stops.sort(key=lambda stop: stop["seq"])
        picked = pick_leg_stops(stops, from_name, to_name)
        if picked:
            return picked
    return empty
```

- [ ] **Step 4: 통과를 확인한다**

Run: `cd Server && python3 -m unittest test_leg_stops -v`
Expected: PASS — 27개

- [ ] **Step 5: 커밋**

```bash
git add Server/homecoming_server.py Server/test_leg_stops.py
git commit -m "서울 구간도 이름만으로 정류장을 정한다 — 경기와 같은 모양"
```

---

### Task 7: `/bus/leg` 에 얹는다

**Files:**
- Modify: `Server/homecoming_server.py:2868-2885` — `/bus/leg` 핸들러
- Test: `Server/test_leg_stops.py`

- [ ] **Step 1: 실패하는 시험을 쓴다**

```python
class BusLegResolveTests(unittest.TestCase):
    """핸들러가 부르는 합성 함수. 경기를 먼저 보고 없으면 서울로 넘어간다."""

    def test_경기에서_찾으면_그것을_쓴다(self):
        gyeonggi = {"boarding": [stop("20753", "풍산역", 13)], "alighting": []}
        with mock.patch.object(hs, "bus_leg_stops", lambda *_a: gyeonggi), \
             mock.patch.object(hs, "seoul_leg_stops", lambda *_a: 1 / 0):
            got = hs.leg_stops("999", "풍산역", "위시티1.3단지")
        self.assertEqual(got, gyeonggi)

    def test_경기에_없으면_서울로_넘어간다(self):
        empty = {"boarding": [], "alighting": []}
        seoul = {"boarding": [{"id": "19003", "no": "19003", "name": "국회의사당역.KB국민은행",
                               "lat": 37.5, "lon": 126.9, "seq": 5}],
                 "alighting": []}
        with mock.patch.object(hs, "bus_leg_stops", lambda *_a: empty), \
             mock.patch.object(hs, "seoul_leg_stops", lambda *_a: seoul):
            got = hs.leg_stops("163", "국회의사당역.KB국민은행", "신촌로터리")
        self.assertEqual(got, seoul)
```

- [ ] **Step 2: 실패를 확인한다**

Run: `cd Server && python3 -m unittest test_leg_stops -v`
Expected: FAIL — `AttributeError: ... 'leg_stops'`

- [ ] **Step 3: 합성 함수를 넣는다**

`seoul_leg_stops` 바로 아래:

```python
def leg_stops(route_no, from_name, to_name):
    """버스 구간의 승차·하차 정류장 — 경기를 먼저 보고, 없으면 서울.

    `bus_arrival` 이 이미 같은 순서로 넘긴다(TAGO 에서 못 찾으면 TOPIS).
    같은 순서를 쓰면 두 자리가 어긋나지 않는다.
    """
    picked = bus_leg_stops(route_no, from_name, to_name)
    if picked["boarding"] or picked["alighting"]:
        return picked
    return seoul_leg_stops(route_no, from_name, to_name)
```

- [ ] **Step 4: 핸들러를 고친다**

`Server/homecoming_server.py:2868` 부터의 블록에서, 좌표 파싱을 **선택으로** 바꾸고 응답에 정류장을 더한다. 아래가 바뀐 전체 블록이다:

```python
        if path.startswith("/bus/leg"):
            query = urllib.parse.parse_qs(urllib.parse.urlparse(path).query)
            route_no = (query.get("no", [""])[0] or "").strip()
            to_name = (query.get("to", [""])[0] or "").strip()
            from_name = (query.get("from", [""])[0] or "").strip() or None
            if not route_no or not to_name:
                return self.reply(400, {"error": "no/to 가 필요합니다"})

            # **좌표는 이제 선택이다.** 있으면 지금까지처럼 좌표열을 그리고, 없으면
            # 이름만으로 정류장을 찾는다. 옛 앱은 늘 보내므로 동작이 그대로다.
            from_lat = from_lon = None
            if query.get("fromLat") and query.get("fromLon"):
                try:
                    from_lat = float(query["fromLat"][0])
                    from_lon = float(query["fromLon"][0])
                except ValueError:
                    return self.reply(400, {"error": "fromLat/fromLon 이 숫자가 아닙니다"})

            points, missing = [], []
            if from_lat is not None:
                points, missing = bus_leg_waypoints(route_no, from_lat, from_lon,
                                                    to_name, from_name)
            picked = leg_stops(route_no, from_name, to_name)
            note = f" · 좌표 못 찾음 {missing}" if missing else ""
            log(f"  버스 {route_no} {from_name or '?'} → {to_name}: "
                f"경유 정류장 {len(points)}개{note} · "
                f"승차 후보 {len(picked['boarding'])}개 "
                f"하차 후보 {len(picked['alighting'])}개")
            return self.reply(200, {"points": points, "missing": missing,
                                    "boarding": picked["boarding"],
                                    "alighting": picked["alighting"]})
```

- [ ] **Step 5: 통과를 확인한다**

Run: `cd Server && python3 -m unittest test_leg_stops -v`
Expected: PASS — 29개

- [ ] **Step 6: 기존 시험 전부**

Run: `cd Server && python3 -m unittest discover`
Expected: OK — 107개 + 29개

- [ ] **Step 7: 커밋**

```bash
git add Server/homecoming_server.py Server/test_leg_stops.py
git commit -m "/bus/leg 이 좌표 없이도 답하고 정류장 후보를 함께 준다"
```

---

### Task 8: 실측 — 시험이 말해 주지 않는 것

**시험만으로는 되는지 모른다.** 시험 환경에 `TAGO_KEY` 가 없어 조회가 즉시 빠져나간다. 이 저장소가 그렇게 세 번 속았다.

**Files:** 없음. 확인만 한다. 어긋나면 그때 고칠 곳을 정한다.

- [ ] **Step 1: 로컬 서버를 띄운다**

```bash
source Server/.env.local
python3 Server/homecoming_server.py --port 8811
```

- [ ] **Step 2: 좌표 없이 999 구간을 묻는다 — 정답을 안다**

```bash
curl -s 'http://localhost:8811/bus/leg?no=999&from=%ED%92%8D%EC%82%B0%EC%97%AD%20%EB%B2%84%EC%8A%A4%EC%A0%95%EB%A5%98%EC%9E%A5&to=%EC%9C%84%EC%8B%9C%ED%8B%B01,3%EB%8B%A8%EC%A7%80' | python3 -m json.tool
```

Expected: `boarding` 이 **1개**이고 `no` 가 **`20753`**, `seq` 13. `alighting` 은 `위시티1.3단지`.
**`58271` 이 나오면 방향 판정이 틀린 것이다** — `pick_leg_stops` 의 `seq` 비교를 본다.

- [ ] **Step 3: 좌표를 함께 보내면 예전과 똑같은지 본다**

```bash
curl -s 'http://localhost:8811/bus/leg?no=999&from=%ED%92%8D%EC%82%B0%EC%97%AD%20%EB%B2%84%EC%8A%A4%EC%A0%95%EB%A5%98%EC%9E%A5&to=%EC%9C%84%EC%8B%9C%ED%8B%B01,3%EB%8B%A8%EC%A7%80&fromLat=37.673180&fromLon=126.787167' | python3 -c 'import json,sys; d=json.load(sys.stdin); print("points", len(d["points"]))'
```

Expected: `points 8` — 배포 로그의 값과 같다(`경유 정류장 8개`). **다르면 기존 동작을 깬 것이다.**

- [ ] **Step 4: 서울 163 구간을 묻는다**

```bash
curl -s 'http://localhost:8811/bus/leg?no=163&from=%EA%B5%AD%ED%9A%8C%EC%9D%98%EC%82%AC%EB%8B%B9%EC%97%AD.KB%EA%B5%AD%EB%AF%BC%EC%9D%80%ED%96%89&to=%EC%8B%A0%EC%B4%8C%EB%A1%9C%ED%84%B0%EB%A6%AC' | python3 -m json.tool
```

Expected: `points` 는 빈 배열(서울 노선은 TAGO 에 없다 — 지금과 같다). `boarding` 에 국회의사당역 정류장이 온다.

- [ ] **Step 5: 서울이 차 안 다니는 시간에도 목록을 주는지 잰다**

설계 문서가 열어 둔 하나다. **심야 노선을 낮에 물으면 같은 상태가 된다.**

```bash
python3 - <<'PY'
import json, pathlib, urllib.parse, urllib.request
import xml.etree.ElementTree as ET
root = pathlib.Path("Server/data/seoul-routes.json")
routes = json.loads(root.read_text(encoding="utf-8"))
key = [l.strip().removeprefix("export ").split("=", 1)[1].strip().strip("\"'")
       for l in open("Server/.env.local") if "HOMECOMING_TAGO_KEY=" in l][0]
for no in [k for k in routes if k.upper().startswith("N")][:3]:
    rid = routes[no][0]
    q = urllib.parse.urlencode({"serviceKey": key, "busRouteId": rid})
    req = urllib.request.Request(
        f"http://ws.bus.go.kr/api/rest/arrive/getArrInfoByRouteAll?{q}",
        headers={"User-Agent": "homecoming2"})
    with urllib.request.urlopen(req, timeout=20) as resp:
        items = ET.fromstring(resp.read()).findall(".//itemList")
    print(f"{no}: 정류장 {len(items)}개")
PY
```

Expected 둘 중 하나 —
- **정류장이 온다** → 서울도 시간과 무관하다. 설계 문서의 `열어 둔 것` 을 지우고 그렇게 적는다
- **0개다** → 새벽·비운행 시간에는 서울 후보를 못 준다. 설계 문서와 `seoul_leg_stops` 주석에 **실측값으로** 적는다. 이 계획에서 고치지는 않는다 — 빈 결과는 틀린 값이 아니다

- [ ] **Step 6: 재 본 값을 문서에 적는다**

`docs/superpowers/specs/2026-08-27-stop-resolution-design.md` 의 `## 열어 둔 것` 을 Step 5 결과로 바꾼다. **짐작이 아니라 잰 값을 적는다.**

- [ ] **Step 7: 커밋**

```bash
git add docs/superpowers/specs/2026-08-27-stop-resolution-design.md
git commit -m "서울 정류장 목록이 비운행 시간에 어떻게 오는지 실측해 적는다"
```

---

## 다 끝났을 때

```bash
cd Server && python3 -m unittest discover     # 136개 (107 + 29)
python3 Tools/verify-progress-sync.py         # 진행도는 안 건드렸다. 그대로여야 한다
```

**앱은 아직 아무것도 안 바뀐다.** `/bus/leg` 응답에 필드가 늘었을 뿐이고 앱은 그걸 안 읽는다. 그게 이 계획의 의도다 — 다음 계획에서 실제 응답을 보고 앱을 붙인다.
