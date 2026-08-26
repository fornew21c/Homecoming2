# 지하철 폴리라인 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 지하철 구간을 두 역 직선이 아니라 **사이 역들을 거치는 꺾은선**으로 그려, 저장된 경로가 실제 선로에서 1,994m까지 벌어지던 것을 없앤다.

**Architecture:** 전국도시철도역사 자료를 한 번 받아 `Server/data/subway-lines.json` 으로 굽는다. 서버가 `GET /subway/leg?from=&to=` 로 사이 역 좌표열을 주고, 앱 `RouteTracer` 가 그걸 이어 보간한다. 못 찾으면 지금처럼 직선을 그리고 **그 사실을 화면에 적는다.** `GET /bus/leg` 와 같은 구조·같은 자리다.

**Tech Stack:** Python 3 표준 라이브러리만(`zipfile`·`xml.etree`·`json`·`unittest`), Swift 5.9 / SwiftUI, MapKit.

설계: [`docs/superpowers/specs/2026-08-26-subway-polyline-design.md`](../specs/2026-08-26-subway-polyline-design.md)

---

## 파일 구조

| 파일 | 책임 |
|---|---|
| `Tools/subway-lines.py` (새로) | XLSX → `Server/data/subway-lines.json` 굽기 |
| `Server/data/subway-lines.json` (생성물, 커밋함) | 노선번호별 역 목록 |
| `Server/homecoming_server.py` (고침) | `subway_leg_stops()` + `GET /subway/leg` |
| `Server/test_subway_leg.py` (새로) | 구간 고르기 시험 |
| `App/Route/RouteClient.swift` (고침) | `subwayWaypoints(from:to:)` |
| `App/Route/RouteTracer.swift` (고침) | 지하철 구간을 역 좌표로 잇기, `subwayFallbacks` |
| `App/Route/RouteEditor*.swift` (고침) | 폴백 안내에 지하철 포함 |
| `Tools/verify-subway-shape.py` (새로) | 성적표 — 직선 대비 벌어짐을 잰다 |

---

## Task 1: 자료를 굽는다

**Files:**
- Create: `Tools/subway-lines.py`
- Create: `Server/data/subway-lines.json` (도구가 만든다)

- [ ] **Step 1: 자료를 받는다**

```bash
cd /Users/wch.heo/Documents/Claude/Projects/Homecoming2
curl -sL -o /tmp/subway.xlsx \
  "https://data.kric.go.kr/rips/dataset/download.file?type=filedata&id=32&operation=1"
file /tmp/subway.xlsx
```

Expected: `Microsoft Excel 2007+`, 약 313KB.

- [ ] **Step 2: 도구를 쓴다**

`Tools/subway-lines.py` 를 만든다.

