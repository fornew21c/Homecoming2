"""버스 구간의 경유 좌표를 **노선 정류장 목록**에서 뽑는다.

    python3 -m unittest discover -s Server

**네트워크를 안 탄다.** 노선 정류장 목록을 갈아 끼우고 집는 규칙만 본다.

## 왜 이 길을 새로 뒀나

2026-08-28 에 캡처로 만든 경로의 999 구간이 자동차 경로로 그려졌다. 로그가
`경유 정류장 0개` 였고 원인은 **우리가 먼저 끊는 것**이었다 —

    TAGO 신규 계열 getBusRoute, opr_ymd=20260601, numOfRows=1
      timeout=15  →  TimeoutError          ← new_style_get 이 쓰던 값
      timeout=75  →  31.9초 만에 SUCCESS

자료는 온다. 다만 32초 걸린다. 타임아웃만 늘려도 못 쓴다 — `bus_route_ids` 가
경기 노선표를 페이지 다섯 개로 받으므로 160초가 된다.

**이미 잘 도는 자료가 있었다.** `route_stop_lists` 는 경기는 GBIS 경유정류소,
서울은 TOPIS 도착정보에서 정류장을 **좌표와 순번까지** 준다. 실측(2026-08-28) —

    999번  0.8초  20753(seq 13) → 20796(seq 21)  사이 7개, 좌표 전부 있음
    163번  0.4초  19132(seq 60) → 14205(seq 64)  사이 3개

둘 다 캡처가 적어 준 `8개 정류장 이동`·`4개 정류장 이동` 과 맞는다.

의존성 없음. 표준 unittest 다.
"""

import os
import pathlib
import sys
import tempfile
import unittest

_TMP = tempfile.mkdtemp()
os.environ.setdefault("HOMECOMING_DB", str(pathlib.Path(_TMP) / "test.sqlite"))

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import homecoming_server as hs   # noqa: E402


def stop(no, name, lat, lon, seq):
    return {"id": no, "no": no, "name": name, "lat": lat, "lon": lon, "seq": seq}


# 실측 — GBIS 고양 999. 승차 20753(seq 13)에서 하차 20796(seq 21)까지.
GOYANG_999 = [
    stop("20753", "풍산역", 37.67315, 126.7872167, 13),
    stop("20576", "애니골입구", 37.67435, 126.79197, 14),
    stop("20721", "해들마을", 37.67583, 126.79548, 15),
    stop("58218", "삼성캐슬.삼학법보사", 37.67785, 126.80048, 16),
    stop("20797", "고양가구3단지입구", 37.68197, 126.80337, 17),
    stop("20791", "전원마을입구", 37.68407, 126.80447, 18),
    stop("20758", "동국로삼거리", 37.68475, 126.80690, 19),
    stop("20794", "고양국제고등학교", 37.68342, 126.80803, 20),
    stop("20796", "위시티1.3단지", 37.6822, 126.8108, 21),
    stop("20523", "위시티3.4단지", 37.6805833, 126.8128167, 22),
]

# 같은 번호를 쓰는 다른 지역 노선. 999 는 고양과 수원 둘이다(2026-08-27 기록).
SUWON_999 = [
    stop("01234", "수원어딘가", 37.26, 127.02, 1),
    stop("01235", "수원또어딘가", 37.27, 127.03, 2),
]

# 승차 기둥 20753 · 하차 기둥 20796 의 좌표. 캡처가 짚어 준 값이다.
FROM = (37.67315, 126.7872167)
TO = (37.6822, 126.8108)


