"""subway_leg_stops() 시험 — 두 역 사이의 역들을 순서대로 고른다.

    cd Server && python3 -m unittest test_subway_leg -v

**역번호는 노선 전체가 아니라 블록 안에서만 순서다.** 경의중앙선은 지선(서울역·
신촌)과 옛 코드 블록 때문에 전체를 한 줄로 세우면 되돌아간다. 그래서 구간을 고른 뒤
**되돌아가는지 검사한다** — 경로 길이가 두 끝 직선거리의 몇 배인지 본다.

구워 둔 `Server/data/subway-lines.json` 을 그대로 쓴다. 가짜 자료를 만들지 않는 이유는
이 시험이 확인하려는 것이 **실제 자료에서 그 구간이 제대로 나오는가** 이기 때문이다.

의존성 없음. 표준 unittest 다.
"""

import tempfile
import os
import pathlib
import sys
import unittest

# **시험은 진짜 DB 에 안 붙는다.** `DB_PATH` 는 import 할 때 정해지고, 여기서
# 안 걸면 먼저 import 되는 쪽이 이겨 저장소의 DB 를 쓴다 — 다른 시험의
# `DELETE FROM` 이 실제 경로를 지운다(2026-08-27 에 실제로 그랬다).
_TMP = tempfile.mkdtemp()
os.environ.setdefault("HOMECOMING_DB", str(pathlib.Path(_TMP) / "test.sqlite"))

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import homecoming_server as hs   # noqa: E402


class SubwayLegTests(unittest.TestCase):

    def test_같은_블록이면_사이_역을_순서대로_준다(self):
        line, stops = hs.subway_leg_stops("서강대역", "풍산역")
        self.assertEqual(line, "경의중앙선")
        names = [s["name"] for s in stops]
        self.assertEqual(names[0], "서강대역")
        self.assertEqual(names[-1], "풍산역")
        self.assertIn("행신역", names)
        self.assertIn("디지털미디어시티역", names)
        self.assertEqual(len(names), 12)

    def test_순서가_뒤집혀_있어도_방향을_맞춘다(self):
        _, stops = hs.subway_leg_stops("풍산역", "서강대역")
        names = [s["name"] for s in stops]
        self.assertEqual(names[0], "풍산역")
        self.assertEqual(names[-1], "서강대역")

    def test_이름_끝의_역은_있어도_없어도_찾는다(self):
        """앱의 경로에는 `풍산역` 으로, 다른 데서는 `풍산` 으로 적힐 수 있다."""
        line, stops = hs.subway_leg_stops("서강대", "풍산")
        self.assertEqual(line, "경의중앙선")
        self.assertEqual(len(stops), 12)

    def test_경로에_적힌_이름이_더_길어도_찾는다(self):
        """경로의 그 구간 이름은 `서강대학교` 인데 자료의 역사명은 `서강대역` 이다.
        2026-08-26 에 이것 때문에 지하철 구간이 조용히 직선으로 저장됐다."""
        line, stops = hs.subway_leg_stops("서강대학교", "풍산역")
        self.assertEqual(line, "경의중앙선")
        self.assertEqual(stops[0]["name"], "서강대역")
        self.assertEqual(len(stops), 12)

    def test_좌표가_함께_온다(self):
        _, stops = hs.subway_leg_stops("서강대역", "풍산역")
        for stop in stops:
            self.assertGreater(stop["lat"], 33)
            self.assertGreater(stop["lon"], 124)

    def test_없는_역이면_빈_결과다(self):
        line, stops = hs.subway_leg_stops("없는역", "풍산역")
        self.assertIsNone(line)
        self.assertEqual(stops, [])

    def test_블록을_넘으면_빈_결과다(self):
        """지평(1220)과 신촌(1252)은 노선번호가 같지만 이어지지 않는다 —
        그 사이를 역번호로 고르면 58km 를 건너뛴다."""
        line, stops = hs.subway_leg_stops("지평역", "신촌역")
        self.assertIsNone(line)
        self.assertEqual(stops, [])


if __name__ == "__main__":
    unittest.main()
