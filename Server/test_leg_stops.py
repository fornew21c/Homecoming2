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

    def run_with(self, table, route_no, from_name, to_name):
        """노선id → 정류소 목록. `gbis_route_ids` 는 그 키들을 순서대로 준다."""
        ids = list(table)
        patches = [
            mock.patch.object(hs, "gbis_route_ids", lambda _no, _i=ids: _i),
            mock.patch.object(hs, "gbis_route_stops", lambda rid: table[rid]),
        ]
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


class SeoulLegStopsTests(unittest.TestCase):

    # `seoul-stops.json` 의 한 줄 모양: [이름, 위도, 경도, arsId]
    STOPS_TABLE = [
        ["국회의사당역.KB국민은행", 37.528491, 126.918087, "19003"],
        ["신촌로터리", 37.555000, 126.936000, "14204"],
        ["엉뚱한곳", 37.400000, 127.000000, "99999"],
    ]

    def items(self, rows):
        """TOPIS 응답 항목을 (arsId, staOrd) 로 흉내낸다.

        **XML 조각 문자열이다.** `seoul_arrival_items` 가 `<itemList>` 안쪽을
        정규식으로 잘라 문자열 목록을 주고, `_tag` 가 다시 정규식으로 읽는다.
        """
        return [f"<arsId>{ars}</arsId><staOrd>{order}</staOrd>"
                for ars, order in rows]

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
        # 차가 안 다니는 시간에 도착정보가 빌 수 있다(계획 Task 8 에서 실측한다).
        got = self.run_with([], "국회의사당역.KB국민은행", "신촌로터리")
        self.assertEqual(got, {"boarding": [], "alighting": []})


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
        seoul = {"boarding": [{"id": "19003", "no": "19003",
                               "name": "국회의사당역.KB국민은행",
                               "lat": 37.5, "lon": 126.9, "seq": 5}],
                 "alighting": []}
        with mock.patch.object(hs, "bus_leg_stops", lambda *_a: empty), \
             mock.patch.object(hs, "seoul_leg_stops", lambda *_a: seoul):
            got = hs.leg_stops("163", "국회의사당역.KB국민은행", "신촌로터리")
        self.assertEqual(got, seoul)


if __name__ == "__main__":
    unittest.main()
