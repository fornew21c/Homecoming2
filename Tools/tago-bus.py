#!/usr/bin/env python3
"""공공데이터포털 버스 API 를 두드린다.

    source Server/.env.local
    HOMECOMING_INSECURE_TLS=1 python3 Tools/tago-bus.py --city 11 --route 163
    HOMECOMING_INSECURE_TLS=1 python3 Tools/tago-bus.py --stops --city 11

`--stops` 는 정류장 API(`/1613000/BusStop`) 다. 아직 활용신청 전이면 코드 30 이
온다. 승인되면 이것으로 **좌표가 오는지**부터 확인한다 — 형제인 버스노선 API 에는
좌표가 없었고, 정류장 쪽 문서에도 좌표 얘기가 없다.

**이 파일이 있는 이유** — 이 API 를 붙이는 데 두 가지에서 막혔고, 둘 다 오류
메시지만으로는 알 수 없었다. 다시 헤매지 않도록 작동하는 호출을 코드로 남긴다.

  1. 서비스 경로가 `/1613000/BusRoute` 다.
     `/1613000/BusRouteInfoInqireService`(옛 TAGO 이름)를 부르면 403 코드 30
     `SERVICE_KEY_IS_NOT_REGISTERED_ERROR` 가 온다. **키 문제처럼 보이지만
     아니다.** 그 경로에 대한 권한이 없다는 뜻이고, 키는 멀쩡하다.

  2. `_type=json` / `type=json` 을 붙이면 51 `INVALID_PARAMETER` 다.
     이 API 는 JSON 이 기본이고 그 파라미터를 거부한다. 다른 공공데이터 API 는
     대부분 요구하는 값이라 습관적으로 붙이게 된다.

오류 코드 읽는 법

    12  경로가 없다 (서비스명·오퍼레이션명이 틀렸다)
    30  경로는 있는데 이 키에 권한이 없다
    51  파라미터 값이 틀렸다
    52  필수 파라미터가 없다  (`opr_ymd`, `ctpv_cd`)

**이 API 에는 좌표가 없다.** 노선 목록과 기점·종점 이름뿐이다. 정류소 좌표를
얻으려면 "버스정류장" 쪽 API 를 따로 활용신청해야 한다.
"""

import argparse
import json
import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

import sys as _sys, os as _os
_sys.path.insert(0, _os.path.dirname(_os.path.abspath(__file__)))
import hc_tls

ROUTE_ENDPOINT = "https://apis.data.go.kr/1613000/BusRoute/getBusRoute"
# 국토교통부_버스정류장 (data.go.kr/data/15142032). 버스노선과 같은 계열이라
# 호출 규칙도 같을 것으로 본다 — 확인은 승인 뒤에.
STOP_ENDPOINT = "https://apis.data.go.kr/1613000/BusStop/getBusStop"
# 구형 TAGO. **좌표는 여기에만 있다.** 대신 서울이 빠진다. docs/BUS-API.md
TAGO_STOP_ENDPOINT = "https://apis.data.go.kr/1613000/BusSttnInfoInqireService/getSttnNoList"

# 시도 코드. 이 앱의 퇴근 경로가 서울에서 경기로 넘어간다.
CITIES = {"11": "서울", "41": "경기", "29": "광주", "26": "부산", "27": "대구", "28": "인천"}


def context():
    """TLS 문맥. 맥 키체인의 루트까지 믿는다 — `Tools/hc_tls.py` 를 보라.

    검증을 끄지 않는다. 이 요청에는 서비스 키가 실려 나간다.
    """
    return hc_tls.context()


def fetch(key, city, opr_ymd, page, rows=1000, endpoint=None):
    query = urllib.parse.urlencode({
        "serviceKey": key,
        "opr_ymd": opr_ymd,
        "ctpv_cd": city,
        "numOfRows": rows,
        "pageNo": page,
    })
    url = f"{endpoint or ROUTE_ENDPOINT}?{query}"
    with urllib.request.urlopen(url, timeout=30, context=context()) as response:
        return json.loads(response.read().decode("utf-8"))