```python
#!/usr/bin/env python3
"""전국도시철도역사 자료를 지하철 폴리라인용 표로 굽는다.

    python3 Tools/subway-lines.py ~/Downloads/전국도시철도역사정보표준데이터.xlsx

**왜 필요한가.** 지하철 구간은 두 역 좌표를 잇는 직선으로 저장된다. 실제 선로는
직선이 아니라서, 서강대 → 풍산에서 저장된 선이 실제 노선에서 **1,994m** 까지
벌어진다(2026-08-26 실측). 이탈 문턱이 1,000m 라 정상 귀가가 이탈로 오판된다.

**왜 런타임 API 가 아닌가.** 역 정보는 자주 안 바뀐다. 매번 물어 일일 한도·사내망
TLS·응답 지연을 치를 이유가 없다. `Server/data/seoul-stops.json` 과 같은 판단이다.

**왜 직접 안 받는가.** 레일포털의 파일 주소가 안정적인지 확인하지 못했다. 확인 안 된
주소를 코드에 박으면 어느 날 조용히 빈 파일이 된다. 받는 주소는 위 docstring 이 아니라
`docs/superpowers/specs/2026-08-26-subway-polyline-design.md` 에 적혀 있다.

의존성 없음. 서버와 같은 방침이다.
"""

import json
import pathlib
import sys
import xml.etree.ElementTree as ET
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "Server" / "data" / "subway-lines.json"
NS = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"


def read_sheet(path):
    """XLSX 첫 시트를 {열이름: 값} 목록으로.

    **셀 주소로 읽는다. 위치로 읽으면 안 된다.** XLSX 는 빈 칸을 아예 안 적어서,
    셀을 나온 순서대로 세면 열이 밀린다. 그렇게 읽고 "좌표 없는 행이 661개" 라는
    틀린 값을 한 번 얻었다(2026-08-26). 실제로는 하나도 없다.
    """
    book = zipfile.ZipFile(path)
    shared = [
        "".join(t.text or "" for t in si.iter(f"{NS}t"))
        for si in ET.fromstring(book.read("xl/sharedStrings.xml")).findall(f"{NS}si")
    ]
    rows = []
    for row in ET.fromstring(book.read("xl/worksheets/sheet1.xml")).iter(f"{NS}row"):
        cells = {}
        for cell in row.findall(f"{NS}c"):
            value = cell.find(f"{NS}v")
            column = "".join(ch for ch in cell.get("r", "") if ch.isalpha())
            if value is None:
                cells[column] = ""
            elif cell.get("t") == "s":
                cells[column] = shared[int(value.text)]
            else:
                cells[column] = value.text
        rows.append(cells)
    if not rows:
        return []
    column_of = {name: col for col, name in rows[0].items()}
    return [{name: row.get(col, "") for name, col in column_of.items()} for row in rows[1:]]


def build(rows):
    """노선번호 → {이름, 역[]}. 역은 역번호 순이다.

    **노선명이 아니라 노선번호로 묶는다.** `1호선` 은 서울에도 부산에도 있다.
    이름으로 묶으면 두 도시의 역이 한 노선에 섞인다.

    **노선을 거르지 않는다.** 역번호는 노선 전체가 아니라 블록 안에서만 순서다 —
    경의중앙선은 지선(서울역·신촌)과 옛 코드 블록 때문에 전체를 한 줄로 세우면
    되돌아간다. 그 판단은 구간을 고르는 서버가 한다(`subway_leg_stops`).
    """
    lines = {}
    for row in rows:
        try:
            lat = float(row["역위도"])
            lon = float(row["역경도"])
        except (KeyError, ValueError, TypeError):
            continue
        line = lines.setdefault(row["노선번호"], {"이름": row["노선명"], "역": []})
        line["역"].append({
            "번호": row["역번호"],
            "이름": row["역사명"],
            "lat": round(lat, 6),
            "lon": round(lon, 6),
        })
    for line in lines.values():
        line["역"].sort(key=lambda s: s["번호"])
    return dict(sorted(lines.items()))


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 1
    rows = read_sheet(sys.argv[1])
    lines = build(rows)
    stations = sum(len(v["역"]) for v in lines.values())
    OUT.write_text(
        json.dumps(lines, ensure_ascii=False, indent=1, sort_keys=True) + "\n",
        encoding="utf-8")
    print(f"노선 {len(lines)}개 · 역 {stations}개 → {OUT.relative_to(ROOT)} "
          f"({OUT.stat().st_size // 1024}KB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 3: 돌려서 값을 확인한다**

```bash
python3 Tools/subway-lines.py /tmp/subway.xlsx
```

Expected: `노선 51개 · 역 1099개 → Server/data/subway-lines.json (…KB)`

노선 51 · 역 1099 가 아니면 멈추고 자료를 다시 본다. 이 숫자는 2026-08-26 에 잰 값이다.

- [ ] **Step 4: 경의중앙선이 제대로 들어갔는지 본다**

```bash
python3 -c "
import json
d = json.load(open('Server/data/subway-lines.json'))
line = d['I4108']
print(line['이름'], len(line['역']), '역')
names = [s['이름'] for s in line['역'] if '1263' <= s['번호'] <= '1274']
print(' → '.join(names))
"
```

Expected:
```
경의중앙선 51 역
서강대역 → 홍대입구역 → 가좌역 → 디지털미디어시티역 → 수색역 → 한국항공대 → 강매역 → 행신역 → 능곡역 → 곡산역 → 백마역 → 풍산역
```

- [ ] **Step 5: 커밋**

```bash
git add Tools/subway-lines.py Server/data/subway-lines.json
git commit -m "지하철 역 좌표를 자료에서 구워 둔다 — 노선 51개 · 역 1,099개"
```

---

## Task 2: 서버가 구간을 고른다

**Files:**
- Create: `Server/test_subway_leg.py`
- Modify: `Server/homecoming_server.py` (`BUS_SGG` 아래, `/bus/leg` 관련 함수들 옆)

- [ ] **Step 1: 실패하는 시험을 쓴다**

`Server/test_subway_leg.py`:

```python
"""subway_leg_stops() 시험 — 두 역 사이의 역들을 순서대로 고른다.

    cd Server && python3 -m unittest test_subway_leg -v

**역번호는 노선 전체가 아니라 블록 안에서만 순서다.** 경의중앙선은 지선(서울역·
신촌)과 옛 코드 블록 때문에 전체를 한 줄로 세우면 되돌아간다. 그래서 구간을 고른
뒤 **되돌아가는지 검사한다** — 경로 길이가 직선거리의 몇 배인지 본다.

의존성 없음. 표준 unittest 다.
"""

