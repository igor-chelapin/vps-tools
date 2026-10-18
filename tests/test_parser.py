import base64
import json

import pytest

from vpncheck.parser import ParseError, parse_link, parse_text
from vpncheck.xray_config import build_config, needs_cert_pin

PIN = "AB:" * 31 + "AB"  # 32 байта, формат с двоеточиями как в hy2-ссылках

UUID = "11111111-2222-3333-4444-555555555555"

VLESS_REALITY = (
    f"vless://{UUID}@example.com:443?type=tcp&security=reality&sni=www.microsoft.com"
    "&fp=chrome&pbk=PUBKEY&sid=ab12&flow=xtls-rprx-vision#My%20Server"
)
VLESS_WS = (
    f"vless://{UUID}@[2001:db8::1]:8443?type=ws&security=tls&sni=a.example"
    "&host=a.example&path=%2Fws#ipv6"
)
TROJAN = "trojan://p%40ss@example.org:443?security=tls&sni=example.org&type=grpc&serviceName=svc#tr"
HY2 = (
    "hysteria2://secret@example.net:443?sni=example.net&pinSHA256=" + PIN +
    "&obfs=salamander&obfs-password=obf#hy"
)
HY2_PORTS = "hy2://user:pass@example.net:443,20000-30000?sni=example.net#hop"


def test_vless_reality():
    p = parse_link(VLESS_REALITY)
    assert (p.protocol, p.host, p.port, p.secret) == ("vless", "example.com", 443, UUID)
    assert p.name == "My Server"
    out = build_config(p, 10808)["outbounds"][0]
    assert out["settings"]["vnext"][0]["users"][0]["flow"] == "xtls-rprx-vision"
    assert out["streamSettings"]["security"] == "reality"
    assert out["streamSettings"]["realitySettings"]["publicKey"] == "PUBKEY"


def test_vless_ws_ipv6():
    p = parse_link(VLESS_WS)
    assert p.host == "2001:db8::1" and p.port == 8443
    s = build_config(p, 10808)["outbounds"][0]["streamSettings"]
    assert s["network"] == "ws" and s["wsSettings"]["path"] == "/ws"
    assert s["tlsSettings"]["serverName"] == "a.example"
    assert s["wsSettings"]["host"] == "a.example"
    assert "headers" not in s["wsSettings"]


def test_trojan_password_unquoted_and_grpc():
    p = parse_link(TROJAN)
    assert p.secret == "p@ss"
    out = build_config(p, 1)["outbounds"][0]
    assert out["settings"]["servers"][0]["password"] == "p@ss"
    assert out["streamSettings"]["grpcSettings"]["serviceName"] == "svc"


def test_hysteria2_with_salamander():
    p = parse_link(HY2)
    out = build_config(p, 1)["outbounds"][0]
    assert out["protocol"] == "hysteria"
    stream = out["streamSettings"]
    assert stream["network"] == "hysteria"
    assert stream["hysteriaSettings"] == {"version": 2, "auth": "secret"}
    assert stream["tlsSettings"]["pinnedPeerCertSha256"] == "ab" * 32
    assert "allowInsecure" not in stream["tlsSettings"]
    assert stream["finalmask"]["udp"][0]["settings"]["password"] == "obf"


def test_hy2_scheme_alias_user_pass_and_port_range():
    p = parse_link(HY2_PORTS)
    assert p.protocol == "hysteria2"
    assert p.secret == "user:pass"
    assert p.port == 443


def test_unsupported_obfs_rejected():
    p = parse_link("hysteria2://s@h.example:443?obfs=weird&obfs-password=x")
    with pytest.raises(ParseError):
        build_config(p, 1)


@pytest.mark.parametrize(
    "bad",
    ["vmess://abc", "vless://nohost", "vless://@h:1", "trojan://p@h:99999", "http://x"],
)
def test_bad_links(bad):
    with pytest.raises(ParseError):
        parse_link(bad)


def test_subscription_plain_and_base64_and_dedup():
    text = "\n".join([VLESS_REALITY, TROJAN, HY2, "vmess://skipme", "# comment", VLESS_REALITY])
    proxies, skipped = parse_text(text)
    assert [p.protocol for p in proxies] == ["vless", "trojan", "hysteria2"]
    assert skipped == 1

    encoded = base64.b64encode(text.encode()).decode()
    proxies2, _ = parse_text(encoded)
    assert len(proxies2) == 3

    urlsafe = base64.urlsafe_b64encode(text.encode()).decode().rstrip("=")
    proxies3, _ = parse_text(urlsafe)
    assert len(proxies3) == 3


def test_insecure_needs_pin():
    vless = parse_link(f"vless://{UUID}@h.example:443?security=tls&sni=s.example&insecure=1#x")
    assert needs_cert_pin(vless)
    with pytest.raises(ParseError):
        build_config(vless, 1)  # без отпечатка Xray 26.3+ такой ключ не примет
    tls = build_config(vless, 1, pin="cd" * 32)["outbounds"][0]["streamSettings"]["tlsSettings"]
    assert tls["pinnedPeerCertSha256"] == "cd" * 32
    assert "allowInsecure" not in tls

    hy2 = parse_link("hysteria2://s@h.example:443?sni=s.example&insecure=1")
    assert not needs_cert_pin(hy2)  # по QUIC отпечаток сами не снимем
    with pytest.raises(ParseError):
        build_config(hy2, 1)


def test_secure_tls_has_no_allow_insecure():
    p = parse_link(f"vless://{UUID}@h.example:443?security=tls&sni=s.example#x")
    assert not needs_cert_pin(p)
    tls = build_config(p, 1)["outbounds"][0]["streamSettings"]["tlsSettings"]
    assert "allowInsecure" not in tls and "pinnedPeerCertSha256" not in tls


def test_config_is_json_serializable():
    for link in (VLESS_REALITY, VLESS_WS, TROJAN, HY2):
        json.dumps(build_config(parse_link(link), 12345))
