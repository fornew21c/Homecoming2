# 노선도 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 가족과 귀가자 화면의 진행 바 자리에 세로 노선도를 넣어, 경로의 어느 정류장을 지났고 다음이 어디인지 보이게 한다.

**Architecture:** 서버가 경로의 구간을 정류장 목록으로 접어(`route_stops`) 세 응답에 싣는다 — 가족 액티비티의 고정값, `GET /route` 목록, `GET /route/{id}` 상세. 앱은 이미 있는 `remainingMeters`/`totalMeters` 로 점을 찍는다. **갱신값(`ContentState`)은 안 건드린다.**

**Tech Stack:** Python 3 표준 라이브러리(서버·시험), SwiftUI + ActivityKit(앱·위젯)

**설계 문서:** `docs/superpowers/specs/2026-08-14-family-route-strip-design.md`

---

## 파일 구조

| 파일 | 하는 일 |
|---|---|
| `Server/homecoming_server.py` | `route_stops(legs)` 추가, 세 응답에 `stops` 싣기 |
| `Server/test_route_stops.py` | **새 파일.** `route_stops` 시험 |
| `Shared/HomecomingAttributes.swift` | `RouteShape` 타입 + `routeShape` 고정값 + 점 위치 계산 |
| `Shared/HomecomingViewParts.swift` | `RouteStripView` — 노선도 뷰 |
| `App/Route/RouteClient.swift` | 목록 응답의 `stops` 디코딩 |
| `App/HomecomingActivityManager.swift` | `start()` 가 `routeShape` 를 받는다 |
| `App/HomecomingCoordinator.swift` | 고른 경로의 `routeShape` 를 넘긴다 |
| `App/Watching/WatchingCard.swift` | 진행 바를 노선도로 교체 |
| `App/ContentView.swift` | 귀가자 노선도 카드 |
| `App/ContractDump.swift` | 점 위치 계산 결과를 찍어낸다 |

**새 Swift 파일을 만들지 않는다.** 이 프로젝트는 파일을 추가하면 `ruby Tools/generate_project.rb` 로 Xcode 프로젝트를 다시 만들어야 하고, 그 작업에는 문서화된 사고 이력이 있다(Xcode 가 열려 있으면 `contents.xcworkspacedata` 가 사라진다). `RouteShape` 는 그것을 쓰는 `HomecomingAttributes.swift` 에, `RouteStripView` 는 자신이 대체하는 `HomecomingProgressBar` 가 사는 `HomecomingViewParts.swift` 에 둔다. 둘 다 이미 앱·위젯 두 타겟에 들어 있다.

새 파일은 `Server/test_route_stops.py` 하나뿐이고 Xcode 와 무관하다.

---

## Task 1: 서버 — `route_stops()` 접는 함수

**Files:**
- Create: `Server/test_route_stops.py`
- Modify: `Server/homecoming_server.py` (`route_length` 아래, 926줄 근처)

- [ ] **Step 1: 실패하는 시험을 쓴다**

`Server/test_route_stops.py` 를 새로 만든다. 실제 경로 파일(`Tools/routes/commute-sample.json`)을 붙박이 자료로 쓴다 — 이 프로젝트에 이미 있는 진짜 10구간 경로다.

```python
"""route_stops() 시험.

    cd Server && python3 -m unittest test_route_stops -v

의존성 없음. 표준 unittest 다.
"""

import json
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from homecoming_server import route_length, route_stops   # noqa: E402

ROUTE = pathlib.Path(__file__).resolve().parent.parent / "Tools" / "routes" / "commute-sample.json"


def legs():
    return json.loads(ROUTE.read_text(encoding="utf-8"))["legs"]


class RouteStopsTests(unittest.TestCase):

    def test_대기_구간은_점이_되지_않는다(self):
        # 10구간 중 대기가 3개다. 대기는 앞 구간과 같은 자리라 점을 따로 찍으면
        # 노선도에 같은 자리가 두 번 나온다.
        stops = route_stops(legs())
        self.assertEqual(len(stops), 7)

    def test_이름이_구간_순서대로다(self):
        names = [s["name"] for s in route_stops(legs())]
        self.assertEqual(names, [
            "출발역.은행앞",
            "환승로터리",
            "서강대역",
            "풍산역",
            "풍산역 정류장",
            "아파트단지",
            "집",
        ])

    def test_대기_시간이_앞_정류장에_붙는다(self):
        stops = route_stops(legs())
        waits = {s["name"]: s["waitSeconds"] for s in stops}
        self.assertEqual(waits["출발역.은행앞"], 180)
        self.assertEqual(waits["서강대역"], 240)
        self.assertEqual(waits["풍산역 정류장"], 120)
        self.assertEqual(waits["환승로터리"], 0)

    def test_거리의_합이_경로_길이와_같다(self):
        # **이 시험이 노선도의 점 위치를 지킨다.** 앱은 지나온거리를 정류장별
        # 거리에 누적해 맞춰 점을 찍는다. 합이 totalMeters 와 다르면 마지막
        # 정류장에서 점이 밀린다. leg_length() 가 아니라 저장된 meters 필드를
        # 쓰면 실제로 1m 어긋난다.
        all_legs = legs()
        self.assertEqual(
            sum(s["meters"] for s in route_stops(all_legs)),
            route_length(all_legs),
        )

    def test_교통수단이_경로의_낱말_그대로다(self):
        modes = [s["mode"] for s in route_stops(legs())]
        self.assertEqual(modes, ["walk", "bus", "walk", "subway", "walk", "bus", "walk"])

    def test_구간이_없으면_빈_목록이다(self):
        self.assertEqual(route_stops([]), [])
        self.assertEqual(route_stops(None), [])

    def test_대기로_시작하면_그_대기는_버려진다(self):
        # 붙일 앞 정류장이 없다. 노선도는 출발점을 점으로 그리지 않으므로
        # 보여 줄 자리도 없다. 조용히 버리되 동작을 못박아 둔다.
        stops = route_stops([
            {"mode": "wait", "seconds": 300},
            {"mode": "walk", "toName": "집", "seconds": 60, "points": [[37.5, 127.0], [37.501, 127.0]]},
        ])
        self.assertEqual(len(stops), 1)
        self.assertEqual(stops[0]["waitSeconds"], 0)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 시험을 돌려 실패를 확인한다**

Run: `cd Server && python3 -m unittest test_route_stops -v`
Expected: FAIL — `ImportError: cannot import name 'route_stops' from 'homecoming_server'`

- [ ] **Step 3: `route_stops()` 를 구현한다**

`Server/homecoming_server.py` 의 `route_length()` 정의(926줄) **바로 아래**에 넣는다.

```python
def route_stops(legs):
    """구간을 노선도에 찍을 정류장 목록으로 접는다.

    **대기 구간은 점을 만들지 않는다.** 대기는 앞 구간과 같은 자리라, 점을 따로
    찍으면 노선도에 같은 자리가 두 번 나온다. 앞 정류장의 `waitSeconds` 로 붙는다.
    그래서 10구간이 점 7개가 된다.

    **거리는 `leg_length()` 로 잰다. 저장된 `meters` 필드가 아니다.**
    `route_length()` 가 좌표열로 재므로 다른 자를 쓰면 정류장 거리의 합이
    `totalMeters` 와 어긋난다. 실제 경로에서 1m 차이가 나고, 그만큼 노선도의
    점이 마지막 정류장에서 밀린다.
    """
    stops = []
    for leg in legs or []:
        if leg.get("mode") == "wait":
            # 붙일 앞 정류장이 없으면 버린다. 노선도는 출발점을 점으로 그리지
            # 않으므로 보여 줄 자리가 없다.
            if stops:
                stops[-1]["waitSeconds"] += int(leg.get("seconds") or 0)
            continue
        stops.append({
            "name": leg.get("toName") or "",
            "mode": leg.get("mode") or "walk",
            "meters": int(leg_length(leg)),
            "seconds": int(leg.get("seconds") or 0),
            "waitSeconds": 0,
        })
    return stops
