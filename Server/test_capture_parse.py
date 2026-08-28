"""길찾기 앱 캡처의 OCR 줄을 구간으로 푼다.

    python3 -m unittest discover -s Server

**네트워크를 안 탄다.** 정류장 조회를 갈아 끼우고 문법과 배분만 본다.
조회까지 보는 시험은 `LookupTests` 하나뿐이고 그것도 표를 갈아 끼운다.

본보기는 `fixtures/capture-{1,2,3}.txt` — **실기기 캡처의 OCR 출력 그대로**다.
주소 세 줄만 가렸다(이 저장소는 공개다). 정류장 이름과 기둥번호는 이미 인계
문서에 적혀 있어 새로 드러나는 것이 없다.

의존성 없음. 표준 unittest 다.
"""

import os
import pathlib
import sys
import tempfile
import unittest
from unittest import mock

_TMP = tempfile.mkdtemp()
os.environ.setdefault("HOMECOMING_DB", str(pathlib.Path(_TMP) / "test.sqlite"))

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import homecoming_server as hs   # noqa: E402

FIXTURES = pathlib.Path(__file__).resolve().parent / "fixtures"


def page(n):
    """본보기 한 장의 OCR 줄."""
    return (FIXTURES / f"capture-{n}.txt").read_text(encoding="utf-8").splitlines()


def pages():
    return [page(1), page(2), page(3)]


# 실측 좌표. `seoul-stops.json` 과 GBIS 에서 가져온 값이다(2026-08-28).
STOPS = {
    ("국회의사당역.KB국민은행", "19132"): (37.528479, 126.918068),
    ("신촌로터리", "14205"): (37.554051, 126.935683),
    ("풍산역", "20753"): (37.67315, 126.7872167),
    ("위시티1.3단지", "20796"): (37.6822, 126.8108),
}


def fake_lookup(name, ars):
    """`stop_by_ars` 를 대신한다. 못 찾으면 None."""
    found = STOPS.get((name, ars))
    if not found:
        return None
    return {"name": name, "ars": ars, "lat": found[0], "lon": found[1]}


class GrammarTests(unittest.TestCase):
    """한 장에서 줄을 뽑는 규칙.

    **구분자를 믿지 않는다.** 같은 자리가 장마다 `•` · `.` · `·` 로 흔들렸다 —
    장1 은 `도보 328m • 7분`, 장2 는 `도보 328m. 7분` 이다(실측).
    """

    def test_승차_줄과_기둥번호(self):
        rows = hs.capture_rows(["국회의사당역.KB국민은행 승차", "19132"])
        self.assertEqual(rows, [{"kind": "board", "name": "국회의사당역.KB국민은행",
                                 "ars": "19132"}])

    def test_하차_줄과_기둥번호(self):
        rows = hs.capture_rows(["신촌로터리 하차", "14205"])
        self.assertEqual(rows, [{"kind": "alight", "name": "신촌로터리",
                                 "ars": "14205"}])

    def test_지하철_승차는_노선을_떼어_적는다(self):
        rows = hs.capture_rows(["경의중앙선 서강대역 승차"])
        self.assertEqual(rows, [{"kind": "board", "name": "서강대역",
                                 "ars": None, "line": "경의중앙선"}])

    def test_노선번호에_붙은_꺾쇠를_뗀다(self):
        rows = hs.capture_rows(["국회의사당역.KB국민은행 승차", "19132", "163>"])
        self.assertEqual(rows[-1], {"kind": "route", "no": "163"})

    def test_구분자가_흔들려도_같은_값(self):
        for line in ["도보 328m • 7분", "도보 328m. 7분", "도보 328m · 7분",
                     "도보 328m,7분"]:
            with self.subTest(line=line):
                self.assertEqual(hs.capture_rows([line]),
                                 [{"kind": "walk", "minutes": 7}])

    def test_정류장_이동과_역_이동을_가른다(self):
        self.assertEqual(hs.capture_rows(["4개 정류장 이동 · 9분"]),
                         [{"kind": "ride", "mode": "bus", "minutes": 9}])
        self.assertEqual(hs.capture_rows(["12개 역 이동 · 31분"]),
                         [{"kind": "ride", "mode": "subway", "minutes": 31}])

    def test_머리글에서_총_시간(self):
        self.assertEqual(hs.capture_rows(["14:35 - 15:52 | 2,050원"]),
                         [{"kind": "total", "minutes": 77}])

    def test_바닥글에서도_총_시간(self):
        self.assertEqual(hs.capture_rows(["1시간 17분"]),
                         [{"kind": "total", "minutes": 77}])

    def test_화면_잡동사니는_버린다(self):
        """지도 라벨·상태바·버튼은 문법에 안 맞는다. 앱이 안 걸러도 안전해야 한다."""
        junk = ["국립아세안", "자연휴양림", "LTE", "80", "(IC) 금촌조리읍",
                "미리보기", "_ 안내시작", "고정한 경로", "지하철 노선도 미리보기",
                "버스 도착정보 더보기 >", "홍대입구역 방면", "내리는 문: 왼쪽",
                "서울 ○○구 ○○대로 00-0", "도로의 오른쪽에 있습니다."]
        self.assertEqual(hs.capture_rows(junk), [])

    def test_다른_경로_후보의_총_시간을_안_줍는다(self):
        """**화면에 다른 경로의 시간이 같이 떠 있다.** 실측 —

            고정 | 1시간 17분     ← 지금 보는 경로
            최적 | 1시간 14분     ← 다른 후보. 이걸 주우면 3분이 틀린다

        `<H>시간 <M>분` 이 줄 전체인 것만 받는다(바닥글). 앞에 딴 글자가 붙으면
        버린다.
        """
        self.assertEqual(hs.capture_rows(["고정 | 1시간 17분",
                                          "최적 | 1시간 14분"]), [])

    def test_요약_막대의_뭉갠_줄도_버린다(self):
        """위쪽 요약 막대는 `ㅊ 2분(표 9분 7분` 로 뭉갠다(실측 conf 0.30).

        **여기서 분을 주우면 안 된다.** 아래 상세 줄과 이중으로 세어진다.
        """
        self.assertEqual(hs.capture_rows(["ㅊ 2분(표 9분 7분"]), [])


