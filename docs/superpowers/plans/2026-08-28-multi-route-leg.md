# 한 구간에 버스 노선 여럿 — 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 버스 구간 하나에 노선번호를 여럿 적고, 도착 칩이 **노선 상관없이 빠른 순 두 대**를 보여 준다.

**Architecture:** 한 노선을 묻는 `bus_arrival` 은 그대로 두고, **여러 노선을 물어 합치는 함수를 위에 얹는다.** 저장은 `busNo` 를 그대로 두고 `busNos` 를 더한다 — 옛 서버·옛 앱이 만나도 첫 노선으로 내려앉는다. 화면 둘째 줄에 노선번호를 적기 위해 `ContentState` 에 `busArrivalThenNo` 하나가 는다.

**Tech Stack:** 서버는 Python 3 표준 라이브러리, 앱은 SwiftUI. 의존성 추가 없음.

설계 문서: [`../specs/2026-08-28-multi-route-leg-design.md`](../specs/2026-08-28-multi-route-leg-design.md)

---

## 파일 구조

| 파일 | 무엇을 맡나 |
|---|---|
| `Server/homecoming_server.py` (수정) | 여러 노선 합치기, `next_bus_leg`·`arrival_ready` 가 `busNos` 를 읽기 |
| `Server/test_multi_route.py` (신규) | 합치기 규칙의 시험. 네트워크를 안 탄다 |
| `Shared/HomecomingAttributes.swift` (수정) | `busArrivalThenNo` — 와이어 세 곳 + 문구 |
| `App/HomecomingActivityManager.swift` (수정) | 와이어 **네 번째** — `update()` 가 옮겨 담기 |
| `Shared/HomecomingViewParts.swift` (수정) | 둘째 줄 앞머리를 `그다음` 또는 `6713번` 으로 |
| `App/Route/RouteTracer.swift` (수정) | `Step.busNos` |
| `App/Route/RouteClient.swift` (수정) | `RouteLeg.busNos` — 보내고 받기 |
| `App/Route/RouteEditor.swift` (수정) | 노선 칩 입력 |

## 이 계획이 기대는 사실 (2026-08-28 실측)

```
국회의사당역.KB국민은행 → 신촌로터리
  163   staOrd 60 → 64      6713  staOrd 28 → 32     하차 기둥 둘 다 14205
서울 노선번호 723개에 공백·쉼표 없음 (괄호와 하이픈만: 7007-1, 한강버스(서부))
```

---

### Task 1: 여러 노선을 합쳐 빠른 순으로

**Files:**
- Modify: `Server/homecoming_server.py` — `def arrival_pending`(`:2923`) 바로 앞
- Test: `Server/test_multi_route.py` (신규)

- [ ] **Step 1: 실패하는 시험을 쓴다**

`Server/test_multi_route.py` 를 새로 만든다:

```python
"""한 구간에 노선이 여럿일 때 도착값을 합치는 규칙.

    python3 -m unittest discover -s Server

**네트워크를 안 탄다.** 한 노선을 묻는 함수를 갈아 끼우고 합치는 규칙만 본다.

의존성 없음. 표준 unittest 다.
"""

import os
import pathlib
import sys
import tempfile
import unittest
from datetime import timedelta
from unittest import mock

# **시험은 진짜 DB 에 안 붙는다.** `DB_PATH` 는 import 할 때 정해지고, 여기서
# 안 걸면 먼저 import 되는 쪽이 이겨 저장소의 DB 를 쓴다 — 다른 시험의
# `DELETE FROM` 이 실제 경로를 지운다(2026-08-27 에 실제로 그랬다).
_TMP = tempfile.mkdtemp()
os.environ.setdefault("HOMECOMING_DB", str(pathlib.Path(_TMP) / "test.sqlite"))

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import homecoming_server as hs   # noqa: E402


def value(no, minutes, stops, then_minutes=None, then_stops=None):
    """`bus_arrival` 이 돌려주는 모양."""
    at = hs.now()
    out = {"no": no, "at": at + timedelta(minutes=minutes),
           "stops": stops, "measuredAt": at}
    if then_minutes is not None:
        out["thenAt"] = at + timedelta(minutes=then_minutes)
        out["thenStops"] = then_stops
    return out


class MergeArrivalsTests(unittest.TestCase):
    """**두 줄은 노선 상관없이 빠른 순 두 대다.**

    이 칩이 답하는 질문은 *지금 뭘 타나* 이지 *어느 노선을 볼까* 가 아니다.
    2026-08-28 실측 — 국회의사당역 → 신촌로터리를 163 과 6713 이 같이 간다.
    """

    def test_빠른_쪽이_앞에_온다(self):
        merged = hs.merge_arrivals([value("163", 12, 5), value("6713", 3, 1)])
        self.assertEqual(merged["no"], "6713")
        self.assertEqual(merged["stops"], 1)
        self.assertEqual(merged["thenNo"], "163")
        self.assertEqual(merged["thenStops"], 5)

    def test_같은_노선의_두_대도_빠른_순에_들어간다(self):
        # 163 이 3분·6분이고 6713 이 20분이면 앞의 둘이 163 이다.
        merged = hs.merge_arrivals([value("163", 3, 1, then_minutes=6, then_stops=3),
                                    value("6713", 20, 9)])
        self.assertEqual(merged["no"], "163")
        self.assertEqual(merged["thenNo"], "163")
        self.assertEqual(merged["thenStops"], 3)

    def test_한_노선이_없어도_나머지를_준다(self):
        merged = hs.merge_arrivals([None, value("6713", 3, 1)])
        self.assertEqual(merged["no"], "6713")
        self.assertNotIn("thenNo", merged)

    def test_다_없으면_None(self):
        self.assertIsNone(hs.merge_arrivals([None, None]))
        self.assertIsNone(hs.merge_arrivals([]))

    def test_measuredAt_은_가장_최근_것을_쓴다(self):
        # 정류장 수의 나이를 재는 값이다. 늙은 쪽을 쓰면 숫자가 먼저 감춰진다.
        old = value("163", 12, 5)
        old["measuredAt"] = old["measuredAt"] - timedelta(seconds=90)
        merged = hs.merge_arrivals([old, value("6713", 3, 1)])
        self.assertEqual(merged["measuredAt"], merged["at"] - timedelta(minutes=3))


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 실패를 확인한다**

Run: `python3 -m unittest discover -s Server`
Expected: FAIL — `AttributeError: module 'homecoming_server' has no attribute 'merge_arrivals'`

- [ ] **Step 3: 최소 구현**

`Server/homecoming_server.py` 의 `def arrival_pending(` 바로 앞에 넣는다:

```python
def merge_arrivals(values):
    """여러 노선의 도착값을 **노선 상관없이 빠른 순 두 대**로 합친다.

    돌려주는 것은 `bus_arrival` 과 **같은 모양에 `thenNo` 하나가 더 붙은 것**이다.
    다 없으면 None.

    **왜 노선별로 한 대씩이 아닌가.** 이 칩은 *뛸까 말까* 를 정하려고 본다.
    163이 3분·6분 뒤이고 6713이 20분 뒤면, 알고 싶은 것은 앞의 둘이다.

    `measuredAt` 은 **가장 최근 것**을 쓴다. 정류장 수의 나이를 재는 값이라
    (`busArrivalStopsFresh`, 60초), 늙은 쪽을 쓰면 아직 참인 숫자가 먼저 감춰진다.
    """
    coming = []
    latest = None
    for value in values:
        if not value:
            continue
        measured = value.get("measuredAt")
        if measured and (latest is None or measured > latest):
            latest = measured
        coming.append((value["at"], value["no"], value.get("stops")))
        if value.get("thenAt"):
            coming.append((value["thenAt"], value["no"], value.get("thenStops")))
    if not coming:
        return None
    coming.sort(key=lambda row: row[0])

    at, no, stops = coming[0]
    merged = {"no": no, "at": at, "stops": stops, "measuredAt": latest}
    if len(coming) > 1:
        then_at, then_no, then_stops = coming[1]
        merged["thenAt"] = then_at
        merged["thenNo"] = then_no
        merged["thenStops"] = then_stops
    return merged
```

- [ ] **Step 4: 통과를 확인한다**

Run: `python3 -m unittest discover -s Server`
Expected: OK — 180개 + 5개 = 185개

- [ ] **Step 5: 커밋**

```bash
git add Server/homecoming_server.py Server/test_multi_route.py
git commit -m "여러 노선의 도착값을 빠른 순으로 합친다"
```

---

### Task 2: 구간에서 노선번호를 여럿 읽는다

**Files:**
- Modify: `Server/homecoming_server.py` — `def next_bus_leg`(`:2811`) 바로 앞
- Test: `Server/test_multi_route.py`

- [ ] **Step 1: 실패하는 시험을 쓴다**

`Server/test_multi_route.py` 의 `MergeArrivalsTests` 아래에 붙인다:

```python
class LegRouteNumbersTests(unittest.TestCase):
    """**`busNos` 가 있으면 그것, 없으면 `busNo` 하나.**

    저장할 때 둘 다 쓴다. 옛 서버·옛 앱이 만나도 첫 노선으로 내려앉게 하려는
    것이다 — `busNo` 하나에 `"163,6713"` 을 욱여넣으면 옛쪽이 그 문자열로
    노선을 찾다 실패해 칩이 통째로 사라진다.
    """

    def test_busNos_가_있으면_그것을_쓴다(self):
        leg = {"busNo": "163", "busNos": ["163", "6713"]}
        self.assertEqual(hs.leg_route_numbers(leg), ["163", "6713"])

    def test_busNos_가_없으면_busNo_하나다(self):
        self.assertEqual(hs.leg_route_numbers({"busNo": "163"}), ["163"])

    def test_빈_값은_거른다(self):
        leg = {"busNo": "163", "busNos": ["163", "", "  ", None, "6713"]}
        self.assertEqual(hs.leg_route_numbers(leg), ["163", "6713"])

    def test_같은_번호는_한_번만(self):
        # 두 번 물으면 한도만 태운다.
        leg = {"busNos": ["163", "163", "6713"]}
        self.assertEqual(hs.leg_route_numbers(leg), ["163", "6713"])

    def test_아무것도_없으면_빈_목록(self):
        self.assertEqual(hs.leg_route_numbers({}), [])
        self.assertEqual(hs.leg_route_numbers({"busNo": ""}), [])
        self.assertEqual(hs.leg_route_numbers({"busNos": []}), [])
```

- [ ] **Step 2: 실패를 확인한다**

Run: `python3 -m unittest discover -s Server`
Expected: FAIL — `AttributeError: ... 'leg_route_numbers'`

- [ ] **Step 3: 최소 구현**

`def next_bus_leg(` 바로 앞에 넣는다:

```python
def leg_route_numbers(leg):
    """그 구간에서 탈 수 있는 노선번호들. 없으면 빈 목록.

    **`busNos` 가 있으면 그것, 없으면 `busNo` 하나.** 저장할 때 둘 다 쓴다 —
    옛 서버·옛 앱이 만나도 첫 노선으로 내려앉게 하려는 것이다. `busNo` 하나에
    `"163,6713"` 을 욱여넣으면 옛쪽이 그 문자열로 노선을 찾다 실패해 **칩이
    통째로 사라진다.** 조용히 나빠지는 쪽을 피한다.

    같은 번호는 한 번만 남긴다. 두 번 물으면 한도만 태운다.
    """
    raw = leg.get("busNos") or ([leg.get("busNo")] if leg.get("busNo") else [])
    out = []
    for no in raw:
        text = str(no or "").strip()
        if text and text not in out:
            out.append(text)
    return out
```

- [ ] **Step 4: 통과를 확인한다**

Run: `python3 -m unittest discover -s Server`
Expected: OK — 190개

- [ ] **Step 5: 커밋**

```bash
git add Server/homecoming_server.py Server/test_multi_route.py
git commit -m "구간의 노선번호를 여럿 읽는다 — busNos 가 있으면 그것"
```

---

### Task 3: 도착 조회가 여러 노선을 본다

**Files:**
- Modify: `Server/homecoming_server.py:2811` `next_bus_leg` · `:2923` `arrival_pending` · `:2949` `arrival_ready`
- Test: `Server/test_multi_route.py`

- [ ] **Step 1: 실패하는 시험을 쓴다**

```python
class ArrivalReadyMultiTests(unittest.TestCase):
    """`arrival_ready` 가 구간의 노선을 **전부** 묻고 합친다."""

    LEGS = [
        {"mode": "walk", "startsAt": 0, "seconds": 240, "points": [[37.5, 127.0]]},
        {"mode": "bus", "busNo": "163", "busNos": ["163", "6713"],
         "startsAt": 240, "seconds": 900, "points": [[37.528491, 126.918087]]},
    ]

    def setUp(self):
        hs._arrival_ready.clear()

    def seed(self, no, minutes):
        key = (no, 37.528491, 126.918087)
        hs._arrival_ready[key] = (hs.now(), value(no, minutes, 1))

    def test_두_노선을_다_보고_빠른_쪽을_준다(self):
        self.seed("163", 12)
        self.seed("6713", 3)
        with mock.patch.object(hs, "start_arrival_refresh", lambda *_a: None):
            got = hs.arrival_ready(self.LEGS, 0)
        self.assertEqual(got["no"], "6713")
        self.assertEqual(got["thenNo"], "163")

    def test_한_노선만_있어도_준다(self):
        self.seed("6713", 3)
        with mock.patch.object(hs, "start_arrival_refresh", lambda *_a: None):
            got = hs.arrival_ready(self.LEGS, 0)
        self.assertEqual(got["no"], "6713")

    def test_옛_구간은_busNo_하나로_돈다(self):
        legs = [dict(self.LEGS[0]), {k: v for k, v in self.LEGS[1].items()
                                     if k != "busNos"}]
        self.seed("163", 12)
        with mock.patch.object(hs, "start_arrival_refresh", lambda *_a: None):
            got = hs.arrival_ready(legs, 0)
        self.assertEqual(got["no"], "163")

    def test_노선마다_배경_갱신을_건다(self):
        asked = []
        with mock.patch.object(hs, "start_arrival_refresh",
                               lambda no, la, lo: asked.append(no)):
            hs.arrival_ready(self.LEGS, 0)
        self.assertEqual(sorted(asked), ["163", "6713"])
```

- [ ] **Step 2: 실패를 확인한다**

Run: `python3 -m unittest discover -s Server`
Expected: FAIL — 첫 시험이 `'163'` 을 준다(지금은 `busNo` 하나만 본다)

- [ ] **Step 3: `next_bus_leg` 가 `leg_route_numbers` 를 쓰게 한다**

`Server/homecoming_server.py` 의 `next_bus_leg` 안에서 `busNo` 를 보는 두 줄을 바꾼다:

```python
    current = legs[here]
    if (current.get("mode") == "bus" and leg_route_numbers(current)
            and lat is not None and lon is not None):
```

그리고 그 아래 반복문:

```python
    for leg in legs[here + 1:]:
        if leg.get("mode") == "bus" and leg_route_numbers(leg):
            return leg
```

- [ ] **Step 4: `arrival_ready` 가 노선마다 묻고 합치게 한다**

`arrival_ready` 의 `key = (str(leg["busNo"]), lat, lon)` 부터 `return value` 까지를
아래로 바꾼다:

```python
    lat, lon = points[0][0], points[0][1]
    numbers = leg_route_numbers(leg)

    # **노선마다 캐시를 본다.** 기다리지 않는다 — 없는 것은 배경에서 채운다.
    found = []
    for number in numbers:
        cached = _arrival_ready.get((number, lat, lon))
        value = cached[1] if cached else None

        # **이미 지난 시각은 주지 않는다.** 배경 갱신이 계속 실패하면 마지막으로
        # 성공한 값이 그대로 남는데, 절대시각이라 시계가 흐르면 언젠가 과거가
        # 된다. 그때 화면은 **이미 떠난 버스**를 `18:42 도착` 이라고 말한다.
        gone = value is not None and value["at"] < at
        if gone:
            value = None
        elif cached and (at - cached[0]).total_seconds() < ARRIVAL_CACHE_SECONDS:
            found.append(value)
            continue
        start_arrival_refresh(number, lat, lon)
        found.append(value)
    return merge_arrivals(found)
```

- [ ] **Step 5: `arrival_pending` 도 같은 자를 쓰게 한다**

`arrival_pending` 의 `if not leg or not leg.get("busNo"):` 와 마지막 `return` 을 바꾼다:

```python
    leg = next_bus_leg(legs, progress, lat, lon)
    numbers = leg_route_numbers(leg) if leg else []
    if not numbers:
        return None
```

그리고 함수 끝:

```python
    if arrival_ready(legs, progress, now=at, lat=lat, lon=lon):
        return None
    return numbers[0]
```

- [ ] **Step 6: 통과를 확인한다**

Run: `python3 -m unittest discover -s Server`
Expected: OK — 194개

- [ ] **Step 7: 커밋**

```bash
git add Server/homecoming_server.py Server/test_multi_route.py
git commit -m "도착 조회가 구간의 노선을 전부 본다"
```

---

### Task 4: `content_state` 가 `thenNo` 를 싣는다

**Files:**
- Modify: `Server/homecoming_server.py` — `state["busArrivalThenAt"]` 근처
- Test: `Server/test_multi_route.py`

- [ ] **Step 1: 실패하는 시험을 쓴다**

```python
class ThenNoWireTests(unittest.TestCase):
    """둘째 줄의 노선번호가 상태에 실린다."""

    def test_노선이_다르면_thenNo_가_실린다(self):
        merged = hs.merge_arrivals([value("163", 12, 5), value("6713", 3, 1)])
        state = {}
        hs.put_arrival(state, merged)
        self.assertEqual(state["busArrivalNo"], "6713")
        self.assertEqual(state["busArrivalThenNo"], "163")

    def test_같은_노선이면_thenNo_를_안_싣는다(self):
        # 화면이 `그다음` 으로 적는다. 번호를 두 번 적으면 눈이 시끄럽다.
        merged = hs.merge_arrivals([value("163", 3, 1, then_minutes=6, then_stops=3)])
        state = {}
        hs.put_arrival(state, merged)
        self.assertEqual(state["busArrivalNo"], "163")
        self.assertNotIn("busArrivalThenNo", state)

    def test_그다음이_없으면_아무것도_안_싣는다(self):
        state = {}
        hs.put_arrival(state, hs.merge_arrivals([value("163", 3, 1)]))
        self.assertNotIn("busArrivalThenAt", state)
        self.assertNotIn("busArrivalThenNo", state)
```

- [ ] **Step 2: 실패를 확인한다**

Run: `python3 -m unittest discover -s Server`
Expected: FAIL — `AttributeError: ... 'put_arrival'`

- [ ] **Step 3: 지금 `content_state` 안에 있는 블록을 함수로 뺀다**

`merge_arrivals` 바로 아래에 넣는다:

```python
def put_arrival(state, arrival):
    """합친 도착값을 상태에 싣는다. 없으면 아무것도 안 싣는다.

    **`thenNo` 는 노선이 다를 때만 싣는다.** 같으면 화면이 `그다음` 으로 적는다 —
    같은 번호를 두 번 적으면 눈이 시끄럽다.
    """
    if not arrival:
        return
    state["busArrivalNo"] = arrival["no"]
    state["busArrivalAt"] = iso(arrival["at"])
    if arrival.get("stops") is not None:
        state["busArrivalStops"] = arrival["stops"]
    # **정류장 수는 늙지 않는다.** 시각은 절대시각이라 시계가 흐르면 스스로
    # 맞아 가는데, `5정류장 전` 은 그대로 남아 거짓이 된다(약 57초에 하나씩
    # 줄었다, 2026-08-26 실측). 그래서 화면이 나이를 알아야 한다.
    if arrival.get("measuredAt"):
        state["busArrivalMeasuredAt"] = iso(arrival["measuredAt"])
    if arrival.get("thenAt"):
        state["busArrivalThenAt"] = iso(arrival["thenAt"])
        if arrival.get("thenStops") is not None:
            state["busArrivalThenStops"] = arrival["thenStops"]
        if arrival.get("thenNo") and arrival["thenNo"] != arrival["no"]:
            state["busArrivalThenNo"] = arrival["thenNo"]
```

- [ ] **Step 4: `content_state` 가 그 함수를 쓰게 한다**

`content_state` 안에서 `if arrival:` 로 시작해 `state["busArrivalThenStops"] = arrival["thenStops"]`
로 끝나는 블록을 통째로 아래 한 줄로 바꾼다. 그 앞의 `if not arrival:` 블록
(`arrival_pending`)은 그대로 둔다:

```python
        put_arrival(state, arrival)
```

- [ ] **Step 5: 통과를 확인한다**

Run: `python3 -m unittest discover -s Server`
Expected: OK — 197개

- [ ] **Step 6: 커밋**

```bash
git add Server/homecoming_server.py Server/test_multi_route.py
git commit -m "둘째 줄의 노선번호를 상태에 싣는다 — 노선이 다를 때만"
```

---

### Task 5: 와이어 네 곳 — `busArrivalThenNo`

**Files:**
- Modify: `Shared/HomecomingAttributes.swift` — 필드(`:230` 근처) · `CodingKeys`(`:549`) · `init(from:)`(`:577`) · `encode(to:)`(`:605`)
- Modify: `App/HomecomingActivityManager.swift:263` — **네 번째**

**이 과제가 이 계획에서 가장 위험하다.** 네 번째를 빠뜨리면 **시험은 다 통과하고 화면만 빈다.** 2026-08-26 에 실제로 그랬다.

- [ ] **Step 1: 필드를 더한다**

`Shared/HomecomingAttributes.swift` 의 `var busArrivalThenAt: Date?` 바로 앞에 넣는다:

```swift
        /// 그다음 차의 노선번호. **노선이 다를 때만 온다.**
        ///
        /// 한 구간에 노선이 여럿일 수 있다 — 국회의사당역 → 신촌로터리를 163 과
        /// 6713 이 같이 간다(2026-08-28 실측). 두 줄은 노선 상관없이 빠른 순
        /// 두 대라, 둘째 줄이 다른 노선일 수 있다.
        ///
        /// 같은 노선이면 안 온다. 그때 화면은 예전처럼 `그다음` 이라고 적는다.
        var busArrivalThenNo: String?

```

- [ ] **Step 2: `CodingKeys` 에 더한다**

`case busArrivalThenAt` 바로 앞에 넣는다:

```swift
        case busArrivalThenNo
```

- [ ] **Step 3: `init(from:)` 에 더한다**

`busArrivalThenAt = try container.decodeWireDateIfPresent(forKey: .busArrivalThenAt)`
바로 앞에 넣는다:

```swift
        busArrivalThenNo = try container.decodeIfPresent(String.self, forKey: .busArrivalThenNo)
```

- [ ] **Step 4: `encode(to:)` 에 더한다**

`try container.encodeWireIfPresent(busArrivalThenAt, forKey: .busArrivalThenAt)`
바로 앞에 넣는다:

```swift
        try container.encodeIfPresent(busArrivalThenNo, forKey: .busArrivalThenNo)
```

- [ ] **Step 5: 네 번째 — `update()` 가 옮겨 담게 한다**

`App/HomecomingActivityManager.swift:263` 의 `busArrivalThenAt: previous.busArrivalThenAt,`
바로 앞에 넣는다:

```swift
            // **서버만 아는 값이다.** 안 옮기면 로컬 갱신 한 번에 지워진다 —
            // 서버는 계속 보내는데 화면에서 사라진다.
            busArrivalThenNo: previous.busArrivalThenNo,
```

- [ ] **Step 6: 빌드**

Run:
```bash
xcodebuild -project Homecoming.xcodeproj -scheme Homecoming -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "error:|BUILD"
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: 네 곳을 다 지나는지 확인한다**

**왜 글자로 재나** — 이 저장소에는 Swift 시험 타깃이 없다(시험 197개가 전부
파이썬이다). 인코딩→디코딩→`update()` 왕복을 진짜로 돌리려면 시험 타깃을 새로
만들어야 하는데 그건 이 계획의 범위 밖이다. **빠뜨리는 것을 잡는 것이 목적이고,
그건 글자로도 잡힌다.** 실제 왕복은 Task 9 의 화면 확인이 본다.

Run:
```bash
python3 - <<'PY'
import re, pathlib
a = pathlib.Path("Shared/HomecomingAttributes.swift").read_text(encoding="utf-8")
m = pathlib.Path("App/HomecomingActivityManager.swift").read_text(encoding="utf-8")
checks = [
    ("필드",        "var busArrivalThenNo: String?" in a),
    ("CodingKeys", "case busArrivalThenNo" in a),
    ("init(from:)", "decodeIfPresent(String.self, forKey: .busArrivalThenNo)" in a),
    ("encode(to:)", "encodeIfPresent(busArrivalThenNo, forKey: .busArrivalThenNo)" in a),
    ("update()",    "busArrivalThenNo: previous.busArrivalThenNo" in m),
]
for name, ok in checks:
    print(f"  {'OK ' if ok else '빠짐'} {name}")
raise SystemExit(0 if all(ok for _, ok in checks) else 1)
PY
```
Expected: 다섯 줄 다 `OK`

- [ ] **Step 8: 커밋**

```bash
git add Shared/HomecomingAttributes.swift App/HomecomingActivityManager.swift
git commit -m "busArrivalThenNo 를 와이어 네 곳에 더한다"
```

---

### Task 6: 둘째 줄에 노선번호를 그린다

**Files:**
- Modify: `Shared/HomecomingAttributes.swift` — `busArrivalLine`
- Modify: `Shared/HomecomingViewParts.swift` — 둘째 줄의 `그다음`

- [ ] **Step 1: 한 줄 문구를 고친다**

`Shared/HomecomingAttributes.swift` 의 `busArrivalLine` 안에서
`if let then = busArrivalThenClockText { line += " · 다음 \(then)" }` 를 바꾼다:

```swift
        if let then = busArrivalThenClockText {
            // 노선이 다르면 번호를 적는다. 같으면 `다음` 으로 충분하다.
            line += busArrivalThenNo.map { " · \($0)번 \(then)" } ?? " · 다음 \(then)"
        }
```

- [ ] **Step 2: 칩의 둘째 줄을 고친다**

`Shared/HomecomingViewParts.swift` 의 둘째 줄 `Text("그다음")` 을 바꾼다:

```swift
                    Text(state.busArrivalThenNo.map { "\($0)번" } ?? "그다음")
                        .font(.system(size: 11, weight: .semibold))
                        .opacity(0.55)
```

- [ ] **Step 3: 빌드**

Run:
```bash
xcodebuild -project Homecoming.xcodeproj -scheme Homecoming -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "error:|BUILD"
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: 커밋**

```bash
git add Shared
git commit -m "둘째 줄에 노선번호를 적는다 — 같은 노선이면 그다음"
```

---

### Task 7: 앱 모델이 노선을 여럿 담는다

**Files:**
- Modify: `App/Route/RouteClient.swift:204` `RouteLeg` · `:208` `CodingKeys` · `:221` `wire`
- Modify: `App/Route/RouteTracer.swift:45` `Step.busNos`

- [ ] **Step 1: `RouteLeg` 에 더한다**

`App/Route/RouteClient.swift` 의 `var busNo: String?` 바로 뒤에 넣는다:

```swift
    /// 이 구간에서 탈 수 있는 노선 전부. 예: `["163", "6713"]`.
    ///
    /// **`busNo` 를 그대로 두고 이것을 더한다.** `busNo` 하나에 `"163,6713"` 을
    /// 욱여넣으면 옛 서버가 그 문자열로 노선을 찾다 실패해 칩이 통째로 사라진다.
    /// 지금처럼 둬야 옛쪽이 만나도 **첫 노선으로 내려앉는다.**
    var busNos: [String]?
```

`CodingKeys` 를 바꾼다:

```swift
        case mode, startsAt, seconds, toName, points, busNo, busNos
    }
```

`wire` 의 `if let busNo, !busNo.isEmpty { out["busNo"] = busNo }` 바로 뒤에 넣는다:

```swift
        if let busNos, !busNos.isEmpty { out["busNos"] = busNos }
```

- [ ] **Step 2: `Step` 에 더한다**

`App/Route/RouteTracer.swift` 의 `var busNo: String?`(`:45`) 을 바꾸고 `init` 도 맞춘다:

```swift
        var busNo: String?

        /// 이 구간에서 탈 수 있는 노선 전부. 편집기가 칩으로 받는다.
        ///
        /// `busNo` 는 그중 첫 번째다 — 선을 그리는 것과 옛 서버가 그 값을 쓴다.
        var busNos: [String] = []
```

`init` 의 인자와 대입을 바꾼다:

```swift
        init(id: UUID = UUID(), mode: RouteLeg.Mode, toName: String = "",
             to: CLLocationCoordinate2D? = nil, minutes: Int = 5,
             busNo: String? = nil, busNos: [String] = []) {
            self.id = id
            self.mode = mode
            self.toName = toName
            self.to = to
            self.minutes = minutes
            self.busNo = busNo
            // 하나만 준 옛 호출도 그대로 돈다.
            self.busNos = busNos.isEmpty ? [busNo].compactMap { $0 } : busNos
        }
```

`==` 에 `busNos` 를 더한다 — 노선을 지웠는데 바뀜으로 안 잡히면 저장이 안 나간다:

```swift
                && a.minutes == b.minutes && a.busNo == b.busNo
                && a.busNos == b.busNos
```

- [ ] **Step 3: `RouteLeg` 를 만드는 자리에서 넘긴다**

`App/Route/RouteTracer.swift` 의 `legs.append(RouteLeg(` 안, `busNo:` 줄을 바꾼다:

```swift
                busNo: step.mode == .bus ? step.busNos.first ?? step.busNo : nil,
                busNos: step.mode == .bus ? step.busNos : nil
```

- [ ] **Step 4: 서버에서 받을 때 되살린다**

`App/Route/RouteClient.swift:76` 의 `busNo: leg.busNo` 를 바꾼다:

```swift
                busNo: leg.busNo,
                busNos: leg.busNos ?? [leg.busNo].compactMap { $0 }
```

- [ ] **Step 5: 빌드**

Run:
```bash
xcodebuild -project Homecoming.xcodeproj -scheme Homecoming -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "error:|BUILD"
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: 커밋**

```bash
git add App/Route
git commit -m "앱 모델이 구간의 노선을 여럿 담는다 — busNo 는 첫 번째로 남는다"
```

---

### Task 8: 편집기의 노선 칩

**Files:**
- Modify: `App/Route/RouteEditor.swift` — `StepRow` 의 노선 `TextField`

- [ ] **Step 1: 칩 입력을 만든다**

`App/Route/RouteEditor.swift` 의 `StepRow` 안, `if step.mode == .bus {` 로 시작하는
`TextField("노선", ...)` 블록을 통째로 아래로 바꾼다:

```swift
                if step.mode == .bus {
                    TextField("노선", text: $routeDraft)
                        .keyboardType(.numbersAndPunctuation)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .multilineTextAlignment(.center)
                        .frame(width: 52)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08)))
                        .foregroundStyle(.white)
                        .submitLabel(.done)
                        .onSubmit { commitRoute() }
                        // 쉼표나 공백을 쳐도 그때 쌓인다. 쉼표로 적던 습관이
                        // 있어도 그대로 통한다 — 노선번호에는 둘 다 안 들어간다
                        // (서울 723개 확인, 괄호와 하이픈만 있다).
                        .onChange(of: routeDraft) { _, new in
                            if new.hasSuffix(",") || new.hasSuffix(" ") { commitRoute() }
                        }
                }
```

- [ ] **Step 2: 칩 줄과 상태·동작을 더한다**

`StepRow` 의 `@State private var found = ""` 바로 뒤에 넣는다:

```swift
    /// 아직 칩이 안 된, 치고 있는 번호.
    @State private var routeDraft = ""

    /// **같은 번호는 한 번만 쌓는다.** 두 번 물으면 한도만 태운다.
    private func commitRoute() {
        let no = routeDraft.trimmingCharacters(in: CharacterSet(charactersIn: ", "))
            .trimmingCharacters(in: .whitespaces)
        routeDraft = ""
        guard !no.isEmpty, !step.busNos.contains(no) else { return }
        step.busNos.append(no)
        step.busNo = step.busNos.first
    }

    /// 등록된 노선들. `ⓧ` 로 하나씩 지운다.
    @ViewBuilder
    private var routeChips: some View {
        if step.mode == .bus, !step.busNos.isEmpty {
            HStack(spacing: 6) {
                ForEach(step.busNos, id: \.self) { no in
                    HStack(spacing: 4) {
                        Text(no)
                            .font(.system(size: 12, weight: .semibold))
                        Button {
                            step.busNos.removeAll { $0 == no }
                            step.busNo = step.busNos.first
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.white.opacity(0.12)))
                }
                Spacer(minLength: 0)
            }
        }
    }
```

- [ ] **Step 3: 칩 줄을 화면에 붙인다**

`StepRow` 의 `body` 안에서 첫 `HStack(spacing: 8) { ... }` 이 닫히는 바로 뒤에 넣는다:

```swift
            routeChips
```

- [ ] **Step 4: 빌드**

Run:
```bash
xcodebuild -project Homecoming.xcodeproj -scheme Homecoming -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "error:|BUILD"
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: 커밋**

```bash
git add App/Route/RouteEditor.swift
git commit -m "편집기가 노선을 칩으로 받는다 — 구분자를 안 배워도 된다"
```

---

### Task 9: 실측 — 시험이 말해 주지 않는 것

**시험만으로는 모른다.** 시험 환경에 `TAGO_KEY` 가 없어 조회가 즉시 빠져나간다.

- [ ] **Step 1: 배포한다**

**저장소 루트에서 쏜다** — `railway up` 은 지금 디렉터리를 올린다.

```bash
railway up --detach --service homecoming2
```

- [ ] **Step 2: 두 노선이 합쳐지는지 잰다**

```bash
python3 - <<'PY'
import json, re, urllib.parse, urllib.request, datetime
key = [l.strip().removeprefix("export ").split("=", 1)[1].strip().strip("\"'")
       for l in open("Server/.env.local") if "HOMECOMING_TAGO_KEY=" in l][0]
routes = json.loads(open("Server/data/seoul-routes.json", encoding="utf-8").read())
now = datetime.datetime.now()
print(f"{now:%H:%M:%S} · 국회의사당역 19132")
for no in ["163", "6713"]:
    q = urllib.parse.urlencode({"serviceKey": key, "busRouteId": routes[no][0]})
    with urllib.request.urlopen(urllib.request.Request(
            f"http://ws.bus.go.kr/api/rest/arrive/getArrInfoByRouteAll?{q}",
            headers={"User-Agent": "homecoming2"}), timeout=20) as r:
        body = r.read().decode("utf-8", "replace")
    def tag(it, n):
        m = re.search(rf"<{n}>(.*?)</{n}>", it)
        return m.group(1) if m else ""
    for it in re.findall(r"<itemList>(.*?)</itemList>", body, re.S):
        if tag(it, "arsId") == "19132":
            for n in (1, 2):
                sec = tag(it, f"traTime{n}")
                if sec and sec != "0":
                    at = now + datetime.timedelta(seconds=int(sec))
                    print(f"  {no:>5s}  {at:%H:%M:%S}  {tag(it, f'arrmsg{n}')}")
PY
```

Expected: 두 노선의 도착시각이 나온다. **이 목록을 빠른 순으로 세운 것이 칩에 떠야 할 값이다.**

- [ ] **Step 3: 앱에서 6713 을 더하고 저장한다**

앱 → `경로` 탭 → `퇴근길` → 163 구간의 노선 칸에 `6713` 을 치고 확인.
칩이 `163` `6713` 둘로 보이면 저장한다.

**좌표열은 저장할 때 박힌다.** 다시 저장해야 반영된다.

- [ ] **Step 4: 배포 로그로 확인한다**

```bash
railway logs --service homecoming2 --lines 60 | grep -E "경로 갱신|도착 새로고침"
```

Expected: `경로 갱신` 이 찍히고, 그 뒤 도착 새로고침이 **163 과 6713 둘 다** 나간다.

- [ ] **Step 5: 화면을 본다**

`귀가 시작` → 국회의사당역 승차 15분 창 안에서 칩을 본다.

```
🚌 6713번 09:01 도착 · 1정류장 전   ↻
   163번  09:05 도착 · 3정류장 전
```

**둘째 줄에 다른 번호가 뜨는지가 이 과제의 확인이다.** 같은 노선의 두 대면
`그다음` 으로 뜬다 — 그것도 맞는 동작이다.

- [ ] **Step 6: 인계 문서에 적는다**

`docs/HANDOFF-2026-08-27-stops.md` 의 `다음 작업` 에서 이 항목을 지우고, 잰 값을
`오늘 한 일` 에 남긴다. **짐작이 아니라 잰 값을 적는다.**

---

## 다 끝났을 때

```bash
python3 -m unittest discover -s Server     # 197개 (180 + 17)
python3 Tools/verify-progress-sync.py      # 진행도는 안 건드렸다. 그대로여야 한다
```

**안 바꾼 것** — 선 그리기(첫 노선으로 그대로), `bus_arrival`·`seoul_bus_arrival`
(한 노선을 묻는 함수로 남는다), 15분 창과 30초 캐시.