```

- [ ] **Step 4: 시험을 돌려 통과를 확인한다**

Run: `cd Server && python3 -m unittest test_route_stops -v`
Expected: PASS — 7개 시험 전부 ok

`test_거리의_합이_경로_길이와_같다` 가 실패하면 `int()` 자르기가 구간마다 쌓인 것이다. 그때는 `route_length()` 도 `int(sum(...))` 로 마지막에 한 번만 자르는지 확인한다 — 자르는 자리가 다르면 합이 안 맞는다.

- [ ] **Step 5: 커밋**

```bash
git add Server/test_route_stops.py Server/homecoming_server.py
git commit -m "구간을 노선도의 정류장으로 접는다"
```

---

## Task 2: 서버 — 세 응답에 `stops` 싣기

**Files:**
- Modify: `Server/homecoming_server.py` — `attributes_for()` (775줄), `GET /route` 의 `summary()` (1418줄 근처), `GET /route/{id}` (1323줄 근처)

세 곳이 같은 함수를 쓴다. **접는 규칙이 한 벌이라는 것이 이 작업의 요점이다** — 두 벌이 되면 귀가자와 가족이 다른 노선도를 본다.

- [ ] **Step 1: `attributes_for()` 에 싣는다 (가족 액티비티)**

`Server/homecoming_server.py:775` 을 이렇게 바꾼다.

```python
def attributes_for(session, audience):
    out = {
        "travelerName": session["traveler_name"],
        "destinationName": session["home_name"],
        "departedAt": session["started_at"],
        "audience": audience,
        "sessionId": session["id"],
    }
    # 노선도. 귀가 중에 안 바뀌므로 갱신값이 아니라 고정값이다.
    # 경로 없이 시작한 귀가는 키를 넣지 않는다 — 앱이 지금 카드로 폴백한다.
    shape = route_shape_for(session)
    if shape:
        out["routeShape"] = shape
    return out


def route_shape_for(session):
    """세션이 쓰는 경로의 노선도. 경로가 없으면 None.

    **크기를 재고 넘치면 뺀다.** 액티비티 시작 푸시는 APNs 4KB 한도를 받는다.
    10구간이면 600바이트 남짓이라 여유가 크지만, 구간 수를 정하는 건 사용자다.
    넘치면 노선도를 빼고 보낸다 — 가족은 지금 카드를 본다.

    **조용히 빼지 않는다.** 계기판이 거짓말하면 안 된다.
    """
    route_id = session["route_id"] if "route_id" in session.keys() else None
    if not route_id:
        return None
    row = db().execute("SELECT legs FROM routes WHERE id = ?", (route_id,)).fetchone()
    if not row:
        return None
    try:
        stops = route_stops(json.loads(row["legs"]))
    except (TypeError, ValueError):
        return None
    if not stops:
        return None
    size = len(json.dumps({"stops": stops}, ensure_ascii=False).encode("utf-8"))
    if size > ROUTE_SHAPE_MAX_BYTES:
        log(f"  노선도 {size}바이트 — {ROUTE_SHAPE_MAX_BYTES} 초과라 뺀다 "
            f"(정류장 {len(stops)}개). 가족은 카드를 본다")
        return None
    return {"stops": stops}
```

`route_stops()` 정의 위에 한도를 둔다.

```python
# 액티비티 시작 푸시는 APNs 4KB 한도를 받는다. 고정값에는 이름·시각도 함께
# 들어가므로 노선도에 전부를 주지 않는다. 10구간이 600바이트 남짓이다.
ROUTE_SHAPE_MAX_BYTES = 3_000
```

- [ ] **Step 2: `GET /route` 목록에 싣는다 (귀가자 액티비티)**

`summary()` 안, `out["totalMeters"] = route_length(legs)` **바로 아래**에 한 줄을 넣는다.

```python
                out["totalMeters"] = route_length(legs)
                out["stops"] = route_stops(legs)