import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import homecoming_server as hs   # noqa: E402


class SubwayLegTests(unittest.TestCase):

    def test_같은_블록이면_사이_역을_순서대로_준다(self):
        line, stops = hs.subway_leg_stops("서강대역", "풍산역")
        self.assertEqual(line, "경의중앙선")
        names = [s["name"] for s in stops]
        self.assertEqual(names[0], "서강대역")
        self.assertEqual(names[-1], "풍산역")
        self.assertIn("행신역", names)
        self.assertIn("디지털미디어시티역", names)
        self.assertEqual(len(names), 12)

    def test_순서가_뒤집혀_있어도_방향을_맞춘다(self):
        _, stops = hs.subway_leg_stops("풍산역", "서강대역")
        names = [s["name"] for s in stops]
        self.assertEqual(names[0], "풍산역")
        self.assertEqual(names[-1], "서강대역")

    def test_이름_끝의_역은_있어도_없어도_찾는다(self):
        """앱의 경로는 `서강대학교`·`풍산역` 인데 자료는 `서강대역`·`풍산역` 이다."""
        line, stops = hs.subway_leg_stops("서강대", "풍산")
        self.assertEqual(line, "경의중앙선")
        self.assertEqual(len(stops), 12)

    def test_없는_역이면_빈_결과다(self):
        line, stops = hs.subway_leg_stops("없는역", "풍산역")
        self.assertIsNone(line)
        self.assertEqual(stops, [])

    def test_블록을_넘으면_빈_결과다(self):
        """지평(1220)과 신촌(1252)은 같은 노선번호지만 이어지지 않는다 —
        그 사이를 역번호로 고르면 58km 를 건너뛴다."""
        line, stops = hs.subway_leg_stops("지평역", "신촌역")
        self.assertIsNone(line)
        self.assertEqual(stops, [])


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 실패를 확인한다**

```bash
cd Server && python3 -m unittest test_subway_leg -v
```

Expected: `AttributeError: module 'homecoming_server' has no attribute 'subway_leg_stops'` 로 5개 모두 실패.

- [ ] **Step 3: 최소 구현**

`Server/homecoming_server.py` 의 `BUS_SGG` 블록 **아래**, `def bus_opr_ymd()` **위**에 넣는다.

