#!/usr/bin/env python3
"""docs/API-SPEC.md 를 그대로 구현한 목 서버.

진짜 서버를 붙이기 전에 앱 쪽 경로를 검증하기 위한 것이다.
대중교통 추정은 진짜로 하지 않고, 명세대로 생긴 응답을 돌려준다.

    python3 Tools/mock-server.py                # 정상 응답
    python3 Tools/mock-server.py --fail 500     # 항상 500 → MapKit 폴백 확인
    python3 Tools/mock-server.py --delay 10     # 응답 지연 → 타임아웃 폴백 확인

앱은 런치 인자로 여기를 가리킨다.

    xcrun simctl launch <udid> com.kona.homecoming2 \\
      -homecomingBackend http://localhost:8787
"""

import argparse
import json
import math
import sys
import time
import uuid
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer

ARGS = None
SESSIONS = {}
SESSION_SEQ = 0

# 페어링: 초대 코드와 연결 관계를 메모리에 들고 있는다.
INVITES = {}          # code -> {"traveler": accountId, "expiresAt": datetime}
LINKS = []            # [{"traveler": id, "watcher": id, "watcherName": str, "travelerName": str}]
TOKENS = {}           # 토큰 → 계정 id. /device/register 로 발급한 것만 담긴다
ROUTES = {}           # (계정, 이름) → 경로. 참조 서버처럼 이름이 유일하다
CODE_SEQ = 0


def make_code():
    global CODE_SEQ
    CODE_SEQ += 1
    alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"   # 헷갈리는 O/0, I/1 은 뺀다
    n = CODE_SEQ * 7919
    return "".join(alphabet[(n >> (i * 5)) % len(alphabet)] for i in range(5))


def iso(dt):
    """명세가 요구하는 ISO8601. 초 단위까지, UTC."""
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def haversine(a_lat, a_lon, b_lat, b_lon):
    r = 6_371_000
    p1, p2 = math.radians(a_lat), math.radians(b_lat)
    dp = math.radians(b_lat - a_lat)
    dl = math.radians(b_lon - a_lon)
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(h))


def estimate(body):
    """진짜 대중교통 API 자리. 지금은 거리로 그럴듯하게 지어낸다."""
    origin = body["origin"]
    destination = body["destination"]
    straight = haversine(origin["lat"], origin["lon"], destination["lat"], destination["lon"])

    route = straight * 1.35
    if route <= 900:
        mode, speed, detail = "walk", 70, "골목 도보"
    elif route <= 3_000:
        mode, speed, detail = "bus", 300, "간선버스 · 4정거장 남음"
    else:
        mode, speed, detail = "subway", 480, "2호선 · %d정거장 남음" % max(1, round(route / 1_400))

    minutes = max(1, round(route / speed))
    return {
        "expectedArrival": iso(datetime.now(timezone.utc) + timedelta(minutes=minutes)),
        "routeMeters": round(route),
        "mode": mode,
        "detail": detail,
    }