```

**여기가 귀가자 노선도의 출처다.** 앱은 `activity.start()` 를 `openSession()` 보다
먼저 부르므로(`HomecomingCoordinator.swift:271` 과 `288`) 세션 응답으로는 늦다.
목록은 앱이 이미 캐시해 두므로 추가 요청이 없다. 같은 자리에서 같은 이유로
`firstTransport`·`firstDetail` 이 이미 이렇게 오고 있다.

- [ ] **Step 3: `GET /route/{id}` 상세에 싣는다**

`homecoming_server.py:1332` 근처, `"legs": json.loads(route["legs"]),` 를 이렇게 바꾼다.

```python
            legs = json.loads(route["legs"])
            return self.reply(200, {
                "routeId": route["id"],
                "name": route["name"],
                "totalSeconds": route["total_seconds"],
                "home": {"lat": route["home_lat"], "lon": route["home_lon"],
                         "name": route["home_name"], "radius": route["home_radius"]},
                "legs": legs,
                # 목록과 상세가 다른 말을 하면 안 된다.
                "stops": route_stops(legs),
            })
```

- [ ] **Step 4: 서버를 띄워 세 응답을 눈으로 확인한다**

```bash
cd Server && python3 homecoming_server.py &
sleep 2
curl -s localhost:8080/health | head -3
```

Expected: `{"ok": true, ...}` 가 나온다.

경로가 이미 있는 DB 가 없으면 이 확인은 Task 9 의 실기기 확인으로 미룬다.
`route_stops()` 자체는 Task 1 의 시험이 지킨다.

- [ ] **Step 5: 커밋**

```bash
git add Server/homecoming_server.py
git commit -m "노선도를 액티비티와 경로 응답에 싣는다"
```

---

## Task 3: 앱 — `RouteShape` 타입과 고정값

**Files:**
- Modify: `Shared/HomecomingAttributes.swift`

- [ ] **Step 1: `RouteShape` 타입을 넣는다**

`Shared/HomecomingAttributes.swift` 의 `// MARK: - EndReason` **바로 위**에 넣는다.

```swift
// MARK: - RouteShape

extension HomecomingAttributes {

    /// 노선도에 그릴 정류장 목록.
    ///
    /// **좌표가 없다.** 노선도는 지리가 아니라 순서를 그린다. 위도·경도는 가족
    /// 폰으로 한 바이트도 가지 않는다.
    ///
    /// 귀가 중에 안 바뀌므로 갱신값이 아니라 고정값이다. 서버가 `route_stops()`
    /// 로 접은 것을 그대로 받는다 — 앱이 다시 접으면 규칙이 두 벌이 되고,
    /// 어긋나면 귀가자와 가족이 다른 노선도를 본다.
    struct RouteShape: Codable, Hashable {

        struct Stop: Codable, Hashable {
            /// "풍산역"
            var name: String
            /// 여기까지 오는 수단. **경로가 쓰는 낱말 그대로**다 — `walk` / `bus`
            /// / `subway` / `car`. 갱신값의 `Transport` 와 별개이고 변환하지
            /// 않는다. 잇는 순간 노선도가 갱신값에 매인다.
            var mode: String
            /// 여기까지 오는 거리(m).
            var meters: Int
            /// 여기까지 걸리는 시간(초).
            var seconds: Int
            /// 여기서 갈아타며 기다리는 시간(초). 없으면 0.
            var waitSeconds: Int
        }

        var stops: [Stop]
    }
}
```

- [ ] **Step 2: 고정값에 더한다**

`Shared/HomecomingAttributes.swift` 의 `var audience: Audience = .traveler` **바로 아래**에 넣는다.

```swift
    /// 노선도에 그릴 정류장 목록. 경로 없이 시작한 귀가면 nil 이다.
    ///
    /// **옵셔널이어야 한다.** 경로 없는 귀가와, 이 변경 전에 시작된 액티비티가
    /// 안 깨진다. 서버가 이 키를 안 보내는 경우도 그대로 통과한다.
    var routeShape: RouteShape?
```

- [ ] **Step 3: 빌드해서 깨진 데를 확인한다**

Run: `xcodebuild -project Homecoming.xcodeproj -scheme Homecoming -destination 'generic/platform=iOS' build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED. `routeShape` 가 기본값 nil 인 옵셔널이라 기존 `HomecomingAttributes(...)` 호출부가 그대로 컴파일된다.

- [ ] **Step 4: 커밋**

```bash
git add Shared/HomecomingAttributes.swift
git commit -m "액티비티 고정값에 노선도를 더한다"
```

---

## Task 4: 앱 — 점 위치 계산

지나온 거리를 정류장별 거리에 맞춰 "몇 번째 정류장 구간의 몇 %" 로 바꾼다. 순수 함수라 시험이 싸다.

**Files:**
- Modify: `Shared/HomecomingAttributes.swift`
- Modify: `App/ContractDump.swift`

- [ ] **Step 1: 계산을 넣는다**

Task 3 에서 넣은 `RouteShape` 안, `var stops: [Stop]` **아래**에 넣는다.

```swift
        /// 노선도 위에서 지금 어디인가.
        ///
        /// `index` 는 향해 가는 중인 정류장, `fraction` 은 그 구간을 얼마나 왔나(0~1).
        /// 출발 직후면 (0, 0), 도착이면 (마지막, 1) 이다.
        struct Position: Equatable {
            var index: Int
            var fraction: Double
        }

        /// 지나온 거리(m)로 점의 자리를 낸다.
        ///
        /// **`progress` 를 바로 못 쓴다.** 진행률에 직선 노선도 길이를 곱하면
        /// 정류장과 어긋난다 — 구간마다 실제 길이가 크게 다르기 때문이다
        /// (도보 78m 와 지하철 18.7km 가 한 경로에 있다). 그래서 거리로 맞춘다.
        ///
        /// 정류장 거리의 합은 서버가 `totalMeters` 와 같게 만들어 준다
        /// (`route_stops()` 가 `leg_length()` 로 재는 이유). 그래도 여기서
        /// 양 끝을 잘라 둔다 — 위치가 튀어 남은거리가 음수로 와도 점이 노선도
        /// 밖으로 나가면 안 된다.
        func position(travelled meters: Int) -> Position {
            guard !stops.isEmpty else { return Position(index: 0, fraction: 0) }
            var remaining = Double(max(0, meters))
            for (index, stop) in stops.enumerated() {
                let length = Double(stop.meters)
                // 길이 0 인 구간(제자리 이동)은 건너뛴다. 나누면 무한이 된다.
                if length <= 0 { continue }
                if remaining < length {
                    return Position(index: index, fraction: remaining / length)
                }
                remaining -= length
            }
            return Position(index: stops.count - 1, fraction: 1)
        }
