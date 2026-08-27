"""버스 실시간 도착 시험 — 노선을 고르고 절대시각을 굽는다.

    cd Server && python3 -m unittest test_bus_arrival -v

**절대시각인 것이 핵심이다.** `10분 후` 로 적으면 갱신이 와야 글자가 변하는데,
정류장에 서서 기다리는 동안은 위치 보고가 멈춘다(`distanceFilter` 가 150m 인데
풍산역에서 정류장까지가 78m 다). 그 몇 분이 하필 이 값이 가장 필요한 순간이다.

의존성 없음. 표준 unittest 다.
"""

import tempfile
import os
import datetime
import pathlib
import sys
import time
import unittest
from unittest import mock

# **시험은 진짜 DB 에 안 붙는다.** `DB_PATH` 는 import 할 때 정해지고, 여기서
# 안 걸면 먼저 import 되는 쪽이 이겨 저장소의 DB 를 쓴다 — 다른 시험의
# `DELETE FROM` 이 실제 경로를 지운다(2026-08-27 에 실제로 그랬다).
_TMP = tempfile.mkdtemp()
os.environ.setdefault("HOMECOMING_DB", str(pathlib.Path(_TMP) / "test.sqlite"))

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
    """`getSttnAcctoArvlPrearngeInfoList` 응답 한 줄.

    **`routeno` 는 숫자로 온다.** 실제 응답에 따옴표가 없다(2026-08-26 포스트맨
    확인: `"routeno": 999`). 표본을 문자열로 적어 두면 숫자로 오는 길을 시험이
    한 번도 밟지 않는다 — 코드가 `str()` 로 감싸는 이유가 여기 있는데 그게
    정말 필요한지 시험이 말해 주지 못한다.

    `nodeid`·`routeid`·`vehicletp` 도 실제 응답에 함께 온다. 쓰지 않지만 표본이
    응답과 같은 모양이어야 나중에 필드를 쓸 때 헛수고를 안 한다.
    """
    return {"arrprevstationcnt": stops_left, "arrtime": seconds,
            "nodeid": "GGB219000638", "nodenm": "풍산역",
            "routeid": "GGB218000111",
            "routeno": int(route_no) if str(route_no).isdigit() else route_no,
            "routetp": "일반버스", "vehicletp": "일반차량"}


# 2026-08-26 실측. 풍산역(GGB219000638, 고양 31100)에 오는 버스들.
#
# 같은 노선이 여러 줄로 온다 — 같은 `routeid` 의 다른 차량이다. 16:07 응답에서
# 81번이 221초·939초, 96번이 1098초·3055초 두 대씩이었다.
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


class ArrivalWindowSharedTests(unittest.TestCase):
    """**창 문턱은 한 자다.**

    위치 보고에 얹히는 길(`arrival_ready`)과 화면이 30초마다 부르는 길
    (`handle_bus_arrival`)이 같은 함수를 쓴다. 따로 들면 한쪽은 안 묻는데
    다른 쪽은 묻는 창이 생기고, 창을 둔 이유가 없어진다.
    """

    def leg_at(self, starts_at):
        return {"startsAt": starts_at, "busNo": "999", "mode": "bus"}

    def test_창_밖이면_참(self):
        # 승차가 4140초인데 지금 2000초 — 2140초(35분) 남았다.
        self.assertTrue(hs.outside_arrival_window(self.leg_at(4140), 2000))

    def test_창_안이면_거짓(self):
        # 900초 남았다 — 정확히 문턱이다. `>` 라 창 안이다.
        self.assertFalse(hs.outside_arrival_window(self.leg_at(4140), 3240))

    def test_승차_시각을_지났으면_창_안이다(self):
        """정류장에서 기다리는 중이다. **이때가 값이 가장 필요한 순간이다.**"""
        self.assertFalse(hs.outside_arrival_window(self.leg_at(4140), 4200))

    def test_버스_구간이_없으면_거짓(self):
        self.assertFalse(hs.outside_arrival_window(None, 0))

    def test_arrival_ready_가_같은_자를_쓴다(self):
        """문턱을 한쪽만 고치면 여기서 걸린다."""
        with mock.patch.object(hs, "outside_arrival_window",
                               lambda leg, progress: True), \
             mock.patch.object(hs, "start_arrival_refresh",
                               lambda *a, **k: self.fail("창 밖인데 물었다")):
            self.assertIsNone(hs.arrival_ready(LEGS, 3300, now=NOW))


