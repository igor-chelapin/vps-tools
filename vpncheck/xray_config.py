"""Сборка JSON-конфига Xray (SOCKS-вход на localhost + один исходящий прокси)."""

from __future__ import annotations

from typing import Any

from .parser import ParseError, Proxy


def _bool(value: str | None) -> bool:
    return (value or "").strip().lower() in {"1", "true", "yes"}


def _alpn(value: str | None) -> list[str] | None:
    items = [a for a in (value or "").split(",") if a]
    return items or None


def _norm_pin(value: str | None) -> str | None:
    """SHA-256 отпечаток сертификата: hex без двоеточий, нижний регистр."""
    pin = (value or "").replace(":", "").strip().lower()
    return pin or None


def _wants_insecure(q: dict[str, str]) -> bool:
    return _bool(q.get("insecure")) or _bool(q.get("allowinsecure"))


def tls_server_name(p: Proxy) -> str:
    q = p.params
    if p.protocol == "hysteria2":
        return q.get("sni") or q.get("peer") or p.host
    return q.get("sni") or q.get("host") or p.host


def needs_cert_pin(p: Proxy) -> bool:
    """Ключ с insecure=1 поверх TCP+TLS: отпечаток можно снять рукопожатием.

    Xray 26.3+ удалил allowInsecure, вместо него нужен pinnedPeerCertSha256.
    """
    q = p.params
    return (
        p.protocol != "hysteria2"
        and (q.get("security") or "").lower() == "tls"
        and _wants_insecure(q)
        and not _norm_pin(q.get("pinsha256"))
    )


def _apply_cert_policy(tls: dict[str, Any], q: dict[str, str], pin: str | None) -> None:
    effective = _norm_pin(q.get("pinsha256")) or pin
    if effective:
        tls["pinnedPeerCertSha256"] = effective
    elif _wants_insecure(q):
        raise ParseError("insecure=1: Xray 26.3+ требует отпечаток сертификата (pinSHA256)")


def _stream_settings(p: Proxy, pin: str | None = None) -> dict[str, Any]:
    q = p.params

    if p.protocol == "hysteria2":
        sni = q.get("sni") or q.get("peer") or p.host
        tls: dict[str, Any] = {
            "serverName": sni,
            "alpn": _alpn(q.get("alpn")) or ["h3"],
        }
        _apply_cert_policy(tls, q, pin)
        stream: dict[str, Any] = {
            "network": "hysteria",
            "security": "tls",
            "tlsSettings": tls,
            "hysteriaSettings": {"version": 2, "auth": p.secret},
        }
        if q.get("obfs", "").lower() == "salamander":
            stream["finalmask"] = {
                "udp": [
                    {
                        "type": "salamander",
                        "settings": {"password": q.get("obfs-password", "")},
                    }
                ]
            }
        elif q.get("obfs"):
            raise ParseError(f"obfs={q['obfs']} не поддерживается")
        return stream

    # vless / trojan
    network = (q.get("type") or "tcp").lower()
    if network in {"raw", "tcp"}:
        network = "tcp"
    stream = {"network": network}

    host = q.get("host") or None
    path = q.get("path") or "/"
    if network == "ws":
        ws: dict[str, Any] = {"path": path}
        if host:
            ws["host"] = host
        stream["wsSettings"] = ws
    elif network == "grpc":
        stream["grpcSettings"] = {
            "serviceName": q.get("servicename") or q.get("path", ""),
            "multiMode": q.get("mode") == "multi",
        }
    elif network == "httpupgrade":
        hu: dict[str, Any] = {"path": path}
        if host:
            hu["host"] = host
        stream["httpupgradeSettings"] = hu
    elif network in {"xhttp", "splithttp"}:
        stream["network"] = "xhttp"
        xh: dict[str, Any] = {"path": path, "mode": q.get("mode") or "auto"}
        if host:
            xh["host"] = host
        stream["xhttpSettings"] = xh
    elif network == "tcp":
        if q.get("headertype") == "http":
            stream["tcpSettings"] = {
                "header": {
                    "type": "http",
                    "request": {
                        "path": [path],
                        "headers": {"Host": [host] if host else []},
                    },
                }
            }
    else:
        raise ParseError(f"транспорт {network!r} не поддерживается")

    security = (q.get("security") or "none").lower()
    if security == "tls":
        tls = {"serverName": tls_server_name(p)}
        _apply_cert_policy(tls, q, pin)
        if q.get("fp"):
            tls["fingerprint"] = q["fp"]
        alpn = _alpn(q.get("alpn"))
        if alpn:
            tls["alpn"] = alpn
        stream["security"] = "tls"
        stream["tlsSettings"] = tls
    elif security == "reality":
        if not q.get("pbk"):
            raise ParseError("reality без publicKey (pbk)")
        stream["security"] = "reality"
        stream["realitySettings"] = {
            "serverName": q.get("sni", ""),
            "fingerprint": q.get("fp") or "chrome",
            "publicKey": q["pbk"],
            "shortId": q.get("sid", ""),
            "spiderX": q.get("spx", ""),
        }
    elif security != "none":
        raise ParseError(f"security={security!r} не поддерживается")
    return stream


def _outbound(p: Proxy, pin: str | None = None) -> dict[str, Any]:
    if p.protocol == "vless":
        user: dict[str, Any] = {
            "id": p.secret,
            "encryption": p.params.get("encryption") or "none",
        }
        if p.params.get("flow"):
            user["flow"] = p.params["flow"]
        settings: dict[str, Any] = {
            "vnext": [{"address": p.host, "port": p.port, "users": [user]}]
        }
    elif p.protocol == "trojan":
        settings = {
            "servers": [{"address": p.host, "port": p.port, "password": p.secret}]
        }
    elif p.protocol == "hysteria2":
        settings = {"version": 2, "address": p.host, "port": p.port}
    else:  # pragma: no cover - парсер не пропустит другие протоколы
        raise ParseError(f"протокол {p.protocol!r} не поддерживается")

    protocol = "hysteria" if p.protocol == "hysteria2" else p.protocol
    return {
        "tag": "proxy",
        "protocol": protocol,
        "settings": settings,
        "streamSettings": _stream_settings(p, pin),
    }


def build_config(p: Proxy, socks_port: int, pin: str | None = None) -> dict[str, Any]:
    return {
        "log": {"loglevel": "none"},
        "inbounds": [
            {
                "tag": "socks-in",
                "listen": "127.0.0.1",
                "port": socks_port,
                "protocol": "socks",
                "settings": {"auth": "noauth", "udp": False},
            }
        ],
        "outbounds": [_outbound(p, pin)],
    }