```

- [ ] **Step 2: `ContractDump` 에 확인용 출력을 더한다**

이 프로젝트에는 시험 타겟이 없다. `ContractDump` 가 "실제 타입에서 페이로드를 뽑아내는" 자리이므로 여기에 붙인다.

`App/ContractDump.swift` 의 `static func run()` **맨 끝**에 넣는다(닫는 중괄호 앞).

```swift
        // 노선도 점 위치. 경계값을 표로 찍어 눈으로 확인한다.
        //
        //     xcrun simctl launch <udid> com.kona.homecoming -homecomingPrintContract
        //
        // 시험 타겟이 없으므로 이 표가 회귀 시험이다. 값이 바뀌면 여기서 보인다.
        let shape = HomecomingAttributes.RouteShape(stops: [
            .init(name: "출발역.은행앞", mode: "walk",   meters: 445,    seconds: 360,  waitSeconds: 180),
            .init(name: "환승로터리",             mode: "bus",    meters: 5_357,  seconds: 540,  waitSeconds: 0),
            .init(name: "서강대역",               mode: "walk",   meters: 664,    seconds: 420,  waitSeconds: 240),
            .init(name: "풍산역",                 mode: "subway", meters: 18_683, seconds: 1_860, waitSeconds: 0),
            .init(name: "풍산역 정류장",           mode: "walk",   meters: 78,     seconds: 360,  waitSeconds: 120),
            .init(name: "아파트단지",          mode: "bus",    meters: 2_950,  seconds: 600,  waitSeconds: 0),
            .init(name: "집",                    mode: "walk",   meters: 181,    seconds: 180,  waitSeconds: 0),
        ])
        let total = shape.stops.reduce(0) { $0 + $1.meters }

        print("=== 노선도 점 위치 (총 \(total)m) ===")
        for travelled in [0, 1, 444, 445, 446, 6_000, total - 1, total, total + 5_000, -100] {
            let at = shape.position(travelled: travelled)
            let name = shape.stops[at.index].name
            print(String(format: "%8d m → [%d] %@ %.3f", travelled, at.index, name, at.fraction))
        }
```

- [ ] **Step 3: 시뮬레이터에서 찍어 본다**

```bash
xcrun simctl boot "iPhone 16 Pro" 2>/dev/null || true
xcodebuild -project Homecoming.xcodeproj -scheme Homecoming \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build
xcrun simctl install booted "$(xcodebuild -project Homecoming.xcodeproj -scheme Homecoming -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{d=$2} / FULL_PRODUCT_NAME/{n=$2} END{print d"/"n}')"
xcrun simctl launch --console booted com.kona.homecoming -homecomingPrintContract 2>&1 | grep -A 12 "노선도 점 위치"
```

Expected — 이 표가 나와야 한다:

```
=== 노선도 점 위치 (총 28358m) ===
       0 m → [0] 출발역.은행앞 0.000
       1 m → [0] 출발역.은행앞 0.002
     444 m → [0] 출발역.은행앞 0.998
     445 m → [1] 환승로터리 0.000
     446 m → [1] 환승로터리 0.000
    6000 m → [2] 서강대역 0.298
   28357 m → [6] 집 0.994
   28358 m → [6] 집 1.000
   33358 m → [6] 집 1.000
    -100 m → [0] 출발역.은행앞 0.000
```

확인할 것 세 가지:
- **445m 에서 다음 정류장으로 넘어간다** — 첫 구간을 정확히 다 왔으면 그 정류장에 도착한 것이다
- **총 거리를 넘겨도 마지막에 멈춘다** — 점이 노선도 밖으로 안 나간다
- **음수도 맨 앞에 멈춘다** — 남은거리가 튀어도 안 깨진다

- [ ] **Step 4: 커밋**

```bash
git add Shared/HomecomingAttributes.swift App/ContractDump.swift
git commit -m "노선도 위의 점 자리를 낸다"
```

---

## Task 5: 앱 — 노선도 뷰

**Files:**
- Modify: `Shared/HomecomingViewParts.swift`

- [ ] **Step 1: `RouteStripView` 를 넣는다**

`Shared/HomecomingViewParts.swift` 의 `HomecomingProgressBar` **아래**, `CountdownText` **위**에 넣는다.

```swift
/// 경로의 정류장을 세로로 잇고 그 위에 지금 자리를 찍는다.
///
/// **지도가 아니라 노선도다.** 우리가 아는 건 정류장이고 그 사이는 직선이다.
/// 지도는 "이게 정확한 위치" 라고 말하는 매체라 부정확한 선을 올리면 거짓말이
/// 된다. 노선도는 순서와 남은 개수만 말하겠다고 선언하는 매체다.
///
/// `HomecomingProgressBar` 를 대신한다. 같은 값을 쓰되 정류장 이름을 붙여 준다.
struct RouteStripView: View {