class ArrivalWindowTests(unittest.TestCase):
    """승차 15분 전부터만 묻는다.

    **살아 있는 길(`arrival_ready`)로 잰다.** 예전에는 `bus_arrival_for` 로 쟀는데
    그 함수는 `content_state` 가 안 쓰게 되면서 죽었다 — 죽은 코드를 재는 시험은
    지나가도 아무것도 지켜 주지 않는다.
    """

    def setUp(self):
        hs._arrival_ready.clear()
        hs._arrival_refreshing.clear()

    def asked(self, progress):
        """그 자리에서 배경 갱신을 시켰는가."""
        started = []
        with mock.patch.object(hs, "start_arrival_refresh",
                               lambda *a, **k: started.append(a)):
            hs.arrival_ready(LEGS, progress, now=NOW)
        return len(started)

    def test_승차까지_15분_넘게_남으면_안_묻는다(self):
        # 999번 승차가 4140초인데 지금 2000초다 — 2140초(35분) 남았다.
        self.assertEqual(self.asked(2000), 0)

    def test_15분_안으로_들어오면_묻는다(self):
        # 3300초면 승차까지 840초(14분) 남았다.
        self.assertEqual(self.asked(3300), 1)

    def test_경계는_정확히_15분이다(self):
        """`>` 로 자른다 — 딱 900초 남은 자리는 창 **안**이다."""
        self.assertEqual(self.asked(4140 - 900), 1)      # 900초 남음 → 묻는다
        self.assertEqual(self.asked(4140 - 901), 0)      # 901초 남음 → 안 묻는다


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
        # 도착이 3분 뒤다. `NOW` 를 그대로 쓰면 "지금 도착" 경계에 걸쳐,
        # 이 시험이 재려는 것(캐시 적중)과 다른 것을 재게 된다.
        value = {"no": "999", "at": NOW + datetime.timedelta(minutes=3), "stops": 3}
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


