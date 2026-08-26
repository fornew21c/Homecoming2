"""버스 실시간 도착 시험 — 노선을 고르고 절대시각을 굽는다.

    cd Server && python3 -m unittest test_bus_arrival -v

**절대시각인 것이 핵심이다.** `10분 후` 로 적으면 갱신이 와야 글자가 변하는데,
정류장에 서서 기다리는 동안은 위치 보고가 멈춘다(`distanceFilter` 가 150m 인데
풍산역에서 정류장까지가 78m 다). 그 몇 분이 하필 이 값이 가장 필요한 순간이다.

의존성 없음. 표준 unittest 다.
"""

import datetime
import pathlib
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import homecoming_server as hs   # noqa: E402


def stop_row(node_id, name, lat, lon, city=31100):
    """`getCrdntPrxmtSttnList` 응답 한 줄."""
    return {"nodeid": node_id, "nodenm": name, "gpslati": lat,
            "gpslong": lon, "nodeno": None, "citycode": city}


class NearbyStopsTests(unittest.TestCase):

    def test_정류장_id_를_같이_준다(self):
        body = {"items": {"item": [stop_row("GGB219000638", "풍산역",
                                            37.67315, 126.7872167)]}}
        # **키를 같이 붙잡아야 한다.** `nearby_stops` 는 `TAGO_KEY` 가 없으면
        # 조회를 하지 않고 빈 목록으로 먼저 빠져나간다. 시험 환경에는 키가 없다.
        with mock.patch.object(hs, "TAGO_KEY", "시험용"), \
             mock.patch.object(hs, "tago_stop_body", lambda lat, lon, limit: body):
            stops = hs.nearby_stops(37.673072, 126.786906)
        self.assertEqual(stops[0]["id"], "GGB219000638")
        self.assertEqual(stops[0]["city"], 31100)


def arrival_row(route_no, seconds, stops_left):
    """`getSttnAcctoArvlPrearngeInfoList` 응답 한 줄."""
    return {"routeno": route_no, "arrtime": seconds,
            "arrprevstationcnt": stops_left, "routetp": "일반버스"}


# 2026-08-26 실측. 풍산역(GGB219000638, 고양 31100)에 오는 버스들.
PUNGSAN_ROWS = [
    arrival_row("999", 582, 6),
    arrival_row("81", 1217, 14),
    arrival_row("81", 1790, 21),
    arrival_row("87", 197, 3),
    arrival_row("96", 2326, 20),
    arrival_row("96", 402, 6),
]

# 999번을 타는 자리. `Tools/routes/commute-sample.json` 의 버스 구간 첫 점이다.
BOARD_LAT, BOARD_LON = 37.673130, 126.787047

NOW = datetime.datetime(2026, 8, 26, 18, 32, 18, tzinfo=datetime.timezone.utc)


