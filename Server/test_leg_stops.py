"""이름만으로 버스 구간의 승차·하차 정류장을 정하는 것들의 시험.

    cd Server && python3 -m unittest test_leg_stops -v

**네트워크를 타지 않는다.** GBIS 응답을 고정해 두고 고르는 규칙만 본다.
실제로 되는지는 시험이 아니라 실측이 말한다
(`docs/superpowers/plans/2026-08-27-stop-resolution.md` Task 8).

의존성 없음. 표준 unittest 다.
"""

import tempfile
import os
import io
import json as _json
import pathlib
import sys
import unittest
from unittest import mock

# **시험은 진짜 DB 에 안 붙는다.** `DB_PATH` 는 import 할 때 정해지고, 여기서
# 안 걸면 먼저 import 되는 쪽이 이겨 저장소의 DB 를 쓴다 — 다른 시험의
# `DELETE FROM` 이 실제 경로를 지운다(2026-08-27 에 실제로 그랬다).
_TMP = tempfile.mkdtemp()
os.environ.setdefault("HOMECOMING_DB", str(pathlib.Path(_TMP) / "test.sqlite"))

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
                                    "lon": 126.7872167, "seq": 13, "turn": False})

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


class NearestStopTests(unittest.TestCase):
    """좌표가 오면 후보를 하나로 좁힌다.

    실측(2026-08-27) — `위시티1.3단지` 가 길 양쪽에 있고 이름이 같다.
      20796 seq 21  저장된 도착점에서   5.0m   ← 실제로 이것
      20795 seq 70  저장된 도착점에서  32.8m
    """

    WISHITY = [
        {"id": "GGB219000776", "no": "20796", "name": "위시티1.3단지",
         "lat": 37.6822, "lon": 126.8108, "seq": 21},
        {"id": "GGB219000775", "no": "20795", "name": "위시티1.3단지",
         "lat": 37.68245, "lon": 126.8107833, "seq": 70},
    ]

    def test_가까운_것_하나로_좁힌다(self):
        got = hs.nearest_stop(self.WISHITY, 37.682155, 126.810803)
        self.assertEqual([s["no"] for s in got], ["20796"])

    def test_좌표가_없으면_그대로_둔다(self):
        self.assertEqual(hs.nearest_stop(self.WISHITY, None, None), self.WISHITY)

    def test_후보가_하나면_그대로다(self):
        one = self.WISHITY[:1]
        self.assertEqual(hs.nearest_stop(one, 37.0, 127.0), one)

    def test_너무_멀면_안_좁힌다(self):
        # 좌표가 엉뚱하면 확신해서 고르지 않는다. 후보를 그대로 둔다.
        got = hs.nearest_stop(self.WISHITY, 37.5000, 127.5000)
        self.assertEqual(got, self.WISHITY)

    def test_빈_후보는_빈_채로(self):
        self.assertEqual(hs.nearest_stop([], 37.0, 127.0), [])


class QueryCoordinateTests(unittest.TestCase):
    """질의에서 좌표를 읽는 규칙. 핸들러가 이것만 쓴다."""

    def query(self, text):
        import urllib.parse
        return urllib.parse.parse_qs(text)

    def test_둘_다_있으면_숫자로_준다(self):
        q = self.query("fromLat=37.673180&fromLon=126.787167")
        self.assertEqual(hs.query_coordinate(q, "fromLat", "fromLon"),
                         (37.673180, 126.787167))

    def test_없으면_없는_것이다(self):
        self.assertEqual(hs.query_coordinate({}, "toLat", "toLon"), (None, None))

    def test_하나만_있으면_없는_것으로_친다(self):
        # 반쪽 좌표로 정류장을 고르면 엉뚱한 곳을 집는다.
        q = self.query("fromLat=37.67")
        self.assertEqual(hs.query_coordinate(q, "fromLat", "fromLon"), (None, None))

    def test_빈_값은_없는_것이다(self):
        # `parse_qs` 가 빈 값을 아예 안 담는다.
        q = self.query("fromLat=&fromLon=")
        self.assertEqual(hs.query_coordinate(q, "fromLat", "fromLon"), (None, None))

    def test_숫자가_아니면_터진다(self):
        # **조용히 무시하면 안 된다.** 앱은 좌표를 보냈다고 믿는데 서버는
        # 이름만으로 답하게 되고, 그 차이가 화면에 안 나타난다.
        q = self.query("toLat=abc&toLon=126.8")
        with self.assertRaises(hs.BadCoordinate):
            hs.query_coordinate(q, "toLat", "toLon")


