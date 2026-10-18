"""Командная строка: python -m vpncheck --sub URL | --file keys.txt"""

from __future__ import annotations

import argparse
import asyncio
import csv
import sys
from pathlib import Path

import httpx

from . import __version__
from .checker import Options, Result, check_proxy, find_xray
from .parser import Proxy, parse_text

XRAY_RELEASES = "https://github.com/XTLS/Xray-core/releases"


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="vpncheck",
        description="Проверка VPN-ключей (vless, trojan, hysteria2) через ядро Xray.",
    )
    p.add_argument("--sub", action="append", default=[], metavar="URL",
                   help="ссылка на подписку (можно несколько раз)")
    p.add_argument("--file", action="append", default=[], metavar="PATH",
                   help="файл со ссылками или подпиской; '-' читает stdin")
    p.add_argument("--xray", metavar="PATH", help="путь к бинарнику xray")
    p.add_argument("-c", "--concurrency", type=int, default=20,
                   help="сколько ключей проверять одновременно (по умолчанию 20)")
    p.add_argument("--timeout", type=float, default=8.0,
                   help="таймаут запросов, сек (по умолчанию 8)")
    p.add_argument("--test-url", default=Options.test_url,
                   help="URL для проверки связи и пинга")
    p.add_argument("--no-speed", action="store_true", help="не измерять скорость")
    p.add_argument("--speed-url", default=Options.speed_url, help="файл для замера скорости")
    p.add_argument("--speed-time", type=float, default=5.0,
                   help="длительность замера скорости, сек (по умолчанию 5)")
    p.add_argument("--speed-workers", type=int, default=2,
                   help="сколько замеров скорости одновременно (по умолчанию 2)")
    p.add_argument("--sort", choices=["ping", "speed"], default="ping",
                   help="сортировка результата (по умолчанию ping)")
    p.add_argument("--max", type=int, default=0, metavar="N",
                   help="проверить только первые N ключей")
    p.add_argument("--out-dir", default=".", help="куда писать working.txt и report.csv")
    p.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    return p


def _load_inputs(args: argparse.Namespace) -> tuple[list[Proxy], int]:
    proxies: list[Proxy] = []
    skipped = 0
    seen: set[str] = set()

    def add(text: str) -> None:
        nonlocal skipped
        found, skip = parse_text(text)
        skipped += skip
        for px in found:
            key = f"{px.protocol}|{px.host}|{px.port}|{px.secret}"
            if key not in seen:
                seen.add(key)
                proxies.append(px)

    for url in args.sub:
        try:
            resp = httpx.get(url, timeout=30, follow_redirects=True,
                             headers={"User-Agent": "vpncheck/" + __version__})
            resp.raise_for_status()
        except httpx.HTTPError as exc:
            print(f"Не удалось скачать подписку {url}: {exc}", file=sys.stderr)
            continue
        add(resp.text)

    for path in args.file:
        if path == "-":
            add(sys.stdin.read())
            continue
        try:
            add(Path(path).read_text(encoding="utf-8"))
        except OSError as exc:
            print(f"Не удалось прочитать {path}: {exc}", file=sys.stderr)
    return proxies, skipped


def _sort_key(mode: str):
    if mode == "speed":
        return lambda r: (-(r.speed_mbps or 0), r.ping_ms or 1e9)
    return lambda r: (r.ping_ms or 1e9, -(r.speed_mbps or 0))


def _write_outputs(results: list[Result], out_dir: Path, sort_mode: str) -> int:
    out_dir.mkdir(parents=True, exist_ok=True)
    working = sorted((r for r in results if r.ok), key=_sort_key(sort_mode))
    (out_dir / "working.txt").write_text(
        "".join(r.proxy.raw + "\n" for r in working), encoding="utf-8"
    )
    ordered = working + [r for r in results if not r.ok]
    with (out_dir / "report.csv").open("w", newline="", encoding="utf-8-sig") as fh:
        writer = csv.writer(fh)
        writer.writerow(["name", "protocol", "host", "port", "status",
                         "ping_ms", "speed_mbps", "note"])
        for r in ordered:
            writer.writerow([
                r.proxy.name,
                r.proxy.protocol,
                r.proxy.host,
                r.proxy.port,
                "ok" if r.ok else "fail",
                "" if r.ping_ms is None else f"{r.ping_ms:.0f}",
                "" if r.speed_mbps is None else f"{r.speed_mbps:.1f}",
                r.error,
            ])
    return len(working)


async def _run(proxies: list[Proxy], opts: Options, args: argparse.Namespace) -> list[Result]:
    sem = asyncio.Semaphore(max(1, args.concurrency))
    speed_sem = asyncio.Semaphore(max(1, args.speed_workers))
    total = len(proxies)
    done = 0
    results: list[Result] = []

    async def worker(px: Proxy) -> None:
        nonlocal done
        res = await check_proxy(px, opts, sem, speed_sem)
        results.append(res)
        done += 1
        if res.ok:
            speed = f"{res.speed_mbps:6.1f} Мбит/с" if res.speed_mbps is not None else "      -     "
            line = f"OK    {res.ping_ms:5.0f} мс  {speed}"
        else:
            line = f"FAIL  {res.error}"
        print(f"[{done:>{len(str(total))}}/{total}] {line}  {px.label[:50]}", flush=True)

    await asyncio.gather(*(worker(px) for px in proxies))
    return results


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if not args.sub and not args.file:
        print("Укажите --sub URL или --file PATH (см. --help).", file=sys.stderr)
        return 2

    xray = find_xray(args.xray)
    if not xray:
        print(f"Не найден xray. Скачайте ядро: {XRAY_RELEASES}\n"
              "и положите рядом, добавьте в PATH или укажите --xray PATH.", file=sys.stderr)
        return 2

    proxies, skipped = _load_inputs(args)
    if args.max > 0:
        proxies = proxies[: args.max]
    if not proxies:
        print("Не найдено ни одной поддерживаемой ссылки.", file=sys.stderr)
        return 1
    print(f"Ключей к проверке: {len(proxies)} (пропущено неподдерживаемых строк: {skipped})")

    opts = Options(
        xray_path=xray,
        timeout=args.timeout,
        test_url=args.test_url,
        measure_speed=not args.no_speed,
        speed_url=args.speed_url,
        speed_seconds=args.speed_time,
    )
    try:
        results = asyncio.run(_run(proxies, opts, args))
    except KeyboardInterrupt:
        print("\nПрервано.", file=sys.stderr)
        return 130

    out_dir = Path(args.out_dir)
    good = _write_outputs(results, out_dir, args.sort)
    print(f"\nРабочих: {good} из {len(results)}. "
          f"Файлы: {out_dir / 'working.txt'}, {out_dir / 'report.csv'}")
    return 0 if good else 1


if __name__ == "__main__":
    raise SystemExit(main())
