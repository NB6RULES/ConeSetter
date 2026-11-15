"""Satellite imagery for the track map: Esri World Imagery tiles, stitched and cached on disk."""

from __future__ import annotations

import math
import os
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass

TILE_URL = "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}"
ATTRIBUTION = "Imagery © Esri, Maxar, Earthstar Geographics"
TILE_PX = 256
MAX_ZOOM = 19
MAX_TILES = 48


def tile_xy(lat: float, lon: float, z: int) -> tuple[float, float]:
    """Fractional Web Mercator tile coordinates."""
    n = 2 ** z
    lat = max(min(lat, 85.0511), -85.0511)
    x = (lon + 180.0) / 360.0 * n
    y = (1.0 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2.0 * n
    return x, y


def tile_latlon(x: float, y: float, z: int) -> tuple[float, float]:
    """Latitude / longitude of the north-west corner of tile (x, y)."""
    n = 2 ** z
    lon = x / n * 360.0 - 180.0
    lat = math.degrees(math.atan(math.sinh(math.pi * (1.0 - 2.0 * y / n))))
    return lat, lon


@dataclass(frozen=True)
class TileRange:
    z: int
    x0: int
    y0: int
    x1: int   # inclusive
    y1: int   # inclusive

    @property
    def cols(self) -> int:
        return self.x1 - self.x0 + 1

    @property
    def rows(self) -> int:
        return self.y1 - self.y0 + 1

    @property
    def count(self) -> int:
        return self.cols * self.rows

    def bounds(self) -> tuple[float, float, float, float]:
        """(south, west, north, east) of the stitched image."""
        north, west = tile_latlon(self.x0, self.y0, self.z)
        south, east = tile_latlon(self.x1 + 1, self.y1 + 1, self.z)
        return south, west, north, east

    def shallower(self) -> "TileRange":
        """The same area one zoom level out."""
        return TileRange(self.z - 1, self.x0 // 2, self.y0 // 2, self.x1 // 2, self.y1 // 2)


def range_for(south: float, west: float, north: float, east: float, max_zoom: int = MAX_ZOOM,
              max_tiles: int = MAX_TILES) -> TileRange:
    """The deepest zoom whose tiles cover the box without exceeding max_tiles."""
    for z in range(max_zoom, 0, -1):
        xa, ya = tile_xy(north, west, z)
        xb, yb = tile_xy(south, east, z)
        r = TileRange(z, int(math.floor(xa)), int(math.floor(ya)), int(math.floor(xb)), int(math.floor(yb)))
        if r.count <= max_tiles:
            return r
    return TileRange(0, 0, 0, 0, 0)


def padded_box(lat_min: float, lat_max: float, lon_min: float, lon_max: float,
               frac: float = 0.3, min_m: float = 40.0) -> tuple[float, float, float, float]:
    """(south, west, north, east) around a track, with a margin so the surroundings show."""
    m_lat = 111_195.0
    m_lon = m_lat * max(math.cos(math.radians((lat_min + lat_max) / 2)), 0.01)
    pad_lat = max((lat_max - lat_min) * frac, min_m / m_lat)
    pad_lon = max((lon_max - lon_min) * frac, min_m / m_lon)
    return lat_min - pad_lat, lon_min - pad_lon, lat_max + pad_lat, lon_max + pad_lon


def _fetch_tile(z: int, x: int, y: int, cache_dir: str | None, timeout: float) -> bytes:
    path = os.path.join(cache_dir, f"{z}_{x}_{y}.jpg") if cache_dir else None
    if path and os.path.exists(path) and os.path.getsize(path) > 0:
        with open(path, "rb") as f:
            return f.read()
    req = urllib.request.Request(TILE_URL.format(z=z, x=x, y=y), headers={"User-Agent": "OBRA-Run-Analyzer"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        data = r.read()
    if path and data:
        try:
            os.makedirs(cache_dir, exist_ok=True)
            tmp = f"{path}.{os.getpid()}.part"
            with open(tmp, "wb") as f:
                f.write(data)
            os.replace(tmp, path)
        except OSError:
            pass
    return data


def _drop_cached(r: TileRange, cache_dir: str | None):
    if not cache_dir:
        return
    for x in range(r.x0, r.x1 + 1):
        for y in range(r.y0, r.y1 + 1):
            try:
                os.remove(os.path.join(cache_dir, f"{r.z}_{x}_{y}.jpg"))
            except OSError:
                pass


def fetch(r: TileRange, cache_dir: str | None = None, timeout: float = 10.0, fetcher=_fetch_tile):
    """Downloads the tiles of r. Where the service has no imagery at that depth it sends the same
    placeholder for every tile; in that case this steps out a zoom level and tries again.
    Returns (range actually used, {(x, y): bytes})."""
    for _ in range(5):
        keys = [(x, y) for y in range(r.y0, r.y1 + 1) for x in range(r.x0, r.x1 + 1)]
        with ThreadPoolExecutor(max_workers=8) as pool:
            blobs = list(pool.map(lambda k: fetcher(r.z, k[0], k[1], cache_dir, timeout), keys))
        if len(blobs) >= 2 and len(set(blobs)) == 1 and r.z > 12:
            _drop_cached(r, cache_dir)
            r = r.shallower()
            continue
        return r, dict(zip(keys, blobs))
    return r, dict(zip(keys, blobs))