    let shape: HomecomingAttributes.RouteShape
    let state: HomecomingAttributes.ContentState
    /// 마지막으로 위치가 확인된 때. nil 이면 "언제 것인지" 를 적지 않는다.
    var lastFixedAt: Date?

    // MARK: - 자리 세기
    //
    // **행과 정류장의 번호가 다르다.** 맨 위에 이름 없는 출발점 행이 하나 있다.
    //
    //     행 0        출발점          ← stops 에 없다
    //     이음 0                     ← stops[0] 으로 가는 구간
    //     행 1        stops[0]
    //     이음 1                     ← stops[1] 로 가는 구간
    //     행 2        stops[1]
    //     ...
    //
    // 출발점 행이 없으면 **첫 구간에 점을 놓을 자리가 없다.** 출발한 지 3분이면
    // 아직 첫 정류장에 안 왔는데, 점을 정류장 행에 찍으면 도착한 것처럼 보인다.

    private var position: HomecomingAttributes.RouteShape.Position {
        shape.position(travelled: state.totalMeters - state.remainingMeters)
    }

    /// 그릴 행 번호들. 0 은 출발점, 1 부터가 `stops[행-1]` 이다.
    ///
    /// 행 7개는 카드 하나 높이를 넘는다. 스크롤을 만들지 않고 접는다 —
    /// 스크롤이 생기면 이 화면이 목록이 되고, 한눈에 읽는다는 목적이 흐려진다.
    /// 항상 보이는 것은 출발점, 지금 있는 구간의 앞뒤, 집이다.
    private var visibleRows: [Int] {
        let last = shape.stops.count            // 행 번호의 최대값
        let here = position.index               // 향해 가는 정류장 = 이음 번호
        let keep = Set([0, here, here + 1, last].filter { $0 >= 0 && $0 <= last })
        return keep.sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(visibleRows.enumerated()), id: \.element) { slot, row in
                if slot > 0 {
                    let previous = visibleRows[slot - 1]
                    if previous < row - 1 {
                        skipped(count: row - previous - 1)
                    } else {
                        connector(previous)     // 이음 번호 = 위 행의 번호
                    }
                }
                stopRow(row)
            }
        }
    }

    // MARK: - 조각

    /// 정류장 한 줄. 행 0 은 이름 없는 출발점이다.
    @ViewBuilder
    private func stopRow(_ row: Int) -> some View {
        // 점은 이음에 있으므로, 행은 지났는지 아닌지만 말한다.
        let passed = row <= position.index
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(passed ? state.tint : .white.opacity(0.25))
                .frame(width: 7, height: 7)
                .frame(width: 12)

            Text(row == 0 ? "출발" : shape.stops[row - 1].name)
                .font(.system(size: 13, weight: row == position.index + 1 ? .semibold : .regular))
                // 긴 이름이 실제로 있다 — "출발역.은행앞".
                // 오늘 잠금화면에서 이미 잘려 본 자리다.
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.85)
                .foregroundStyle(row == 0 ? .white.opacity(0.4)
                                          : .white.opacity(passed ? 0.6 : 0.4))
            Spacer(minLength: 0)
        }
        .frame(height: 22)
    }

    /// 정류장 사이를 잇는 선. 지금 있는 구간이면 여기에 점을 찍는다.
    ///
    /// `index` 는 `stops[index]` 로 **향해 가는** 구간이다.
    @ViewBuilder
    private func connector(_ index: Int) -> some View {
        let here = index == position.index
        let passed = index < position.index
        let height: CGFloat = here ? 30 : 16

        HStack(alignment: .center, spacing: 10) {
            ZStack(alignment: .top) {
                Rectangle()
                    .fill(passed ? state.tint.opacity(0.7) : .white.opacity(0.18))
                    .frame(width: 2, height: height)
                if here {
                    Circle()
                        .fill(.white)
                        .frame(width: 11, height: 11)
                        .shadow(color: state.tint.opacity(0.9), radius: 4)
                        // 구간을 얼마나 왔는지가 점의 높이다. 0 이면 맨 위,
                        // 1 이면 맨 아래. 점 지름만큼 빼서 선 밖으로 안 나가게 한다.
                        .offset(y: (height - 11) * position.fraction)
                }
            }
            .frame(width: 12, height: height)

            VStack(alignment: .leading, spacing: 1) {
                if let label = legLabel(toward: index) {
                    Text(label)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.35))
                }
                if here, let note = hereNote {
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func skipped(count: Int) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Rectangle()
                .fill(state.tint.opacity(0.7))
                .frame(width: 2, height: 16)
                .frame(width: 12)
            Text("⋯ \(count)곳 지남")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.35))
            Spacer(minLength: 0)
        }
    }

    /// 그 정류장으로 가는 수단과 시간. "버스 9분"
    ///
    /// 갈아타며 기다리는 시간은 **앞 정류장**에 붙어 있으므로 여기에 더한다 —
    /// 기다린 뒤에 타는 것이 이 구간이다.
    private func legLabel(toward index: Int) -> String? {
        guard shape.stops.indices.contains(index) else { return nil }
        let stop = shape.stops[index]
        let wait = index > 0 ? shape.stops[index - 1].waitSeconds : 0
        let minutes = max(1, (stop.seconds + wait) / 60)
        let label: String
        switch stop.mode {
        case "bus":    label = "버스"
        case "subway": label = "지하철"
        case "car":    label = "차"
        default:       label = "도보"
        }
        return wait > 0 ? "\(label) \(minutes)분 (대기 포함)" : "\(label) \(minutes)분"
    }

    /// 지금 자리 옆에 붙는 한 줄. 끊겼으면 언제 것인지 적는다.
    ///
    /// **점을 예상 위치로 옮기지 않는다.** 지하철에서 31분 끊기는데, 지연되면
    /// 점이 집에 먼저 도착해 있는 거짓말을 한다. 아는 것만 말한다.
    private var hereNote: String? {
        guard let lastFixedAt else { return nil }
        let minutes = Int(Date().timeIntervalSince(lastFixedAt) / 60)
        guard minutes >= 2 else { return nil }
        return "\(minutes)분 전 확인"
    }
}
```

- [ ] **Step 2: 빌드한다**

Run: `xcodebuild -project Homecoming.xcodeproj -scheme Homecoming -destination 'generic/platform=iOS' build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: 커밋**