class StaleArrivalTests(unittest.TestCase):
    """이미 지나간 도착은 값이 아니다.

    배경 갱신이 계속 실패하면 마지막으로 성공한 값이 그대로 남는다. 절대시각이라
    시계가 흐르면 언젠가 과거가 되고, 그때 화면은 이미 떠난 버스를 가리킨다.
    """

    def setUp(self):
        hs._arrival_ready.clear()
        hs._arrival_refreshing.clear()

    def test_지나간_값은_안_준다(self):
        key = ("999", 37.673130, 126.787047)
        # 1분 전에 도착했어야 할 버스. 방금 잰 값이라 캐시는 신선하다.
        hs._arrival_ready[key] = (NOW, {"no": "999", "stops": 0,
                                        "at": NOW - datetime.timedelta(minutes=1)})
        started = []
        with mock.patch.object(hs, "start_arrival_refresh",
                               lambda *a, **k: started.append(a)):
            got = hs.arrival_ready(LEGS, 3300, now=NOW)
        self.assertIsNone(got)
        # 신선해도 다시 묻는다 — 알고 싶은 것은 그다음 차다.
        self.assertEqual(len(started), 1)

    def test_앞차가_지나면_그다음_차가_다음_차다(self):
        """**버리기만 하면 아는 것을 안 말하게 된다.**

        2026-08-27 실주행에서 풍산역 정류장에 서 있는 동안 칩이 통째로 사라졌다.
        앞차가 지났다고 `thenAt` 까지 버렸는데, 그건 아직 오지 않은 차였다.
        """
        key = ("999", 37.673130, 126.787047)
        # 실측 근거(2026-08-26): 999번이 293초·1158초 두 대로 왔다.
        # 앞차는 1분 전에 지났고, 그다음 차는 14분 뒤다.
        hs._arrival_ready[key] = (NOW, {
            "no": "999", "stops": 0, "at": NOW - datetime.timedelta(minutes=1),
            "measuredAt": NOW,
            "thenAt": NOW + datetime.timedelta(minutes=14), "thenStops": 11})
        with mock.patch.object(hs, "start_arrival_refresh", lambda *a, **k: None):
            got = hs.arrival_ready(LEGS, 3300, now=NOW)
        self.assertIsNotNone(got, "그다음 차가 있는데 아무것도 안 줬다")
        self.assertEqual(got["at"], NOW + datetime.timedelta(minutes=14))
        self.assertEqual(got["stops"], 11)
        self.assertEqual(got["no"], "999")
        # 정류장 수의 나이를 재는 자는 그대로 따라와야 한다.
        self.assertEqual(got["measuredAt"], NOW)
        # **그다음의 그다음은 모른다.** 자료가 두 대까지만 준다.
        self.assertIsNone(got.get("thenAt"))

    def test_그다음_차도_지났으면_안_준다(self):
        key = ("999", 37.673130, 126.787047)
        hs._arrival_ready[key] = (NOW, {
            "no": "999", "stops": 0, "at": NOW - datetime.timedelta(minutes=5),
            "measuredAt": NOW,
            "thenAt": NOW - datetime.timedelta(minutes=1), "thenStops": 0})
        started = []
        with mock.patch.object(hs, "start_arrival_refresh",
                               lambda *a, **k: started.append(a)):
            got = hs.arrival_ready(LEGS, 3300, now=NOW)
        self.assertIsNone(got)
        self.assertEqual(len(started), 1)

    def test_그다음_차가_아예_없으면_안_준다(self):
        """막차거나 배차가 뜸한 시간. 예전 동작 그대로다."""
        key = ("999", 37.673130, 126.787047)
        hs._arrival_ready[key] = (NOW, {
            "no": "999", "stops": 0, "at": NOW - datetime.timedelta(minutes=1),
            "measuredAt": NOW})
        with mock.patch.object(hs, "start_arrival_refresh", lambda *a, **k: None):
            self.assertIsNone(hs.arrival_ready(LEGS, 3300, now=NOW))

    def test_승격해도_배경_갱신은_시킨다(self):
        """승격은 임시방편이다 — 진짜 값은 배경이 가져온다."""
        key = ("999", 37.673130, 126.787047)
        hs._arrival_ready[key] = (NOW, {
            "no": "999", "stops": 0, "at": NOW - datetime.timedelta(minutes=1),
            "measuredAt": NOW,
            "thenAt": NOW + datetime.timedelta(minutes=14), "thenStops": 11})
        started = []
        with mock.patch.object(hs, "start_arrival_refresh",
                               lambda *a, **k: started.append(a)):
            hs.arrival_ready(LEGS, 3300, now=NOW)
        self.assertEqual(len(started), 1)

    def test_빈손도_이유를_말한다(self):
        """**이 자리가 가장 오래 조용했다.** 구간도 좌표도 창도 멀쩡하고 값만
        빈손인 경우는 `arrival_says` 의 세 갈래 어디에도 안 걸린다."""
        key = ("999", 37.673130, 126.787047)
        hs._arrival_ready[key] = (NOW, None)
        said = []
        hs._arrival_silence = None
        with mock.patch.object(hs, "start_arrival_refresh", lambda *a, **k: None), \
             mock.patch.object(hs, "log", lambda *parts: said.append(" ".join(map(str, parts)))):
            self.assertIsNone(hs.arrival_ready(LEGS, 3300, now=NOW))
        self.assertTrue(any("빈손" in line for line in said),
                        f"이유를 안 말했다: {said}")

    def test_아직_안_물었으면_그렇게_말한다(self):
        said = []
        hs._arrival_silence = None
        with mock.patch.object(hs, "start_arrival_refresh", lambda *a, **k: None), \
             mock.patch.object(hs, "log", lambda *parts: said.append(" ".join(map(str, parts)))):
            self.assertIsNone(hs.arrival_ready(LEGS, 3300, now=NOW))
        self.assertTrue(any("배경이 채우는 중" in line for line in said),
                        f"이유를 안 말했다: {said}")

    def test_아무것도_못_주면_이유를_말한다(self):
        """**이 길만 조용했다.** 칩이 왜 없는지 말하게 해 뒀는데(2026-08-27)
        `gone` 은 세 갈래를 안 거치고 빠져나가서, 정작 실주행에서 사라진 그
        경우에 로그가 한 줄도 없었다."""
        key = ("999", 37.673130, 126.787047)
        hs._arrival_ready[key] = (NOW, {
            "no": "999", "stops": 0, "at": NOW - datetime.timedelta(minutes=1),
            "measuredAt": NOW})
        said = []
        hs._arrival_silence = None
        with mock.patch.object(hs, "start_arrival_refresh", lambda *a, **k: None), \
             mock.patch.object(hs, "log", lambda *parts: said.append(" ".join(map(str, parts)))):
            hs.arrival_ready(LEGS, 3300, now=NOW)
        self.assertTrue(any("앞차가 지났" in line for line in said),
                        f"이유를 안 말했다: {said}")

    def test_낡았어도_아직_안_지났으면_준다(self):
        key = ("999", 37.673130, 126.787047)
        # 2분 전에 잰 값(캐시 30초를 넘겼다)이지만 도착은 3분 뒤다.
        hs._arrival_ready[key] = (NOW - datetime.timedelta(minutes=2),
                                  {"no": "999", "stops": 2,
                                   "at": NOW + datetime.timedelta(minutes=3)})
        started = []
        with mock.patch.object(hs, "start_arrival_refresh",
                               lambda *a, **k: started.append(a)):
            got = hs.arrival_ready(LEGS, 3300, now=NOW)
        # 절대시각이라 낡아도 참이다. 새 값은 배경이 가져온다.
        self.assertEqual(got["no"], "999")
        self.assertEqual(len(started), 1)