class Handler(BaseHTTPRequestHandler):

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            body = json.loads(raw)
        except json.JSONDecodeError:
            return self.send_json(400, {"error": "invalid json"})

        path = self.path.rstrip("/")
        print(f"\n→ POST {path}\n  {json.dumps(body, ensure_ascii=False)}", flush=True)

        if ARGS.delay:
            time.sleep(ARGS.delay)
        if ARGS.fail:
            print(f"  ← {ARGS.fail} (강제 실패)", flush=True)
            return self.send_json(ARGS.fail, {"error": "forced failure"})

        if path == "/device/register":
            # 목 서버는 토큰을 검사하지 않는다. 하지만 앱이 이걸 부르고 나서야
            # 나머지 요청을 보내므로, 없으면 앱이 여기서 멈춘다.
            account = uuid.uuid4().hex[:12]
            token = uuid.uuid4().hex + uuid.uuid4().hex
            TOKENS[token] = account
            print(f"  ← 기기 등록 {account}", flush=True)
            return self.send_json(200, {"accountId": account, "token": token})

        if path == "/route":
            # 참조 서버처럼 (계정, 이름) 이 유일하다. 같은 이름을 다시 올리면 고치는 것이다.
            me = self.account_id()
            name = body.get("name") or "귀가 경로"
            key = (me, name)
            existing = ROUTES.get(key)
            route_id = existing["routeId"] if existing else uuid.uuid4().hex[:12]
            ROUTES[key] = {
                "routeId": route_id, "account": me, "name": name,
                "totalSeconds": int(body.get("totalSeconds") or 0),
                "homeName": (body.get("home") or {}).get("name") or "집",
                "legs": body.get("legs") or [],
            }
            verb = "갱신" if existing else "저장"
            print(f"  ← 경로 {verb} {route_id} ({name})", flush=True)
            return self.send_json(200, {"routeId": route_id,
                                        "totalSeconds": ROUTES[key]["totalSeconds"]})

        if path == "/eta":
            result = estimate(body)
            print(f"  ← {json.dumps(result, ensure_ascii=False)}", flush=True)
            return self.send_json(200, result)

        if path.startswith("/push/"):
            # 토큰은 저장하는 척만 한다. 실제 발급 여부를 눈으로 보는 것이 목적이다.
            return self.send_json(200, {"ok": True})

        if path == "/session/start":
            global SESSION_SEQ
            SESSION_SEQ += 1
            session_id = "S%04d" % SESSION_SEQ
            SESSIONS[session_id] = {"start": body, "locations": 0, "end": None}
            print(f"  ← 세션 개시 {session_id}", flush=True)
            return self.send_json(200, {"sessionId": session_id})

        if path.startswith("/session/") and path.endswith("/location"):
            session_id = path.split("/")[2]
            if session_id not in SESSIONS:
                return self.send_json(404, {"error": "unknown session"})
            SESSIONS[session_id]["locations"] += 1
            n = SESSIONS[session_id]["locations"]
            print(f"  ← {session_id} 위치 {n}번째 수신", flush=True)
            return self.send_json(200, {"ok": True})

        if path.startswith("/session/") and path.endswith("/end"):
            session_id = path.split("/")[2]
            if session_id not in SESSIONS:
                return self.send_json(404, {"error": "unknown session"})
            SESSIONS[session_id]["end"] = body.get("reason")
            n = SESSIONS[session_id]["locations"]
            print(f"  ← {session_id} 종료 ({body.get('reason')}) · 위치 {n}건 수신", flush=True)
            return self.send_json(200, {"ok": True})

        if path == "/pair/invite":
            code = make_code()
            expires = datetime.now(timezone.utc) + timedelta(minutes=30)
            INVITES[code] = {"traveler": self.account_id(), "expiresAt": expires,
                             "travelerName": body.get("travelerName") or "귀가자"}
            print(f"  ← 초대 코드 {code} (귀가자 {self.account_id()[:8]})", flush=True)
            return self.send_json(200, {"code": code, "expiresAt": iso(expires)})

        if path == "/pair/accept":
            code = (body.get("code") or "").upper()
            invite = INVITES.get(code)
            if invite is None:
                print(f"  ← 404 알 수 없는 코드 {code}", flush=True)
                return self.send_json(404, {"error": "unknown code"})
            if invite["expiresAt"] < datetime.now(timezone.utc):
                return self.send_json(410, {"error": "expired"})

            watcher = self.account_id()
            traveler = invite["traveler"]
            if watcher == traveler:
                return self.send_json(400, {"error": "자기 자신은 연결할 수 없습니다"})

            LINKS[:] = [l for l in LINKS if not (l["traveler"] == traveler and l["watcher"] == watcher)]
            LINKS.append({
                "traveler": traveler,
                "watcher": watcher,
                "watcherName": body.get("name") or "가족",
                "travelerName": invite["travelerName"],
            })
            print(f"  ← 연결 {watcher[:8]} → {traveler[:8]} ({body.get('name')})", flush=True)
            return self.send_json(200, {"travelerName": invite["travelerName"], "travelerAccountId": traveler})

        return self.send_json(404, {"error": "unknown path"})

    def do_GET(self):
        path = self.path.rstrip("/")
        me = self.account_id()
        print(f"\n→ GET {path} (me {me[:8]})", flush=True)

        if path == "/health":
            return self.send_json(200, {"ok": True, "mock": True})

        if path == "/route":
            rows = [{"routeId": r["routeId"], "name": r["name"],
                     "totalSeconds": r["totalSeconds"], "homeName": r["homeName"]}
                    for r in ROUTES.values() if r["account"] == me]
            print(f"  ← 저장된 경로 {len(rows)}개", flush=True)
            return self.send_json(200, rows)

        if path == "/pair/watchers":
            rows = [{"accountId": l["watcher"], "name": l["watcherName"]}
                    for l in LINKS if l["traveler"] == me]
            print(f"  ← 나를 보는 가족 {len(rows)}명", flush=True)
            return self.send_json(200, rows)

        if path == "/pair/watching":
            rows = [{"accountId": l["traveler"], "name": l["travelerName"]}
                    for l in LINKS if l["watcher"] == me]
            print(f"  ← 내가 보는 사람 {len(rows)}명", flush=True)
            return self.send_json(200, rows)

        return self.send_json(404, {"error": "unknown path"})

    def do_DELETE(self):
        path = self.path.rstrip("/")
        me = self.account_id()
        print(f"\n→ DELETE {path} (me {me[:8]})", flush=True)

        if path.startswith("/pair/link/"):
            other = path.split("/")[-1]
            before = len(LINKS)
            LINKS[:] = [l for l in LINKS
                        if not ((l["traveler"] == me and l["watcher"] == other)
                                or (l["watcher"] == me and l["traveler"] == other))]
            print(f"  ← 연결 해제 {before - len(LINKS)}건", flush=True)
            return self.send_json(200, {"ok": True})

        return self.send_json(404, {"error": "unknown path"})

    def account_id(self):
        """토큰이 가리키는 계정.

        목 서버는 **인증을 흉내만 낸다.** 모르는 토큰이어도 401 을 주지 않고
        토큰 앞자리를 계정 이름처럼 쓴다 — 여기서 막으면 목 서버를 쓰는 이유
        (앱을 서버 없이 굴리기)가 없어진다. 인증 자체는 참조 서버에서 시험한다.
        """
        header = self.headers.get("Authorization", "")
        if not header.startswith("Bearer "):
            return "unknown"
        token = header[7:].strip()
        return TOKENS.get(token, token[:12] or "unknown")

    def send_json(self, status, payload):
        data = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_):
        pass   # 기본 액세스 로그는 끈다. 위에서 필요한 것만 찍는다.


def main():
    global ARGS
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--fail", type=int, default=0, help="이 상태코드로 항상 실패")
    parser.add_argument("--delay", type=float, default=0, help="응답 지연(초)")
    ARGS = parser.parse_args()

    server = HTTPServer(("0.0.0.0", ARGS.port), Handler)
    print(f"귀가마중 목 서버 :{ARGS.port}", flush=True)
    if ARGS.fail:
        print(f"  모든 요청을 {ARGS.fail} 로 실패시킵니다", flush=True)
    if ARGS.delay:
        print(f"  모든 응답을 {ARGS.delay}초 지연시킵니다", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)


if __name__ == "__main__":
    main()
