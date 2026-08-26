"""route_stops() 시험.

    cd Server && python3 -m unittest test_route_stops -v

의존성 없음. 표준 unittest 다.
"""

import json
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from homecoming_server import (   # noqa: E402
    ROUTE_SHAPE_MAX_BYTES,
    route_length,
    route_shape_payload,
    route_stops,
)

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
            "환승역",
            "도착역",
            "도착역 정류장",
            "아파트단지",
            "집",
        ])

    def test_대기_시간이_앞_정류장에_붙는다(self):
        stops = route_stops(legs())
        waits = {s["name"]: s["waitSeconds"] for s in stops}
        self.assertEqual(waits["출발역.은행앞"], 180)
        self.assertEqual(waits["환승역"], 240)
        self.assertEqual(waits["도착역 정류장"], 120)
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


class RouteShapePayloadTests(unittest.TestCase):
    """`route_shape_payload()` 시험. DB 를 타지 않는 순수 함수라 여기서 크기
    판단을 직접 검증한다 — 조용히 빠지는 동작이 이 작업에서 제일 위험하다."""

    def test_실제_경로의_정류장은_한도_안에_넉넉히_들어간다(self):
        stops = route_stops(legs())
        size = len(json.dumps({"stops": stops}, ensure_ascii=False).encode("utf-8"))
        # 여유가 얼마인지도 못박아 둔다 — 나중에 아슬아슬해지면 이 시험이 알려 준다.
        self.assertLess(size, ROUTE_SHAPE_MAX_BYTES // 2)
        self.assertEqual(route_shape_payload(stops), {"stops": stops})

    def test_한도를_넘으면_None_이다(self):
        # 코드 안에서 만든 자료로 한도를 확실히 넘긴다. 실제 경로 파일에
        # 묶으면 그 파일이 바뀔 때 이 시험이 상관없이 깨진다.
        huge_stops = [
            {"name": "정류장" * 200, "mode": "bus", "meters": 100,
             "seconds": 60, "waitSeconds": 0}
            for _ in range(50)
        ]
        size = len(json.dumps({"stops": huge_stops}, ensure_ascii=False).encode("utf-8"))
        self.assertGreater(size, ROUTE_SHAPE_MAX_BYTES)
        self.assertIsNone(route_shape_payload(huge_stops))

    def test_빈_목록은_None_이다(self):
        self.assertIsNone(route_shape_payload([]))


if __name__ == "__main__":
    unittest.main()
