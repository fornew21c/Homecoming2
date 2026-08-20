#!/usr/bin/env python3
"""실기기의 Live Activity 를 APNs 로 직접 갱신해 본다.

docs/API-SPEC.md 의 페이로드를 그대로 쏘므로, 서버를 만들기 전에
명세가 실제로 동작하는지 확인할 수 있다.

필요한 것
  - APNs 인증 키(.p8), 키 ID, 팀 ID
  - 기기에서 발급된 토큰 (앱 화면의 '기기 토큰 / push-to-start / 액티비티 토큰' 행,
    또는 서버 미연결 모드일 때 콘솔 출력)

의존성은 openssl 하나뿐이다. 파이썬 패키지를 따로 깔지 않는다.

예)
  # 이미 떠 있는 액티비티 갱신
  python3 Tools/apns-push.py update \\
    --key AuthKey_ABC123.p8 --key-id ABC123 --team-id DEF456 \\
    --token <액티비티 갱신 토큰> \\
    --remaining 3200 --eta-minutes 12 --stage moving --detail "2호선 · 3정거장 남음"

  # 앱이 떠 있지 않아도 액티비티를 시작시킨다 (가족 기기에 띄우는 그 경로)
  python3 Tools/apns-push.py start \\
    --key ... --key-id ... --team-id ... --token <push-to-start 토큰> \\
    --traveler 엄마 --audience watcher --eta-minutes 25 --remaining 11000

  # 도착 처리
  python3 Tools/apns-push.py end --key ... --token <액티비티 토큰> --stage arrived
"""

import argparse
import base64
import json
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone

BUNDLE_ID = "com.kona.homecoming2"


# ---------------------------------------------------------------- JWT (ES256)

def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_to_raw(der: bytes) -> bytes:
    """openssl 이 내주는 DER 서명을 JWT 가 요구하는 r||s 64바이트로 바꾼다.

    DER: SEQUENCE { INTEGER r, INTEGER s }
    앞에 붙는 0x00 패딩을 떼고 각각 32바이트로 맞춘다.
    """
    if der[0] != 0x30:
        raise ValueError("DER SEQUENCE 가 아닙니다")

    index = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)

    def read_int(pos):
        if der[pos] != 0x02:
            raise ValueError("DER INTEGER 가 아닙니다")
        length = der[pos + 1]
        value = der[pos + 2: pos + 2 + length].lstrip(b"\x00")
        return value.rjust(32, b"\x00"), pos + 2 + length

    r, index = read_int(index)
    s, _ = read_int(index)
    return r + s


def make_jwt(key_path: str, key_id: str, team_id: str) -> str:
    header = {"alg": "ES256", "kid": key_id}
    claims = {"iss": team_id, "iat": int(time.time())}
    signing_input = f"{b64url(json.dumps(header).encode())}.{b64url(json.dumps(claims).encode())}"

    signed = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", key_path],
        input=signing_input.encode(),
        capture_output=True,
    )
    if signed.returncode != 0:
        sys.exit(f"서명 실패: {signed.stderr.decode()}")

    return f"{signing_input}.{b64url(der_to_raw(signed.stdout))}"


# ------------------------------------------------------------------ 페이로드

def iso(dt) -> str:
    """명세가 요구하는 형식. 여기서 어긋나면 값이 조용히 틀어진다."""
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def content_state(args) -> dict:
    now = datetime.now(timezone.utc)
    state = {
        "stage": args.stage,
        "transport": args.transport,
        "expectedArrival": iso(now + timedelta(minutes=args.eta_minutes)),
        "remainingMeters": args.remaining,
        "totalMeters": args.total,
    }
    if args.detail:
        state["detail"] = args.detail
    return state


