"""진행도(`travelledMeters`) 시험.

    cd Server && python3 -m unittest test_progress_sync -v

의존성 없음. 표준 unittest 다. DB 는 `HOMECOMING_DB` 로 임시 파일에 붙인다.

**이 시험이 지키는 것** — 카드의 노선도 점과 지도의 색 분리가 "얼마나 왔나" 를
각자 계산했다. 정상 이동에서는 평균 36m 로 맞았지만 예외에서 갈라졌다
(2026-08-20 실측, 28.4km 경로): GPS 역행 7,404m, 경로 이탈 4,349m.

원인은 `remaining_meters` 를 되짚어 위치를 낸 것이다. 그 값은 **뜻이 바뀐다** —
경로를 벗어나면 서버가 집까지 직선거리로 바꿔 보낸다. 직선은 경로보다 짧으니
되짚은 값이 커지고 노선도의 점이 **앞으로 뛴다**.

그래서 진행도를 서버가 한 번 계산해 내려보내고 두 화면이 그 숫자를 쓴다.
여기서 지키는 것은 그 값의 성질이다 — 뒤로 가지 않고, 이탈하면 멈추고,
도착하면 끝에 닿는다.

**지도가 그 값으로 실제로 같은 자리를 자르는지**는 여기서 못 잰다(Swift 코드다).
`python3 Tools/verify-progress-sync.py` 가 앱 원본을 컴파일해서 그것을 잰다.
"""

import os
import pathlib
import sys
import tempfile
import unittest
from datetime import timedelta

_TMP = tempfile.mkdtemp()
os.environ["HOMECOMING_DB"] = str(pathlib.Path(_TMP) / "test.sqlite")

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import homecoming_server as hs   # noqa: E402

ROUTE = pathlib.Path(__file__).resolve().parent.parent / "Tools" / "routes" / "commute-sample.json"

# 집. 아래 경로의 끝이다.
HOME = (37.6800, 126.7600)

# `test_off_route` 와 같은 경로다. 꼭짓점 다섯 개짜리 한 구간 — 진행이 0 도 끝도
# 아닌 값을 가질 수 있어야 "뒤로 가지 않는다" 를 확인할 수 있다.
LEGS = [{
    "mode": "subway",
    "toName": "풍산역",
    "startsAt": 0,
    "seconds": 1800,
    "points": [
        [37.5500, 126.9200],
        [37.5825, 126.8800],
        [37.6150, 126.8400],   # 가운데
        [37.6475, 126.8000],
        [37.6800, 126.7600],
    ],
}]

MID = (37.6150, 126.8400)
START = (37.5500, 126.9200)


