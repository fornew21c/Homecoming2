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
        """`urlopen` 을 막고 정해진 JSON 을 돌려준다.

        **키도 넣어야 한다.** `gbis_get` 은 키가 없으면 나가지 않고 바로 None 이다
        (나가 봐야 403 이다). 여기서 재는 것은 봉투 해독이라 키가 있는 자리다.
        """
        def fake(_url, timeout=None, context=None):
            # `BytesIO` 는 그 자체로 컨텍스트 매니저다 — `with` 가 그대로 된다.
            return io.BytesIO(_json.dumps(payload).encode("utf-8"))

        with mock.patch.object(hs, "TAGO_KEY", "시험용"), \
             mock.patch.object(hs.urllib.request, "urlopen", fake):
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


class NextStopLabelTests(unittest.TestCase):
    """**다음 정류장으로 방향을 가린다.** 짐작이 없다.

    노선번호로 좁혀도 길 양쪽 두 기둥이 남는다(풍산역 20753 · 58271). 회차점을
    찾아 `종점 방면` 을 적으려 했는데, 서울 자료에는 회차 표시가 없고 규칙으로
    짚는 것이 안 됐다 — 2026-08-27 에 두 규칙을 5개 노선으로 재 봤다.

        출발점에서 가장 먼 정류장   5개 중 1개만 맞음
        같은 이름 쌍 사이의 창      5개 중 4개 (81번이 창 밖)

    4/5 로 맞는 규칙은 5번째 사람의 화면을 조용히 틀리게 한다. 다음 정류장은
    순서 목록의 그 다음 줄일 뿐이라 언제나 맞는다.
    """

    ROUTE = [
        {"id": "a", "no": "20572", "name": "저동중고교", "lat": 0, "lon": 0, "seq": 11},
        {"id": "b", "no": "20753", "name": "풍산역", "lat": 0, "lon": 0, "seq": 13},
        {"id": "c", "no": "20576", "name": "애니골입구", "lat": 0, "lon": 0, "seq": 14},
        {"id": "d", "no": "58271", "name": "풍산역", "lat": 0, "lon": 0, "seq": 78},
        {"id": "e", "no": "58261", "name": "밤가시7.8단지.광림교회", "lat": 0, "lon": 0, "seq": 79},
    ]

    def test_길_양쪽이_서로_다른_다음_정류장을_준다(self):
        self.assertEqual(hs.next_stop_name(self.ROUTE, "20753"), "애니골입구")
        self.assertEqual(hs.next_stop_name(self.ROUTE, "58271"), "밤가시7.8단지.광림교회")

    def test_마지막_정류장은_종점이라고_말한다(self):
        # 빈칸으로 두면 "왜 이건 정보가 없지" 로 읽힌다. 종점인 것이 정보다.
        self.assertEqual(hs.next_stop_name(self.ROUTE, "58261"), "종점")

    def test_그_기둥이_없으면_모른다(self):
        self.assertIsNone(hs.next_stop_name(self.ROUTE, "99999"))

    def test_목록이_비면_모른다(self):
        self.assertIsNone(hs.next_stop_name([], "20753"))


class GbisSingleRowTests(unittest.TestCase):
    """**결과가 하나면 목록이 아니라 dict 로 온다.**

    2026-08-27 실측 — `keyword=999` 는 `busRouteList` 가 list(셋)인데
    `keyword=271` 은 dict 하나다(경기도 이천시 노선). 그대로 `for` 로 돌면
    **키 문자열**이 나와서 `row.get` 이 터진다.

    실제로 `/stops?q=…&route=271` 이 500 을 냈다 —
    `'str' object has no attribute 'get'`. 이 파일의 `new_style_get` 은 같은
    함정을 이미 막고 있었는데(`rows if isinstance(rows, list) else [rows]`)
    GBIS 쪽 셋에서 빠뜨렸다.

    **이름 검색·노선 찾기·경유정류소 셋 다 같은 모양이다.**
    """

    def setUp(self):
        hs._gbis_routes.clear()
        hs._gbis_route_stops.clear()

    ONE_ROUTE = {"busRouteList": {"routeId": 233000019, "routeName": 271}}
    ONE_STOP_ON_ROUTE = {"busRouteStationList": {
        "stationSeq": 1, "stationId": 219000638, "mobileNo": "20753",
        "stationName": "풍산역", "y": "37.67315", "x": "126.78722"}}
    ONE_NAMED = {"busStationList": {
        "stationId": 219000638, "mobileNo": "20753", "stationName": "풍산역",
        "y": "37.67315", "x": "126.78722"}}

    def test_노선_찾기가_하나여도_된다(self):
        with mock.patch.object(hs, "gbis_get", lambda _p, _q: self.ONE_ROUTE):
            self.assertEqual(hs.gbis_route_ids("271"), ["233000019"])

    def test_경유정류소가_하나여도_된다(self):
        with mock.patch.object(hs, "gbis_get", lambda _p, _q: self.ONE_STOP_ON_ROUTE):
            got = hs.gbis_route_stops("233000019")
        self.assertEqual([s["no"] for s in got], ["20753"])

    def test_이름_검색이_하나여도_된다(self):
        with mock.patch.object(hs, "gbis_get", lambda _p, _q: self.ONE_NAMED):
            got = hs.gbis_stops_named("풍산역")
        self.assertEqual([s["ars"] for s in got], ["20753"])

    def test_봉투가_문자열이어도_안_터진다(self):
        # `comMsgHeader` 가 늘 빈 문자열로 온다. 다른 자리도 그럴 수 있다.
        for junk in ("", "빈값", None):
            with mock.patch.object(hs, "gbis_get", lambda _p, _q, j=junk: {"busRouteList": j}):
                self.assertEqual(hs.gbis_route_ids("x"), [])
            hs._gbis_routes.clear()