class RealDatabaseGuardTests(unittest.TestCase):
    """**시험이 진짜 DB 에 붙으면 안 된다.**

    `DB_PATH` 는 import 할 때 한 번 정해지고 기본값이 상대경로다. 시험 모듈이
    `HOMECOMING_DB` 를 안 걸면, 먼저 import 되는 쪽이 이겨서 저장소의
    `Server/homecoming.sqlite` 에 붙는다. 그러면 다른 시험의 `DELETE FROM` 이
    실제 경로를 지운다 — **2026-08-27 에 실제로 그랬다.** 저장된 `퇴근길` 이
    날아갔다.

    돌리는 자리에 따라 결과가 갈리는 것도 같은 뿌리다 —
      cd Server && python3 -m unittest discover   → Server/Server/homecoming.sqlite
      python3 -m unittest discover -s Server      → 진짜 DB 를 지운다

    이 시험이 그 길을 막는다. **새 시험 파일을 만들 때 `HOMECOMING_DB` 를
    빠뜨리면 여기서 걸린다.**
    """

    def test_시험은_저장소_DB_에_안_붙는다(self):
        repo_db = (pathlib.Path(__file__).resolve().parent / "homecoming.sqlite")
        self.assertNotEqual(pathlib.Path(hs.DB_PATH).resolve(), repo_db,
                            "시험이 저장소의 진짜 DB 를 쓰고 있다 — "
                            "먼저 import 되는 시험 파일이 HOMECOMING_DB 를 안 걸었다")

    def test_DB_PATH_기본값이_절대경로다(self):
        # 상대경로면 돌리는 자리에 따라 Server/Server/ 가 생긴다.
        import os
        saved = os.environ.pop("HOMECOMING_DB", None)
        try:
            import importlib
            default = hs.default_db_path()
        finally:
            if saved is not None:
                os.environ["HOMECOMING_DB"] = saved
        self.assertTrue(pathlib.Path(default).is_absolute(),
                        f"기본 DB 경로가 상대경로다: {default}")


class ArrivalBurstTests(unittest.TestCase):
    """**같은 값을 몰아 묻는 것을 막는다.**

    2026-08-27 실측 — `/bus-arrival` 이 1초 간격으로 네 번 나갔다(04:13:53 · :54 ·
    :55 · :57). **사람이 새로고침을 톡톡 누른 것이다.** 버튼의 중복 방지는 응답이
    오면 풀리는데 왕복이 1초 미만이라 1초 간격 탭을 못 막는다. 값은 같은데
    한도만 네 배로 탄다.

    3초는 뜻이 있는 문턱이다. 실측에서 정류장 수가 약 57초에 하나씩 줄었다
    (`busArrivalMeasuredAt` 주석). 3초 안에 다시 물어도 같은 값이 온다. 사람이
    누르는 경우는 왕복(1~4초)에 반응 시간이 붙어 이 문턱에 안 걸린다.
    """

    def setUp(self):
        hs._arrival_ready.clear()

    def test_방금_잰_값이_있으면_다시_안_묻는다(self):
        from datetime import timedelta
        at = hs.now()
        hs._arrival_ready[("163", 37.5, 126.9)] = (at - timedelta(seconds=1), {"no": "163"})
        fresh, value = hs.arrival_recently_measured("163", 37.5, 126.9, at)
        self.assertTrue(fresh)
        self.assertEqual(value, {"no": "163"})

    def test_문턱을_넘으면_다시_묻는다(self):
        from datetime import timedelta
        at = hs.now()
        hs._arrival_ready[("163", 37.5, 126.9)] = (at - timedelta(seconds=4), {"no": "163"})
        fresh, _ = hs.arrival_recently_measured("163", 37.5, 126.9, at)
        self.assertFalse(fresh)

    def test_잰_적이_없으면_묻는다(self):
        fresh, value = hs.arrival_recently_measured("163", 37.5, 126.9, hs.now())
        self.assertFalse(fresh)
        self.assertIsNone(value)


