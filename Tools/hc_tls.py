"""맥이 신뢰하는 인증서로 TLS 를 검증한다.

**왜 필요한가** — 회사 네트워크가 TLS 를 검사하는 프록시를 지나고, 그 프록시가
자기 루트 인증서로 서명한 인증서를 내민다. 그 루트는 맥 시스템 키체인에 설치돼
있어서 사파리도 `curl` 도 통과하는데, 파이썬은 자기가 들고 다니는 인증서 묶음만
보기 때문에 통째로 실패한다.

    ssl.SSLCertVerificationError: self-signed certificate in certificate chain

**검증을 끄지 않는다.** 이 도구들은 서비스 키와 계정 토큰을 실어 보낸다. 대신
맥 키체인의 루트들을 뽑아 파이썬에게 넘긴다 — 사파리가 믿는 것과 같은 것을 믿는다.

맥이 아니거나 뽑기에 실패하면 기본 검증으로 돌아간다.
"""

import os
import ssl
import subprocess
import tempfile

_KEYCHAINS = [
    "/System/Library/Keychains/SystemRootCertificates.keychain",  # 애플이 넣은 루트
    "/Library/Keychains/System.keychain",                          # 관리자가 넣은 루트(회사)
]

_cached = None


def _bundle():
    """맥 키체인의 루트 인증서를 모아 파일 하나로 만든다. 한 번만 한다."""
    global _cached
    if _cached is not None:
        return _cached

    chunks = []
    for keychain in _KEYCHAINS:
        if not os.path.exists(keychain):
            continue
        try:
            out = subprocess.run(
                ["security", "find-certificate", "-a", "-p", keychain],
                capture_output=True, text=True, timeout=20, check=True,
            ).stdout
        except (OSError, subprocess.SubprocessError):
            continue
        if out.strip():
            chunks.append(out)

    if not chunks:
        _cached = ""
        return _cached

    path = os.path.join(tempfile.gettempdir(), "homecoming-ca-bundle.pem")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(chunks))
    _cached = path
    return _cached


def context():
    """검증하는 TLS 문맥. 맥에서는 시스템이 믿는 루트까지 함께 믿는다."""
    bundle = _bundle()
    if bundle:
        try:
            return ssl.create_default_context(cafile=bundle)
        except ssl.SSLError:
            pass
    return ssl.create_default_context()