class RefreshThreadTests(unittest.TestCase):
    """배경 갱신이 **실제로** 스레드로 돌고 캐시를 채운다.

    다른 시험들은 `start_arrival_refresh` 를 통째로 가짜로 바꿔서 이 기능의
    본체 — 스레드를 띄우고, 중복을 막고, 결과를 써 넣는 것 — 이 한 번도 안 돈다.
    """

    def setUp(self):
        hs._arrival_ready.clear()
        hs._arrival_refreshing.clear()

    def _wait(self, key, timeout=2.0):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if key in hs._arrival_ready:
                return True
            time.sleep(0.01)
        return False

    def test_배경이_캐시를_채운다(self):
        value = {"no": "999", "at": NOW, "stops": 4}
        key = ("999", 37.673130, 126.787047)
        with mock.patch.object(hs, "bus_arrival", lambda *a, **k: value):
            hs.start_arrival_refresh("999", 37.673130, 126.787047)
            self.assertTrue(self._wait(key), "배경 갱신이 캐시를 안 채웠다")
        self.assertEqual(hs._arrival_ready[key][1], value)
        # 다 끝났으면 진행 중 표시를 지운다.
        self.assertNotIn(key, hs._arrival_refreshing)

    def test_빈손이_아직_참인_값을_안_지운다(self):
        """**빈손은 증거가 아니다.**

        `tago_arrival_rows` 는 호출이 실패해도 빈 목록을 준다 — "그 버스가 안
        온다" 와 "물어보지 못했다" 가 같은 `None` 이다. 그 `None` 이 아직 안 지난
        값을 덮으면, 정류장에 서 있는 사람의 칩이 조회 한 번 실패로 사라진다.
        """
        # **실제 시계로 잰다.** `fill` 은 배경 스레드라 `now` 를 못 받는다 —
        # 고정된 `NOW` 로 쓰면 그 값이 이미 과거라 "아직 안 지난" 이 성립하지 않는다.
        real = hs.now()
        key = ("999", 37.673130, 126.787047)
        good = {"no": "999", "at": real + datetime.timedelta(minutes=6),
                "stops": 5, "measuredAt": real}
        hs._arrival_ready[key] = (real - datetime.timedelta(minutes=1), good)
        with mock.patch.object(hs, "bus_arrival", lambda *a, **k: None):
            hs.start_arrival_refresh("999", 37.673130, 126.787047)
            end = time.monotonic() + 2.0
            while key in hs._arrival_refreshing and time.monotonic() < end:
                time.sleep(0.01)
        self.assertEqual(hs._arrival_ready[key][1], good,
                         "빈손이 아직 참인 값을 지웠다")

    def test_빈손이_지나간_값은_지운다(self):
        """지나간 값은 지켜 줄 것이 없다. `gone` 이 어차피 걷어낸다."""
        real = hs.now()
        key = ("999", 37.673130, 126.787047)
        old = {"no": "999", "at": real - datetime.timedelta(minutes=10),
               "stops": 0, "measuredAt": real}
        hs._arrival_ready[key] = (real - datetime.timedelta(minutes=11), old)
        with mock.patch.object(hs, "bus_arrival", lambda *a, **k: None):
            hs.start_arrival_refresh("999", 37.673130, 126.787047)
            end = time.monotonic() + 2.0
            while key in hs._arrival_refreshing and time.monotonic() < end:
                time.sleep(0.01)
        self.assertIsNone(hs._arrival_ready[key][1])

    def test_빈손이어도_값이_없었으면_그대로_써넣는다(self):
        """처음부터 없던 자리다. 지킬 값이 없으니 캐시 시각이 갱신돼야
        30초 캐시가 제 몫을 한다."""
        key = ("999", 37.673130, 126.787047)
        with mock.patch.object(hs, "bus_arrival", lambda *a, **k: None):
            hs.start_arrival_refresh("999", 37.673130, 126.787047)
            self.assertTrue(self._wait(key), "빈손을 안 써넣었다")
        self.assertIsNone(hs._arrival_ready[key][1])

    def test_터져도_진행중_표시를_지운다(self):
        """안 지우면 그 노선은 이 프로세스가 사는 동안 영영 갱신이 막힌다."""
        key = ("999", 37.673130, 126.787047)

        def boom(*a, **k):
            raise ValueError("망가진 응답")

        with mock.patch.object(hs, "bus_arrival", boom):
            hs.start_arrival_refresh("999", 37.673130, 126.787047)
            end = time.monotonic() + 2.0
            while key in hs._arrival_refreshing and time.monotonic() < end:
                time.sleep(0.01)
        self.assertNotIn(key, hs._arrival_refreshing)
        # 터졌으니 값은 안 써진다 — 낡은 값이 있었다면 그대로 남는다.
        self.assertNotIn(key, hs._arrival_ready)