```python
# ------------------------------------------------------------------ 지하철

SUBWAY_LINES_PATH = pathlib.Path(__file__).resolve().parent / "data" / "subway-lines.json"
_subway_lines = None

# 고른 구간이 **되돌아가는지** 보는 문턱. 경로 길이 / 두 끝 직선거리.
#
# 역번호는 노선 전체가 아니라 블록 안에서만 순서다(설계문서 참고). 블록을 넘어
# 고르면 노선 밖으로 나갔다 돌아오느라 이 비가 폭발한다 — 경의중앙선에서 지평 →
# 신촌은 58km 를 건너뛴다. 정상 구간은 1에 가깝다(서강대 → 풍산이 19.5/18.7 =
# **1.04**, 2026-08-26 실측).
#
# 2.0 은 여유다. 실제 노선도 곧게 가지는 않는다.
SUBWAY_DETOUR_LIMIT = 2.0


def subway_lines():
    """구워 둔 역 표. 한 번 읽고 들고 있는다."""
    global _subway_lines
    if _subway_lines is None:
        try:
            _subway_lines = json.loads(SUBWAY_LINES_PATH.read_text(encoding="utf-8"))
        except OSError:
            log("  지하철 역 표가 없다 — 지하철 구간은 직선으로 그려진다")
            _subway_lines = {}
    return _subway_lines


def _station_key(name):
    """이름을 맞추기 위한 정규화. 공백·가운뎃점을 빼고 끝의 `역` 을 뗀다.

    앱의 경로는 `서강대학교`·`풍산역` 인데 자료의 역사명은 `서강대역`·`풍산역` 이다.
    버스의 `stops_by_name` 이 같은 문제를 같은 방법으로 풀었다.
    """
    key = "".join(name.split()).replace("·", "").replace(".", "")
    return key[:-1] if key.endswith("역") and len(key) > 1 else key


def _find_station(stations, name):
    """정규화해서 같은 것을 먼저, 없으면 **포함하는 것**을 쓴다."""
    want = _station_key(name)
    if not want:
        return None
    for index, station in enumerate(stations):
        if _station_key(station["이름"]) == want:
            return index
    for index, station in enumerate(stations):
        if want in _station_key(station["이름"]):
            return index
    return None


def subway_leg_stops(from_name, to_name):
    """두 역 사이의 역들을 순서대로. 돌려주는 것 — (노선명, [{name,lat,lon}]).

    못 찾으면 `(None, [])` 다. **오류가 아니다** — 앱은 그때 지금처럼 직선으로
    그리고 그 사실을 화면에 적는다. 짐작해서 엉뚱한 역을 넣지 않는다. 틀린
    폴리라인은 직선보다 나쁘다(직선은 최소한 틀린 줄 안다).
    """
    best = None
    for line in subway_lines().values():
        stations = line["역"]
        start = _find_station(stations, from_name)
        end = _find_station(stations, to_name)
        if start is None or end is None or start == end:
            continue
        span = stations[start:end + 1] if start < end else stations[end:start + 1][::-1]
        if best is None or len(span) < len(best[1]):
            best = (line["이름"], span)
    if best is None:
        return None, []

    name, span = best
    points = [(s["lat"], s["lon"]) for s in span]
    along = sum(haversine(points[i][0], points[i][1], points[i + 1][0], points[i + 1][1])
                for i in range(len(points) - 1))
    straight = haversine(points[0][0], points[0][1], points[-1][0], points[-1][1])
    if straight <= 0 or along / straight > SUBWAY_DETOUR_LIMIT:
        log(f"  지하철 {name} {from_name} → {to_name}: 이어지지 않는다 "
            f"(경로 {int(along)}m / 직선 {int(straight)}m) — 자료 없음으로 둔다")
        return None, []

    return name, [{"name": s["이름"], "lat": s["lat"], "lon": s["lon"]} for s in span]
```

`pathlib` 이 이미 import 되어 있는지 확인하고, 없으면 파일 맨 위 import 묶음에 더한다.

- [ ] **Step 4: 시험이 통과하는지 본다**

```bash
cd Server && python3 -m unittest test_subway_leg -v
```

Expected: `Ran 5 tests ... OK`

- [ ] **Step 5: 전체 시험을 돌린다**

```bash
cd Server && python3 -m unittest discover
```

Expected: `Ran 59 tests ... OK` (기존 54 + 새 5)

- [ ] **Step 6: 커밋**

```bash
git add Server/homecoming_server.py Server/test_subway_leg.py
git commit -m "서버가 지하철 구간의 경유 역을 고른다"
```

---

## Task 3: 서버 라우트

**Files:**
- Modify: `Server/homecoming_server.py` (`if path.startswith("/bus/leg"):` 블록 바로 아래)

- [ ] **Step 1: 라우트를 더한다**

```python
        # 지하철 구간의 경유 역. `/bus/leg` 와 같은 자리, 같은 계약이다 —
        # 빈 결과는 실패가 아니고, 앱은 그때 직선으로 그리며 그 사실을 화면에 적는다.
        if path.startswith("/subway/leg"):
            query = urllib.parse.parse_qs(urllib.parse.urlparse(path).query)
            from_name = (query.get("from", [""])[0] or "").strip()
            to_name = (query.get("to", [""])[0] or "").strip()
            if not from_name or not to_name:
                return self.reply(400, {"error": "from/to 가 필요합니다"})
            line, stops = subway_leg_stops(from_name, to_name)
            if line:
                log(f"  지하철 {line} {from_name} → {to_name}: 경유 역 {len(stops)}개")
            return self.reply(200, {"line": line, "stops": stops})
```

- [ ] **Step 2: 서버를 띄워 손으로 부른다**