class StopSearchTests(unittest.TestCase):
    """이름으로 정류장 찾기 — **서울과 경기를 함께 본다.**

    예전에는 서울 표만 봤다. `풍산역` 을 치면 0건이라 편집기가 애플 지도로
    떨어졌고, 애플 지도에는 버스정류장이 시설로 없어서 근처 가게가 나왔다
    (`신촌로터리` → 종로김밥 · 탐엔탐스). 2026-08-20 에는 그렇게 고른 GS25 가
    가족 잠금화면에 `GS25까지 9분` 으로 떴다.
    """

    SEOUL = [
        ["신촌로터리", 37.554051, 126.935683, "14205"],
        ["신촌로터리", 37.555, 126.9357, "14204"],
    ]

    GYEONGGI = {"busStationList": [
        {"stationId": 219000638, "mobileNo": " 20753", "stationName": "풍산역",
         "y": "37.67315", "x": "126.7872167", "regionName": "고양"},
        {"stationId": 227000210, "mobileNo": "28223", "stationName": "하남풍산역.꽃뫼마을1단지",
         "y": "37.5528", "x": "127.2016167", "regionName": "하남"},
    ]}

    def search(self, text, gyeonggi=None):
        patches = [
            mock.patch.object(hs, "SEOUL_STOPS", self.SEOUL),
            mock.patch.object(hs, "gbis_get", lambda _p, _q: gyeonggi),
        ]
        for p in patches:
            p.start()
        try:
            return hs.stop_search(text)
        finally:
            for p in patches:
                p.stop()

    def test_서울은_예전처럼_나온다(self):
        got = self.search("신촌로터리", gyeonggi={})
        self.assertEqual([s["ars"] for s in got], ["14205", "14204"])

    def test_경기도_나온다(self):
        got = self.search("풍산역", gyeonggi=self.GYEONGGI)
        self.assertEqual([s["name"] for s in got],
                         ["풍산역", "하남풍산역.꽃뫼마을1단지"])
        self.assertEqual(got[0]["lat"], 37.67315)
        self.assertEqual(got[0]["ars"], "20753")

    def test_서울이_먼저다(self):
        # 두 자료에 같은 이름이 있으면 서울 표가 앞이다 — 좌표를 직접 갖고 있고
        # 호출이 안 나간다.
        got = self.search("풍산역", gyeonggi=self.GYEONGGI)
        self.assertEqual(len(got), 2)

    def test_두_글자보다_짧으면_안_찾는다(self):
        # 한 글자로 물으면 전국이 나온다. 호출도 아깝다.
        self.assertEqual(self.search("풍", gyeonggi=self.GYEONGGI), [])

    def test_경기_조회가_실패해도_서울은_준다(self):
        got = self.search("신촌로터리", gyeonggi=None)
        self.assertEqual([s["ars"] for s in got], ["14205", "14204"])