def make_session(route=True):
    started = hs.now() - timedelta(minutes=10)
    if route:
        hs.db().execute(
            """INSERT INTO routes (id, account_id, name, home_lat, home_lon, home_radius,
               home_name, total_seconds, legs, created_at) VALUES (?,?,?,?,?,?,?,?,?,?)""",
            ("r1", "acct", "회사-집", HOME[0], HOME[1], 150, "집",
             1800, hs.json.dumps(LEGS), hs.iso(started)))
    hs.db().execute(
        """INSERT INTO sessions (id, traveler, traveler_name, home_lat, home_lon,
           home_radius, home_name, total_meters, remaining_meters, stage, transport,
           expected_arrival, started_at, route_id, measured_at)
           VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
        ("s1", "acct", "아빠", HOME[0], HOME[1], 150, "집",
         20000, 20000, "leaving", "subway", hs.iso(started),
         hs.iso(started), "r1" if route else None, hs.iso(started)))
    hs.db().commit()
    return hs.db().execute("SELECT * FROM sessions WHERE id = 's1'").fetchone()


class TravelledMeters(unittest.TestCase):

    def setUp(self):
        for table in ("sessions", "routes", "fixes", "activities"):
            hs.db().execute(f"DELETE FROM {table}")
        hs.db().commit()
        self.at = hs.now()

    def step(self, lat, lon):
        """위치 하나를 흘려 넣고 그때 나가는 상태를 돌려준다."""
        self.at += timedelta(seconds=45)
        session = hs.db().execute("SELECT * FROM sessions WHERE id = 's1'").fetchone()
        hs.recompute(session, lat, lon, self.at)
        return hs.content_state(
            hs.db().execute("SELECT * FROM sessions WHERE id = 's1'").fetchone())

    # ------------------------------------------------------------ 있는가

    def test_경로가_있으면_진행도가_실린다(self):
        make_session()
        state = self.step(*MID)
        self.assertIn("travelledMeters", state)

    def test_경로_없이_시작한_귀가는_진행도가_없다(self):
        # 경로 위에서만 정의되는 값이다. 없는 것을 0 으로 보내면 앱은 "출발점에
        # 있다" 로 읽는다 — 키를 빼야 앱이 예전 계산으로 폴백한다.
        make_session(route=False)
        state = self.step(*MID)
        self.assertNotIn("travelledMeters", state)

    def test_진행도가_경로_길이를_넘지_않는다(self):
        make_session()
        state = self.step(*MID)
        self.assertLessEqual(state["travelledMeters"], hs.route_length(LEGS))
        self.assertGreaterEqual(state["travelledMeters"], 0)

    # ------------------------------------------------------------ 뒤로 안 간다

    def test_GPS_가_역행해도_진행도는_유지된다(self):
        # 사람은 되돌아가지 않았다. 되돌아가면 노선도의 점과 지도의 색이 함께
        # 뒤로 밀린다 — 실측에서 옛 지도 계산이 7,404m 되돌아갔다.
        make_session()
        self.step(*MID)
        forward = self.step(37.6475, 126.8000)["travelledMeters"]
        back = self.step(*START)["travelledMeters"]
        self.assertEqual(back, forward)

    # ------------------------------------------------------------ 이탈

    def test_이탈하면_진행도가_멈춘다(self):
        make_session()
        self.step(*MID)
        before = self.step(*MID)["travelledMeters"]
        off = self.step(MID[0] + 0.02, MID[1])          # 경로에서 2km 남짓
        self.assertEqual(off["estimateSource"], "offRoute")
        self.assertEqual(off["travelledMeters"], before,
                         "이탈 중에는 진행도가 그 자리에 서 있어야 한다")

    def test_이탈하면_남은거리로_되짚은_값은_앞으로_튄다(self):
        """**고친 버그를 못박는 시험이다.**

        옛 계산(`totalMeters - remainingMeters`)이 왜 위치의 근거가 못 되는지
        여기서 보인다. 이탈하면 `remainingMeters` 가 집까지 직선거리로 바뀌므로
        되짚은 값이 갑자기 커진다 — 노선도의 점이 앞으로 뛴다.
        """
        make_session()
        self.step(*MID)
        before = self.step(*MID)
        off = self.step(MID[0] + 0.02, MID[1])
        total = hs.route_length(LEGS)
        self.assertGreater(total - off["remainingMeters"], total - before["remainingMeters"],
                           "되짚은 값은 이탈에서 앞으로 튄다 — 그래서 쓰지 않는다")
        self.assertEqual(off["travelledMeters"], before["travelledMeters"],
                         "진행도는 같은 자리에 서 있다")

    def test_복귀하면_다시_늘어난다(self):
        make_session()
        self.step(*START)
        self.step(MID[0] + 0.02, MID[1])                # 이탈
        back = self.step(37.6475, 126.8000)             # 경로로 복귀
        self.assertEqual(back["estimateSource"], "route")
        self.assertGreater(back["travelledMeters"], 0)

    # ------------------------------------------------------------ 도착

    def test_도착하면_경로_전체_길이다(self):
        # `route_progress` 는 끝까지 가지 않는다 — 도착은 거리로 판정하므로
        # (`stage_for`) 진행이 남는다. 그대로 보내면 두 화면이 마지막 구간을
        # 남은 것으로 그린다.
        make_session()
        state = self.step(*HOME)
        self.assertEqual(state["stage"], "arrived")
        self.assertEqual(state["travelledMeters"], hs.route_length(LEGS))


class TrailAxis(unittest.TestCase):
    """지도가 자르는 축이 진행도의 축과 같은지.

    지도는 좌표열을 따라 누적으로 자른다. 그 누적을 **구간별로** 재야
    `route_length()` 와 같은 자가 된다 — 이어붙인 폴리라인으로 재면 구간 경계의
    이음(앞 구간의 끝점과 뒤 구간의 시작점이 어긋난 자리)이 거리에 섞인다.

    앱이 그렇게 하고 있는지는 Swift 쪽 일이라 여기서 못 본다
    (`Tools/verify-progress-sync.py` 가 잰다). 여기서 지키는 것은 **서버가 보내는
    좌표열이 그 축을 유지하는지**다 — `route_geometry` 가 구간을 합치거나 이음을
    메우기 시작하면 지도의 자가 조용히 달라진다.
    """

    def setUp(self):
        self.legs = hs.json.loads(ROUTE.read_text(encoding="utf-8"))["legs"]
        self.geometry = hs.route_geometry(self.legs)

    def line_length(self, points):
        return sum(hs.haversine(a[0], a[1], b[0], b[1])
                   for a, b in zip(points, points[1:]))

    def test_구간별_누적이_경로_길이와_같다(self):
        total = sum(self.line_length(s["points"]) for s in self.geometry["segments"])
        # 좌표를 소수 5자리로 줄여 보내므로 몇 m 는 어긋난다. 10m 면 넉넉하다.
        self.assertAlmostEqual(total, hs.route_length(self.legs), delta=10)

    def test_이어붙인_폴리라인은_축이_다르다(self):
        """**측정 기록이다.** 폴리라인으로 자르면 안 되는 이유가 이 숫자다.

        이 시험이 깨지면 두 가지 중 하나다 — 이음이 없어졌거나(그럼 폴리라인으로
        재도 된다) 더 벌어졌거나. 어느 쪽이든 지도의 자를 다시 봐야 한다.
        """
        line = self.line_length(self.geometry["polyline"])
        gap = line - hs.route_length(self.legs)
        self.assertGreater(gap, 50, "2026-08-20 측정: 이음 세 곳, 합 97.9m")
        self.assertLess(gap, 150)


if __name__ == "__main__":
    unittest.main()