```bash
source Server/.env.local && python3 Server/homecoming_server.py --port 8811 &
sleep 3
curl -s "http://localhost:8811/subway/leg?from=%EC%84%9C%EA%B0%95%EB%8C%80%EC%97%AD&to=%ED%92%8D%EC%82%B0%EC%97%AD" | python3 -m json.tool | head -12
```

Expected: `"line": "경의중앙선"` 과 `stops` 12개, 첫 역이 `서강대역`.

- [ ] **Step 3: 인증이 필요한지 확인한다**

`/bus/leg` 가 인증 뒤에 있으면 `/subway/leg` 도 같은 자리여야 한다. 위 `curl` 이
`401` 을 주면 `/bus/leg` 와 같은 위치(인증 검사 뒤)에 넣었는지 다시 본다.

- [ ] **Step 4: 커밋**

```bash
git add Server/homecoming_server.py
git commit -m "GET /subway/leg — 경유 역 좌표를 준다"
```

---

## Task 4: 앱이 서버에 묻는다

**Files:**
- Modify: `App/Route/RouteClient.swift` (`busWaypoints` 선언 옆 · 구현부 옆)

- [ ] **Step 1: 프로토콜에 더한다**

`func busWaypoints(no:from:fromName:toName:)` 선언 **바로 아래**:

```swift
    /// 지하철 구간의 경유 역 좌표. 못 찾으면 빈 배열이다(오류가 아니다).
    func subwayWaypoints(fromName: String, toName: String) async throws -> [CLLocationCoordinate2D]
```

- [ ] **Step 2: 구현을 더한다**

`RouteClient` 의 `busWaypoints(...)` 구현 **바로 아래**:

```swift
    func subwayWaypoints(fromName: String, toName: String) async throws -> [CLLocationCoordinate2D] {
        struct Response: Decodable {
            let stops: [Stop]?
            struct Stop: Decodable { let lat: Double; let lon: Double }
        }
        var items = URLComponents()
        items.queryItems = [
            URLQueryItem(name: "from", value: fromName),
            URLQueryItem(name: "to", value: toName),
        ]
        let query = items.percentEncodedQuery ?? ""
        let data = try await get("subway/leg?\(query)")
        let response = try JSONDecoder().decode(Response.self, from: data)
        return (response.stops ?? []).map {
            CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
        }
    }
```

`busWaypoints` 가 쓰는 GET 헬퍼 이름이 `get(_:)` 이 아니면 그 이름으로 맞춘다.
`busWaypoints` 구현을 그대로 보고 같은 모양으로 쓴다.

- [ ] **Step 3: 다른 구현체를 채운다**

`RouteClientProtocol`(또는 같은 프로토콜)을 따르는 다른 타입이 있으면 컴파일이 깨진다.
찾아서 빈 구현을 넣는다.

```bash
grep -rn ": RouteClientProtocol\|: RouteFetching" App/ | head
```

각각에:

```swift
    func subwayWaypoints(fromName: String, toName: String) async throws -> [CLLocationCoordinate2D] { [] }
```

- [ ] **Step 4: 빌드**

```bash
xcodebuild -project Homecoming.xcodeproj -scheme Homecoming -sdk iphonesimulator \
  -destination 'id=54C508B4-CD79-4916-A3D3-7EFB5DE7CEB9' -configuration Debug build 2>&1 \
  | grep -E "error:|BUILD" | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: 커밋**

```bash
git add App/Route/RouteClient.swift
git commit -m "앱이 지하철 경유 역을 서버에 묻는다"
```

---

## Task 5: 그 좌표로 선을 긋는다

**Files:**
- Modify: `App/Route/RouteTracer.swift` (`busWaypoints` 선언 옆 · `Plotted` · `trace(_:from:to:fromName:)` · `line(_:from:to:label:)`)

- [ ] **Step 1: 클로저와 폴백 목록을 더한다**

`var busWaypoints: (...)?` **바로 아래**:

```swift
    /// 지하철 구간의 경유 역을 물어 준다. nil 이면 안 묻고 두 역 직선으로 그린다.
    ///
    /// 실제 선로는 직선이 아니다. 서강대 → 풍산에서 직선이 실제 노선에서 **1,994m**
    /// 까지 벌어졌고(2026-08-26 실측), 이탈 문턱이 1,000m 라 정상 귀가가 이탈로
    /// 오판됐다(2026-08-25 실주행, 그 뒤 39분을 이탈 상태로 돌았다).
    var subwayWaypoints: ((_ fromName: String, _ toName: String)
                          async -> [CLLocationCoordinate2D])?
