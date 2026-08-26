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


if __name__ == "__main__":
    unittest.main()
