"""Разбор ссылок vless://, trojan://, hysteria2:// (hy2://) и подписок."""

from __future__ import annotations

import base64
import binascii
from dataclasses import dataclass, field
from urllib.parse import parse_qsl, unquote, urlsplit

SCHEMES = {
    "vless": "vless",
    "trojan": "trojan",
    "hysteria2": "hysteria2",
    "hy2": "hysteria2",
}


class ParseError(ValueError):
    """Ссылка не разобрана или протокол не поддерживается."""


@dataclass
class Proxy:
    protocol: str  # vless | trojan | hysteria2
    host: str
    port: int
    secret: str  # uuid (vless) или пароль (trojan / hysteria2)
    name: str = ""
    params: dict[str, str] = field(default_factory=dict)
    raw: str = ""  # исходная ссылка, её же пишем в working.txt

    @property
    def label(self) -> str:
        return self.name or f"{self.host}:{self.port}"


def _split_hostport(hostport: str) -> tuple[str, int]:
    """host:port, [ipv6]:port, а также host:443,20000-30000 (берём первый порт)."""
    hostport = hostport.strip()
    if hostport.startswith("["):
        end = hostport.find("]")
        if end == -1:
            raise ParseError("битый IPv6-адрес")
        host = hostport[1:end]
        rest = hostport[end + 1 :]
        if not rest.startswith(":"):
            raise ParseError("не указан порт")
        port_part = rest[1:]
    else:
        host, sep, port_part = hostport.rpartition(":")
        if not sep or not host:
            raise ParseError("не указан порт")
    first = port_part.split(",")[0].split("-")[0]
    try:
        port = int(first)
    except ValueError as exc:
        raise ParseError(f"некорректный порт: {port_part!r}") from exc
    if not 1 <= port <= 65535:
        raise ParseError(f"порт вне диапазона: {port}")
    return host, port


def parse_link(link: str) -> Proxy:
    link = link.strip()
    scheme, sep, _ = link.partition("://")
    scheme = scheme.lower()
    if not sep or scheme not in SCHEMES:
        raise ParseError(f"неподдерживаемая ссылка: {link[:30]!r}")

    parts = urlsplit(link)
    netloc = parts.netloc
    if "@" not in netloc:
        raise ParseError("в ссылке нет логина/пароля (часть до @)")
    userinfo, _, hostport = netloc.rpartition("@")
    host, port = _split_hostport(hostport)
    secret = unquote(userinfo)  # hysteria2 допускает "user:pass", оставляем как есть
    if not secret:
        raise ParseError("пустой uuid/пароль")

    params = {k.lower(): v for k, v in parse_qsl(parts.query, keep_blank_values=True)}
    return Proxy(
        protocol=SCHEMES[scheme],
        host=host,
        port=port,
        secret=secret,
        name=unquote(parts.fragment),
        params=params,
        raw=link,
    )


def _maybe_b64decode(text: str) -> str:
    """Подписки часто целиком закодированы в base64 (обычный или urlsafe)."""
    stripped = "".join(text.split())
    if not stripped or "://" in text:
        return text
    padded = stripped + "=" * (-len(stripped) % 4)
    for decoder in (base64.b64decode, base64.urlsafe_b64decode):
        try:
            return decoder(padded).decode("utf-8")
        except (binascii.Error, UnicodeDecodeError, ValueError):
            continue
    return text


def parse_text(text: str) -> tuple[list[Proxy], int]:
    """Возвращает (прокси без дублей, число пропущенных строк)."""
    text = _maybe_b64decode(text.strip())
    proxies: list[Proxy] = []
    seen: set[str] = set()
    skipped = 0
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        try:
            proxy = parse_link(line)
        except ParseError:
            skipped += 1
            continue
        key = f"{proxy.protocol}|{proxy.host}|{proxy.port}|{proxy.secret}"
        if key in seen:
            continue
        seen.add(key)
        proxies.append(proxy)
    return proxies, skipped