class SecondBusTests(unittest.TestCase):
    """같은 노선이 여러 대면 **그다음 차까지** 준다.

    앞차를 놓쳤을 때 얼마를 더 기다리는지가 뛸지 말지를 가른다. 실측에서 999번이
    293초·1158초 두 대로 왔다(2026-08-26).
    """

    def setUp(self):
        hs._arrival_stops.clear()
        hs._arrival_rows.clear()

    def near(self):
        return mock.patch.object(
            hs, "nearby_stops",
            lambda lat, lon, limit=8: [{"id": "GGB219000638", "name": "풍산역",
                                        "lat": 37.67315, "lon": 126.7872167,
                                        "city": 31100}])

    def test_두_대면_둘_다_준다(self):
        with self.near(), mock.patch.object(
                hs, "tago_arrival_rows",
                lambda city, node: [arrival_row("999", 1158, 11),
                                    arrival_row("999", 293, 2)]):
            got = hs.bus_arrival(BOARD_LAT, BOARD_LON, "999", now=NOW)
        # 빠른 쪽이 앞차다. 응답 순서를 믿지 않는다.
        self.assertEqual(got["at"], NOW + datetime.timedelta(seconds=293))
        self.assertEqual(got["stops"], 2)
        self.assertEqual(got["thenAt"], NOW + datetime.timedelta(seconds=1158))
        self.assertEqual(got["thenStops"], 11)

    def test_한_대뿐이면_그다음은_없다(self):
        with self.near(), mock.patch.object(
                hs, "tago_arrival_rows",
                lambda city, node: [arrival_row("999", 293, 2)]):
            got = hs.bus_arrival(BOARD_LAT, BOARD_LON, "999", now=NOW)
        self.assertNotIn("thenAt", got)

    def test_지난_차는_그다음에도_안_들어간다(self):
        with self.near(), mock.patch.object(
                hs, "tago_arrival_rows",
                lambda city, node: [arrival_row("999", -40, 0),
                                    arrival_row("999", 293, 2),
                                    arrival_row("999", 900, 8)]):
            got = hs.bus_arrival(BOARD_LAT, BOARD_LON, "999", now=NOW)
        self.assertEqual(got["at"], NOW + datetime.timedelta(seconds=293))
        self.assertEqual(got["thenAt"], NOW + datetime.timedelta(seconds=900))

    def test_잰_시각을_같이_준다(self):
        """정류장 수의 나이를 화면이 재려면 이게 있어야 한다."""
        with self.near(), mock.patch.object(
                hs, "tago_arrival_rows",
                lambda city, node: [arrival_row("999", 293, 2)]):
            got = hs.bus_arrival(BOARD_LAT, BOARD_LON, "999", now=NOW)
        self.assertEqual(got["measuredAt"], NOW)