```bash
git add Shared/HomecomingViewParts.swift
git commit -m "정류장을 세로로 잇는 노선도를 그린다"
```

---

## Task 6: 가족 카드에 붙인다

**Files:**
- Modify: `App/Watching/WatchingStore.swift` (`Entry` 에 받은 시각)
- Modify: `App/Watching/WatchingCard.swift:44`

- [ ] **Step 1: 갱신을 받은 시각을 기록한다**

노선도는 끊겼을 때 "12분 전 확인" 을 보여 준다. 그런데 **`ContentState` 에는 그
시각이 없고, 넣으면 "갱신값을 안 건드린다" 는 이 설계의 핵심 성질이 깨진다.**

가족 폰이 스스로 알 수 있다 — 갱신 푸시는 위치 보고가 올 때 나가므로, **갱신을 받은
시각**이 곧 마지막으로 위치가 확인된 시각이다. 와이어는 한 글자도 안 바뀐다.

`App/Watching/WatchingStore.swift` 의 `Entry` 에 필드를 더한다.

```swift
    struct Entry: Identifiable {
        let id: String
        let attributes: HomecomingAttributes
        var state: HomecomingAttributes.ContentState
        var isFinished: Bool
        /// 이 값을 **받은** 때.
        ///
        /// 갱신 푸시는 위치 보고가 올 때 나간다. 그러니 이게 곧 마지막으로 위치가
        /// 확인된 때다. `ContentState` 에 시각을 넣지 않으려고 이렇게 한다 —
        /// 갱신값을 안 건드리는 것이 이 설계의 핵심이다.
        var receivedAt: Date
    }
```

`upsert(...)` 가 이 값을 채우게 한다. 새 값을 받을 때마다 `Date()` 로 갱신한다.
기존 `upsert` 선언을 찾아 호출부와 함께 고친다 — 세 군데에서 부른다(`adopt` 의 첫
줄, `contentUpdates` 루프, `activityStateUpdates` 루프).

**`activityStateUpdates` 에서는 갱신하지 마라.** 그건 액티비티가 끝났다는 신호지
새 위치가 아니다. 거기서 시각을 밀면 끊긴 것을 안 끊긴 것으로 만든다.

- [ ] **Step 2: 진행 바를 노선도로 바꾼다**

`App/Watching/WatchingCard.swift:44` 의 이 줄을

```swift
            HomecomingProgressBar(state: state, height: 8)
```

이렇게 바꾼다.

```swift
            // 경로가 있으면 노선도, 없으면 진행 바. 경로 없이 시작한 귀가는
            // 그릴 선이 없다.
            if let shape = attributes.routeShape, !state.stage.isFinished {
                RouteStripView(shape: shape, state: state, lastFixedAt: entry.receivedAt)
            } else {
                HomecomingProgressBar(state: state, height: 8)
            }
```

- [ ] **Step 3: 빌드한다**

Run: `xcodebuild -project Homecoming.xcodeproj -scheme Homecoming -destination 'generic/platform=iOS' build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: 커밋**

```bash
git add App/Watching/WatchingStore.swift App/Watching/WatchingCard.swift
git commit -m "가족 카드가 노선도를 보여 준다"
```

---

## Task 7: 앱 — 경로 목록에서 노선도를 받는다

**Files:**
- Modify: `App/Route/RouteClient.swift:93-118` (`HomecomingRoute`), `:214-234` (`routes()`)

- [ ] **Step 1: `HomecomingRoute` 에 담을 자리를 만든다**

`App/Route/RouteClient.swift:108` 의 `let totalMeters: Int?` **아래**에 넣는다.

```swift

    /// 노선도에 그릴 정류장 목록.
    ///
    /// **목록 응답에서 온다.** 앱은 귀가 시작 순간의 액티비티를 직접 만들고
    /// 서버 응답을 기다리지 않는다(`activity.start()` 가 `openSession()` 보다
    /// 먼저다). 그래서 세션 응답으로는 늦다. `firstTransport` 가 여기 있는
    /// 이유와 같다.
    let stops: [HomecomingAttributes.RouteShape.Stop]?
```

- [ ] **Step 2: 디코딩한다**

`App/Route/RouteClient.swift:215-223` 의 `struct Row` 에 한 줄, `:226-232` 의 생성자에 한 줄을 더한다.

```swift
    func routes() async throws -> [HomecomingRoute] {
        struct Row: Decodable {
            let routeId: String
            let name: String
            let totalSeconds: Int
            let homeName: String?
            let firstTransport: String?
            let firstDetail: String?
            let totalMeters: Int?
            let stops: [HomecomingAttributes.RouteShape.Stop]?
        }
        let rows: [Row] = try await get("route")
        return rows.map {
            HomecomingRoute(
                id: $0.routeId, name: $0.name,
                totalSeconds: $0.totalSeconds, homeName: $0.homeName,
                firstTransport: $0.firstTransport.flatMap(HomecomingAttributes.Transport.init(rawValue:)),
                firstDetail: $0.firstDetail,
                totalMeters: $0.totalMeters,
                stops: $0.stops
            )
        }
    }
