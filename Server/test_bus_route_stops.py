"""bus_route_stop_names() 시험 — 특히 **이어지지 않는 목록을 걸러내는지**.

    cd Server && python3 -m unittest test_bus_route_stops -v

경유정류장은 시군구별로 쪼개져 온다. 노선이 `BUS_SGG` 밖의 시군구를 지나면 그
구간이 통째로 빠진 채 오는데(3500번은 `sttn_seq` 0~82 중 46개만 왔다,
2026-08-25), 그대로 이으면 빠진 구간을 가로지르는 직선이 된다. 화면은 그것을
실제 노선인 것처럼 그린다 — 자동차 폴백보다 나쁘다.

의존성 없음. 표준 unittest 다.
"""

import pathlib
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import homecoming_server as hs   # noqa: E402


def rows(*pairs):
    """(순번, 이름) 들을 API 응답 모양으로."""
    return [{"sttn_seq": seq, "sttn_nm": name} for seq, name in pairs]


class BusRouteStopNamesTests(unittest.TestCase):

    def setUp(self):
        hs._bus_route_stops.clear()
        patches = [
            mock.patch.object(hs, "BUS_SGG", {"41": ["41131", "41135"]}),
            mock.patch.object(hs, "bus_opr_ymd", lambda: "20260601"),
            mock.patch.object(hs, "bus_route_ids", lambda ctpv, no: ["41255002"]),
        ]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)

    def fetch(self, table):
        """시군구 코드마다 미리 정한 응답을 준다."""
        def get(_url, params):
            return table.get(params["sgg_cd"])
        return mock.patch.object(hs, "new_style_get", get)

    def test_이어지면_순서대로_돌려준다(self):
        with self.fetch({
            "41131": rows((0, "위례자이"), (1, "신흥역")),
            "41135": rows((2, "율동공원"), (3, "오리역")),
        }):
            names = hs.bus_route_stop_names("41", "66", {"신흥역"})
        self.assertEqual(names, ["위례자이", "신흥역", "율동공원", "오리역"])

    def test_가운데가_비면_자료가_없는_것으로_둔다(self):
        # 0,1 과 40,41 만 오고 그 사이 38자리가 빈다 — 3500번이 그랬다.
        with self.fetch({
            "41131": rows((0, "위례자이"), (1, "신흥역")),
            "41135": rows((40, "강남역"), (41, "역삼역")),
        }):
            names = hs.bus_route_stop_names("41", "3500", {"신흥역"})
        self.assertEqual(names, [])

    def test_출발_정류장을_안_지나면_받아들이지_않는다(self):
        # 같은 노선번호가 여러 도시에 있다(999 는 고양과 수원에 있다).
        with self.fetch({
            "41131": rows((0, "위례자이"), (1, "신흥역")),
            "41135": None,
        }):
            names = hs.bus_route_stop_names("41", "66", {"마두역"})
        self.assertEqual(names, [])

    def test_한_번_찾은_것은_다시_묻지_않는다(self):
        calls = []

        def get(_url, params):
            calls.append(params["sgg_cd"])
            return rows((0, "위례자이"), (1, "신흥역")) if params["sgg_cd"] == "41131" else None

        with mock.patch.object(hs, "new_style_get", get):
            first = hs.bus_route_stop_names("41", "66", {"신흥역"})
            second = hs.bus_route_stop_names("41", "66", {"신흥역"})
        self.assertEqual(first, second)
        self.assertEqual(len(calls), 2, "두 번째 호출은 요청을 내면 안 된다")


if __name__ == "__main__":
    unittest.main()