class WaitingAtStopTests(unittest.TestCase):
    """정류장에 **서서 기다리는 동안**에도 도착정보가 살아 있어야 한다.

    진행도는 저장된 시간표에서 나온다. 버스가 늦으면 서 있는데도 승차 시각을
    지나고, 그러면 "이미 탔다" 로 판정돼 값이 사라졌다 — 하필 그 값이 가장
    필요한 순간이다(2026-08-26 시뮬레이터 검증에서 그렇게 사라졌다).
    """

    def test_좌표가_없으면_시간만으로_본다(self):
        # 옛 계약 그대로 — 첫 보고 전에는 좌표가 없다.
        self.assertIsNone(hs.next_bus_leg(LEGS, 4300))

    def test_승차_지점_근처면_아직_기다리는_중이다(self):
        found = hs.next_bus_leg(LEGS, 4300, 37.673180, 126.787167)
        self.assertEqual(found["busNo"], "999")

    def test_멀어졌으면_탄_것으로_본다(self):
        # 승차 지점에서 2km 밖. 버스를 타고 움직이는 중이다.
        self.assertIsNone(hs.next_bus_leg(LEGS, 4300, 37.6915, 126.787167))


class StringBodyTests(unittest.TestCase):
    """응답 `body` 가 **문자열**로 올 때 터지지 않는다.

    결과가 없으면 이 API 가 `"body": ""` 를 보낸다. `body.get(...)` 이 그대로
    터졌고, `/stops` 가 500 을 내며 정류장 목록이 통째로 안 보였다
    (2026-08-26, 서울 좌표로 물었을 때 — 서울 시내버스가 이 자료에 없어서
    그 자리에서는 늘 빈 응답이 온다).
    """

    def test_정류소_조회가_문자열을_받아도_빈_목록이다(self):
        with mock.patch.object(hs, "TAGO_KEY", "시험용"), \
             mock.patch.object(hs, "tago_stop_body", lambda lat, lon, limit: ""):
            self.assertEqual(hs.nearby_stops(37.528330, 126.917660), [])

    def test_도착정보_조회가_문자열을_받아도_빈_목록이다(self):
        with mock.patch.object(hs, "TAGO_KEY", "시험용"), \
             mock.patch.object(hs, "tago_arrival_body", lambda city, node: ""):
            self.assertEqual(hs.tago_arrival_rows(31100, "GGB219000638"), [])


def seoul_item(ars, sta_ord, tra1=None, sect1=None, tra2=None, sect2=None, msg1="", msg2=""):
    """`getArrInfoByRouteAll` 응답 한 항목. 실제 응답에서 쓰는 필드만 담는다.

    **글자가 아니라 숫자를 쓴다.** `arrmsg1` 은 `곧 도착` 일 때도 `traTime1` 이
    85 로 온다(2026-08-27 실측) — 글자를 뜯으면 그런 경우마다 규칙이 는다.
    """
    parts = [f"<arsId>{ars}</arsId>", f"<staOrd>{sta_ord}</staOrd>",
             f"<arrmsg1>{msg1}</arrmsg1>", f"<arrmsg2>{msg2}</arrmsg2>"]
    if tra1 is not None:
        parts += [f"<traTime1>{tra1}</traTime1>", f"<sectOrd1>{sect1}</sectOrd1>"]
    if tra2 is not None:
        parts += [f"<traTime2>{tra2}</traTime2>", f"<sectOrd2>{sect2}</sectOrd2>"]
    return "".join(parts)