```

- [ ] **Step 3: 빌드해서 다른 생성자를 찾는다**

Run: `xcodebuild -project Homecoming.xcodeproj -scheme Homecoming -destination 'generic/platform=iOS' build 2>&1 | grep -E "error|HomecomingRoute" | head -20`

`HomecomingRoute(...)` 를 부르는 다른 자리(미리보기·시뮬레이터 자료)가 있으면 `stops: nil` 을 더한다. 옵셔널이므로 뜻이 안 바뀐다.

Expected: 고치고 나면 BUILD SUCCEEDED

- [ ] **Step 4: 커밋**

```bash
git add App/Route/RouteClient.swift
git commit -m "경로 목록에서 노선도를 받는다"
```

---

## Task 8: 귀가자 액티비티에 노선도를 싣는다

**Files:**
- Modify: `App/HomecomingActivityManager.swift:73-79`
- Modify: `App/HomecomingCoordinator.swift:270-279`, `:588-613`

- [ ] **Step 1: `activity.start()` 가 노선도를 받게 한다**

`App/HomecomingActivityManager.swift` 의 `start(...)` 선언에 인자를 더하고, `HomecomingAttributes(...)` 에 넘긴다.

```swift
        let attributes = HomecomingAttributes(
            travelerName: travelerName,
            destinationName: destinationName,
            departedAt: Date(),
            sessionID: sessionID,
            audience: audience,
            routeShape: routeShape
        )
```

`start(...)` 의 인자 목록에서 `checkInDeadline:` **앞**에 넣는다.

```swift
        routeShape: HomecomingAttributes.RouteShape? = nil,
```

기본값 `nil` 이라 다른 호출부(데모·재시작)가 그대로 컴파일된다.

- [ ] **Step 2: `ETAEstimate` 가 노선도를 나르게 한다**

`startingEstimate()` 가 경로에서 값을 꺼내는 자리가 이미 있다. 거기에 노선도를 얹는다.
`App/ETA/ETAProviding.swift` 의 `ETAEstimate` 에 필드를 더한다.

```swift
    /// 저장된 경로로 도는 귀가면 그 노선도. 다른 출처면 nil 이다.
    var routeShape: HomecomingAttributes.RouteShape?
```

기본값이 있어야 다른 생성자가 안 깨진다. 선언에 `= nil` 을 붙인다.

- [ ] **Step 3: `startingEstimate()` 에서 채운다**

`App/HomecomingCoordinator.swift:606-612` 의 반환을 이렇게 바꾼다.

```swift
        return ETAEstimate(
            expectedArrival: Date().addingTimeInterval(TimeInterval(route.totalSeconds)),
            routeMeters: along,
            transport: route.firstTransport ?? fallback.transport,
            detail: route.firstDetail,
            source: .savedRoute,
            // 노선도도 경로에서 온다. 도착예정·수단·거리와 같은 출처여야
            // 카드와 노선도가 어긋나지 않는다.
            routeShape: route.stops.map { HomecomingAttributes.RouteShape(stops: $0) }
        )
```

- [ ] **Step 4: 액티비티 시작에 넘긴다**

`App/HomecomingCoordinator.swift:271-279` 의 `activity.start(...)` 호출에 한 줄을 더한다.

```swift
            try activity.start(
                travelerName: travelerName,
                destinationName: home.name,
                transport: estimate.transport,
                totalMeters: estimate.routeMeters,
                expectedArrival: estimate.expectedArrival,
                detail: estimate.detail,
                routeShape: estimate.routeShape,
                checkInDeadline: safetyMode ? Date().addingTimeInterval(checkInInterval) : nil
            )
```

- [ ] **Step 5: 빌드한다**

Run: `xcodebuild -project Homecoming.xcodeproj -scheme Homecoming -destination 'generic/platform=iOS' build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

- [ ] **Step 6: 커밋**

```bash
git add App/HomecomingActivityManager.swift App/HomecomingCoordinator.swift App/ETA/ETAProviding.swift
git commit -m "귀가자 액티비티에 노선도를 싣는다"
```

---

## Task 9: 귀가자 화면에 노선도 카드를 놓는다

**Files:**
- Modify: `App/ContentView.swift:42-43`

- [ ] **Step 1: 카드를 넣는다**

`App/ContentView.swift` 의 `modePicker` 와 `statusCard` **사이**에 넣는다.

```swift
                    modePicker
                    travelerStripCard
                    statusCard
```

그리고 `// MARK: - 구성 요소` (116줄) 아래에 정의를 넣는다.

```swift
    /// 귀가자가 보는 노선도.
    ///
    /// **가족 화면과 글자 하나 안 틀리게 같다.** 자기 폰에 "아빠가 오는 중" 이라고
    /// 뜨는 건 어색한데, 그게 요점이다 — 귀가자가 보는 것은 자기 상태가 아니라
    /// 가족에게 나가고 있는 그림이다. 문구를 바꾸면 그 뜻이 사라진다.
    ///
    /// `statusCard` 와 섞지 않는다. 그쪽은 조종석이다(가족에게 보이는 이름,
    /// 추정 출처, 관측 보정, 전송 상태). 진단값과 공유되는 그림은 성격이 다르다.
    @ViewBuilder
    private var travelerStripCard: some View {
        if activity.isRunning,
           let shape = activity.currentAttributes?.routeShape,
           let state = activity.currentState {
            Card {
                RouteStripView(shape: shape, state: state, lastFixedAt: coordinator.lastReportedAt)
            }
        }
    }
```

- [ ] **Step 2: `HomecomingActivityManager` 가 지금 값을 내주게 한다**

`activity.currentAttributes` 와 `activity.currentState` 가 없으면 만든다.
`App/HomecomingActivityManager.swift` 에 넣는다.