class OverlapTests(unittest.TestCase):
    """겹침은 줄이 아니라 구간으로 접는다.

    줄로 접으면 안 되는 것을 실제 캡처가 보여줬다 — 같은 자리를 장1 은
    `서강대역 2 번 출구까지` 한 줄로, 장2 는 `서강대역` + `번 출구까지`
    두 줄로 쪼갰다.
    """

    def test_겹치는_구간을_한_번만_센다(self):
        got = hs.capture_parse(pages(), lookup=fake_lookup)
        names = [s["toName"] for s in got["steps"]]
        self.assertEqual(names.count("신촌로터리"), 1)
        self.assertEqual(names.count("풍산역"), 1)

    def test_안_이어지면_지우지_않고_적는다(self):
        got = hs.capture_parse([page(1), page(3)], lookup=fake_lookup)
        self.assertTrue(any("안 이어" in n for n in got["notes"]),
                        got["notes"])


class StepTests(unittest.TestCase):
    """세 장이 열 구간으로 풀린다. 2026-08-28 실기기 캡처."""

    def setUp(self):
        self.got = hs.capture_parse(pages(), lookup=fake_lookup)

    def test_열_구간(self):
        self.assertEqual(len(self.got["steps"]), 10)

    def test_구간의_모양과_시간(self):
        want = [
            ("walk", "국회의사당역.KB국민은행", 2),
            ("wait", "163번 대기", 3),
            ("bus", "신촌로터리", 9),
            ("walk", "서강대역", 7),
            ("wait", "경의중앙선 대기", 3),
            ("subway", "풍산역", 31),
            ("walk", "풍산역 정류장", 6),
            ("wait", "999번 대기", 3),
            ("bus", "위시티1.3단지", 10),
            ("walk", "", 3),
        ]
        got = [(s["mode"], s["toName"], s["minutes"]) for s in self.got["steps"]]
        self.assertEqual(got, want)

    def test_노선번호가_버스_구간에_붙는다(self):
        buses = [s for s in self.got["steps"] if s["mode"] == "bus"]
        self.assertEqual([s["busNos"] for s in buses], [["163"], ["999"]])

    def test_마지막_구간의_도착은_비운다(self):
        """집이다. 편집기의 `resolvedSteps` 가 채운다 — 여기서 짐작하지 않는다."""
        self.assertEqual(self.got["steps"][-1]["toName"], "")

    def test_기둥번호가_좌표로_바뀐다(self):
        by_name = {s["toName"]: s for s in self.got["steps"]}
        self.assertAlmostEqual(by_name["신촌로터리"]["lat"], 37.554051, places=5)
        self.assertAlmostEqual(by_name["신촌로터리"]["lon"], 126.935683, places=5)
        self.assertAlmostEqual(by_name["위시티1.3단지"]["lat"], 37.6822, places=4)


