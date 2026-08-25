"""경로 이탈·복귀 판정 시험.

    cd Server && python3 -m unittest test_off_route -v

의존성 없음. 표준 unittest 다. DB 는 `HOMECOMING_DB` 로 임시 파일에 붙인다.

**이 시험이 지키는 것** — 2026-08-18 실주행에서 지하철 GPS 가 1043m 튀어 이탈 문턱
(1000m)을 43m 넘긴 순간 `off_route` 가 서고, 그걸 False 로 되돌리는 코드가 한 줄도
없어서 **남은 49분 전체가 직선거리 폴백으로 돌았다.** 구간 문구와 노선도의 점도 그
순간에 얼어붙었다. 다시 그렇게 되면 여기서 걸린다.
"""

import os
import pathlib
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone

_TMP = tempfile.mkdtemp()
os.environ["HOMECOMING_DB"] = str(pathlib.Path(_TMP) / "test.sqlite")

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import homecoming_server as hs   # noqa: E402


# 집. 아래 경로의 끝이다.
HOME = (37.6800, 126.7600)

# 한 구간, 좌표 다섯 개. 집으로 곧장 다가간다.
#
# 실제 경로처럼 여러 구간을 만들 이유는 없다 — 이 시험이 보는 것은 `where_on_route`
# 가 잰 거리로 이탈·복귀가 갈리는지 하나뿐이다.
#
# **좌표를 두 개만 두면 안 된다.** `where_on_route` 는 선분에 투영하지 않고 가장
# 가까운 **꼭짓점**을 고르므로, 두 개뿐이면 진행이 0 아니면 1800 두 값밖에 못 된다.
# 그러면 "이탈 중에 진행이 뒤로 가지 않는다" 를 0 에서 확인하는 셈이 되어 아무것도
# 증명하지 못한다.
LEGS = [{
    "mode": "subway",
    "toName": "풍산역",
    "startsAt": 0,
    "seconds": 1800,
    "points": [
        [37.5500, 126.9200],
        [37.5825, 126.8800],
        [37.6150, 126.8400],   # 가운데. 진행 시험이 이 점을 쓴다
        [37.6475, 126.8000],
        [37.6800, 126.7600],
    ],
}]

# 경로 가운데 꼭짓점. 여기 서면 진행이 0 도 끝도 아닌 값이 된다.
MID = (37.6150, 126.8400)