```swift
    /// 지금 떠 있는 액티비티의 고정값. 화면이 노선도를 그리는 데 쓴다.
    var currentAttributes: HomecomingAttributes? { activity?.attributes }

    /// 지금 떠 있는 액티비티의 갱신값.
    var currentState: HomecomingAttributes.ContentState? { activity?.content.state }
```

`activity` 가 `@Observable` 이 관찰하는 저장 속성이 아니면 화면이 안 갱신된다.
그 경우 기존에 `isRunning` 이 어떻게 갱신되는지 보고 같은 방식을 쓴다.

- [ ] **Step 3: `lastReportedAt` 을 밖에서 읽을 수 있게 한다**

`App/HomecomingCoordinator.swift` 의 `lastReportedAt` 이 `private` 이면 `private(set)` 으로 바꾼다.

- [ ] **Step 4: 빌드하고 시뮬레이터에서 본다**

```bash
xcodebuild -project Homecoming.xcodeproj -scheme Homecoming \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

데모 모드로 귀가를 시작해 노선도가 뜨는지, 점이 정류장 순서대로 지나가는지 본다.

- [ ] **Step 5: 커밋**

```bash
git add App/ContentView.swift App/HomecomingActivityManager.swift App/HomecomingCoordinator.swift
git commit -m "귀가자도 자기 노선도를 본다"
```

---

## Task 10: 두 화면이 같은지 실기기로 확인한다

**이것이 이 작업의 회귀 시험이다.** 두 폰의 노선도가 다르면 접는 규칙이 두 벌이 됐다는 뜻이다.

- [ ] **Step 1: 서버를 배포한다**

```bash
git push
```

Railway 가 `auth-session-token` 브랜치를 보고 있지 않으면 배포 설정을 확인한다.

- [ ] **Step 2: e2e 를 돌린다**

```bash
Tools/e2e-device.sh --route Tools/routes/commute-sample.json --play-speed 25
```

Expected: 84분 경로가 3분 반에 재생되고, 연결된 실기기 잠금화면에 카드가 뜬다.

**`--regen` 을 붙이지 마라.** Xcode 가 열려 있으면 프로젝트 파일이 갈리면서
`contents.xcworkspacedata` 가 사라진다. 이 계획은 새 Swift 파일을 만들지 않으므로
재생성할 이유가 없다.

- [ ] **Step 3: 두 폰을 나란히 놓고 본다**

페어링된 두 폰(`f9bd0a58` 귀가자, `a06b1002` 가족)에서 앱을 열고 노선도를 나란히 본다.

확인할 것:
- 정류장 이름 7개가 **양쪽에서 같다**
- 지금 점이 **같은 자리**에 있다
- 접힌 줄(`⋯ N곳 지남`)이 같은 개수를 말한다
- `출발역.은행앞` 이 잘리되 읽을 수 있다

하나라도 다르면 접는 규칙이 두 벌이 된 것이다. 서버 응답을 직접 본다:

```bash
curl -s -H "Authorization: Bearer <토큰>" \
  https://homecoming-production-8463.up.railway.app/route | python3 -m json.tool | head -40
```

- [ ] **Step 4: 경로 없는 귀가로 폴백을 확인한다**

경로를 안 고르고 귀가를 시작해 **지금 카드(진행 바)** 가 그대로 나오는지 본다.

- [ ] **Step 5: 커밋**

```bash
git add -A
git commit -m "노선도를 실기기에서 확인한다"
```

---

## 자체 점검 기록

**설계 대비 빠진 것** — 설계의 모든 절이 작업에 대응한다.

| 설계 절 | 작업 |
|---|---|
| 새 고정값 (`RouteShape`) | Task 3 |
| 접는 규칙은 서버에만 산다 | Task 1, 2 |
| 접는 함수 (`route_stops`) | Task 1 |
| 갱신값은 안 건드린다 | 전 작업. `ContentState` 를 고치는 단계가 없다 |
| 점을 어디에 찍나 | Task 4 |
| 위치 보고가 끊길 때 | Task 5 (`hereNote`) |
| 정류장 이름이 길다 | Task 5 (`lineLimit` · `minimumScaleFactor`) |
| 세로로 길다 (접기) | Task 5 (`visible` · `skipped`) |
| 페이로드가 넘칠 수 있다 | Task 2 (`ROUTE_SHAPE_MAX_BYTES`) |
| 귀가자 화면 | Task 8, 9 |
| 두 화면이 같은지 | Task 10 |
| 경로 없으면 폴백 | Task 6, Task 10 Step 4 |

**미리 정해 둔 것** — 계획을 쓰다 드러난 사실 세 가지.

1. **`activity.start()` 가 `openSession()` 보다 먼저다.** 그래서 노선도가 세션 응답이 아니라 경로 목록 응답으로 온다. 설계를 이미 고쳤다(`c85b908`).
2. **접을 때 `leg_length()` 를 써야 한다.** 저장된 `meters` 필드로 재면 합이 `totalMeters` 와 1m 어긋나고 점이 마지막 정류장에서 밀린다. Task 1 의 `test_거리의_합이_경로_길이와_같다` 가 이걸 지킨다.
3. **새 Swift 파일을 만들지 않는다.** `generate_project.rb` 재생성의 사고 이력을 피한다.

**정하지 못한 것 하나** — Task 9 Step 2 의 `activity.currentAttributes` / `currentState` 가 `@Observable` 로 화면에 반영되는지는 `HomecomingActivityManager` 의 실제 관찰 구조를 봐야 안다. 그 단계에서 `isRunning` 이 어떻게 갱신되는지 보고 같은 방식을 쓴다. 안 되면 `WatchingStore` 처럼 `activity.contentUpdates` 를 구독하는 작은 저장소를 만든다.
