"""Запуск Xray под каждый ключ и замер пинга и скорости через локальный SOCKS."""

from __future__ import annotations

import asyncio
import hashlib
import json
import shutil
import socket
import ssl
import statistics
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path

import httpx

from .parser import ParseError, Proxy
from .xray_config import build_config, needs_cert_pin, tls_server_name


@dataclass
class Options:
    xray_path: str
    timeout: float = 8.0
    test_url: str = "https://www.gstatic.com/generate_204"
    measure_speed: bool = True
    speed_url: str = "https://speed.cloudflare.com/__down?bytes=10000000"
    speed_seconds: float = 5.0
    ping_samples: int = 3
    startup_timeout: float = 5.0


@dataclass
class Result:
    proxy: Proxy
    ok: bool = False
    ping_ms: float | None = None
    speed_mbps: float | None = None
    error: str = ""


def find_xray(explicit: str | None) -> str | None:
    """Ищем xray: явный путь, затем PATH, затем текущая папка."""
    if explicit:
        return explicit if shutil.which(explicit) or Path(explicit).is_file() else None
    found = shutil.which("xray")
    if found:
        return found
    for name in ("xray", "xray.exe"):
        local = Path.cwd() / name
        if local.is_file():
            return str(local)
    return None


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


async def fetch_cert_sha256(host: str, port: int, server_name: str, timeout: float) -> str:
    """SHA-256 листового сертификата сервера (без проверки цепочки), hex.

    Нужен для ключей с insecure=1: Xray 26.3+ принимает только pinnedPeerCertSha256.
    """
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    _, writer = await asyncio.wait_for(
        asyncio.open_connection(host, port, ssl=ctx, server_hostname=server_name),
        timeout=timeout,
    )
    try:
        ssl_obj = writer.get_extra_info("ssl_object")
        der = ssl_obj.getpeercert(binary_form=True) if ssl_obj else None
        if not der:
            raise ssl.SSLError("сервер не отдал сертификат")
        return hashlib.sha256(der).hexdigest()
    finally:
        writer.close()


async def _wait_listening(proc: asyncio.subprocess.Process, port: int, timeout: float) -> str:
    """Ждём, пока Xray откроет SOCKS-порт. Возвращает текст ошибки или ''."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if proc.returncode is not None:
            err = b""
            if proc.stderr is not None:
                err = await proc.stderr.read()
            msg = err.decode("utf-8", "replace").strip().splitlines()
            return "xray не запустился: " + (msg[-1] if msg else f"код {proc.returncode}")
        try:
            _, writer = await asyncio.open_connection("127.0.0.1", port)
        except OSError:
            await asyncio.sleep(0.1)
            continue
        writer.close()
        return ""
    return "xray не открыл порт вовремя"


async def _measure_ping(client: httpx.AsyncClient, opts: Options) -> float:
    """Первый запрос поднимает туннель (прогрев), остальные дают время отклика."""
    resp = await client.get(opts.test_url)
    if resp.status_code >= 500:
        raise httpx.HTTPError(f"HTTP {resp.status_code}")
    samples: list[float] = []
    for _ in range(opts.ping_samples):
        start = time.perf_counter()
        await client.get(opts.test_url)
        samples.append((time.perf_counter() - start) * 1000)
    return statistics.median(samples)


async def _measure_speed(client: httpx.AsyncClient, opts: Options) -> float:
    """Качаем файл не дольше speed_seconds, считаем Мбит/с."""
    total = 0
    start = time.perf_counter()
    async with client.stream("GET", opts.speed_url) as resp:
        resp.raise_for_status()
        async for chunk in resp.aiter_bytes(65536):
            total += len(chunk)
            if time.perf_counter() - start >= opts.speed_seconds:
                break
    elapsed = time.perf_counter() - start
    if total == 0 or elapsed <= 0:
        raise httpx.HTTPError("нет данных")
    return total * 8 / elapsed / 1_000_000


async def _stop(proc: asyncio.subprocess.Process) -> None:
    if proc.returncode is not None:
        return
    proc.terminate()
    try:
        await asyncio.wait_for(proc.wait(), timeout=3)
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()


async def check_proxy(
    proxy: Proxy,
    opts: Options,
    sem: asyncio.Semaphore,
    speed_sem: asyncio.Semaphore,
) -> Result:
    result = Result(proxy=proxy)

    async with sem:
        pin: str | None = None
        if needs_cert_pin(proxy):
            try:
                pin = await fetch_cert_sha256(
                    proxy.host, proxy.port, tls_server_name(proxy), opts.timeout
                )
            except (OSError, ssl.SSLError, asyncio.TimeoutError) as exc:
                result.error = f"не получен сертификат сервера: {type(exc).__name__}"
                return result

        port = _free_port()
        try:
            config = build_config(proxy, port, pin)
        except ParseError as exc:
            result.error = str(exc)
            return result

        with tempfile.TemporaryDirectory(prefix="vpncheck-") as tmp:
            cfg_path = Path(tmp) / "config.json"
            cfg_path.write_text(json.dumps(config), encoding="utf-8")
            try:
                proc = await asyncio.create_subprocess_exec(
                    opts.xray_path,
                    "run",
                    "-c",
                    str(cfg_path),
                    stdout=asyncio.subprocess.DEVNULL,
                    stderr=asyncio.subprocess.PIPE,
                )
            except OSError as exc:
                result.error = f"не удалось запустить xray: {exc}"
                return result

            try:
                err = await _wait_listening(proc, port, opts.startup_timeout)
                if err:
                    result.error = err
                    return result

                async with httpx.AsyncClient(
                    proxy=f"socks5://127.0.0.1:{port}",
                    timeout=opts.timeout,
                    verify=True,
                ) as client:
                    try:
                        result.ping_ms = await _measure_ping(client, opts)
                        result.ok = True
                    except (httpx.HTTPError, OSError) as exc:
                        result.error = f"нет связи: {type(exc).__name__}"
                        return result

                    if opts.measure_speed:
                        async with speed_sem:
                            try:
                                result.speed_mbps = await _measure_speed(client, opts)
                            except (httpx.HTTPError, OSError) as exc:
                                result.error = f"скорость не измерена: {type(exc).__name__}"
            finally:
                await _stop(proc)
    return result