```

`struct Plotted` 안, `busFallbacks` **바로 아래**:

```swift
        /// 노선을 못 찾아 두 역 직선으로 그린 지하철 구간의 도착역 이름.
        var subwayFallbacks: [String] = []
```

- [ ] **Step 2: `trace` 가 지하철도 다루게 한다**

`trace(_:from:to:fromName:)` 의 `guard step.mode == .bus, ...` **앞**에 넣는다.

```swift
        if step.mode == .subway, let ask = subwayWaypoints {
            let stations = await ask(fromName, step.toName)
            if stations.count >= 2 {
                return (through(stations, from: from, to: to), false)
            }
            HomecomingLog.push.warning(
                "지하철 \(step.toName, privacy: .public) 노선 자료가 없다 — 직선으로 그린다")
            return (straight(from: from, to: to), true)
        }
```

- [ ] **Step 3: 역들을 잇는 함수를 더한다**

`private func straight(from:to:)` **바로 위**:

```swift
    /// 역 좌표들을 순서대로 잇고 사이를 보간한다.
    ///
    /// **양 끝은 요청받은 좌표로 맞춘다.** 자료의 역 좌표와 경로가 든 좌표가 몇십
    /// 미터 다를 수 있는데, 그대로 두면 구간 사이에 틈이 생겨 다음 구간이 다른
    /// 자리에서 시작한다(`ending(_:at:)` 이 막는 것과 같은 문제다).
    private func through(
        _ stations: [CLLocationCoordinate2D],
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D
    ) -> [[Double]] {
        var nodes = stations
        nodes[0] = from
        nodes[nodes.count - 1] = to
        var points: [[Double]] = []
        for index in 0..<(nodes.count - 1) {
            let piece = straight(from: nodes[index], to: nodes[index + 1])
            points += (index == 0) ? piece : Array(piece.dropFirst())
        }
        return points
    }
```

- [ ] **Step 4: 폴백을 모아 내보낸다**

`plot(origin:steps:)` 안에서 `fallbacks` 를 모으는 자리를 찾아, 지하철 폴백은 별도
배열에 담는다. `let (points, fellBack) = try await trace(...)` 뒤:

```swift
            if fellBack {
                if step.mode == .subway {
                    subwayFallbacks.append(step.toName)
                } else if let no = step.busNo { fallbacks.append(no) }
            }
```

`var subwayFallbacks: [String] = []` 를 `var fallbacks: [String] = []` 옆에 선언하고,
`return Plotted(legs: legs, busFallbacks: fallbacks)` 를 이렇게 바꾼다.

```swift
        return Plotted(legs: legs, busFallbacks: fallbacks, subwayFallbacks: subwayFallbacks)
```

기존 `fellBack` 처리 코드의 실제 모양이 다르면 그 모양에 맞춘다 — **`busFallbacks`
동작을 바꾸지 않는 것이 조건이다.**

- [ ] **Step 5: 배선을 잇는다**

`RouteSample.make` 에서 `tracer.busWaypoints = { ... }` 바로 아래:

```swift
            tracer.subwayWaypoints = { fromName, toName in
                await environment.routes.subwayWaypoints(fromName: fromName, toName: toName)
            }
