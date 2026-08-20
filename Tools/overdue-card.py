#!/usr/bin/env python3
"""도착예정이 지난 카드를 실기기에 만든다.

    python3 Tools/overdue-card.py --backend https://…up.railway.app

**왜 이 도구가 필요한가** — 압축 재생(`route-play.py`)은 저장된 경로대로 정확히
흘러서 지연이 0이고 도착예정도 안 지난다. 그래서 화면 결함 셋이 그 길로는 안 나온다.

  - 지난 도착시각을 남은 시간처럼 그리는가   (`CountdownText`)
  - 축소 아일랜드가 늦었을 때 무엇을 그리는가 (`remainingClockText`)
  - 부제에 `N분 지연` 이 붙는가              (`detailWithDelay`)

**서버는 지난 도착시각을 절대 보내지 않는다** (`arrival = now() + max(30, ...)`).
그러니 이 상태는 "갱신이 끊긴 동안 시계가 도착예정을 지나갔다" 로만 만들 수 있다 —
2026-08-18 실주행에서 벌어진 그 조건이다. 이 도구가 그걸 몇 분 안에 재현한다.

경로를 붙이지 않는다. 집에서 250m 떨어뜨리면 폴백 추정이 도보 속도로 3~4분을 내므로
기다리는 시간이 짧다.

**판정** — 도착예정이 지난 뒤 카드의 큰 숫자를 본다.
    0:00 에서 멈춰 있다  → 맞다
    계속 자란다          → `Text(_, style: .relative)` 로 되돌아간 것이다

## 밟기 쉬운 함정 — 순서

액티비티 갱신 토큰은 **카드가 뜬 뒤에** 올라온다. 시작 푸시 직후에 위치를 보내면 그
갱신을 받을 카드가 아직 없어서 버려지고, 카드는 시작 기본값(`0m 남음`, `지하철`)에
얼어붙는다. 실제로 한 번 밟았고(2026-08-19), 스크린샷을 보고서야 알았다.

그래서 이 도구는 **토큰 등록을 기다린 뒤에** 위치를 보낸다.

가족 기기의 계정은 `e2e-device.sh` 가 `~/.homecoming-e2e/<udid>` 에 캐시해 둔 것을
쓴다. 그 파일이 없으면 `e2e-device.sh` 를 한 번 돌려라 — 기기에서 push-to-start
토큰이 올라가야 카드를 띄울 수 있다.

의존성 없음. 서버와 같은 방침이다.
"""

import argparse
import json
import os
import sys
import time
import urllib.request
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hc_tls

KST = timezone(timedelta(hours=9))
KEY_DIR = os.path.expanduser("~/.homecoming-e2e")


def call(backend, method, path, token, body=None):
    data = json.dumps(body or {}).encode() if method != "GET" else None
    request = urllib.request.Request(backend.rstrip("/") + path, data=data, method=method)
    request.add_header("Content-Type", "application/json")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(request, timeout=15, context=hc_tls.context()) as response:
        raw = response.read()
    return json.loads(raw) if raw else {}


def iso(moment):
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--backend", default="http://127.0.0.1:8787")
    parser.add_argument("--home", default="37.6800,126.7600",
                        help="집 좌표. 기본값은 시험용 좌표다")
    parser.add_argument("--away", type=int, default=250,
                        help="집에서 떨어뜨릴 거리(m). 도착 반경보다 커야 한다")
    parser.add_argument("--end", metavar="세션",
                        help="이 세션을 닫고 끝낸다. 시험 뒤 정리에 쓴다")
    parser.add_argument("--token", help="귀가자 토큰. --end 와 함께 쓴다")
    args = parser.parse_args()

    if args.end:
        if not args.token:
            print("--end 에는 --token 이 필요하다", file=sys.stderr)
            return 2
        call(args.backend, "POST", f"/session/{args.end}/end", args.token, {"reason": "stopped"})
        print(f"세션 {args.end} 닫았다. 카드는 5분 뒤 사라진다")
        return 0

    if not os.path.isdir(KEY_DIR) or not os.listdir(KEY_DIR):
        print(f"가족 기기 계정이 없다: {KEY_DIR}\n"
              f"  `Tools/e2e-device.sh` 를 한 번 돌려라 — 기기에서 push-to-start "
              f"토큰이 올라가야 카드를 띄울 수 있다.", file=sys.stderr)
        return 1

    watchers = []
    for name in sorted(os.listdir(KEY_DIR)):
        with open(os.path.join(KEY_DIR, name), encoding="utf-8") as handle:
            watchers.append(handle.read().split()[1])
    print(f"가족 기기 {len(watchers)}대")

    token = call(args.backend, "POST", "/device/register", None)["token"]
    code = call(args.backend, "POST", "/pair/invite", token, {"travelerName": "아빠"})["code"]
    names = ["엄마", "이모", "삼촌", "할머니"]
    for index, watcher in enumerate(watchers):
        call(args.backend, "POST", "/pair/accept", watcher,
             {"code": code, "name": names[index % len(names)]})
    print(f"페어링 {code}")

    lat, lon = (float(part) for part in args.home.split(","))
    session = call(args.backend, "POST", "/session/start", token, {
        "travelerName": "아빠",
        "home": {"lat": lat, "lon": lon, "name": "집", "arrivalRadius": 120},
    })["sessionId"]
    print(f"세션 {session} 시작 — 기기에 카드가 뜬다")

    # **여기서 기다린다.** 이유는 파일 맨 위 "밟기 쉬운 함정" 에 있다.
    print("  액티비티 토큰 등록 대기…", end="", flush=True)
    live = 0
    for _ in range(24):
        live = call(args.backend, "GET", f"/session/{session}", token)["activities"]
        if live >= len(watchers):
            break
        time.sleep(2)
    print(f" 카드 {live}대")
    if live == 0:
        print("  ✗ 카드가 한 대도 안 떴다. 기기에서 앱을 한 번 켜서 "
              "push-to-start 토큰을 올려라.", file=sys.stderr)
        return 1

    # 집에서 `away` 미터 북쪽. 위도 1도가 약 111km 다.
    call(args.backend, "POST", f"/session/{session}/location", token,
         {"lat": lat + args.away / 111_000, "lon": lon,
          "at": iso(datetime.now(timezone.utc))})
    time.sleep(2)

    state = call(args.backend, "GET", f"/session/{session}", token)
    eta = datetime.strptime(state["expectedArrival"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    now = datetime.now(timezone.utc)
    print(f"\n  단계 {state['stage']} · 남은거리 {state['remainingMeters']}m · "
          f"갱신 {state['updatesSent']}회")
    print(f"  도착예정 {eta.astimezone(KST):%H:%M:%S} "
          f"({(eta - now).total_seconds():.0f}초 뒤)")
    print("\n  **여기서 갱신을 끊는다.**")
    print(f"  ★ {(eta + timedelta(seconds=20)).astimezone(KST):%H:%M:%S} 이후에 기기를 봐라")
    print("     0:00 에서 멈춰 있다  → 맞다")
    print("     계속 자란다          → 되돌아갔다")
    print(f"\n  정리: python3 Tools/overdue-card.py --backend {args.backend} "
          f"--end {session} --token {token}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