def make_session(session_id="s1"):
    """경로를 붙인 세션 하나를 넣고 그 행을 돌려준다."""
    started = datetime.now(timezone.utc) - timedelta(minutes=10)
    hs.db().execute(
        """INSERT INTO routes (id, account_id, name, home_lat, home_lon, home_radius,
           home_name, total_seconds, legs, created_at) VALUES (?,?,?,?,?,?,?,?,?,?)""",
        ("r1", "acct", "회사-집", HOME[0], HOME[1], 150, "집",
         1800, hs.json.dumps(LEGS), hs.iso(started)),
    )
    hs.db().execute(
        """INSERT INTO sessions (id, traveler, traveler_name, home_lat, home_lon,
           home_radius, home_name, total_meters, remaining_meters, stage, transport,
           expected_arrival, detail, started_at, route_id, measured_at)
           VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
        (session_id, "acct", "아빠", HOME[0], HOME[1], 150, "집",
         20000, 20000, "leaving", "subway", hs.iso(started), None,
         hs.iso(started), "r1", hs.iso(started)),
    )
    hs.db().commit()
    return hs.db().execute("SELECT * FROM sessions WHERE id = ?", (session_id,)).fetchone()


def route_columns(conn, session_id):
    return conn.execute(
        "SELECT off_route, route_progress, remaining_meters, detail FROM sessions WHERE id = ?",
        (session_id,),
    ).fetchone()


class OffRouteHysteresis(unittest.TestCase):

    def setUp(self):
        # 표를 비우고 시작한다. 시험끼리 상태를 물려주면 안 된다.
        for table in ("sessions", "routes", "fixes", "activities"):
            hs.db().execute(f"DELETE FROM {table}")
        hs.db().commit()
        self.session = make_session()
        self.at = hs.now()

    def step(self, lat, lon):
        """위치 하나를 흘려 넣고 갱신된 세션 행을 돌려준다."""
        self.at += timedelta(seconds=30)
        session = hs.db().execute(
            "SELECT * FROM sessions WHERE id = ?", (self.session["id"],)
        ).fetchone()
        return hs.recompute(session, lat, lon, self.at)

    def test_경로_위에서는_경로_거리로_잰다(self):
        row = self.step(37.5500, 126.9200)
        self.assertEqual(row["off_route"], 0)
        self.assertIsNotNone(row["detail"], "경로 위에서는 구간 문구가 있어야 한다")

    def test_크게_벗어나면_이탈로_떨어진다(self):
        # 경로에서 한참 남쪽. 문턱(1000m)을 확실히 넘긴다.
        row = self.step(37.4000, 126.9200)
        self.assertEqual(row["off_route"], 1)

    def test_이탈했다가_돌아오면_다시_경로로_잰다(self):
        """**이게 이 파일의 이유다.** 예전에는 영영 돌아오지 못했다."""
        self.assertEqual(self.step(37.4000, 126.9200)["off_route"], 1)

        # 경로 좌표 위로 돌아왔다.
        row = self.step(37.5500, 126.9200)
        self.assertEqual(row["off_route"], 0, "복귀 문턱 안으로 들어왔으면 풀려야 한다")
        self.assertIsNotNone(row["detail"], "복귀했으면 구간 문구가 다시 나와야 한다")

    def test_이탈해도_도착예정은_경로의_시간_예산에서_온다(self):
        """**2026-08-25 실주행에서 이걸로 가족이 도착한 줄 알았다.**

        직선거리 폴백은 도착예정을 크게 앞당긴다 — 그날 저장된 경로의 예정
        (18:54)은 실제 도착(18:48)과 6분 차이였는데, 폴백은 18분 틀렸다.
        도착예정은 `총소요시간 + 지연 − 경과시간` 이라 위치를 안 쓴다.
        """
        on_route = self.step(37.5500, 126.9200)
        self.assertEqual(on_route["off_route"], 0)

        # 경로에서 한참 벗어난다. 집에 **더 가까운** 쪽으로 벗어나는 것이 요점이다 —
        # 직선거리로 재면 도착예정이 확 당겨지는 자리다.
        off = self.step(HOME[0] - 0.01, HOME[1])
        self.assertEqual(off["off_route"], 1)

        # `elapsed` 는 측정 시각(`at`)으로 재고, 도착예정은 **벽시계**에서 더한다 —
        # 경로 위에 있을 때와 같은 규칙이다.
        elapsed = (self.at - hs.parse_iso(self.session["started_at"])).total_seconds()
        expected = hs.now() + timedelta(
            seconds=max(30, 1800 + off["delay_seconds"] - elapsed))
        gap = abs((hs.parse_iso(off["expected_arrival"]) - expected).total_seconds())
        self.assertLess(gap, 5, "이탈해도 경로의 시간 예산으로 내야 한다")

    def test_이탈하면_남은거리는_직선으로_잰다(self):
        """도착예정과 달리 **남은거리는 경로에서 못 낸다.** 경로 위 어디인지
        모르는 채로 경로 거리를 말하면 거짓이다."""
        self.step(37.5500, 126.9200)
        off = self.step(HOME[0] - 0.01, HOME[1])
        straight = hs.haversine(HOME[0] - 0.01, HOME[1], HOME[0], HOME[1])
        self.assertAlmostEqual(off["remaining_meters"], int(straight), delta=5)

    def test_이탈_문턱과_복귀_문턱_사이에서는_이탈을_유지한다(self):
        """경계에서 깜박이지 않는다 — 이력(hysteresis)이 있다."""
        self.assertLess(hs.OFF_ROUTE_REJOIN_METERS, hs.OFF_ROUTE_METERS)

        self.assertEqual(self.step(37.4000, 126.9200)["off_route"], 1)

        # 경로에서 약 800m. 이탈 문턱(1000m)보다는 가깝고 복귀 문턱(600m)보다는 멀다.
        gap = hs.haversine(37.5428, 126.9200, 37.5500, 126.9200)
        self.assertTrue(
            hs.OFF_ROUTE_REJOIN_METERS < gap < hs.OFF_ROUTE_METERS,
            f"시험 좌표가 두 문턱 사이에 있어야 한다 (지금 {int(gap)}m)",
        )
        self.assertEqual(self.step(37.5428, 126.9200)["off_route"], 1,
                         "두 문턱 사이에서는 이탈을 유지해야 한다")

    def test_진행은_이탈_중에_뒤로_가지_않는다(self):
        self.step(*MID)                       # 경로 가운데
        before = route_columns(hs.db(), self.session["id"])["route_progress"]
        self.assertGreater(before, 0)

        self.step(37.4000, 126.9200)          # 이탈
        after = route_columns(hs.db(), self.session["id"])["route_progress"]
        self.assertEqual(after, before, "이탈 중에는 진행을 건드리지 않는다")


class MeasuredAtAndSource(unittest.TestCase):
    """화면이 낡음과 추정 방식을 스스로 말할 수 있어야 한다."""

    def setUp(self):
        for table in ("sessions", "routes", "fixes", "activities"):
            hs.db().execute(f"DELETE FROM {table}")
        hs.db().commit()
        self.session = make_session("s2")

    def test_측정_시각을_상태에_싣는다(self):
        at = hs.now()
        row = hs.recompute(self.session, 37.5500, 126.9200, at)
        state = hs.content_state(row)
        self.assertEqual(state["measuredAt"], hs.iso(at),
                         "배달 시각이 아니라 측정 시각이어야 한다")

    def test_경로_위에서는_source_가_route(self):
        row = hs.recompute(self.session, 37.5500, 126.9200, hs.now())
        self.assertEqual(hs.content_state(row)["estimateSource"], "route")

    def test_벗어나면_source_가_offRoute(self):
        row = hs.recompute(self.session, 37.4000, 126.9200, hs.now())
        self.assertEqual(hs.content_state(row)["estimateSource"], "offRoute",
                         "경로가 있는데 벗어난 것과 경로가 없는 것은 달라야 한다")

    def test_경로_없이_시작한_귀가는_source_가_distance(self):
        hs.db().execute("UPDATE sessions SET route_id = NULL WHERE id = ?", ("s2",))
        hs.db().commit()
        session = hs.db().execute("SELECT * FROM sessions WHERE id = ?", ("s2",)).fetchone()
        row = hs.recompute(session, 37.5500, 126.9200, hs.now())
        self.assertEqual(hs.content_state(row)["estimateSource"], "distance")


class SessionReuse(unittest.TestCase):
    """진행 중인 세션을 언제 재사용하고 언제 버리는가.

    **이 시험이 지키는 것** — 앱이 강제 종료되면 iOS 가 Live Activity 를 끝내고, 앱은
    서버 세션을 닫지 못한다. 그 세션이 영구히 "진행 중" 으로 남아 다음 귀가에
    재사용되면 경과 시간이 몇 시간으로 잡혀 도착예정이 통째로 어긋난다.
    2026-08-19 에 실제로 그렇게 됐다(`이미 진행 중인 세션 2a7a3c973cef 재사용`).
    """

    def setUp(self):
        for table in ("sessions", "routes", "fixes", "activities"):
            hs.db().execute(f"DELETE FROM {table}")
        hs.db().commit()

    def open_session(self, session_id, age_hours):
        started = hs.now() - timedelta(hours=age_hours)
        hs.db().execute(
            """INSERT INTO sessions (id, traveler, traveler_name, home_lat, home_lon,
               home_radius, home_name, total_meters, remaining_meters, stage, transport,
               expected_arrival, detail, started_at, route_id, measured_at)
               VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
            (session_id, "acct", "아빠", HOME[0], HOME[1], 150, "집",
             20000, 20000, "moving", "bus", hs.iso(started), None,
             hs.iso(started), None, hs.iso(started)),
        )
        hs.db().commit()

    def test_재사용_문턱이_하루보다_짧다(self):
        """어제 세션이 오늘 재사용되면 안 된다."""
        self.assertLess(hs.SESSION_REUSE_MAX_HOURS, 24)

    def test_재사용_문턱이_한_퇴근보다_길다(self):
        """82분 퇴근 중에 앱이 다시 켜지면 같은 세션을 이어야 한다."""
        self.assertGreater(hs.SESSION_REUSE_MAX_HOURS * 3600, 82 * 60)

    def test_버려진_세션은_purge_가_닫는다(self):
        """예전에는 위치만 지우고 세션 행은 영구히 남았다."""
        self.open_session("old", hs.SESSION_RETENTION_HOURS + 1)
        hs.purge()
        row = hs.db().execute("SELECT ended_at, end_reason FROM sessions WHERE id='old'").fetchone()
        # 닫혔거나(표시), 닫힌 뒤 삭제됐다. 둘 다 "진행 중이 아니다" 를 뜻한다.
        self.assertTrue(row is None or row["ended_at"] is not None)

    def test_진행_중인_세션은_purge_가_건드리지_않는다(self):
        self.open_session("live", 0.5)
        hs.purge()
        row = hs.db().execute("SELECT ended_at FROM sessions WHERE id='live'").fetchone()
        self.assertIsNotNone(row)
        self.assertIsNone(row["ended_at"], "진행 중인 귀가를 닫으면 안 된다")

if __name__ == "__main__":
    unittest.main()
