"""가족 한 명에게 카드를 띄우는 길 시험.

    cd Server && python3 -m unittest test_start_activity -v

**이 시험이 지키는 것** — `start_activities` 는 세션 시작 때 딱 한 번 불린다. 그래서
귀가 중에 가족이 새로 붙으면 다음 귀가까지 아무것도 안 보였다. 2026-08-19 에 실제로
그렇게 헤맸다: SE2 에 초대 코드를 넣었는데 카드가 안 떴고, 로그의 계정 id 를 따라가서야
원인을 찾았다.

`start_activity_for` 가 그 한 명을 쏘는 길이다. 여기가 막히면 같은 일이 다시 난다.

APNs 는 설정하지 않는다. `apns_push` 는 미설정이면 보내지 않고 True 를 주므로,
**토큰이 있는지 없는지로 갈라지는 판단**을 그대로 시험할 수 있다.
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


def seed(watcher_has_token=True):
    """귀가자 하나, 가족 하나, 진행 중인 세션 하나."""
    for table in ("sessions", "links", "accounts", "activities", "fixes"):
        hs.db().execute(f"DELETE FROM {table}")
    started = datetime.now(timezone.utc) - timedelta(minutes=5)

    hs.db().execute("INSERT INTO accounts (id) VALUES (?)", ("traveler1",))
    hs.db().execute(
        "INSERT INTO accounts (id, start_token) VALUES (?, ?)",
        ("watcher1", "TOKEN" if watcher_has_token else None),
    )
    hs.db().execute(
        "INSERT INTO links (traveler, watcher, watcher_name, traveler_name) VALUES (?,?,?,?)",
        ("traveler1", "watcher1", "엄마", "아빠"),
    )
    hs.db().execute(
        """INSERT INTO sessions (id, traveler, traveler_name, home_lat, home_lon,
           home_radius, home_name, total_meters, remaining_meters, stage, transport,
           expected_arrival, detail, started_at, measured_at)
           VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
        ("sess1", "traveler1", "아빠", 37.68, 126.76, 150, "집",
         20000, 12000, "moving", "bus", hs.iso(hs.now() + timedelta(minutes=30)),
         "환승 대기", hs.iso(started), hs.iso(started)),
    )
    hs.db().commit()
    session = hs.db().execute("SELECT * FROM sessions WHERE id = 'sess1'").fetchone()
    link = hs.db().execute("SELECT * FROM links WHERE watcher = 'watcher1'").fetchone()
    return session, link


class StartActivityForOne(unittest.TestCase):

    def test_토큰이_있으면_쏜다(self):
        session, link = seed(watcher_has_token=True)
        self.assertTrue(hs.start_activity_for(session, link))

    def test_토큰이_없으면_건너뛴다(self):
        """푸시를 못 보낸 것과 보낸 것을 섞으면 로그가 거짓말을 한다."""
        session, link = seed(watcher_has_token=False)
        self.assertFalse(hs.start_activity_for(session, link))

    def test_보내는_상태가_content_state_와_같다(self):
        """가족이 받는 첫 화면이 갱신과 같은 값이어야 한다."""
        session, link = seed()
        state = hs.content_state(session)
        self.assertEqual(state["remainingMeters"], 12000)
        self.assertEqual(state["detail"], "환승 대기")
        self.assertIn("measuredAt", state)
        # 경로가 없으므로 노선도도 없다. 앱이 지금 카드로 폴백한다.
        self.assertIsNone(hs.route_shape_for(session))

    def test_여러_가족에게_한_번씩_간다(self):
        session, _ = seed()
        hs.db().execute("INSERT INTO accounts (id, start_token) VALUES (?, ?)",
                        ("watcher2", "TOKEN2"))
        hs.db().execute(
            "INSERT INTO links (traveler, watcher, watcher_name, traveler_name) VALUES (?,?,?,?)",
            ("traveler1", "watcher2", "이모", "아빠"),
        )
        hs.db().commit()
        self.assertEqual(len(hs.watchers_of("traveler1")), 2)
        hs.start_activities(session)   # 예외 없이 둘 다 돌면 된다

    def test_가족이_없으면_조용히_끝난다(self):
        session, _ = seed()
        hs.db().execute("DELETE FROM links")
        hs.db().commit()
        hs.start_activities(session)   # 죽지 않는다


if __name__ == "__main__":
    unittest.main()