class SeoulArrivalTests(unittest.TestCase):
    """서울은 TAGO 에 없어서 TOPIS 로 넘어간다.

    TAGO 도시코드 목록에 서울이 아예 없고 좌표로 정류장을 물어도 빈 결과다
    (2026-08-26 실측). 노선번호 → 노선id 는 구워 둔 표에서 온다 — 그 API 는
    지금 키로 401 이다.
    """

    # 국회의사당역.KB국민은행. `seoul-stops.json` 의 실제 값이다.
    ARS = "19132"
    LAT, LON = 37.528479, 126.918068

    def setUp(self):
        hs._seoul_rows.clear()
        hs._arrival_stops.clear()

    def stops_table(self):
        return mock.patch.object(hs, "SEOUL_STOPS",
                                 [["국회의사당역.KB국민은행", self.LAT, self.LON, self.ARS]])

    def routes(self, table=None):
        return mock.patch.object(hs, "_seoul_routes",
                                 table if table is not None else {"163": ["100100032"]})

    def test_두_대를_절대시각으로_준다(self):
        items = [seoul_item("99999", 10, 60, 9),
                 seoul_item(self.ARS, 60, 85, 60, 377, 59, "곧 도착", "6분17초후[1번째 전]")]
        with self.stops_table(), self.routes(), mock.patch.object(
                hs, "seoul_arrival_items", lambda rid: items):
            got = hs.seoul_bus_arrival(self.LAT, self.LON, "163", now=NOW)
        self.assertEqual(got["no"], "163")
        self.assertEqual(got["at"], NOW + datetime.timedelta(seconds=85))
        self.assertEqual(got["stops"], 0)          # staOrd 60 − sectOrd1 60
        self.assertEqual(got["thenAt"], NOW + datetime.timedelta(seconds=377))
        self.assertEqual(got["thenStops"], 1)      # 60 − 59
        self.assertEqual(got["measuredAt"], NOW)

    def test_곧_도착이라고_적혀_있어도_숫자를_쓴다(self):
        """`arrmsg1` 을 파싱했다면 `곧 도착` 에서 시각을 못 냈을 것이다."""
        items = [seoul_item(self.ARS, 60, 85, 60, msg1="곧 도착")]
        with self.stops_table(), self.routes(), mock.patch.object(
                hs, "seoul_arrival_items", lambda rid: items):
            got = hs.seoul_bus_arrival(self.LAT, self.LON, "163", now=NOW)
        self.assertEqual(got["at"], NOW + datetime.timedelta(seconds=85))

    def test_노선_안에서_가장_가까운_정류장을_고른다(self):
        """한 번 부르면 그 노선 정류장이 다 온다 — 노선이 안 서는 기둥을 고를 수 없다."""
        far = ["먼정류장", 37.560000, 126.930000, "11111"]
        items = [seoul_item("11111", 20, 60, 19), seoul_item(self.ARS, 60, 85, 60)]
        with mock.patch.object(hs, "SEOUL_STOPS",
                               [far, ["국회의사당역.KB국민은행", self.LAT, self.LON, self.ARS]]), \
             self.routes(), mock.patch.object(hs, "seoul_arrival_items", lambda rid: items):
            got = hs.seoul_bus_arrival(self.LAT, self.LON, "163", now=NOW)
        self.assertEqual(got["at"], NOW + datetime.timedelta(seconds=85))

    def test_표에_없는_노선이면_안_묻는다(self):
        asked = []
        with self.stops_table(), self.routes({}), mock.patch.object(
                hs, "seoul_arrival_items", lambda rid: asked.append(1) or []):
            self.assertIsNone(hs.seoul_bus_arrival(self.LAT, self.LON, "163", now=NOW))
        self.assertEqual(asked, [])

    def test_승차_좌표에서_멀면_그_갈래가_아니다(self):
        """같은 번호가 여러 id 를 가질 수 있다(01A/01B). 엉뚱한 갈래를 안 쓴다."""
        items = [seoul_item(self.ARS, 60, 85, 60)]
        with self.stops_table(), self.routes(), mock.patch.object(
                hs, "seoul_arrival_items", lambda rid: items):
            got = hs.seoul_bus_arrival(37.60, 127.05, "163", now=NOW)
        self.assertIsNone(got)

    def test_TAGO_가_정류장을_못_찾으면_서울로_넘어간다(self):
        items = [seoul_item(self.ARS, 60, 85, 60)]
        with self.stops_table(), self.routes(), \
             mock.patch.object(hs, "nearby_stops", lambda lat, lon, limit=8: []), \
             mock.patch.object(hs, "seoul_arrival_items", lambda rid: items):
            got = hs.bus_arrival(self.LAT, self.LON, "163", now=NOW)
        self.assertEqual(got["no"], "163")

    def test_구워_둔_표에_163_과_6713_이_있다(self):
        """표가 깨지면 서울이 통째로 조용히 안 뜬다."""
        table = hs.seoul_routes()
        self.assertGreater(len(table), 500)
        self.assertEqual(table.get("163"), ["100100032"])
        self.assertEqual(table.get("6713"), ["100100293"])


if __name__ == "__main__":
    unittest.main()