class WaitTests(unittest.TestCase):
    """대기는 총량만 캡처에서 나온다. 어디에 얼마씩인지는 안 나온다."""

    def test_남는_분을_승차_수로_나눈다(self):
        got = hs.capture_parse(pages(), lookup=fake_lookup)
        waits = [s["minutes"] for s in got["steps"] if s["mode"] == "wait"]
        self.assertEqual(waits, [3, 3, 3])

    def test_총합이_머리글과_맞는다(self):
        got = hs.capture_parse(pages(), lookup=fake_lookup)
        self.assertEqual(sum(s["minutes"] for s in got["steps"]), 77)

    def test_나머지는_앞쪽부터_한_분씩(self):
        """남는 11분을 승차 두 곳에 — 6·5 다. 합이 총 시간과 맞아야 한다."""
        rows = [{"kind": "total", "minutes": 21},
                {"kind": "board", "name": "가", "ars": None},
                {"kind": "ride", "mode": "bus", "minutes": 5},
                {"kind": "alight", "name": "나", "ars": None},
                {"kind": "board", "name": "다", "ars": None},
                {"kind": "ride", "mode": "bus", "minutes": 5},
                {"kind": "alight", "name": "라", "ars": None}]
        got = hs.capture_steps(rows, lookup=fake_lookup)
        waits = [s["minutes"] for s in got["steps"] if s["mode"] == "wait"]
        self.assertEqual(waits, [6, 5])
        self.assertEqual(sum(s["minutes"] for s in got["steps"]), 21)

    def test_남는_분이_음수면_0_으로_두고_적는다(self):
        """캡처가 어긋난 것이지 우리가 지어낼 값이 아니다."""
        rows = [{"kind": "total", "minutes": 3},
                {"kind": "board", "name": "가", "ars": None},
                {"kind": "ride", "mode": "bus", "minutes": 30},
                {"kind": "alight", "name": "나", "ars": None}]
        got = hs.capture_steps(rows, lookup=fake_lookup)
        waits = [s["minutes"] for s in got["steps"] if s["mode"] == "wait"]
        self.assertEqual(waits, [0])
        self.assertTrue(got["notes"], "어긋난 것을 적어야 한다")

    def test_총_시간이_없으면_대기를_안_만든다(self):
        """짐작해서 넣지 않는다."""
        rows = [{"kind": "board", "name": "가", "ars": None},
                {"kind": "ride", "mode": "bus", "minutes": 5},
                {"kind": "alight", "name": "나", "ars": None}]
        got = hs.capture_steps(rows, lookup=fake_lookup)
        self.assertEqual([s["mode"] for s in got["steps"]], ["bus"])