class BothRegionsTests(unittest.TestCase):
    """**같은 번호가 두 지역에 있다.** 한쪽에서 찾았다고 다른 쪽을 안 보면 안 된다.

    2026-08-27 실측 — `271` 이 경기(이천시)에도 있고 서울에도 있다. 경기에서
    먼저 찾고 멈추면 서울 271 의 정류장 목록을 못 받아, `용마문화복지센터.
    서일대후문`(서울) 에 다음 정류장이 안 붙었다.

    `999` 도 고양·수원 둘이고 `163` 은 서울에만 있다. 번호만으로는 지역이
    안 정해진다 — **둘 다 내고 부르는 쪽이 이름으로 고른다.**
    """

    GYEONGGI = [{"id": "GGB1", "no": "11111", "name": "이천어딘가",
                 "lat": 0, "lon": 0, "seq": 1},
                {"id": "GGB2", "no": "11112", "name": "이천다음",
                 "lat": 0, "lon": 0, "seq": 2}]
    SEOUL_TABLE = [["용마문화복지센터.서일대후문", 37.5, 127.0, "24001"],
                   ["서일대입구", 37.51, 127.01, "24002"]]

    def lists(self):
        patches = [
            mock.patch.object(hs, "gbis_route_ids", lambda _no: ["233000019"]),
            mock.patch.object(hs, "gbis_route_stops", lambda _rid: self.GYEONGGI),
            mock.patch.object(hs, "SEOUL_STOPS", self.SEOUL_TABLE),
            mock.patch.object(hs, "seoul_routes", lambda: {"271": ["100100100"]}),
            mock.patch.object(hs, "seoul_arrival_items_cached", lambda _r, _a: [
                "<arsId>24001</arsId><staOrd>5</staOrd>",
                "<arsId>24002</arsId><staOrd>6</staOrd>"]),
        ]
        for p in patches:
            p.start()
        try:
            return list(hs.route_stop_lists("271"))
        finally:
            for p in patches:
                p.stop()

    def test_두_지역_목록을_다_낸다(self):
        got = self.lists()
        self.assertEqual(len(got), 2, "경기에서 찾았다고 서울을 빼면 안 된다")
        self.assertEqual([s["no"] for s in got[0]], ["11111", "11112"])
        self.assertEqual([s["no"] for s in got[1]], ["24001", "24002"])

    def test_서울_정류장에도_다음이_붙는다(self):
        stops = [{"name": "용마문화복지센터.서일대후문", "lat": 37.5, "lon": 127.0,
                  "ars": "24001"}]
        patches = [
            mock.patch.object(hs, "gbis_route_ids", lambda _no: ["233000019"]),
            mock.patch.object(hs, "gbis_route_stops", lambda _rid: self.GYEONGGI),
            mock.patch.object(hs, "SEOUL_STOPS", self.SEOUL_TABLE),
            mock.patch.object(hs, "seoul_routes", lambda: {"271": ["100100100"]}),
            mock.patch.object(hs, "seoul_arrival_items_cached", lambda _r, _a: [
                "<arsId>24001</arsId><staOrd>5</staOrd>",
                "<arsId>24002</arsId><staOrd>6</staOrd>"]),
        ]
        for p in patches:
            p.start()
        try:
            hs.label_next_stops(stops, "271")
        finally:
            for p in patches:
                p.stop()
        self.assertEqual(stops[0].get("next"), "서일대입구")


class TerminusLabelTests(unittest.TestCase):
    """**종점에는 `종점` 이라고 적는다.**

    2026-08-27 실측 — 좁혀진 둘 중 하나가 노선의 마지막 정류장인 경우가 흔하다.
    163 은 09103(staOrd 2)과 09104(staOrd 112, 마지막)이고, 271 은 07195(1)과
    07196(123, 마지막)이다. 마지막에는 다음 정류장이 없다.

    빈칸으로 두면 "왜 이건 정보가 없지" 로 읽힌다. **종점이라는 것 자체가
    고르는 데 쓰이는 정보다** — 거기서 타는 사람은 없다.
    """

    def test_종점이_표시된다(self):
        route = [
            {"id": "a", "no": "09103", "name": "우이동도선사입구", "lat": 0, "lon": 0, "seq": 2},
            {"id": "b", "no": "09105", "name": "강북씨앤지", "lat": 0, "lon": 0, "seq": 3},
            {"id": "c", "no": "09104", "name": "우이동성원아파트", "lat": 0, "lon": 0, "seq": 112},
        ]
        self.assertEqual(hs.next_stop_name(route, "09103"), "강북씨앤지")
        self.assertEqual(hs.next_stop_name(route, "09104"), "종점")

    def test_그_기둥이_없으면_여전히_모른다(self):
        route = [{"id": "a", "no": "1", "name": "x", "lat": 0, "lon": 0, "seq": 1}]
        self.assertIsNone(hs.next_stop_name(route, "99999"))