class BusArrivalTests(unittest.TestCase):

    def setUp(self):
        hs._arrival_stops.clear()
        hs._arrival_rows.clear()

    def stops(self, *rows):
        return mock.patch.object(hs, "nearby_stops", lambda lat, lon, limit=8: list(rows))

    def near(self):
        """풍산역 정류장 셋. 가까운 순서가 아니라 섞어 둔다."""
        return self.stops(
            {"id": "GGB219001069", "name": "풍산역", "lat": 37.6734167,
             "lon": 126.7872333, "city": 31100},
            {"id": "GGB219000638", "name": "풍산역", "lat": 37.67315,
             "lon": 126.7872167, "city": 31100},
            {"id": "GGB219000608", "name": "풍산역", "lat": 37.67385,
             "lon": 126.7860333, "city": 31100},
        )

    def test_그_노선만_골라_절대시각으로_준다(self):
        with self.near(), mock.patch.object(
                hs, "tago_arrival_rows", lambda city, node: PUNGSAN_ROWS):
            got = hs.bus_arrival(BOARD_LAT, BOARD_LON, "999", now=NOW)
        self.assertEqual(got["no"], "999")
        self.assertEqual(got["stops"], 6)
        # 582초 뒤다.
        self.assertEqual(got["at"], NOW + datetime.timedelta(seconds=582))

    def test_같은_노선이_여러_대면_가장_빠른_것(self):
        with self.near(), mock.patch.object(
                hs, "tago_arrival_rows", lambda city, node: PUNGSAN_ROWS):
            got = hs.bus_arrival(BOARD_LAT, BOARD_LON, "96", now=NOW)
        # 96번은 2326초와 402초 두 대다.
        self.assertEqual(got["at"], NOW + datetime.timedelta(seconds=402))
        self.assertEqual(got["stops"], 6)

    def test_가장_가까운_정류장을_고른다(self):
        seen = []

        def rows(city, node):
            seen.append(node)
            return PUNGSAN_ROWS

        with self.near(), mock.patch.object(hs, "tago_arrival_rows", rows):
            hs.bus_arrival(BOARD_LAT, BOARD_LON, "999", now=NOW)
        # 승차 좌표에서 가장 가까운 것이 GGB219000638 이다(15.1m, 다음 후보인
        # GGB219001069 가 35.8m). 목록 순서가 아니라 거리로 골라야 한다.
        self.assertEqual(seen[0], "GGB219000638")

    def test_그_노선이_안_오면_아무것도_안_준다(self):
        with self.near(), mock.patch.object(
                hs, "tago_arrival_rows", lambda city, node: PUNGSAN_ROWS):
            got = hs.bus_arrival(BOARD_LAT, BOARD_LON, "163", now=NOW)
        self.assertIsNone(got)

    def test_정류장을_못_찾으면_아무것도_안_준다(self):
        """서울 시내버스가 이 자리다 — 좌표로 물어도 빈 결과가 온다(2026-08-26 실측)."""
        with self.stops(), mock.patch.object(
                hs, "tago_arrival_rows", lambda city, node: PUNGSAN_ROWS):
            got = hs.bus_arrival(37.528330, 126.917660, "163", now=NOW)
        self.assertIsNone(got)

    def test_호출이_실패해도_터지지_않는다(self):
        with self.near(), mock.patch.object(
                hs, "tago_arrival_rows", lambda city, node: []):
            got = hs.bus_arrival(BOARD_LAT, BOARD_LON, "999", now=NOW)
        self.assertIsNone(got)

    def test_이미_지난_차는_버린다(self):
        with self.near(), mock.patch.object(
                hs, "tago_arrival_rows",
                lambda city, node: [arrival_row("999", -30, 0),
                                    arrival_row("999", 240, 2)]):
            got = hs.bus_arrival(BOARD_LAT, BOARD_LON, "999", now=NOW)
        self.assertEqual(got["at"], NOW + datetime.timedelta(seconds=240))

    def test_정류장을_한_번_고르면_다시_안_찾는다(self):
        calls = []

        def stops(lat, lon, limit=8):
            calls.append(1)
            return [{"id": "GGB219000638", "name": "풍산역", "lat": 37.67315,
                     "lon": 126.7872167, "city": 31100}]

        with mock.patch.object(hs, "nearby_stops", stops), mock.patch.object(
                hs, "tago_arrival_rows", lambda city, node: PUNGSAN_ROWS):
            hs.bus_arrival(BOARD_LAT, BOARD_LON, "999", now=NOW)
            hs.bus_arrival(BOARD_LAT, BOARD_LON, "999", now=NOW)
        self.assertEqual(len(calls), 1)

    def test_도착정보를_30초_동안_다시_안_묻는다(self):
        """호출 예산이 이 캐시에 걸려 있다. 창 안에서는 안 묻고 밖에서는 묻는다."""
        calls = []

        def rows(city, node):
            calls.append(1)
            return PUNGSAN_ROWS

        with self.near(), mock.patch.object(hs, "tago_arrival_rows", rows):
            hs.bus_arrival(BOARD_LAT, BOARD_LON, "999", now=NOW)
            hs.bus_arrival(BOARD_LAT, BOARD_LON, "999",
                           now=NOW + datetime.timedelta(seconds=29))
            self.assertEqual(len(calls), 1)
            # 30초는 이미 낡은 것으로 본다 — 비교가 `<` 다.
            hs.bus_arrival(BOARD_LAT, BOARD_LON, "999",
                           now=NOW + datetime.timedelta(seconds=30))
            self.assertEqual(len(calls), 2)