class RouteListPointsTests(unittest.TestCase):
    """노선 정류장 목록에서 집는다. **32초 걸리는 길을 타지 않는다.**"""

    def points(self, lists, **kwargs):
        got = hs.bus_leg_waypoints(
            "999", FROM[0], FROM[1], kwargs.pop("to_name", "위시티1.3단지"),
            to_lat=kwargs.pop("to_lat", TO[0]),
            to_lon=kwargs.pop("to_lon", TO[1]),
            lists=lists, **kwargs)
        return got

    def test_사이_정류장_일곱_개를_좌표로_준다(self):
        points, missing = self.points([GOYANG_999])
        self.assertEqual(len(points), 7)
        self.assertEqual(missing, [])
        # 승차·하차 자신은 안 넣는다. 부르는 쪽이 두 끝을 이미 갖고 있다.
        self.assertNotIn([37.67315, 126.78722], points)
        self.assertNotIn([37.6822, 126.8108], points)

    def test_순서가_노선_순번_그대로다(self):
        points, _ = self.points([GOYANG_999])
        self.assertEqual(points[0], [37.67435, 126.79197])    # 애니골입구
        self.assertEqual(points[-1], [37.68342, 126.80803])   # 고양국제고등학교

    def test_자동차_경로에_없던_정류장이_들어_있다(self):
        """2026-08-20 기록 — 999 가 전원마을입구·동국로삼거리로 북쪽으로 올라갔다
        내려오는데 자동차 경로에는 그 구간이 없었다. 그게 이 함수가 있는 이유다."""
        points, _ = self.points([GOYANG_999])
        self.assertIn([37.68407, 126.80447], points)          # 전원마을입구
        self.assertIn([37.68475, 126.8069], points)           # 동국로삼거리

    def test_번호가_같은_다른_지역_노선은_건너뛴다(self):
        """999 는 고양과 수원 둘이다. 좌표가 어느 쪽인지 정한다."""
        points, _ = self.points([SUWON_999, GOYANG_999])
        self.assertEqual(len(points), 7)

    def test_방향이_반대인_목록은_안_쓴다(self):
        """하차가 승차보다 앞에 있으면 그 방향이 아니다."""
        points, _ = self.points([list(reversed(GOYANG_999))])
        self.assertEqual(points, [])

    def test_좌표가_없으면_이름으로_하차를_집는다(self):
        """옛 앱은 좌표를 늘 보내지만, 안 보내는 길도 살려 둔다."""
        points, _ = self.points([GOYANG_999], to_lat=None, to_lon=None)
        self.assertEqual(len(points), 7)

    def test_너무_먼_좌표는_안_집는다(self):
        """확신 없이 하나를 고르는 것보다 빈손이 낫다 — `nearest_stop` 과 같은 자다."""
        got = hs.bus_leg_waypoints("999", 37.55, 126.93, "위시티1.3단지",
                                   to_lat=TO[0], to_lon=TO[1], lists=[GOYANG_999])
        self.assertEqual(got, ([], []))

    def test_바로_다음_정류장이면_사이가_비고_그것이_정답이다(self):
        """한 정류장만 가는 구간. 빈 배열이 실패가 아니다."""
        points, missing = hs.bus_leg_waypoints(
            "999", FROM[0], FROM[1], "애니골입구",
            to_lat=37.67435, to_lon=126.79197, lists=[GOYANG_999])
        self.assertEqual(points, [])
        self.assertEqual(missing, [])


class FallbackTests(unittest.TestCase):
    """목록에서 못 집으면 예전 길(TAGO 신규 계열)로 내려간다.

    **없애지 않는 이유** — GBIS 는 경기, TOPIS 는 서울뿐이다. 다른 시도는
    그 길밖에 없다.
    """

    def test_목록이_비면_예전_길을_부른다(self):
        called = {}

        def spy(route_no, from_lat, from_lon, to_name, from_name):
            called["yes"] = (route_no, to_name)
            return [[1.0, 2.0]], ["어딘가"]

        original = hs._bus_leg_waypoints_tago
        hs._bus_leg_waypoints_tago = spy
        try:
            got = hs.bus_leg_waypoints("999", FROM[0], FROM[1], "위시티1.3단지",
                                       to_lat=TO[0], to_lon=TO[1], lists=[])
        finally:
            hs._bus_leg_waypoints_tago = original
        self.assertEqual(got, ([[1.0, 2.0]], ["어딘가"]))
        self.assertEqual(called.get("yes"), ("999", "위시티1.3단지"))


class TimeoutTests(unittest.TestCase):
    """`new_style_get` 이 15초에 끊으면 **자료가 와도 못 받는다.**

    실측(2026-08-28) — 그 API 는 31.9초 걸린다. 15초는 실패를 보장하는 값이다.
    """

    def test_타임아웃이_실측보다_넉넉하다(self):
        self.assertGreaterEqual(hs.NEW_STYLE_TIMEOUT, 35)


if __name__ == "__main__":
    unittest.main()