class ArrivalReasonTests(unittest.TestCase):
    """**`없음` 의 이유를 가른다.**

    2026-08-27 실귀가에서 18:34:09 에 `버스 999 도착 새로고침 → 없음` 이 찍혔고
    칩이 사라졌다. 그런데 로그에 `없음` 이라고만 있어서 **자료가 빈 것인지 우리가
    걸러낸 것인지 구분할 수가 없었다** — 이미 지난 차는 우리가 일부러 버린다.

    셋을 가른다. 다음에 같은 일이 나면 로그가 말해 준다.
    """

    def rows(self, *triples):
        return [{"routeno": no, "arrtime": sec, "arrprevstationcnt": left}
                for no, sec, left in triples]

    def ask(self, rows):
        hs._arrival_none_reason = None
        patches = [
            mock.patch.object(hs, "arrival_stop", lambda _la, _lo, now=None: ("31100", "N1")),
            mock.patch.object(hs, "arrival_rows_cached", lambda _c, _n, _a: rows),
        ]
        for p in patches:
            p.start()
        try:
            value = hs.bus_arrival(37.0, 127.0, "999")
        finally:
            for p in patches:
                p.stop()
        return value, hs._arrival_none_reason

    def test_자료가_비면_그렇게_말한다(self):
        value, why = self.ask([])
        self.assertIsNone(value)
        self.assertIn("자료가 비었다", why)

    def test_그_노선이_안_오면_그렇게_말한다(self):
        value, why = self.ask(self.rows(("81", 300, 2), ("96", 600, 5)))
        self.assertIsNone(value)
        self.assertIn("안 온다", why)

    def test_지난_차뿐이면_그렇게_말한다(self):
        value, why = self.ask(self.rows(("999", -30, 0)))
        self.assertIsNone(value)
        self.assertIn("지난 차", why)

    def test_값이_있으면_이유가_없다(self):
        value, why = self.ask(self.rows(("999", 300, 2)))
        self.assertIsNotNone(value)
        self.assertIsNone(why)


class ArrivalPendingTests(unittest.TestCase):
    """**창은 열렸는데 자료가 아직 없을 때를 말한다.**

    칩이 없는 것이 화면에서 세 가지로 똑같이 보였다 — 승차가 아직 멀다(정상),
    버스가 아직 안 잡혔다(정상), 고장. 사용자가 두 번 다 "왜 안 뜨지" 로 읽었다.

    2026-08-27 실귀가 — 18:17 에 창(15분)이 열렸는데 999 칩은 18:27:39 에야 떴다.
    실시간 도착정보는 차가 11~17정류장 안에 들어와야 나온다(실측: 999 첫차 17분
    뒤가 가장 먼 값이고 둘째 차는 아예 없다). 그 10분이 "자료가 아직 없는" 시간이다.
    """

    LEGS = [
        {"mode": "walk", "startsAt": 0, "seconds": 240, "points": [[37.5, 127.0]]},
        {"mode": "bus", "busNo": "999", "startsAt": 240, "seconds": 900,
         "points": [[37.673180, 126.787167]]},
    ]

    def ready(self, progress, cached):
        hs._arrival_ready.clear()
        if cached is not None:
            hs._arrival_ready[("999", 37.673180, 126.787167)] = (hs.now(), cached)
        with mock.patch.object(hs, "start_arrival_refresh", lambda *_a: None):
            return hs.arrival_pending(self.LEGS, progress)

    def test_창_안인데_값이_없으면_기다리는_중이다(self):
        self.assertEqual(self.ready(0, None), "999")

    def test_값이_있으면_기다리는_중이_아니다(self):
        from datetime import timedelta
        self.assertIsNone(
            self.ready(0, {"no": "999", "at": hs.now() + timedelta(minutes=5)}))

    def test_창_밖이면_기다리는_중이_아니다(self):
        # 승차까지 아직 멀다. 그건 정상이고 화면에 적을 것이 없다.
        legs = [dict(self.LEGS[0]), dict(self.LEGS[1])]
        legs[1]["startsAt"] = 5000
        hs._arrival_ready.clear()
        with mock.patch.object(hs, "start_arrival_refresh", lambda *_a: None):
            self.assertIsNone(hs.arrival_pending(legs, 0))

    def test_버스_구간이_없으면_없다(self):
        walk_only = [{"mode": "walk", "startsAt": 0, "seconds": 240,
                      "points": [[37.5, 127.0]]}]
        self.assertIsNone(hs.arrival_pending(walk_only, 0))


if __name__ == "__main__":
    unittest.main()