class TagoArrivalBodyNormalizationTests(unittest.TestCase):
    """`tago_arrival_rows` 의 응답 정규화. TAGO 는 정상 요청에도 자료 모양이
    들쭉날쭉하다(`tago_stop_body` 의 주석과 같은 사정) — 여기서 직접 잰다.
    """

    def test_여러_대면_목록_그대로(self):
        body = {"items": {"item": [arrival_row("999", 582, 6),
                                    arrival_row("81", 1217, 14)]}}
        with mock.patch.object(hs, "TAGO_KEY", "시험용"), mock.patch.object(
                hs, "tago_arrival_body", lambda city, node: body):
            rows = hs.tago_arrival_rows(31100, "GGB219000638")
        self.assertEqual(rows, [arrival_row("999", 582, 6),
                                 arrival_row("81", 1217, 14)])

    def test_한_대면_목록으로_감싼다(self):
        """`item` 이 배열이 아니라 객체 하나로 오는 경우다(딱 한 대일 때)."""
        body = {"items": {"item": arrival_row("999", 582, 6)}}
        with mock.patch.object(hs, "TAGO_KEY", "시험용"), mock.patch.object(
                hs, "tago_arrival_body", lambda city, node: body):
            rows = hs.tago_arrival_rows(31100, "GGB219000638")
        self.assertEqual(rows, [arrival_row("999", 582, 6)])

    def test_items_가_없으면_빈_목록(self):
        """막차가 끊긴 정류장은 `items` 가 빈 문자열로 온다."""
        body = {"items": ""}
        with mock.patch.object(hs, "TAGO_KEY", "시험용"), mock.patch.object(
                hs, "tago_arrival_body", lambda city, node: body):
            rows = hs.tago_arrival_rows(31100, "GGB219000638")
        self.assertEqual(rows, [])

    def test_호출이_실패하면_빈_목록(self):
        """`tago_arrival_body` 가 None 을 주는 경우 — 위쪽(`bus_arrival`)까지
        예외 없이 흘러가야 한다."""
        with mock.patch.object(hs, "TAGO_KEY", "시험용"), mock.patch.object(
                hs, "tago_arrival_body", lambda city, node: None):
            rows = hs.tago_arrival_rows(31100, "GGB219000638")
        self.assertEqual(rows, [])


def leg(mode, starts_at, seconds, to_name, bus_no=None, lat=37.0, lon=127.0):
    out = {"mode": mode, "startsAt": starts_at, "seconds": seconds,
           "toName": to_name, "points": [[lat, lon]]}
    if bus_no:
        out["busNo"] = bus_no
    return out


# 실제 경로의 모양이다 — 도보·대기·버스·도보·지하철·도보·대기·버스·도보.
LEGS = [
    leg("walk", 0, 360, "출발역.은행앞"),
    leg("wait", 360, 180, None),
    leg("bus", 540, 540, "환승로터리", bus_no="163", lat=37.528458, lon=126.917876),
    leg("walk", 1080, 420, "서강대역"),
    leg("wait", 1500, 270, None),
    leg("subway", 1770, 1860, "풍산역"),
    leg("walk", 3630, 390, "풍산역 정류장"),
    leg("wait", 4020, 120, None),
    leg("bus", 4140, 600, "아파트단지", bus_no="999",
        lat=37.673130, lon=126.787047),
    leg("walk", 4740, 180, "집"),
]


class NextBusLegTests(unittest.TestCase):

    def test_지금_뒤의_첫_버스_구간을_고른다(self):
        # 지하철을 타는 중(progress 2000초)이면 다음 버스는 999번이다.
        found = hs.next_bus_leg(LEGS, 2000)
        self.assertEqual(found["busNo"], "999")

    def test_출발_전에는_첫_버스_구간이다(self):
        found = hs.next_bus_leg(LEGS, 0)
        self.assertEqual(found["busNo"], "163")

    def test_타고_있는_버스는_다음이_아니다(self):
        # 999번을 타는 중(progress 4300초)이면 뒤에 버스 구간이 없다.
        self.assertIsNone(hs.next_bus_leg(LEGS, 4300))

    def test_버스가_없는_경로면_없다(self):
        walk_only = [leg("walk", 0, 600, "집")]
        self.assertIsNone(hs.next_bus_leg(walk_only, 0))


