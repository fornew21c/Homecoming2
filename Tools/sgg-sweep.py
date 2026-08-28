#!/usr/bin/env python3
"""버스 시군구 코드를 자료에서 확인한다. 하루 예산만큼만 하고 이어서 한다.

    python3 Tools/sgg-sweep.py            # 예산 안에서 남은 것을 훑는다
    python3 Tools/sgg-sweep.py --budget 200

**2026-08-27 — 훑을 것이 남아 있지 않다.** 경기 41000~41999 를 다 훑어 35개를
얻었고(08-25), 서울 11000~11999 는 1,000개를 다 물어 **0개**였다(08-27). 지금
이 도구를 돌리면 요청을 0회 쓰고 끝난다. 새 시도를 더할 때만 다시 쓴다.

**그리고 경기는 이제 이 코드가 필요 없다.** GBIS 의 `getBusRouteStationListv2` 가
`routeId` 하나로 경유정류소를 준다. 아래는 그 전에 왜 이 훑기가 필요했는지의 기록이다.

**왜 필요했나.** 경유정류장 API 는 `sgg_cd`(시군구)를 요구하는데 그 값을 **그 계열
안에서는** 좌표나 노선번호에서 얻지 못했다(`docs/BUS-API.md`). 그래서 자료에 없는
지역의 버스 구간은 실제 노선을 못 찾아 자동차 경로로 그려졌다.

**확인이 짐작이 아닌 이유.** `getBusStop` 응답에 `sgg_nm` 이 온다 — 코드를 넣어
보면 자료가 그게 어느 시군구인지 말해 준다. 되는 코드만 모으면 표가 된다.

**하루 요청 한도가 1,000회다.** 2026-08-21 에 동시 4개로 1,000개를 훑다가 하루치를
다 써서 그날 서버의 버스 노선 조회까지 종일 막혔다. 그래서 이 도구는 —

  · 하루 예산(기본 700)만큼만 부르고 멈춘다. 나머지 300 은 서버 몫이다
    (기동 때 노선표 받기, 경로 만들 때 `/bus/leg`)
  · 429 를 만나면 그날은 즉시 접는다. 재시도로 예산을 태우지 않는다
  · **동시 1개.** 4개로도 429 가 섞여 되는 코드가 조용히 결과에서 빠졌다
  · 훑은 코드를 파일에 남겨 다음 날 이어서 한다. 다 끝났으면 아무것도 안 한다

멱등하다. 여러 번 돌려도 남은 것만 줄어든다 — `launchd` 로 매일 걸어 두면 맥이
깨어 있는 아무 날에 저절로 끝난다.
"""

import argparse
import json
import os
import pathlib
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "Tools"))
import hc_tls   # noqa: E402

URL = "https://apis.data.go.kr/1613000/BusStop/getBusStop"

# 훑을 시도와 결과 파일. 경기가 먼저다 — 지금 쓰는 경로가 다 경기다.
REGIONS = [
    ("41", ROOT / "Server" / "data" / "gyeonggi-sgg.json", "경기"),
    ("11", ROOT / "Server" / "data" / "seoul-sgg.json", "서울"),
]

# 운영일자. 최근 날짜는 자료가 없다(`bus_opr_ymd` 와 같은 값을 쓴다).
OPR_YMD = "20260601"


def load_key():
    """공공데이터 키. `Server/.env.local` 에 있고 저장소에는 없다."""
    key = os.environ.get("HOMECOMING_TAGO_KEY")
    if key:
        return key
    env = ROOT / "Server" / ".env.local"
    if env.exists():
        for line in env.read_text(encoding="utf-8").splitlines():
            line = line.strip().removeprefix("export ").strip()
            if line.startswith("HOMECOMING_TAGO_KEY="):
                return line.split("=", 1)[1].strip().strip("'\"")
    return None


def load(path, ctpv):
    if path.exists():
        saved = json.loads(path.read_text(encoding="utf-8"))
        codes = saved.get("코드", {})
        probed = set(saved.get("훑은코드", []))
        # 옛 파일에는 훑은 코드 목록이 없고 범위만 문자열로 있었다. 그 범위를 살린다.
        if not probed and "41000~41550" in (saved.get("훑은범위") or ""):
            probed = {f"41{n:03d}" for n in range(551)}
        return codes, probed | set(codes)
    return {}, set()


def save(path, ctpv, codes, probed):
    path.write_text(json.dumps({
        "확인일": time.strftime("%Y-%m-%d"),
        "방법": "getBusStop 에 sgg_cd 를 넣고 응답의 sgg_nm 을 읽는다. docs/BUS-API.md 참고",
        "시도": ctpv,
        "훑은코드수": len(probed),
        "코드": dict(sorted(codes.items())),
        "훑은코드": sorted(probed),
    }, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")


def ask(key, ctpv, code):
    """한 코드를 물어본다. 돌려주는 것 — ("있음", 이름) / ("없음", None) / ("한도", None)."""
    query = urllib.parse.urlencode({
        "serviceKey": key, "_type": "json", "opr_ymd": OPR_YMD, "ctpv_cd": ctpv,
        "sgg_cd": code, "numOfRows": 1, "pageNo": 1})
    try:
        with urllib.request.urlopen(f"{URL}?{query}", timeout=20,
                                    context=hc_tls.context()) as response:
            body = json.loads(response.read())
    except urllib.error.HTTPError as error:
        if error.code == 429:
            return "한도", None
        return "실패", None
    except Exception:                                               # noqa: BLE001
        return "실패", None

    items = (body.get("response", {}).get("body", {}) or {}).get("items") or {}
    rows = items.get("item") if isinstance(items, dict) else items
    if isinstance(rows, dict):
        rows = [rows]
    if not rows:
        return "없음", None
    return "있음", rows[0].get("sgg_nm")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--budget", type=int, default=700,
                        help="이번 실행에서 쓸 요청 수. 하루 한도가 1,000회다")
    parser.add_argument("--pace", type=float, default=1.1, help="요청 사이 초")
    args = parser.parse_args()

    key = load_key()
    if not key:
        print("HOMECOMING_TAGO_KEY 가 없다 — Server/.env.local 을 본다")
        return 1

    spent = 0
    for ctpv, path, label in REGIONS:
        codes, probed = load(path, ctpv)
        todo = [f"{ctpv}{n:03d}" for n in range(1000) if f"{ctpv}{n:03d}" not in probed]
        if not todo:
            print(f"[{label}] 다 끝났다 — 확인 {len(codes)}개")
            continue
        print(f"[{label}] 남은 {len(todo)}개 · 확인 {len(codes)}개 · 예산 {args.budget - spent}")

        for code in todo:
            if spent >= args.budget:
                print(f"[{label}] 예산 다 씀 — 다음 실행에서 이어서 한다")
                save(path, ctpv, codes, probed)
                return 0
            state, name = ask(key, ctpv, code)
            spent += 1
            if state == "한도":
                print(f"[{label}] 일일 한도 초과 — 오늘은 접는다 (쓴 요청 {spent})")
                save(path, ctpv, codes, probed)
                return 0
            probed.add(code)
            if state == "있음":
                codes[code] = name
                print(f"  + {code} {name}")
                save(path, ctpv, codes, probed)
            time.sleep(args.pace)

        save(path, ctpv, codes, probed)
        print(f"[{label}] 끝 — 확인 {len(codes)}개")

    print(f"쓴 요청 {spent}회")
    return 0


if __name__ == "__main__":
    sys.exit(main())