def build_payload(event: str, args) -> dict:
    aps = {
        "timestamp": int(time.time()),
        "event": event,
        "content-state": content_state(args),
    }

    if event == "start":
        aps["attributes-type"] = "HomecomingAttributes"
        aps["attributes"] = {
            "travelerName": args.traveler,
            "destinationName": args.destination,
            "departedAt": iso(datetime.now(timezone.utc)),
            "audience": args.audience,
        }

    if event == "end":
        aps["dismissal-date"] = int(time.time()) + 60

    if args.alert_title:
        aps["alert"] = {"title": args.alert_title, "body": args.alert_body or ""}

    return {"aps": aps}


# ---------------------------------------------------------------------- 전송

def send(args, event: str):
    payload = build_payload(event, args)
    host = "api.sandbox.push.apple.com" if args.sandbox else "api.push.apple.com"
    url = f"https://{host}/3/device/{args.token}"

    print(json.dumps(payload, ensure_ascii=False, indent=2))

    if args.dry_run:
        print(f"\n(dry-run) POST {url}")
        return

    jwt = make_jwt(args.key, args.key_id, args.team_id)
    result = subprocess.run(
        [
            "curl", "-sS", "--http2", "-X", "POST", url,
            "-H", f"authorization: bearer {jwt}",
            "-H", f"apns-topic: {BUNDLE_ID}.push-type.liveactivity",
            "-H", "apns-push-type: liveactivity",
            "-H", f"apns-priority: {args.priority}",
            "-H", f"apns-expiration: {int(time.time()) + 3600}",
            "-d", json.dumps(payload, ensure_ascii=False),
            "-D", "-", "-o", "/dev/stdout",
        ],
        capture_output=True,
    )
    output = result.stdout.decode(errors="replace")
    print("\n--- APNs 응답 ---")
    print(output.strip() or "(응답 없음)")

    if "apns-unique-id" in output.lower() and " 200 " in output:
        print("\n성공. 기기 화면을 확인하세요.")
    elif "BadDeviceToken" in output:
        print("\n토큰이 이 환경과 맞지 않습니다. --sandbox 여부를 확인하세요.")
    elif "410" in output:
        print("\n410 Gone — 죽은 토큰입니다. 폐기하고 재발급을 기다리세요.")


def main():
    parser = argparse.ArgumentParser(description="Live Activity 를 APNs 로 갱신한다")
    parser.add_argument("event", choices=["start", "update", "end"])

    parser.add_argument("--key", help="AuthKey_XXXX.p8 경로")
    parser.add_argument("--key-id")
    parser.add_argument("--team-id")
    parser.add_argument("--token", help="push-to-start(start) 또는 액티비티 갱신(update/end) 토큰")
    parser.add_argument("--sandbox", action="store_true", default=True,
                        help="개발 빌드는 sandbox (기본값)")
    parser.add_argument("--production", dest="sandbox", action="store_false")
    parser.add_argument("--dry-run", action="store_true", help="페이로드만 출력하고 보내지 않는다")

    parser.add_argument("--stage", default="moving",
                        choices=["leaving", "moving", "nearby", "arrived"])
    parser.add_argument("--transport", default="subway",
                        choices=["subway", "bus", "car", "walk"])
    parser.add_argument("--eta-minutes", type=int, default=15)
    parser.add_argument("--remaining", type=int, default=4200)
    parser.add_argument("--total", type=int, default=11000)
    parser.add_argument("--detail", default=None)

    parser.add_argument("--traveler", default="아빠")
    parser.add_argument("--destination", default="집")
    parser.add_argument("--audience", default="watcher", choices=["traveler", "watcher"])

    parser.add_argument("--alert-title", default=None)
    parser.add_argument("--alert-body", default=None)
    parser.add_argument("--priority", default="10")

    args = parser.parse_args()

    if not args.dry_run and not all([args.key, args.key_id, args.team_id, args.token]):
        sys.exit("--key --key-id --team-id --token 이 모두 필요합니다 (또는 --dry-run)")

    send(args, args.event)


if __name__ == "__main__":
    main()