class StopSearchByRouteTests(unittest.TestCase):
    """**노선번호를 알면 그 노선이 서는 기둥만 준다.**

    풍산역은 기둥이 넷이고 이름이 다 같다. 화면에 `정류장 번호 20753` 이라고
    적어 줘도, 그 번호는 기둥에 가서 봐야 아는 값이다 — 경로를 만드는 건 대개
    집이나 회사다. 노선번호를 알면 자료가 정해 준다.
    """

    STOPS = [
        {"name": "풍산역", "lat": 37.67385, "lon": 126.78603, "ars": "20573"},
        {"name": "풍산역", "lat": 37.67315, "lon": 126.7872167, "ars": "20753"},
        {"name": "풍산역", "lat": 37.6734167, "lon": 126.7872333, "ars": "58271"},
        {"name": "풍산역2번출구", "lat": 37.6726667, "lon": 126.7870833, "ars": "20486"},
    ]

    # 999 가 서는 기둥은 20753 과 58271 이다(2026-08-27 실측).
    ON_ROUTE = [
        {"id": "GGB219000638", "no": "20753", "name": "풍산역",
         "lat": 37.67315, "lon": 126.7872167, "seq": 13},
        {"id": "GGB219001069", "no": "58271", "name": "풍산역",
         "lat": 37.6734167, "lon": 126.7872333, "seq": 78},
    ]

    def narrow(self, route_no, on_route):
        with mock.patch.object(hs, "route_stop_numbers",
                               lambda _no: {s["no"] for s in on_route}):
            return hs.narrow_by_route(self.STOPS, route_no)

    def test_그_노선이_서는_기둥만_남는다(self):
        got = self.narrow("999", self.ON_ROUTE)
        self.assertEqual([s["ars"] for s in got], ["20753", "58271"])

    def test_노선번호가_없으면_그대로_준다(self):
        self.assertEqual(hs.narrow_by_route(self.STOPS, None), self.STOPS)
        self.assertEqual(hs.narrow_by_route(self.STOPS, ""), self.STOPS)

    def test_그_노선을_못_찾으면_그대로_준다(self):
        # **좁힐 수 없으면 안 좁힌다.** 빈 목록을 주면 사용자가 아무것도 못 고른다.
        got = self.narrow("없는번호", [])
        self.assertEqual(got, self.STOPS)

    def test_하나도_안_맞으면_그대로_준다(self):
        # 이름을 잘못 쳤거나 다른 동네다. 빈 화면보다 낫다.
        other = [{"id": "x", "no": "99999", "name": "딴곳",
                  "lat": 0, "lon": 0, "seq": 1}]
        got = self.narrow("999", other)
        self.assertEqual(got, self.STOPS)


class RouteDirectionTests(unittest.TestCase):
    """**어느 쪽으로 가는 차인가.** 회차점 앞이면 회차점 쪽, 뒤면 종점 쪽이다.

    999 실측(2026-08-27) — 92개, seq 1 대화역(중) 출발 · seq 45 신원중학교
    회차(`turnYn=Y`) · seq 92 대화역(중) 종점.

        20753  seq 13  ≤ 45  → 신원중학교 방면
        58271  seq 78  >  45 → 대화역(중) 방면

    경유노선 조회(`getBusStationViaRouteListv2`)가 따로 말해 주는 값과 같다.
    **이미 받아 온 목록에서 나오므로 조회가 늘지 않는다.**
    """

    ROUTE = [
        {"id": "a", "no": "20434", "name": "대화역(중)", "lat": 0, "lon": 0, "seq": 1},
        {"id": "b", "no": "20753", "name": "풍산역", "lat": 0, "lon": 0, "seq": 13},
        {"id": "c", "no": "30001", "name": "신원중학교", "lat": 0, "lon": 0, "seq": 45,
         "turn": True},
        {"id": "d", "no": "58271", "name": "풍산역", "lat": 0, "lon": 0, "seq": 78},
        {"id": "e", "no": "20434", "name": "대화역(중)", "lat": 0, "lon": 0, "seq": 92},
    ]

    def test_회차점_앞이면_회차점_방면(self):
        self.assertEqual(hs.route_direction(self.ROUTE, "20753"), "신원중학교")

    def test_회차점_뒤면_종점_방면(self):
        self.assertEqual(hs.route_direction(self.ROUTE, "58271"), "대화역(중)")

    def test_회차점이_없으면_종점_방면(self):
        straight = [dict(s) for s in self.ROUTE]
        for s in straight:
            s.pop("turn", None)
        self.assertEqual(hs.route_direction(straight, "20753"), "대화역(중)")

    def test_그_기둥이_없으면_모른다(self):
        self.assertIsNone(hs.route_direction(self.ROUTE, "99999"))

    def test_목록이_비면_모른다(self):
        self.assertIsNone(hs.route_direction([], "20753"))


if __name__ == "__main__":
    unittest.main()