```

`environment.routes` 쪽에 `busWaypoints` 를 감싼 메서드가 있으면 같은 모양으로
`subwayWaypoints` 도 더한다(실패를 빈 배열로 삼키는 그 래퍼다).

```bash
grep -rn "func busWaypoints" App/Route/RouteStore.swift App/Route/*.swift | head
```

경로 편집기에서도 `tracer` 를 만든다. 같은 두 줄을 그쪽에도 넣는다.

```bash
grep -rn "RouteTracer()" App/ | head
```

- [ ] **Step 6: 빌드**

```bash
xcodebuild -project Homecoming.xcodeproj -scheme Homecoming -sdk iphonesimulator \
  -destination 'id=54C508B4-CD79-4916-A3D3-7EFB5DE7CEB9' -configuration Debug build 2>&1 \
  | grep -E "error:|BUILD" | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: 커밋**

```bash
git add App/Route/RouteTracer.swift App/Route/RouteSample.swift
git commit -m "지하철 구간을 역을 거치는 꺾은선으로 그린다"
```

---

## Task 6: 못 찾았으면 화면이 말한다

**Files:**
- Modify: `App/Route/RouteSample.swift` (`busFallbacks` 를 찍는 자리)
- Modify: 편집기의 저장 후 안내 (`grep -rn "busFallbacks" App/` 로 찾는다)

- [ ] **Step 1: 어디서 쓰는지 찾는다**

```bash
grep -rn "busFallbacks" App/
```

- [ ] **Step 2: 그 자리마다 지하철도 더한다**

`RouteSample.make` 의 경우:

```swift
            if !plotted.subwayFallbacks.isEmpty {
                print("[귀가마중] 노선 자료 없음 — 직선으로 그린 지하철: "
                      + plotted.subwayFallbacks.joined(separator: ", "))
            }
```

편집기 안내 문구도 같은 방식으로 지하철 목록을 덧붙인다. **조용한 폴백을 만들지
않는 것**이 이 작업의 규칙이다 — 저장된 선이 실제 노선과 다르면 저장한 사람이 알아야 한다.

- [ ] **Step 3: 빌드하고 커밋**

```bash
xcodebuild -project Homecoming.xcodeproj -scheme Homecoming -sdk iphonesimulator \
  -destination 'id=54C508B4-CD79-4916-A3D3-7EFB5DE7CEB9' -configuration Debug build 2>&1 \
  | grep -E "error:|BUILD" | tail -3
git add -A && git commit -m "지하철 폴백도 화면이 말한다"
```

---

## Task 7: 성적표 — 얼마나 좋아졌는지 잰다

**Files:**
- Create: `Tools/verify-subway-shape.py`

- [ ] **Step 1: 재는 도구를 쓴다**

```python
#!/usr/bin/env python3
"""저장된 지하철 폴리라인이 실제 노선에서 얼마나 벌어지는지 잰다.

    python3 Tools/verify-subway-shape.py 서강대역 풍산역

**이 작업의 성적표다.** 2026-08-25 실주행에서 저장된 직선이 실제 선로에서 벌어져
이탈로 판정됐고(1,105m, 문턱 1,000m), 그 뒤 39분을 이탈 상태로 돌았다.

여기서 "실제 노선" 은 굽어 둔 역 좌표를 이은 선이다. 그보다 정밀한 자료(선형 GIS)는
쓰지 않기로 했다 — 설계문서 "무엇을" 참고.

의존성 없음.
"""

import json
import math
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "Server"))
import homecoming_server as hs   # noqa: E402


def straight_points(a, b, spacing=200.0):
    """앱의 `RouteTracer.straight(from:to:)` 와 같은 계산."""
    span = hs.haversine(a[0], a[1], b[0], b[1])
    steps = max(int(span / spacing), 1)
    return [(a[0] + (b[0] - a[0]) * i / steps, a[1] + (b[1] - a[1]) * i / steps)
            for i in range(steps + 1)]


def gap_to_path(point, path):
    """그 점에서 꺾은선까지의 최단 거리(m)."""
    best = float("inf")
    for i in range(len(path) - 1):
        best = min(best, hs.haversine(point[0], point[1], path[i][0], path[i][1]))
    best = min(best, hs.haversine(point[0], point[1], path[-1][0], path[-1][1]))
    return best


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 1
    line, stops = hs.subway_leg_stops(sys.argv[1], sys.argv[2])
    if not stops:
        print(f"구간을 못 찾았다: {sys.argv[1]} → {sys.argv[2]}")
        return 1
    real = [(s["lat"], s["lon"]) for s in stops]
    line_points = straight_points(real[0], real[-1])
    worst = max(gap_to_path(p, real) for p in line_points)
    along = sum(hs.haversine(real[i][0], real[i][1], real[i + 1][0], real[i + 1][1])
                for i in range(len(real) - 1))
    print(f"{line} · {sys.argv[1]} → {sys.argv[2]} · 역 {len(real)}개")
    print(f"  직선 길이        {hs.haversine(real[0][0], real[0][1], real[-1][0], real[-1][1]) / 1000:6.1f}km")
    print(f"  역을 거치는 길이  {along / 1000:6.1f}km")
    print(f"  **직선이 실제 노선에서 가장 멀리 벌어지는 곳: {worst:.0f}m**")
    print(f"  이탈 문턱 {hs.OFF_ROUTE_METERS}m")
    return 0 if worst > hs.OFF_ROUTE_METERS else 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2: 돌린다**

```bash
python3 Tools/verify-subway-shape.py 서강대역 풍산역
```

Expected: `직선이 실제 노선에서 가장 멀리 벌어지는 곳: 1994m` · `이탈 문턱 1000m`

이 값이 **고치기 전** 상태를 보여 준다. 고친 뒤에는 저장된 경로가 역을 거치므로
벌어짐이 0에 가깝다.

- [ ] **Step 3: 커밋**

```bash
git add Tools/verify-subway-shape.py
git commit -m "지하철 폴리라인이 실제 노선에서 얼마나 벌어지는지 재는 도구"
```

---

## Task 8: 실제로 경로를 다시 만들어 확인한다

**Files:** 없음 (검증만)

**경로의 좌표열은 저장할 때 박힌다.** 그리는 로직을 고쳐도 이미 저장된 경로에는
반영되지 않는다 — 앱에서 경로를 다시 저장해야 한다(CLAUDE.md).

- [ ] **Step 1: 로컬 서버와 시뮬레이터를 띄운다**

```bash
source Server/.env.local && python3 Server/homecoming_server.py --port 8811 &
xcrun simctl boot 54C508B4-CD79-4916-A3D3-7EFB5DE7CEB9
xcrun simctl install 54C508B4-CD79-4916-A3D3-7EFB5DE7CEB9 <빌드한 .app 경로>
```

- [ ] **Step 2: 경로를 다시 만든다**

```bash
xcrun simctl launch --console-pty --terminate-running-process \
  54C508B4-CD79-4916-A3D3-7EFB5DE7CEB9 com.kona.homecoming2 \
  -homecomingBackend http://localhost:8811 \
  -homecomingHome 37.67885,127.81591 \
  -homecomingMakeRoute
```

Expected: 지하철 구간의 점 개수가 **늘어난다.** 고치기 전에는 `구간 subway 1860초
… 점 96` 이었다(18.7km / 200m ≈ 96). 역을 거치면 경로가 19.5km 로 길어지므로 점이
100개 안팎으로 는다. 그리고 `노선 자료 없음 — 직선으로 그린 지하철:` 이 **안 떠야**
한다.

- [ ] **Step 3: 저장된 좌표열을 실제 노선과 견준다**

```bash
python3 - <<'EOF'
import json, sqlite3, sys, pathlib
sys.path.insert(0, "Server"); import homecoming_server as hs
conn = sqlite3.connect("Server/homecoming.sqlite"); conn.row_factory = sqlite3.Row
row = conn.execute("SELECT legs FROM routes ORDER BY rowid DESC LIMIT 1").fetchone()
legs = json.loads(row["legs"])
leg = max((l for l in legs if l["mode"] == "subway"), key=lambda l: len(l["points"]))
saved = [(p[0], p[1]) for p in leg["points"]]
_, stops = hs.subway_leg_stops("서강대", leg.get("toName", "풍산역"))
real = [(s["lat"], s["lon"]) for s in stops]
worst = max(min(hs.haversine(p[0], p[1], r[0], r[1]) for r in real) for p in saved)
print(f"저장된 좌표열 {len(saved)}점 · 실제 역에서 최대 {worst:.0f}m")
EOF
```

Expected: 최대 벌어짐이 **역 사이 간격의 절반 이하**(수백 m). 1,000m 를 넘으면 안 된다.

- [ ] **Step 4: 결과를 설계문서에 적는다**

`docs/superpowers/specs/2026-08-26-subway-polyline-design.md` 의 "검증" 절에 잰 값을
적는다. **재지 않은 값을 적지 않는다.**

- [ ] **Step 5: 커밋**

```bash
git add docs/superpowers/specs/2026-08-26-subway-polyline-design.md
git commit -m "지하철 폴리라인 — 실측 결과를 설계문서에 적는다"
```

---

## 마지막 확인

- [ ] `cd Server && python3 -m unittest discover` → 59개 통과
- [ ] `python3 Tools/verify-progress-sync.py` → 진행도 동기화가 안 깨졌는지
- [ ] `ruby Tools/generate_project.rb` → 새 Swift 파일을 더했다면 (이번 계획은 안 더한다)
- [ ] 실기기 설치 후 `경로` 탭에서 경로를 **다시 저장**해야 반영된다
- [ ] 배포: `railway up --detach --service homecoming2`
