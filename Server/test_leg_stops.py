"""이름만으로 버스 구간의 승차·하차 정류장을 정하는 것들의 시험.

    cd Server && python3 -m unittest test_leg_stops -v

**네트워크를 타지 않는다.** GBIS 응답을 고정해 두고 고르는 규칙만 본다.
실제로 되는지는 시험이 아니라 실측이 말한다
(`docs/superpowers/plans/2026-08-27-stop-resolution.md` Task 8).

의존성 없음. 표준 unittest 다.
"""

import io
import json as _json
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


if __name__ == "__main__":
    unittest.main()