class ArrivalWindowTests(unittest.TestCase):

    def setUp(self):
        hs._arrival_stops.clear()
        hs._arrival_rows.clear()

    def test_승차까지_15분_넘게_남으면_안_묻는다(self):
        asked = []
        with mock.patch.object(hs, "bus_arrival",
                               lambda *a, **k: asked.append(1)):
            # 999번 승차가 4140초인데 지금 2000초다 — 2140초(35분) 남았다.
            got = hs.bus_arrival_for(LEGS, 2000, now=NOW)
        self.assertEqual(asked, [])
        self.assertIsNone(got)

    def test_15분_안으로_들어오면_묻는다(self):
        with mock.patch.object(
                hs, "bus_arrival",
                lambda lat, lon, no, now=None: {"no": no, "at": NOW, "stops": 3}):
            # 3300초면 승차까지 840초(14분) 남았다.
            got = hs.bus_arrival_for(LEGS, 3300, now=NOW)
        self.assertEqual(got["no"], "999")


class NonBlockingTests(unittest.TestCase):
    """`content_state()` 는 네트워크를 기다리지 않는다.

    앱의 위치 보고 타임아웃이 8초인데 도착 조회가 실측 9~13초다. 기다리면
    귀가자 화면이 응답으로 상태를 받는 길이 끊긴다.
    """

    def setUp(self):
        hs._arrival_stops.clear()
        hs._arrival_rows.clear()
        hs._arrival_ready.clear()
        hs._arrival_refreshing.clear()

    def test_캐시가_비면_안_싣고_넘어간다(self):
        """느린 조회를 배경으로 미룬다 — 그 자리에서 기다리지 않는다."""
        started = []
        with mock.patch.object(hs, "start_arrival_refresh",
                               lambda *a, **k: started.append(a)):
            got = hs.arrival_ready(LEGS, 3300, now=NOW)
        self.assertIsNone(got)
        # 다음 번을 위해 배경 갱신을 시켰다.
        self.assertEqual(len(started), 1)

    def test_캐시에_있으면_그걸_준다(self):
        value = {"no": "999", "at": NOW, "stops": 3}
        hs._arrival_ready[("999", 37.673130, 126.787047)] = (NOW, value)
        started = []
        with mock.patch.object(hs, "start_arrival_refresh",
                               lambda *a, **k: started.append(a)):
            got = hs.arrival_ready(LEGS, 3300, now=NOW)
        self.assertEqual(got["no"], "999")
        # 아직 신선하니 갱신도 안 시킨다.
        self.assertEqual(started, [])

    def test_창_밖이면_배경_갱신도_안_시킨다(self):
        started = []
        with mock.patch.object(hs, "start_arrival_refresh",
                               lambda *a, **k: started.append(a)):
            got = hs.arrival_ready(LEGS, 2000, now=NOW)
        self.assertIsNone(got)
        self.assertEqual(started, [])


class NegativeStopCacheTests(unittest.TestCase):
    """정류장을 못 찾은 것도 캐시한다 — 서울이 매번 4.4초를 태웠다."""

    def setUp(self):
        hs._arrival_stops.clear()

    def test_못_찾은_것도_기억한다(self):
        calls = []

        def none(lat, lon, limit=8):
            calls.append(1)
            return []

        with mock.patch.object(hs, "nearby_stops", none):
            hs.arrival_stop(37.528330, 126.917660, now=NOW)
            hs.arrival_stop(37.528330, 126.917660, now=NOW)
        self.assertEqual(len(calls), 1)

    def test_10분_뒤에는_다시_본다(self):
        """일시적 장애일 수도 있다. 영원히 포기하지는 않는다."""
        calls = []

        def none(lat, lon, limit=8):
            calls.append(1)
            return []

        with mock.patch.object(hs, "nearby_stops", none):
            hs.arrival_stop(37.528330, 126.917660, now=NOW)
            hs.arrival_stop(37.528330, 126.917660,
                            now=NOW + datetime.timedelta(minutes=10))
        self.assertEqual(len(calls), 2)


if __name__ == "__main__":
    unittest.main()