class LookupTests(unittest.TestCase):
    """못 짚으면 좌표를 비운다. **채워 넣지 않는다.**

    틀린 좌표가 박히면 서버가 그 자리를 지나갔는지로 구간을 판정하니 조용히
    어긋난다. 2026-08-20 에 근처 GS25 가 가족 잠금화면에 떴던 것이 그 값이다.
    """

    def test_기둥번호가_없으면_이름으로_좁히고_하나면_쓴다(self):
        rows = [{"kind": "board", "name": "가", "ars": None},
                {"kind": "ride", "mode": "bus", "minutes": 5},
                {"kind": "alight", "name": "하나뿐인곳", "ars": None}]
        only = lambda name, ars: ({"name": name, "ars": None,
                                   "lat": 1.0, "lon": 2.0}
                                  if name == "하나뿐인곳" else None)
        got = hs.capture_steps(rows, lookup=only)
        self.assertEqual(got["steps"][-1]["lat"], 1.0)

    def test_못_짚으면_좌표를_비우고_적는다(self):
        rows = [{"kind": "board", "name": "가", "ars": None},
                {"kind": "ride", "mode": "bus", "minutes": 5},
                {"kind": "alight", "name": "모르는곳", "ars": "99999"}]
        got = hs.capture_steps(rows, lookup=lambda name, ars: None)
        self.assertIsNone(got["steps"][-1]["lat"])
        self.assertTrue(any("모르는곳" in n for n in got["notes"]), got["notes"])

    def test_서울_기둥번호는_구운_표에서_바로_나온다(self):
        """망을 안 탄다. `stop_by_ars` 의 서울 쪽을 실제로 부른다."""
        got = hs.stop_by_ars("신촌로터리", "14205")
        self.assertAlmostEqual(got["lat"], 37.554051, places=5)

    def test_서울에_같은_이름이_넷이어도_번호가_하나를_짚는다(self):
        """실측 — `신촌로터리` 는 14168·14169·14204·14205 넷이다."""
        pairs = {a: hs.stop_by_ars("신촌로터리", a)["lat"]
                 for a in ["14168", "14169", "14204", "14205"]}
        self.assertEqual(len(set(pairs.values())), 4)

    def test_번호가_이름과_안_맞으면_안_쓴다(self):
        """**OCR 이 번호 한 자를 잘못 읽으면 엉뚱한 정류장이 나온다.**

        `19132`(국회의사당역.KB국민은행) 를 `14205`(신촌로터리) 로 잘못 읽으면
        번호만 믿을 때 3km 떨어진 자리가 조용히 박힌다. 이름이 안 맞으면 버린다.
        """
        self.assertIsNone(hs.stop_by_ars("국회의사당역.KB국민은행", "14205"))

    def test_지하철역은_번호가_없어도_좌표가_나온다(self):
        """`subway-lines.json` 에 역 좌표가 구워져 있다. 캡처에 번호가 없는
        자리가 바로 지하철역이다(`풍산역 하차` 에는 번호가 안 붙는다)."""
        got = hs.stop_by_ars("서강대역", None)
        self.assertIsNotNone(got)
        self.assertTrue(37.5 < got["lat"] < 37.6, got)


class NoKeyTests(unittest.TestCase):
    """키가 없으면 **나가지 않는다.**

    시험 환경에 `TAGO_KEY` 가 없다. 그대로 부르면 GBIS 가 403 을 주는데, 나가
    봐야 반드시 실패하는 호출이다 — 시험이 망을 타고 0.5초를 버렸다.
    """

    def test_키가_없으면_GBIS_를_안_부른다(self):
        with mock.patch.object(hs, "TAGO_KEY", ""), \
             mock.patch.object(hs.urllib.request, "urlopen") as opened:
            self.assertIsNone(hs.gbis_get("busrouteservice/v2/getBusRouteListv2",
                                          {"keyword": "999"}))
        opened.assert_not_called()


class EndpointTests(unittest.TestCase):
    """`POST /capture/parse` 의 와이어 모양.

    **이미지는 안 받는다.** 줄만 받는다 — 앱이 온디바이스로 OCR 한 결과다.
    """

    class Caller:
        """`reply` 만 갈아 끼운 최소 껍데기. 소켓을 안 연다."""

        def __init__(self):
            self.status = None
            self.payload = None

        def reply(self, status, payload):
            self.status = status
            self.payload = payload

        def post(self, body):
            hs.Handler.handle_capture_parse(self, body)
            return self.status, self.payload

    def test_줄을_올리면_구간이_온다(self):
        status, got = self.Caller().post({"pages": [page(1), page(2), page(3)]})
        self.assertEqual(status, 200)
        self.assertEqual(len(got["steps"]), 10)
        self.assertIn("notes", got)

    def test_pages_가_없으면_400(self):
        status, got = self.Caller().post({})
        self.assertEqual(status, 400)
        self.assertIn("pages", got["error"])

    def test_빈_장만_오면_400(self):
        status, _ = self.Caller().post({"pages": [[], []]})
        self.assertEqual(status, 400)

    def test_줄이_아닌_것은_버린다(self):
        """앱이 잘못 보내도 500 이 나지 않아야 한다."""
        status, got = self.Caller().post(
            {"pages": [["도보 82m • 2분", 5, None, {"a": 1}]]})
        self.assertEqual(status, 200)
        self.assertEqual(len(got["steps"]), 1)


if __name__ == "__main__":
    unittest.main()