def routes(key, city, opr_ymd):
    """그 시도의 노선을 전부 훑는다. 노선번호로 찾으려면 이 방법뿐이다 —
    번호로 거르는 파라미터가 없다."""
    page = 1
    while True:
        body = fetch(key, city, opr_ymd, page)["Response"]["body"]
        items = body["items"]["item"]
        yield from items
        if page * 1000 >= int(body["totalCount"]):
            return
        page += 1


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--city", default="11", help=f"시도 코드 {CITIES}")
    parser.add_argument("--route", action="append", default=[],
                        help="찾을 노선번호. 여러 번 쓸 수 있다")
    parser.add_argument("--date", default="20250801", help="운영일자(필수 파라미터다)")
    parser.add_argument("--find", metavar="정류소명",
                        help="구형 TAGO 로 정류소를 찾는다. **좌표가 나오는 유일한 길**이다. "
                             "--city 는 TAGO 도시코드다(고양시 31100). 서울은 없다")
    parser.add_argument("--stops", action="store_true",
                        help="정류장 API 를 부른다. 응답 필드를 그대로 찍는다 — "
                             "좌표가 오는지 확인하는 것이 목적이다")
    args = parser.parse_args()

    key = os.environ.get("HOMECOMING_TAGO_KEY")
    if not key:
        raise SystemExit("HOMECOMING_TAGO_KEY 가 없다. `source Server/.env.local`")

    if args.find:
        query = urllib.parse.urlencode({
            "serviceKey": key, "cityCode": args.city, "nodeNm": args.find,
            "numOfRows": 10, "pageNo": 1, "_type": "json",
        })
        with urllib.request.urlopen(f"{TAGO_STOP_ENDPOINT}?{query}",
                                    timeout=30, context=context()) as response:
            payload = json.loads(response.read().decode("utf-8"))
        items = payload["response"]["body"]["items"]
        rows = items["item"] if items else []
        rows = rows if isinstance(rows, list) else [rows]
        if not rows:
            print(f"  '{args.find}' 없음. 도시코드({args.city})가 맞는지 봐라 — "
                  "TAGO 는 서울을 다루지 않는다.")
            return
        for row in rows:
            print(f"  {row['nodenm']:26} {row['gpslati']}, {row['gpslong']}  no={row['nodeno']}")
        return

    if args.stops:
        try:
            body = fetch(key, args.city, args.date, 1, rows=3,
                         endpoint=STOP_ENDPOINT)["Response"]["body"]
        except urllib.error.HTTPError as error:
            text = error.read().decode("utf-8", "replace")
            if "SERVICE_KEY_IS_NOT_REGISTERED" in text:
                raise SystemExit("아직 활용신청 전이다 (코드 30).\n"
                                 "  https://data.go.kr/data/15142032/openapi.do")
            raise SystemExit(f"HTTP {error.code}\n{text[:300]}")
        items = body["items"]["item"]
        print(f"  전체 {body['totalCount']}건")
        print(f"  필드: {list(items[0].keys())}")
        has_coord = [k for k in items[0] if any(t in k.lower() for t in ("lat", "lon", "gps", "crd", "y_", "x_"))]
        print(f"  좌표로 보이는 필드: {has_coord or '없다 — 구형 BusSttnInfoInqireService 를 신청해야 한다'}")
        for it in items[:3]:
            print("   ", it)
        return

    wanted = set(args.route)
    found = 0
    try:
        for item in routes(key, args.city, args.date):
            if wanted and item["rte_no"] not in wanted:
                continue
            found += 1
            print(f"  {item['rte_no']:14} rte_id={item['rte_id']:10} "
                  f"{item.get('dptre_sttn_nm') or '-'} → {item.get('arvl_sttn_nm') or '-'}")
            if not wanted and found >= 20:
                print("  … (노선번호를 주면 그것만 찾는다)")
                return
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", "replace")[:300]
        print(f"HTTP {error.code}\n{body}", file=sys.stderr)
        raise SystemExit(1)
    except urllib.error.URLError as error:
        if "CERTIFICATE_VERIFY_FAILED" in str(error.reason):
            raise SystemExit(
                "TLS 검증 실패. 회사 네트워크의 검사 프록시일 가능성이 높다.\n"
                "  HOMECOMING_INSECURE_TLS=1 python3 Tools/tago-bus.py ...")
        raise

    if wanted and not found:
        print(f"  {CITIES.get(args.city, args.city)} 에 그 노선이 없다. 다른 시도를 봐라.")


if __name__ == "__main__":
    main()
