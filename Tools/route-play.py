#!/usr/bin/env python3
"""저장된 귀가 경로를 서버에 흘려 넣는다.

직선으로 단조롭게 가까워지는 가짜 경로로는 서버 로직의 절반이 안 돌아간다.
ETA 보정도 단계 후퇴 방지도 멈춤 판정도 시험되지 않는다. 그래서 실제 귀가에
가까운 좌표열을 파일로 저장해 두고 그걸 재생한다.

    python3 Tools/route-play.py Tools/routes/subway-walk.json
    python3 Tools/route-play.py Tools/routes/detour.json --speed 30

**시간 압축.** 서버는 벽시계가 아니라 위치에 실린 `at` 타임스탬프로 접근
속도를 잰다(최근 12건, 시간 폭 90초 이상, 좁힌 거리 150m 이상). 그래서 `at`
을 현실적으로 유지하면서 벽시계만 압축해도 계산이 그대로 성립한다.
25분 귀가가 --speed 20 에서 75초에 끝난다.

의존성 없음. 서버와 같은 방침이다.
"""

import argparse
import json
import math
import os
import sys
import time
import urllib.error
import urllib.request

import sys as _sys, os as _os
_sys.path.insert(0, _os.path.dirname(_os.path.abspath(__file__)))
import hc_tls
from datetime import datetime, timedelta, timezone

# 서버의 TRANSPORT_SPEED (m/분). 보정이 걸렸는지 가늠하는 기준으로만 쓴다.
FLAT_SPEED = {"walk": 70, "bus": 300, "car": 400, "subway": 480}


def haversine(lat1, lon1, lat2, lon2):
    radius = 6_371_000
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = p2 - p1
    dl = math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * radius * math.asin(math.sqrt(a))


def register(backend):
    """기기를 등록해 토큰을 받는다. 인증이 필요 없는 유일한 엔드포인트다."""
    request = urllib.request.Request(
        f"{backend.rstrip('/')}/device/register", data=b"{}", method="POST")
    request.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(request, timeout=10, context=hc_tls.context()) as response:
        issued = json.loads(response.read())
    return issued["accountId"], issued["token"]


def call(backend, method, path, token, body=None, quiet=()):
    """서버를 부른다. `quiet` 에 든 상태코드는 오류로 찍지 않는다 —
    도착으로 세션이 닫히면 404 가 오는데 그건 고장이 아니라 끝이다."""
    url = f"{backend.rstrip('/')}{path}"
    data = json.dumps(body or {}).encode() if method != "GET" else None
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Authorization", f"Bearer {token}")
    if data:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=10, context=hc_tls.context()) as response:
            raw = response.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        if error.code not in quiet:
            print(f"  ✗ {method} {path} → {error.code} {error.read().decode(errors='replace')[:120]}")
        raise
    except urllib.error.URLError as error:
        print(f"  ✗ {method} {path} → 서버에 못 닿는다: {error.reason}")
        raise


