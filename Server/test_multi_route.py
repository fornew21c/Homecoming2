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


if __name__ == "__main__":
    unittest.main()