def read_state(backend, token, session_id):
    """서버가 계산한 상태를 읽는다.

    위치 응답은 {"ok": true} 뿐이라 상태가 안 온다. 예전에는 서버의 SQLite 를 직접
    열었는데, 그건 서버가 같은 기계에 있을 때만 되는 방법이었다. 배포한 서버로도
    같은 도구가 돌아야 해서 `GET /session/{id}` 에 물어본다.
    """
    try:
        state = call(backend, "GET", f"/session/{session_id}", token, quiet=(404,))
    except urllib.error.HTTPError as error:
        # 도착 판정으로 서버가 세션을 닫으면 404 다. 그건 오류가 아니라 끝이다.
        if error.code == 404:
            return None
        raise
    return {
        "stage": state.get("stage"),
        "remaining_meters": state.get("remainingMeters"),
        "expected_arrival": state.get("expectedArrival"),
        "transport": state.get("transport"),
        "ended_at": state.get("endedAt"),
        "detail": state.get("detail"),
        "delay_seconds": state.get("delaySeconds") or 0,
        # **서버가 밝힌 추정 방식.** 예전에는 `"off_route": 0` 이 상수로 박혀 있었다 —
        # 서버의 SQLite 를 직접 열던 것을 `GET /session/{id}` 로 옮길 때 조용히 0 이
        # 됐고, 그래서 근거 칸이 이탈 중에도 `경로` 로 찍히고 마지막 "경로 이탈 없음"
        # 검사는 절대 실패할 수 없었다. 2026-08-18 실주행은 49분을 이탈 상태로 돌았는데
        # 이 도구로는 초록불이 났을 것이다.
        "estimate_source": state.get("estimateSource"),
        "off_route": 1 if state.get("estimateSource") == "offRoute" else 0,
        "updates_sent": state.get("updatesSent", 0),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("route", help="경로 파일 (Tools/routes/*.json)")
    parser.add_argument("--backend", default="http://127.0.0.1:8787")
    parser.add_argument("--token", help="귀가자 토큰. 없으면 새 기기를 등록한다")
    parser.add_argument("--speed", type=float, default=20.0,
                        help="벽시계 압축 배수. 1 이면 실시간")
    parser.add_argument("--session", help="이미 있는 세션에 흘린다")
    parser.add_argument("--no-end", action="store_true", help="끝나도 세션을 닫지 않는다")
    parser.add_argument("--register", action="store_true",
                        help="경로를 서버에 등록하고 그 경로로 세션을 시작한다. "
                             "도착예정이 저장된 소요시간에서 나오고 위치는 지연만 잰다")
    parser.add_argument("--session-out", metavar="파일",
                        help="세션 id 를 여기 적는다. 재생이 끝난 뒤에도 그 세션을 "
                             "조회하려면 필요하다 — 도착하면 활성 세션 조회로는 못 찾는다")
    parser.add_argument("--route-id",
                        help="이미 서버에 있는 경로로 돈다. 앱이 만든 경로를 그대로 "
                             "시험할 때 쓴다 — 그 경로의 주인 토큰이 필요하다")
    args = parser.parse_args()

    with open(args.route, encoding="utf-8") as handle:
        route = json.load(handle)

    # 서버가 X-Account-Id 를 더 믿지 않는다. 토큰이 없으면 새 기기로 등록한다.
    token = args.token
    if not token:
        account, token = register(args.backend)
        print(f"  기기 등록 {account}")

    fixes = route["fixes"]
    home = route["home"]
    expect = route.get("expect", {})
    total = fixes[-1]["t"]

    print(f"\n\033[1m경로 {route['name']}\033[0m")
    print(f"  {route.get('note', '')}")
    print(f"  위치 {len(fixes)}건 · 모사 {total // 60}분 {total % 60}초 · "
          f"압축 {args.speed:g}배 → 실제 {total / args.speed:.0f}초")

    # ------------------------------------------------------------------ 경로 등록
    route_id = args.route_id
    if route_id:
        print(f"  서버에 있는 경로 {route_id} 로 돈다")
    if args.register:
        if not route.get("legs"):
            print("  ✗ 이 경로 파일에는 legs 가 없다. route-make.py 로 다시 만들어라")
            return 1
        saved = call(args.backend, "POST", "/route", token, {
            "name": route["name"],
            "totalSeconds": route["totalSeconds"],
            "home": {"lat": home["lat"], "lon": home["lon"],
                     "name": home.get("name", "집"), "radius": home.get("radius", 120)},
            "legs": route["legs"],
        })
        route_id = saved["routeId"]
        print(f"  경로 등록 {route_id} · 소요 {saved['totalSeconds'] // 60}분")
        print("  도착예정은 이 값에서 나온다. 위치는 어느 구간인지와 지연만 잰다.")

    # ------------------------------------------------------------------ 세션
    if args.session:
        session_id = args.session
        print(f"  기존 세션 {session_id}")
    else:
        payload = {"travelerName": route.get("travelerName", "아빠")}
        if route_id:
            payload["routeId"] = route_id      # 집 좌표도 경로에서 온다
        else:
            payload["home"] = {"lat": home["lat"], "lon": home["lon"],
                               "name": home.get("name", "집"),
                               "arrivalRadius": home.get("radius", 120)}
        started = call(args.backend, "POST", "/session/start", token, payload)
        session_id = started["sessionId"]
        print(f"  세션 {session_id} 시작")
    if args.session_out:
        with open(args.session_out, "w", encoding="utf-8") as handle:
            handle.write(session_id)

    # `at` 의 기준점. 압축해도 서버가 보는 시간 간격은 현실적으로 유지된다.
    origin = datetime.now(timezone.utc)

    print()
    if route_id:
        print("     경과   남은거리   단계        도착예정   근거   구간 · 지연")
    else:
        print("     경과   남은거리   단계        도착예정   보정   이동")
    print("  ─────────────────────────────────────────────────────────────")

    stages = ["leaving", "moving", "nearby", "arrived"]
    stage = "leaving"
    worst = 0
    backward = []
    corrected = False
    previous_t = 0
    worst_eta = 0.0     # 도착예정이 가장 크게 튄 값. 상식성 검사에 쓴다.
    # **끝 상태만 보면 스쳐 간 이탈을 놓친다.** 이탈했다가 돌아오면 마지막 상태는
    # 경로이므로 "이탈 없음" 이 되어 버린다. 그래서 도는 동안 센다.
    off_route_fixes = 0

    for fix in fixes:
        wait = (fix["t"] - previous_t) / args.speed
        if wait > 0:
            time.sleep(wait)
        previous_t = fix["t"]

        at = origin + timedelta(seconds=fix["t"])
        try:
            call(args.backend, "POST", f"/session/{session_id}/location", token, {
                # 서버가 내보내는 것과 같은 형식으로 보낸다. isoformat() 은 마이크로초를
                # 붙이는데, 서버가 그걸 못 읽으면 조용히 now() 로 대체해서 접근 속도가
                # 통째로 어긋난다. 실제로 한 번 그렇게 속았다.
                "lat": fix["lat"], "lon": fix["lon"], "at": at.strftime("%Y-%m-%dT%H:%M:%SZ"),
            })
        except urllib.error.HTTPError as error:
            if error.code == 404 and stage == "arrived":
                print("  (도착해서 세션이 닫혔다. 남은 위치는 흘리지 않는다)")
                break
            return 1
        except Exception:
            return 1

        fresh = read_state(args.backend, token, session_id)
        if fresh is None:
            # 서버가 세션을 닫았다. 도착 판정이 났다는 뜻이다 — 위치 응답은
            # {"ok": true} 뿐이라 이 조회로만 알 수 있다.
            stage = "arrived"
            worst = max(worst, stages.index("arrived") if "arrived" in stages else worst)
            print("  (서버가 도착으로 세션을 닫았다. 남은 위치는 흘리지 않는다)")
            break
        state = fresh
        stage = state.get("stage") or "?"
        remaining = state.get("remaining_meters")
        if remaining is None:
            remaining = round(haversine(fix["lat"], fix["lon"], home["lat"], home["lon"]))

        # 단계는 뒤로 가지 않아야 한다. GPS 가 튀어도.
        index = stages.index(stage) if stage in stages else -1
        if index < worst:
            backward.append(f"{fix['t']}초 {stages[worst]} → {stage}")
        worst = max(worst, index)

        # 보정이 걸렸는지: 남은 시간이 평평한 교통수단 추정과 다르면 걸린 것이다.
        eta_seconds = None
        mark = " "
        if state.get("expected_arrival"):
            try:
                eta = datetime.fromisoformat(state["expected_arrival"].replace("Z", "+00:00"))
                eta_seconds = (eta - datetime.now(timezone.utc)).total_seconds()
                worst_eta = max(worst_eta, eta_seconds)
                mode = state.get("transport") or "subway"
                flat = remaining / (FLAT_SPEED.get(mode, 480) / 60)
                if flat > 0 and abs(eta_seconds - flat) / flat > 0.10:
                    mark, corrected = "○", True
            except ValueError:
                pass

        # 경로로 도는 중이면 도착예정의 근거가 저장된 소요시간이다. 관측 속도 보정과
        # 무관하니 ○ 를 찍는 게 무의미하다. 대신 근거가 경로인지 폴백인지 보여 준다.
        if route_id:
            if state.get("off_route"):
                off_route_fixes += 1
            mark = "이탈" if state.get("off_route") else "경로"
            tail = f"{state.get('detail') or '?':<10} 지연 {state.get('delay_seconds', 0):4d}초"
        else:
            tail = fix.get("note", "")

        print(f"  {fix['t']:5d}초  {remaining:6d}m   {stage:<10}  "
              f"{('%4.0f초' % eta_seconds) if eta_seconds is not None else '   -':>7}   "
              f"{mark:<4}   {tail}")

        if stage == "arrived":
            # 서버가 도착으로 닫았다. 뒤 위치는 의미가 없다.
            if fix is not fixes[-1]:
                print("  (도착 판정. 남은 위치는 흘리지 않는다)")
            break

    # ------------------------------------------------------------------ 판정
    print()
    failures = []

    if backward:
        failures.append("단계가 뒤로 갔다: " + ", ".join(backward))
    else:
        print("  ✓ 단계가 뒤로 가지 않았다")

    # 도착예정이 상식적인가. 이 검사가 없어서 18.8시간이 나온 채로 통과한 적이 있다.
    # 가족 잠금화면에 뜨는 숫자라 값이 틀리면 서비스가 거짓말을 하는 것이다.
    eta_limit = expect.get("maxEtaSeconds") or total * 3
    if worst_eta > eta_limit:
        failures.append(
            f"도착예정이 {worst_eta / 3600:.1f}시간까지 튀었다. "
            f"모사 여정 {total // 60}분의 3배({eta_limit // 60:.0f}분)를 넘는다. "
            f"관측 접근 속도가 비현실적으로 낮게 잡힌 것이다")
    else:
        print(f"  ✓ 도착예정 최댓값 {worst_eta / 60:.0f}분 "
              f"(여정 {total // 60}분, 한계 {eta_limit // 60:.0f}분)")

    want_stage = expect.get("stage")
    if want_stage:
        if stage == want_stage:
            print(f"  ✓ 최종 단계 {stage}")
        else:
            failures.append(f"최종 단계가 {stage} 다. {want_stage} 여야 한다")

    if route_id:
        # 경로로 돌 때는 관측 속도 보정이 관여하지 않는다. 검사할 것이 다르다.
        # 도착예정이 저장된 소요시간에서 나오니 여정 시간에 딱 붙어야 한다.
        total_route = route["totalSeconds"]
        if worst_eta > total_route * 1.2:
            failures.append(
                f"도착예정 최댓값 {worst_eta / 60:.0f}분이 저장된 소요시간 "
                f"{total_route // 60}분보다 20% 넘게 크다. 경로 기반이면 이렇게 벌어지지 않는다")
        else:
            print(f"  ✓ 도착예정이 저장된 소요시간에 붙어 있다 "
                  f"({worst_eta / 60:.0f}분 vs {total_route // 60}분)")

        # 스쳐 간 이탈까지 본다. 끝에 돌아와 있어도 도는 동안 벗어났으면 알려야 한다 —
        # 그 구간에서는 남은거리의 자가 직선거리로 바뀌어 화면의 점이 뛴다.
        if off_route_fixes:
            failures.append(
                f"경로 이탈이 위치 {off_route_fixes}건에서 났다"
                f"{' (끝에는 복귀했다)' if not state.get('off_route') else ' (복귀하지 못했다)'}. "
                "이 경로는 저장된 경로를 그대로 따라간다")
        else:
            print("  ✓ 경로 이탈 없음")

    elif expect.get("correction") is True:
        if corrected:
            print("  ✓ ETA 보정이 걸렸다 (○ 표시된 줄)")
        else:
            failures.append("ETA 보정이 한 번도 안 걸렸다. "
                            "최근 12건 시간 폭 90초·좁힌 거리 150m 하한을 못 넘었다")
    elif expect.get("correction") is False:
        if corrected:
            failures.append("ETA 보정이 걸렸다. 이 경로는 하한을 못 넘어야 한다")
        else:
            print("  ✓ ETA 보정이 안 걸렸다 (하한 미달, 의도한 대로)")

    # 도착하면 서버가 이미 닫았다. 또 닫으면 404 다.
    if not args.no_end and not args.session and stage != "arrived":
        try:
            call(args.backend, "POST", f"/session/{session_id}/end", token, {})
        except Exception:
            pass

    if failures:
        print()
        for line in failures:
            print(f"  \033[31m✗\033[0m {line}")
        return 1

    print(f"\n  \033[32m경로 {route['name']} 통과\033[0m")
    return 0


if __name__ == "__main__":
    sys.exit(main())
