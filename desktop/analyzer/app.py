"""Main window: run list, track map, playback, graphs, start / finish lines and laps."""

from __future__ import annotations

import json
import math
import os
import sys
from datetime import timezone

import numpy as np
import pyqtgraph as pg
from PySide6 import QtCore, QtGui, QtWidgets
from PySide6.QtCore import Qt

from . import __version__, canlog, tiles, updater
from .data import G, Run, load_path, safe_filename, site_key, to_local
from .laps import (Gate, Lap, best_lap, delta_to, find_laps, format_lap_time, gate_from_xy, lap_trace, laps_csv)

ACCENT = "#FF6B12"
BG = "#0E0F12"
SURFACE = "#1B1C21"
SURFACE_HI = "#26272E"
TEXT = "#F2F2F4"
MUTED = "#9A9CA6"
GREEN = "#35D07F"
RED = "#FF4D5E"
BLUE = "#4DA3FF"
LAP_COLORS = ["#FF6B12", "#4DA3FF", "#35D07F", "#E8C547", "#C77DFF", "#FF4D5E", "#3DD6D0", "#F28FB5",
              "#A3B86C", "#B0B4C0", "#FF9F6B", "#7C8CFF"]

UNITS = {"km/h": 3.6, "mph": 2.2369362921, "m/s": 1.0}

STYLE = f"""
* {{ font-family: "Segoe UI", "Inter", sans-serif; font-size: 10pt; color: {TEXT}; }}
QMainWindow, QWidget#root, QStackedWidget {{ background: {BG}; }}
QFrame#panel {{ background: {SURFACE}; border: 1px solid #2A2B33; border-radius: 12px; }}
QLabel#title {{ color: {MUTED}; font-size: 8pt; font-weight: 700; letter-spacing: 1px; }}
QLabel#muted {{ color: {MUTED}; }}
QLabel#big {{ font-size: 28pt; font-weight: 800; }}
QLabel#value {{ font-size: 12pt; font-weight: 700; }}
QLabel#hero {{ font-size: 20pt; font-weight: 800; }}
QPushButton {{ background: {SURFACE_HI}; border: 1px solid #34353E; border-radius: 8px; padding: 6px 12px; }}
QPushButton:hover {{ background: #30313A; }}
QPushButton:checked {{ background: {ACCENT}; border-color: {ACCENT}; color: white; font-weight: 700; }}
QPushButton:disabled {{ color: #5E606A; }}
QPushButton#primary {{ background: {ACCENT}; border-color: {ACCENT}; color: white; font-weight: 700; }}
QPushButton#primary:hover {{ background: #FF7F33; }}
QComboBox, QDoubleSpinBox {{ background: {SURFACE_HI}; border: 1px solid #34353E; border-radius: 8px; padding: 4px 8px; }}
QComboBox QAbstractItemView {{ background: {SURFACE_HI}; selection-background-color: {ACCENT}; }}
QListWidget, QTableWidget, QTreeWidget {{ background: {SURFACE}; border: 1px solid #2A2B33; border-radius: 10px; outline: none; }}
QTreeWidget::item {{ padding: 2px 0; }}
QTreeWidget::indicator {{ width: 12px; height: 12px; border: 1px solid #6A6C76; border-radius: 3px; background: {SURFACE_HI}; }}
QTreeWidget::indicator:checked {{ background: {ACCENT}; border-color: {ACCENT}; }}
QTreeWidget::item:selected {{ background: #3A2A20; color: {TEXT}; }}
QLineEdit {{ background: {SURFACE_HI}; border: 1px solid #34353E; border-radius: 8px; padding: 5px 8px; }}
QListWidget::item {{ padding: 8px; border-bottom: 1px solid #25262D; }}
QListWidget::item:selected, QTableWidget::item:selected {{ background: #3A2A20; color: {TEXT}; }}
QHeaderView::section {{ background: {SURFACE_HI}; border: none; padding: 5px; color: {MUTED}; font-weight: 700; }}
QTableWidget {{ gridline-color: #25262D; }}
QTabWidget::pane {{ border: 1px solid #2A2B33; border-radius: 10px; background: {SURFACE}; }}
QTabBar::tab {{ background: transparent; padding: 7px 16px; color: {MUTED}; font-weight: 700; }}
QTabBar::tab:selected {{ color: {TEXT}; border-bottom: 2px solid {ACCENT}; }}
QSlider::groove:horizontal {{ height: 6px; background: {SURFACE_HI}; border-radius: 3px; }}
QSlider::sub-page:horizontal {{ background: {ACCENT}; border-radius: 3px; }}
QSlider::handle:horizontal {{ width: 16px; margin: -6px 0; border-radius: 8px; background: white; }}
QCheckBox::indicator {{ width: 16px; height: 16px; }}
QSplitter::handle {{ background: {BG}; }}
QScrollArea {{ background: {BG}; border: none; }}
QToolTip {{ background: {SURFACE_HI}; color: {TEXT}; border: 1px solid #34353E; }}
QScrollBar:vertical {{ background: transparent; width: 10px; }}
QScrollBar::handle:vertical {{ background: #3A3B45; border-radius: 5px; min-height: 24px; }}
QScrollBar::add-line, QScrollBar::sub-line {{ height: 0; }}
"""


def heat_color(x: float) -> QtGui.QColor:
    """0 = blue (slow) to 1 = red (fast): the same scale as the phone app."""
    x = 0.0 if not math.isfinite(x) else min(max(x, 0.0), 1.0)
    return QtGui.QColor.fromHsvF((1 - x) * 240.0 / 360.0, 0.92, 1.0)


def diverging_color(x: float) -> QtGui.QColor:
    """-1 = red, 0 = grey, +1 = green."""
    x = 0.0 if not math.isfinite(x) else min(max(x, -1.0), 1.0)
    base = QtGui.QColor(GREEN) if x >= 0 else QtGui.QColor(RED)
    grey = QtGui.QColor("#6A6C76")
    a = abs(x)
    return QtGui.QColor(int(grey.red() + (base.red() - grey.red()) * a),
                        int(grey.green() + (base.green() - grey.green()) * a),
                        int(grey.blue() + (base.blue() - grey.blue()) * a))


def panel(*widgets, title: str | None = None, margins=(12, 10, 12, 12), spacing=8) -> QtWidgets.QFrame:
    f = QtWidgets.QFrame()
    f.setObjectName("panel")
    lay = QtWidgets.QVBoxLayout(f)
    lay.setContentsMargins(*margins)
    lay.setSpacing(spacing)
    if title:
        lay.addWidget(label(title.upper(), "title"))
    for w in widgets:
        if isinstance(w, QtWidgets.QLayout):
            lay.addLayout(w)
        else:
            lay.addWidget(w)
    return f


def label(text: str = "", name: str | None = None, wrap: bool = False) -> QtWidgets.QLabel:
    l = QtWidgets.QLabel(text)
    if name:
        l.setObjectName(name)
    l.setWordWrap(wrap)
    return l


def row(*widgets, spacing=6) -> QtWidgets.QHBoxLayout:
    h = QtWidgets.QHBoxLayout()
    h.setSpacing(spacing)
    h.setContentsMargins(0, 0, 0, 0)
    for w in widgets:
        if w is None:
            h.addStretch(1)
        elif isinstance(w, QtWidgets.QLayout):
            h.addLayout(w)
        else:
            h.addWidget(w)
    return h


class _stretch(QtWidgets.QHBoxLayout):
    """A layout holding one widget that takes all spare width."""
    def __init__(self, w):
        super().__init__()
        self.setContentsMargins(0, 0, 0, 0)
        self.addWidget(w, 1)


class Tile(QtWidgets.QFrame):
    def __init__(self, title: str):
        super().__init__()
        self.setObjectName("panel")
        lay = QtWidgets.QVBoxLayout(self)
        lay.setContentsMargins(10, 5, 10, 6)
        lay.setSpacing(1)
        lay.addWidget(label(title.upper(), "title"))
        self.value = label("–", "value")
        lay.addWidget(self.value)
        self.setMinimumHeight(54)

    def set(self, text: str):
        self.value.setText(text)


def make_plot(left: str | None = None) -> pg.PlotWidget:
    p = pg.PlotWidget()
    p.setBackground(SURFACE)
    p.setMenuEnabled(False)
    p.hideButtons()
    p.showGrid(x=True, y=True, alpha=0.12)
    for ax in ("left", "bottom"):
        p.getAxis(ax).setPen(pg.mkPen("#3A3B45"))
        p.getAxis(ax).setTextPen(pg.mkPen(MUTED))
    p.getAxis("left").setWidth(48)
    p.getAxis("left").enableAutoSIPrefix(False)
    p.getAxis("bottom").enableAutoSIPrefix(False)
    if left:
        p.setLabel("left", left, color=MUTED)
    return p


class Worker(QtCore.QThread):
    """Runs one function off the UI thread."""
    done = QtCore.Signal(object)
    failed = QtCore.Signal(str)
    progress = QtCore.Signal(object, object)

    def __init__(self, fn):
        super().__init__()
        self.fn = fn

    def run(self):
        try:
            self.done.emit(self.fn())
        except Exception as e:  # noqa: BLE001 - reported to the user by the caller
            self.failed.emit(str(getattr(e, "reason", None) or e) or type(e).__name__)


def stitch_tiles(rng, cache_dir: str):
    """Downloads and joins the tiles into one image. Returns (range used, RGBA array with row 0 at the south edge)."""
    used, blobs = tiles.fetch(rng, cache_dir)
    canvas = QtGui.QImage(used.cols * tiles.TILE_PX, used.rows * tiles.TILE_PX, QtGui.QImage.Format_RGBA8888)
    canvas.fill(QtGui.QColor(SURFACE))
    painter = QtGui.QPainter(canvas)
    drawn = 0
    for (x, y), data in blobs.items():
        img = QtGui.QImage()
        if data and img.loadFromData(data):
            painter.drawImage(QtCore.QRect((x - used.x0) * tiles.TILE_PX, (y - used.y0) * tiles.TILE_PX,
                                           tiles.TILE_PX, tiles.TILE_PX), img)
            drawn += 1
    painter.end()
    if drawn == 0:
        raise OSError("the map service returned no usable images")
    w, h = canvas.width(), canvas.height()
    buf = np.frombuffer(canvas.constBits(), dtype=np.uint8, count=h * canvas.bytesPerLine())
    arr = buf.reshape(h, canvas.bytesPerLine())[:, :w * 4].reshape(h, w, 4)
    return used, np.ascontiguousarray(arr[::-1])


class MainWindow(QtWidgets.QMainWindow):
    def __init__(self, persist: bool = True):
        super().__init__()
        self.setWindowTitle(f"OBRA Run Analyzer {__version__}")
        self.resize(1500, 920)
        self.setMinimumSize(1000, 640)
        self.setAcceptDrops(True)
        self.persist = persist
        self.settings = QtCore.QSettings("OBRA", "RunAnalyzer")

        self.runs: list[Run] = []
        self.run: Run | None = None
        self.t = 0.0
        self.t_lo = 0.0
        self.t_hi = 0.0
        self.laps: list[Lap] = []
        self.gates: dict[str, dict] = {}
        self.pick_mode: str | None = None
        self.unit = "km/h"
        self._updating = False
        self._lap_lines: list = []
        self._gate_items: list = []
        self.satellite = True
        self._sat_cache: dict = {}
        self._sat_pending: set = set()
        self._sat_status = ""
        self.dbc: canlog.Dbc | None = None
        self.carlog: canlog.CarLog | None = None
        self.car_offsets: dict[int, float] = {}
        self.car_plots: list = []
        self._car_status = ""
        self._car_values_at = 0.0
        self._load_settings()

        self._build()
        self._shortcuts()
        self.timer = QtCore.QTimer(self)
        self.timer.setInterval(25)
        self.timer.timeout.connect(self._tick)
        self.clock = QtCore.QElapsedTimer()
        self._show_run(None)
        self.pending_release: updater.Release | None = None
        self._update_threads: list = []
        if self.persist and updater.BUILD:
            QtCore.QTimer.singleShot(1500, lambda: self.check_updates(manual=False))

    # ------------------------------------------------------------ updates

    def check_updates(self, manual: bool):
        if manual and self.pending_release is not None:
            self._offer_update(self.pending_release, manual=True)
            return
        if manual and not updater.BUILD:
            QtWidgets.QMessageBox.information(self, "Updates", "This copy is running from source, so it doesn't update itself.")
            return
        th = Worker(updater.fetch_latest)
        th.done.connect(lambda rel: self._update_checked(rel, manual))
        th.failed.connect(lambda msg: manual and QtWidgets.QMessageBox.warning(
            self, "Updates", f"Couldn't check for updates.\n{msg}"))
        self._keep(th)
        th.start()

    def _keep(self, th):
        self._update_threads.append(th)
        th.finished.connect(lambda: self._update_threads.remove(th) if th in self._update_threads else None)

    def _update_checked(self, rel, manual: bool):
        if not updater.is_newer(rel):
            if manual:
                QtWidgets.QMessageBox.information(self, "Updates", f"You have the newest version, {updater.current_label()}.")
            return
        self.pending_release = rel
        self.update_btn.setText(f"Update to {rel.version} available")
        self.update_btn.setFlat(False)
        self.update_btn.setStyleSheet(f"background: {ACCENT}; border: 1px solid {ACCENT}; color: white; font-weight: 700; "
                                      "border-radius: 8px; padding: 6px 12px;")
        if not manual and int(self.settings.value("skipBuild", 0) or 0) == rel.build:
            return
        self._offer_update(rel, manual)

    def _offer_update(self, rel, manual: bool):
        box = QtWidgets.QMessageBox(self)
        box.setWindowTitle("Update available")
        box.setIcon(QtWidgets.QMessageBox.Information)
        box.setText(f"OBRA Run Analyzer {rel.label} is available.")
        info = f"You have {updater.current_label()}."
        if rel.notes:
            info += f"\n\nWhat's new:\n{rel.notes}"
        can = updater.can_self_update()
        if not can:
            info += "\n\nThis copy can't replace itself here, so the download page will open instead."
        box.setInformativeText(info)
        now = box.addButton("Update now" if can else "Open download page", QtWidgets.QMessageBox.AcceptRole)
        box.addButton("Later", QtWidgets.QMessageBox.RejectRole)
        skip = box.addButton("Skip this version", QtWidgets.QMessageBox.DestructiveRole)
        box.exec()
        if box.clickedButton() is skip:
            self.settings.setValue("skipBuild", rel.build)
        elif box.clickedButton() is now:
            if can:
                self._install_update(rel)
            else:
                QtGui.QDesktopServices.openUrl(QtCore.QUrl(updater.DOWNLOAD_PAGE))

    def _install_update(self, rel):
        dest = updater.staging_path()
        dlg = QtWidgets.QProgressDialog("Downloading the update…", "Cancel", 0, 100, self)
        dlg.setWindowTitle("Updating")
        dlg.setWindowModality(Qt.WindowModal)
        dlg.setMinimumDuration(0)
        dlg.setAutoClose(False)
        dlg.setAutoReset(False)
        th = Worker(lambda: updater.download(rel, dest, progress=lambda d, t: th.progress.emit(d, t),
                                             cancelled=dlg.wasCanceled))
        th.progress.connect(lambda d, t: (dlg.setValue(int(d * 100 / t)) if t else None,
                                          dlg.setLabelText(f"Downloading the update…  {d / 1e6:.0f} of {t / 1e6:.0f} MB" if t else
                                                           f"Downloading the update…  {d / 1e6:.0f} MB")))

        def finished(_):
            dlg.close()
            updater.swap_and_restart(dest)
            QtWidgets.QApplication.quit()

        def failed(msg):
            dlg.close()
            if "cancelled" in msg:
                return
            r = QtWidgets.QMessageBox.warning(self, "Update failed", f"The update couldn't be downloaded.\n{msg}\n\nOpen the download page instead?",
                                              QtWidgets.QMessageBox.Yes | QtWidgets.QMessageBox.No)
            if r == QtWidgets.QMessageBox.Yes:
                QtGui.QDesktopServices.openUrl(QtCore.QUrl(updater.DOWNLOAD_PAGE))

        th.done.connect(finished)
        th.failed.connect(failed)
        self._keep(th)
        th.start()

    # ------------------------------------------------------------ settings

    def _load_settings(self):
        if not self.persist:
            return
        try:
            raw = json.loads(self.settings.value("gates", "{}") or "{}")
            for key, g in raw.items():
                self.gates[key] = {
                    "start": Gate.from_dict(g["start"]) if g.get("start") else None,
                    "finish": Gate.from_dict(g["finish"]) if g.get("finish") else None,
                }
        except Exception:  # noqa: BLE001 - a damaged settings entry must not stop the app opening
            self.gates = {}
        self.satellite = str(self.settings.value("satellite", "true")).lower() != "false"
        u = self.settings.value("unit", "km/h")
        self.unit = u if u in UNITS else "km/h"

    def _save_settings(self):
        if not self.persist:
            return
        raw = {k: {"start": g["start"].to_dict() if g.get("start") else None,
                   "finish": g["finish"].to_dict() if g.get("finish") else None}
               for k, g in self.gates.items()}
        self.settings.setValue("gates", json.dumps(raw))
        self.settings.setValue("unit", self.unit)
        self.settings.setValue("satellite", "true" if self.satellite else "false")

    # ------------------------------------------------------------ build

    def _build(self):
        root = QtWidgets.QWidget()
        root.setObjectName("root")
        self.setCentralWidget(root)
        outer = QtWidgets.QVBoxLayout(root)
        outer.setContentsMargins(10, 10, 10, 10)
        outer.setSpacing(8)

        # top bar
        self.open_btn = QtWidgets.QPushButton("Open runs…")
        self.open_btn.setObjectName("primary")
        self.open_btn.clicked.connect(self.open_dialog)
        self.car_btn = QtWidgets.QPushButton("Open car log…")
        self.car_btn.setToolTip("Open an MF4 log from the car and the DBC that describes it")
        self.car_btn.clicked.connect(self.open_car_dialog)
        self.unit_box = QtWidgets.QComboBox()
        self.unit_box.addItems(list(UNITS))
        self.unit_box.setCurrentText(self.unit)
        self.unit_box.currentTextChanged.connect(self._unit_changed)
        self.color_box = QtWidgets.QComboBox()
        self.color_box.addItems(["Speed", "Acceleration / braking", "Cornering"])
        self.color_box.currentIndexChanged.connect(lambda _: self._draw_track())
        self.map_box = QtWidgets.QComboBox()
        self.map_box.addItems(["Satellite", "Plain"])
        self.map_box.setCurrentIndex(0 if self.satellite else 1)
        self.map_box.currentIndexChanged.connect(self._map_style_changed)
        self.x_box = QtWidgets.QComboBox()
        self.x_box.addItems(["Time", "Distance"])
        self.x_box.currentIndexChanged.connect(lambda _: self._draw_traces())
        self.heading = label("OBRA Run Analyzer", "value")
        self.heading.setSizePolicy(QtWidgets.QSizePolicy.Ignored, QtWidgets.QSizePolicy.Preferred)
        self.heading.setMinimumWidth(120)
        self.update_btn = QtWidgets.QPushButton(f"v{updater.current_label()}")
        self.update_btn.setToolTip("Check for updates")
        self.update_btn.setFlat(True)
        self.update_btn.clicked.connect(lambda: self.check_updates(manual=True))
        outer.addLayout(row(self.open_btn, self.car_btn, _stretch(self.heading), self.update_btn,
                            label("Map", "muted"), self.map_box,
                            label("Colour track by", "muted"), self.color_box,
                            label("Graphs against", "muted"), self.x_box,
                            label("Units", "muted"), self.unit_box, spacing=8))

        self.stack = QtWidgets.QStackedWidget()
        outer.addWidget(self.stack, 1)

        # welcome page
        w = QtWidgets.QWidget()
        wl = QtWidgets.QVBoxLayout(w)
        wl.addStretch(1)
        t1 = label("Open your speed runs", "hero")
        t1.setAlignment(Qt.AlignCenter)
        t2 = label("Drop a .zip from “Save as zip” in the phone app here, or a single .csv, .xlsx or .gpx export.\n"
                   "Then play the run back, and set a start / finish line to get lap times.\n"
                   "Car logs work too: drop an .mf4 and its .dbc to see the CAN signals, with or without a GPS run.", "muted")
        t2.setAlignment(Qt.AlignCenter)
        b = QtWidgets.QPushButton("Open runs…")
        b.setObjectName("primary")
        b.setFixedWidth(180)
        b.clicked.connect(self.open_dialog)
        wl.addWidget(t1)
        wl.addWidget(t2)
        wl.addSpacing(10)
        wl.addLayout(row(None, b, None))
        wl.addStretch(1)
        self.stack.addWidget(w)

        # main page
        main = QtWidgets.QSplitter(Qt.Horizontal)
        main.setChildrenCollapsible(False)
        self.stack.addWidget(main)
        main.addWidget(self._build_left())
        main.addWidget(self._build_centre())
        main.addWidget(self._build_right())
        main.setStretchFactor(0, 0)
        main.setStretchFactor(1, 1)
        main.setStretchFactor(2, 0)
        main.setSizes([280, 830, 380])

        outer.addWidget(self._build_transport())

    def _build_left(self) -> QtWidgets.QWidget:
        w = QtWidgets.QWidget()
        lay = QtWidgets.QVBoxLayout(w)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(8)
        self.run_list = QtWidgets.QListWidget()
        self.run_list.currentRowChanged.connect(self._run_selected)
        self.run_list.setWordWrap(True)
        self.run_list.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        self.run_list.setTextElideMode(Qt.ElideRight)
        lay.addWidget(label("RUNS", "title"))
        lay.addWidget(self.run_list, 1)
        self.info = label("", "muted", wrap=True)
        self.info.setTextFormat(Qt.RichText)
        self.info.setAlignment(Qt.AlignTop)
        lay.addWidget(panel(self.info, title="Run details"))
        w.setMinimumWidth(220)
        return w

    def _build_centre(self) -> QtWidgets.QWidget:
        split = QtWidgets.QSplitter(Qt.Vertical)
        split.setChildrenCollapsible(False)

        self.map = pg.PlotWidget()
        self.map.setBackground(SURFACE)
        self.map.setAspectLocked(True)
        self.map.setMenuEnabled(False)
        self.map.hideButtons()
        self.map.hideAxis("left")
        self.map.hideAxis("bottom")
        self.sat_item = pg.ImageItem(axisOrder="row-major")
        self.sat_item.setZValue(-10)
        self.sat_item.setVisible(False)
        self.map.addItem(self.sat_item, ignoreBounds=True)
        self.hl_item = pg.PlotDataItem(pen=pg.mkPen("#FFFFFF", width=11, cap=Qt.RoundCap, join=Qt.RoundJoin))
        self.hl_item.setOpacity(0.55)
        self.hl_item.setZValue(1)
        self.track_item = pg.ScatterPlotItem(pen=None, size=6, pxMode=True)
        self.track_item.setZValue(2)
        self.marker = pg.ScatterPlotItem(size=18, pen=pg.mkPen("white", width=3), brush=pg.mkBrush(ACCENT))
        self.marker.setZValue(10)
        for it in (self.hl_item, self.track_item, self.marker):
            self.map.addItem(it)
        self.scale = pg.ScaleBar(size=50, suffix="m", brush=pg.mkBrush(TEXT), pen=pg.mkPen(TEXT))
        self.scale.setParentItem(self.map.getPlotItem().vb)
        self.scale.anchor((1, 1), (1, 1), offset=(-20, -16))
        self.legend = label("", "muted")
        self.legend.setSizePolicy(QtWidgets.QSizePolicy.Ignored, QtWidgets.QSizePolicy.Preferred)
        self.legend.setMinimumWidth(80)
        self.credit = label("", "muted")
        self.credit.setAlignment(Qt.AlignRight | Qt.AlignVCenter)
        self.map.scene().sigMouseClicked.connect(self._map_clicked)
        mp = QtWidgets.QWidget()
        ml = QtWidgets.QVBoxLayout(mp)
        ml.setContentsMargins(0, 0, 0, 0)
        ml.setSpacing(4)
        ml.addWidget(self.map, 1)
        foot = QtWidgets.QHBoxLayout()
        foot.setContentsMargins(0, 0, 0, 0)
        foot.addWidget(self.legend, 1)
        foot.addWidget(self.credit, 0)
        ml.addLayout(foot)
        split.addWidget(mp)

        self.tabs = QtWidgets.QTabWidget()
        # traces
        tw = QtWidgets.QWidget()
        tl = QtWidgets.QVBoxLayout(tw)
        tl.setContentsMargins(6, 6, 6, 6)
        tl.setSpacing(2)
        self.p_speed = make_plot("Speed")
        self.p_acc = make_plot("g")
        self.p_elev = make_plot("Elev m")
        self.p_acc.setXLink(self.p_speed)
        self.p_elev.setXLink(self.p_speed)
        self.c_speed = self.p_speed.plot(pen=pg.mkPen(ACCENT, width=2))
        self.c_long = self.p_acc.plot(pen=pg.mkPen(GREEN, width=1.6), name="Longitudinal")
        self.c_lat = self.p_acc.plot(pen=pg.mkPen(BLUE, width=1.6), name="Lateral")
        self.c_elev = self.p_elev.plot(pen=pg.mkPen("#B0B4C0", width=1.6))
        self.cursors = []
        for p in (self.p_speed, self.p_acc, self.p_elev):
            p.setDownsampling(auto=True, mode="peak")
            p.setClipToView(True)
            line = pg.InfiniteLine(angle=90, movable=True, pen=pg.mkPen("white", width=1.5),
                                   hoverPen=pg.mkPen(ACCENT, width=2))
            line.setZValue(20)
            line.sigDragged.connect(self._cursor_dragged)
            p.addItem(line)
            self.cursors.append(line)
            p.scene().sigMouseClicked.connect(lambda ev, plot=p: self._plot_clicked(ev, plot))
        self.p_speed.getAxis("bottom").setStyle(showValues=False)
        self.p_acc.getAxis("bottom").setStyle(showValues=False)
        self.p_speed.sigXRangeChanged.connect(lambda _, rng: self._sync_x(getattr(self, "_car_master", None), rng))
        tl.addWidget(self.p_speed, 5)
        tl.addWidget(self.p_acc, 4)
        tl.addWidget(self.p_elev, 3)
        tl.addWidget(label("Orange: speed.  Green: longitudinal g (+ accelerating, − braking).  Blue: lateral g (+ left).  "
                           "Click or drag on a graph to move the car.", "muted"))
        self.tabs.addTab(tw, "Run graphs")
        # compare
        cw = QtWidgets.QWidget()
        cl = QtWidgets.QVBoxLayout(cw)
        cl.setContentsMargins(6, 6, 6, 6)
        cl.setSpacing(2)
        self.p_cmp = make_plot("Speed")
        self.p_delta = make_plot("Δ s")
        self.p_delta.setXLink(self.p_cmp)
        self.p_cmp.addLegend(offset=(-10, 10), labelTextColor=TEXT, brush=pg.mkBrush(SURFACE_HI))
        self.p_cmp.getAxis("bottom").setStyle(showValues=False)
        self.p_delta.setLabel("bottom", "Distance into the lap (m)", color=MUTED)
        self.cmp_hint = label("", "muted", wrap=True)
        cl.addWidget(self.p_cmp, 3)
        cl.addWidget(self.p_delta, 2)
        cl.addWidget(self.cmp_hint)
        self.tabs.addTab(cw, "Lap compare")
        self.tabs.addTab(self._build_car_tab(), "Car data")
        self.tabs.currentChanged.connect(lambda _: self._update_car_values(force=True))
        split.addWidget(self.tabs)
        split.setSizes([470, 380])
        self.centre_split = split
        self.tabs.currentChanged.connect(lambda _: self._balance_centre())
        return split

    def _balance_centre(self):
        """Gives the Car data tab more room; a car log without GPS needs almost no map."""
        total = sum(self.centre_split.sizes()) or 850
        if self.run is not None and not self.run.has_gps:
            share = 0.14
        elif self.tabs.currentIndex() == 2:
            share = 0.36
        else:
            share = 0.55
        self.centre_split.setSizes([int(total * share), int(total * (1 - share))])

    def _build_right(self) -> QtWidgets.QWidget:
        w = QtWidgets.QWidget()
        lay = QtWidgets.QVBoxLayout(w)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(8)

        self.speed_big = label("0.0", "big")
        self.speed_unit = label(self.unit, "muted")
        self.tiles = {k: Tile(k) for k in ("Time", "Distance", "Accel / brake", "Cornering", "Elevation", "Lap")}
        grid = QtWidgets.QGridLayout()
        grid.setSpacing(6)
        for i, t in enumerate(self.tiles.values()):
            grid.addWidget(t, i // 2, i % 2)

        self.gg = pg.PlotWidget()
        self.gg.setBackground(SURFACE)
        self.gg.setAspectLocked(True)
        self.gg.setMenuEnabled(False)
        self.gg.hideButtons()
        self.gg.setMouseEnabled(False, False)
        self.gg.hideAxis("left")
        self.gg.hideAxis("bottom")
        self.gg.setFixedHeight(128)
        self.gg_cloud = pg.ScatterPlotItem(size=3, pen=None, brush=pg.mkBrush(255, 255, 255, 45))
        self.gg_trail = pg.PlotDataItem(pen=pg.mkPen(ACCENT, width=2))
        self.gg_dot = pg.ScatterPlotItem(size=12, pen=pg.mkPen("white", width=2), brush=pg.mkBrush(ACCENT))
        self._gg_rings: list = []
        for it in (self.gg_cloud, self.gg_trail, self.gg_dot):
            self.gg.addItem(it)

        speed_col = QtWidgets.QVBoxLayout()
        speed_col.setSpacing(0)
        speed_col.addWidget(label("SPEED", "title"))
        speed_col.addWidget(self.speed_big)
        speed_col.addWidget(self.speed_unit)
        speed_col.addStretch(1)
        gg_col = QtWidgets.QVBoxLayout()
        gg_col.setSpacing(2)
        gg_col.addWidget(label("G-G", "title"))
        gg_col.addWidget(self.gg)
        top = QtWidgets.QHBoxLayout()
        top.addLayout(speed_col, 2)
        top.addLayout(gg_col, 3)
        lay.addWidget(panel(top, grid))

        # start / finish
        self.pick_start = QtWidgets.QPushButton("Click on map")
        self.pick_start.setCheckable(True)
        self.pick_start.clicked.connect(lambda on: self._set_pick("start" if on else None))
        self.start_here = QtWidgets.QPushButton("At car")
        self.start_here.clicked.connect(lambda: self._gate_at_cursor("start"))
        self.pick_finish = QtWidgets.QPushButton("Click on map")
        self.pick_finish.setCheckable(True)
        self.pick_finish.clicked.connect(lambda on: self._set_pick("finish" if on else None))
        self.finish_here = QtWidgets.QPushButton("At car")
        self.finish_here.clicked.connect(lambda: self._gate_at_cursor("finish"))
        self.finish_clear = QtWidgets.QPushButton("Remove")
        self.finish_clear.clicked.connect(lambda: self._clear_gate("finish"))
        self.width_box = QtWidgets.QDoubleSpinBox()
        self.width_box.setRange(2, 60)
        self.width_box.setSingleStep(1)
        self.width_box.setDecimals(0)
        self.width_box.setSuffix(" m wide")
        self.width_box.setValue(12)
        self.width_box.valueChanged.connect(self._width_changed)
        self.both_ways = QtWidgets.QCheckBox("Either direction")
        self.both_ways.toggled.connect(lambda _: self._recompute_laps())
        self.clear_all = QtWidgets.QPushButton("Clear lines")
        self.clear_all.clicked.connect(lambda: self._clear_gate("all"))
        self.gate_hint = label("", "muted", wrap=True)
        lay.addWidget(panel(
            row(label("Start line"), None, self.pick_start, self.start_here),
            row(label("Finish line"), None, self.pick_finish, self.finish_here, self.finish_clear),
            row(self.width_box, self.both_ways, None, self.clear_all),
            self.gate_hint,
            title="Start / finish"))

        # laps
        self.lap_table = QtWidgets.QTableWidget(0, 7)
        self.lap_table.setHorizontalHeaderLabels(["Lap", "Time", "Δ best", "Top", "Avg", "Min", "Lat g"])
        self.lap_table.verticalHeader().setVisible(False)
        self.lap_table.setSelectionBehavior(QtWidgets.QAbstractItemView.SelectRows)
        self.lap_table.setSelectionMode(QtWidgets.QAbstractItemView.ExtendedSelection)
        self.lap_table.setEditTriggers(QtWidgets.QAbstractItemView.NoEditTriggers)
        self.lap_table.setShowGrid(False)
        hh = self.lap_table.horizontalHeader()
        hh.setSectionResizeMode(QtWidgets.QHeaderView.Stretch)
        for c in (0, 1, 2):
            hh.setSectionResizeMode(c, QtWidgets.QHeaderView.ResizeToContents)
        self.lap_table.setMinimumHeight(170)
        self.lap_table.itemSelectionChanged.connect(self._laps_selected)
        self.whole_btn = QtWidgets.QPushButton("Whole run")
        self.whole_btn.clicked.connect(self.lap_table.clearSelection)
        self.export_btn = QtWidgets.QPushButton("Export laps…")
        self.export_btn.clicked.connect(self._export_laps)
        self.lap_summary = label("", "muted", wrap=True)
        lp = panel(self.lap_table, self.lap_summary, row(self.whole_btn, None, self.export_btn), title="Laps")
        lay.addWidget(lp, 1)
        w.setObjectName("root")
        # On small or scaled-up screens the column scrolls instead of squashing its contents.
        scroll = QtWidgets.QScrollArea()
        scroll.setWidget(w)
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QtWidgets.QFrame.NoFrame)
        scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        scroll.setMinimumWidth(372)
        return scroll

    def _build_transport(self) -> QtWidgets.QWidget:
        self.play_btn = QtWidgets.QPushButton("▶  Play")
        self.play_btn.setObjectName("primary")
        self.play_btn.setFixedWidth(110)
        self.play_btn.clicked.connect(self.toggle_play)
        self.slider = QtWidgets.QSlider(Qt.Horizontal)
        self.slider.setRange(0, 10000)
        self.slider.valueChanged.connect(self._slider_moved)
        self.time_label = label("0.0 / 0.0 s")
        self.time_label.setMinimumWidth(130)
        self.rate_box = QtWidgets.QComboBox()
        self.rate_box.addItems(["0.25×", "0.5×", "1×", "2×", "4×", "8×"])
        self.rate_box.setCurrentText("1×")
        self.loop_box = QtWidgets.QCheckBox("Loop")
        self.loop_box.setChecked(True)
        bar = panel(row(self.play_btn, self.slider, self.time_label, self.rate_box, self.loop_box, spacing=12),
                    margins=(12, 8, 12, 8))
        return bar

    def _shortcuts(self):
        def sc(key, fn):
            s = QtGui.QShortcut(QtGui.QKeySequence(key), self)
            s.setContext(Qt.ApplicationShortcut)
            s.activated.connect(fn)
        sc("Space", self.toggle_play)
        sc("Ctrl+O", self.open_dialog)
        sc("Left", lambda: self.seek(self.t - 0.1))
        sc("Right", lambda: self.seek(self.t + 0.1))
        sc("Shift+Left", lambda: self.seek(self.t - 1.0))
        sc("Shift+Right", lambda: self.seek(self.t + 1.0))
        sc("Escape", lambda: self._set_pick(None))

    # ------------------------------------------------------------ files

    def dragEnterEvent(self, e: QtGui.QDragEnterEvent):
        if e.mimeData().hasUrls():
            e.acceptProposedAction()

    def dropEvent(self, e: QtGui.QDropEvent):
        self.open_files([u.toLocalFile() for u in e.mimeData().urls() if u.isLocalFile()])

    def open_dialog(self):
        last = self.settings.value("lastDir", "") if self.persist else ""
        paths, _ = QtWidgets.QFileDialog.getOpenFileNames(
            self, "Open runs", last, "Runs and car logs (*.zip *.csv *.xlsx *.gpx *.json *.mf4 *.dbc);;All files (*)")
        if paths:
            if self.persist:
                self.settings.setValue("lastDir", os.path.dirname(paths[0]))
            self.open_files(paths)

    def open_car_dialog(self):
        last = self.settings.value("lastCarDir", "") if self.persist else ""
        paths, _ = QtWidgets.QFileDialog.getOpenFileNames(
            self, "Open a car log and its DBC", last, "Car logs and DBC (*.mf4 *.mf *.dat *.dbc);;All files (*)")
        if paths:
            if self.persist:
                self.settings.setValue("lastCarDir", os.path.dirname(paths[0]))
            self.open_files(paths)

    def open_files(self, paths: list[str], quiet: bool = False) -> list[str]:
        problems: list[str] = []
        added = 0
        car_paths = [p for p in paths if os.path.splitext(p)[1].lower() in (".mf4", ".mf", ".dat", ".dbc")]
        paths = [p for p in paths if p not in car_paths]
        QtWidgets.QApplication.setOverrideCursor(Qt.WaitCursor)
        try:
            for p in paths:
                runs, probs = load_path(p)
                problems += probs
                for r in runs:
                    self.runs.append(r)
                    self._add_run_item(r)
                    added += 1
        finally:
            QtWidgets.QApplication.restoreOverrideCursor()
        if added:
            self.stack.setCurrentIndex(1)
            self.run_list.setCurrentRow(len(self.runs) - added)
        if car_paths:
            QtWidgets.QApplication.setOverrideCursor(Qt.WaitCursor)
            try:
                problems += self._open_car_files(car_paths)
            finally:
                QtWidgets.QApplication.restoreOverrideCursor()
        if problems and not quiet:
            QtWidgets.QMessageBox.warning(self, "Some files couldn't be opened", "\n".join(problems[:12]))
        return problems

    def _add_run_item(self, r: Run):
        bits = [b for b in (r.driver, r.run_type) if b]
        bits.append(f"{r.duration:.0f} s")
        bits.append(f"{r.top_speed * UNITS[self.unit]:.0f} {self.unit}")
        it = QtWidgets.QListWidgetItem(f"{r.name}\n{'  ·  '.join(bits)}")
        self.run_list.addItem(it)

    def _refresh_run_items(self):
        for i, r in enumerate(self.runs):
            bits = [b for b in (r.driver, r.run_type) if b]
            bits.append(f"{r.duration:.0f} s")
            bits.append(f"{r.top_speed * UNITS[self.unit]:.0f} {self.unit}")
            self.run_list.item(i).setText(f"{r.name}\n{'  ·  '.join(bits)}")

    # ------------------------------------------------------------ run display

    def _run_selected(self, i: int):
        self._show_run(self.runs[i] if 0 <= i < len(self.runs) else None)

    def _show_run(self, run: Run | None):
        self.pause()
        self._set_pick(None)
        self.run = run
        has = run is not None
        for wdg in (self.play_btn, self.slider):
            wdg.setEnabled(has)
        for wdg in (self.pick_start, self.start_here, self.pick_finish, self.finish_here, self.width_box, self.both_ways):
            wdg.setEnabled(has and run.has_gps)
        if not has:
            self.heading.setText("OBRA Run Analyzer")
            return
        self.heading.setText(run.name)
        self.t_lo, self.t_hi = float(run.t[0]), float(run.t[-1])
        self.t = self.t_lo
        g = self._site().get("start")
        if g:
            self.width_box.blockSignals(True)
            self.width_box.setValue(g.width)
            self.width_box.blockSignals(False)
        self._draw_info()
        self._draw_track()
        self._draw_satellite()
        self._draw_traces()
        self._draw_gg_cloud()
        self._recompute_laps()
        self.map.getPlotItem().vb.autoRange(padding=0.08)
        self._car_run_changed()
        self._balance_centre()
        self.seek(self.t_lo)

    def _site(self) -> dict:
        return self.gates.setdefault(site_key(self.run), {"start": None, "finish": None})

    def _draw_info(self):
        r = self.run
        f = UNITS[self.unit]
        esc = lambda s: (s.replace("&", "&amp;").replace("<", "&lt;").replace("\n", "<br>"))  # noqa: E731
        rows = []
        if r.start:
            rows.append(("Recorded", r.start.strftime("%d %b %Y %H:%M")))
        if r.driver:
            rows.append(("Driver", esc(r.driver)))
        if r.run_type:
            rows.append(("Type", esc(r.run_type)))
        rows.append(("Duration", f"{r.duration:.1f} s"))
        rows.append(("Distance", f"{r.distance:.0f} m"))
        rows.append(("Top speed", f"{r.top_speed * f:.1f} {self.unit}"))
        rows.append(("Max accel", f"{max(r.long_acc.max(), 0) / G:.2f} g"))
        rows.append(("Max braking", f"{max(-r.long_acc.min(), 0) / G:.2f} g"))
        rows.append(("Max lateral", f"{np.abs(r.lat_acc).max() / G:.2f} g"))
        rows.append(("Data", f"{r.sample_rate:.0f} Hz" + (f" · {esc(r.source)}" if r.source else "")))
        html = "".join(f"<tr><td style='color:{MUTED};padding-right:10px'>{k}</td><td style='color:{TEXT}'>{v}</td></tr>"
                       for k, v in rows)
        html = f"<table cellspacing='2'>{html}</table>"
        if r.notes:
            html += f"<p style='color:{TEXT};margin-top:8px'>{esc(r.notes)}</p>"
        self.info.setText(html)

    def _stride(self, n: int, cap: int) -> np.ndarray:
        return np.arange(0, n, max(1, int(math.ceil(n / cap))))

    def _draw_track(self):
        r = self.run
        if r is None:
            return
        if not r.has_gps:
            self.track_item.setData(x=[], y=[])
            self.legend.setText("This is a car log without GPS, so there is no map. Open a run from the phone app to add one.")
            return
        idx = self._stride(len(r.t), 7000)
        mode = self.color_box.currentIndex()
        f = UNITS[self.unit]
        if mode == 0:
            top = max(r.top_speed, 0.1)
            cols = [heat_color(v / top) for v in r.speed[idx]]
            self.legend.setText(f"Blue = slow,  red = {r.top_speed * f:.0f} {self.unit}.   "
                                "Click the track to move the car there.  Scroll to zoom, drag to pan.")
        else:
            arr = r.long_acc if mode == 1 else r.lat_acc
            peak = max(float(np.percentile(np.abs(arr), 99)), 0.5)
            cols = [diverging_color(v / peak) for v in arr[idx]]
            what = "green = accelerating,  red = braking" if mode == 1 else "green = turning left,  red = turning right"
            self.legend.setText(f"{what}  (full colour at {peak / G:.2f} g).   Click the track to move the car there.")
        self.track_item.setData(x=r.x[idx], y=r.y[idx], brush=[pg.mkBrush(c) for c in cols],
                                size=7 if self.satellite else 6)

    # ------------------------------------------------------------ satellite

    def _map_style_changed(self, i: int):
        self.satellite = i == 0
        self._save_settings()
        self._draw_track()
        self._draw_satellite()

    def _tile_cache_dir(self) -> str:
        base = QtCore.QStandardPaths.writableLocation(QtCore.QStandardPaths.GenericCacheLocation) or os.path.expanduser("~")
        return os.path.join(base, "OBRA-Run-Analyzer", "tiles")

    def _draw_satellite(self):
        r = self.run
        self.sat_item.setVisible(False)
        self.credit.setText("")
        if r is None or not self.satellite or not r.has_gps:
            return
        box = tiles.padded_box(float(r.lat.min()), float(r.lat.max()), float(r.lon.min()), float(r.lon.max()))
        rng = tiles.range_for(*box)
        if rng in self._sat_cache:
            self._place_satellite(r, *self._sat_cache[rng])
            return
        self.credit.setText("Loading satellite image…")
        if rng in self._sat_pending:
            return
        self._sat_pending.add(rng)
        cache_dir = self._tile_cache_dir()
        th = Worker(lambda: stitch_tiles(rng, cache_dir))
        th.done.connect(lambda res: self._satellite_ready(rng, res))
        th.failed.connect(lambda msg: self._satellite_failed(rng, msg))
        self._keep(th)
        th.start()

    def _satellite_ready(self, rng, res):
        self._sat_pending.discard(rng)
        self._sat_cache[rng] = res
        self._sat_status = f"satellite ok zoom={res[0].z} tiles={res[0].count} image={res[1].shape[1]}x{res[1].shape[0]}"
        if self.run is not None and self.satellite:
            r = self.run
            box = tiles.padded_box(float(r.lat.min()), float(r.lat.max()), float(r.lon.min()), float(r.lon.max()))
            if tiles.range_for(*box) == rng:
                self._place_satellite(r, *res)

    def _satellite_failed(self, rng, msg: str):
        self._sat_pending.discard(rng)
        self._sat_status = f"satellite failed: {msg}"
        if self.satellite:
            self.credit.setText("No satellite image (offline?). Showing the plain map.")

    def _place_satellite(self, r: Run, used, arr):
        south, west, north, east = used.bounds()
        xs, ys = to_local(np.array([south, north]), np.array([west, east]), r.lat[0], r.lon[0])
        self.sat_item.setImage(arr, autoLevels=False, levels=(0, 255))
        self.sat_item.setRect(QtCore.QRectF(float(xs[0]), float(ys[0]), float(xs[1] - xs[0]), float(ys[1] - ys[0])))
        self.sat_item.setOpacity(0.92)
        self.sat_item.setVisible(True)
        self.credit.setText(tiles.ATTRIBUTION)

    # ------------------------------------------------------------ car data (MF4 + DBC)

    def _build_car_tab(self) -> QtWidgets.QWidget:
        w = QtWidgets.QWidget()
        lay = QtWidgets.QHBoxLayout(w)
        lay.setContentsMargins(6, 6, 6, 6)
        lay.setSpacing(8)

        left = QtWidgets.QVBoxLayout()
        left.setSpacing(4)
        self.car_filter = QtWidgets.QLineEdit()
        self.car_filter.setPlaceholderText("Find a signal…")
        self.car_filter.setClearButtonEnabled(True)
        self.car_filter.textChanged.connect(self._filter_car_tree)
        self.car_tree = QtWidgets.QTreeWidget()
        self.car_tree.setHeaderLabels(["Signal", "Value now"])
        self.car_tree.setRootIsDecorated(True)
        self.car_tree.setUniformRowHeights(True)
        self.car_tree.header().setSectionResizeMode(0, QtWidgets.QHeaderView.Stretch)
        self.car_tree.header().setSectionResizeMode(1, QtWidgets.QHeaderView.Interactive)
        self.car_tree.header().resizeSection(1, 124)
        self.car_tree.setTextElideMode(Qt.ElideMiddle)
        self.car_tree.header().setStretchLastSection(False)
        self.car_tree.itemChanged.connect(self._car_item_changed)
        left.addWidget(self.car_filter)
        left.addWidget(self.car_tree, 1)
        lw = QtWidgets.QWidget()
        lw.setLayout(left)
        lw.setMinimumWidth(350)
        lw.setMaximumWidth(480)
        lay.addWidget(lw, 0)

        right = QtWidgets.QVBoxLayout()
        right.setSpacing(4)
        self.car_offset = QtWidgets.QDoubleSpinBox()
        self.car_offset.setRange(-1e7, 1e7)
        self.car_offset.setDecimals(2)
        self.car_offset.setSingleStep(0.1)
        self.car_offset.setSuffix(" s")
        self.car_offset.setToolTip("Seconds added to the car log's time to line it up with the GPS run")
        self.car_offset.valueChanged.connect(self._car_offset_changed)
        self.car_clock_btn = QtWidgets.QPushButton("Use clocks")
        self.car_clock_btn.setToolTip("Line the log up using the logger's clock and the phone's GPS time")
        self.car_clock_btn.clicked.connect(self._car_use_clocks)
        self.car_match_btn = QtWidgets.QPushButton("Match speed")
        self.car_match_btn.setToolTip("Click a vehicle-speed or wheel-speed signal in the list, then press this to "
                                      "find the offset where it best follows the GPS speed")
        self.car_match_btn.clicked.connect(self._car_match)
        self.car_gps_box = QtWidgets.QCheckBox("GPS speed")
        self.car_gps_box.setChecked(True)
        self.car_gps_box.toggled.connect(lambda _: self._draw_car_plots())
        right.addLayout(row(label("Log offset", "muted"), self.car_offset, self.car_clock_btn, self.car_match_btn,
                            None, self.car_gps_box, spacing=8))
        self.car_status = label("", "muted", wrap=True)
        right.addWidget(self.car_status)
        self.car_plot_box = QtWidgets.QVBoxLayout()
        self.car_plot_box.setSpacing(2)
        holder = QtWidgets.QWidget()
        holder.setLayout(self.car_plot_box)
        right.addWidget(holder, 1)
        self.car_empty = label("Open a car log (.mf4) together with its .dbc to see the CAN signals here, on the same "
                               "timeline as the GPS run. Use “Open car log…” at the top, or drop both files on the window.",
                               "muted", wrap=True)
        self.car_empty.setAlignment(Qt.AlignCenter)
        self.car_plot_box.addWidget(self.car_empty, 1)
        rw = QtWidgets.QWidget()
        rw.setLayout(right)
        lay.addWidget(rw, 1)
        self._car_controls_enabled()
        return w

    def _car_controls_enabled(self):
        on = self.carlog is not None and self.run is not None
        for wdg in (self.car_offset, self.car_clock_btn, self.car_match_btn, self.car_gps_box, self.car_filter):
            wdg.setEnabled(on)

    def _open_car_files(self, paths: list[str]) -> list[str]:
        """Loads .dbc and .mf4 files. Returns problems."""
        problems: list[str] = []
        new_dbc = False
        for p in paths:
            if p.lower().endswith(".dbc"):
                try:
                    self.dbc = canlog.load_dbc(p)
                    new_dbc = True
                    if self.persist:
                        self.settings.setValue("lastDbc", p)
                except (canlog.CanLogError, OSError) as e:
                    problems.append(str(e))
        logs = [p for p in paths if not p.lower().endswith(".dbc")]
        remembered = ""
        if logs and self.dbc is None and self.persist:
            last = str(self.settings.value("lastDbc", "") or "")
            if last and os.path.exists(last):
                try:
                    self.dbc = canlog.load_dbc(last)
                    remembered = f"Using the DBC from last time: {self.dbc.name}."
                except (canlog.CanLogError, OSError):
                    self.dbc = None
        loaded = None
        for p in logs[-1:]:          # one car log at a time
            try:
                loaded = canlog.load_car_log(p, self.dbc)
            except canlog.CanLogError as e:
                problems.append(str(e))
            except Exception as e:  # noqa: BLE001
                problems.append(f"{os.path.basename(p)}: {e}")
        if len(logs) > 1:
            problems.append("One car log is shown at a time; the last one you picked was opened.")
        if loaded is None and new_dbc and self.carlog is not None and self.carlog.frames is not None:
            loaded = canlog.decode(self.carlog.frames, self.dbc, self.carlog.name)     # same log, new DBC
        if loaded is None:
            if new_dbc and not logs:
                self._car_status = f"DBC loaded: {self.dbc.name}. Now open the car log (.mf4)."
                self.car_status.setText(self._car_status)
            return problems
        if remembered:
            loaded.notes.insert(0, remembered)
        self.carlog = loaded
        self.car_offsets = {}
        if not self.runs or all(not r.has_gps for r in self.runs):
            self._add_log_only_run(loaded)
        self._fill_car_tree()
        self._car_run_changed()
        self.stack.setCurrentIndex(1)
        self.tabs.setCurrentIndex(2)
        return problems

    def _add_log_only_run(self, log: canlog.CarLog):
        """Lets a car log be played on its own: a run with time and (if the log has one) speed, but no map."""
        t0 = min((float(s.t[0]) for s in log.series if len(s.t)), default=0.0)
        t = np.arange(0.0, max(log.duration, 0.2) + 0.05, 0.1) + t0
        speed = np.zeros_like(t)
        for s in log.series:
            unit = s.unit.lower().replace(" ", "")
            if s.decoded and len(s.t) > 10 and unit in ("km/h", "kmh", "kph", "m/s", "mph") and np.ptp(s.values) > 0:
                factor = {"m/s": 1.0, "mph": 0.44704}.get(unit, 1 / 3.6)
                speed = np.interp(t, s.t, np.abs(s.values)) * factor
                break
        dist = np.concatenate([[0.0], np.cumsum((speed[1:] + speed[:-1]) / 2 * np.diff(t))])
        zeros = np.zeros_like(t)
        run = Run(name=f"{log.name} (car log)", t=t, lat=zeros.copy(), lon=zeros.copy(), alt=zeros.copy(), speed=speed,
                  long_acc=np.gradient(speed, t), lat_acc=zeros.copy(), dist=dist, heading=zeros.copy(),
                  start=log.start, source="Car log only, no GPS", has_gps=False)
        self.runs = [r for r in self.runs if r.has_gps]
        self.run_list.blockSignals(True)
        self.run_list.clear()
        for r in self.runs:
            self._add_run_item(r)
        self.runs.append(run)
        self._add_run_item(run)
        self.run_list.blockSignals(False)
        self.car_offsets[id(run)] = 0.0
        self.run_list.setCurrentRow(len(self.runs) - 1)

    def _fill_car_tree(self):
        log = self.carlog
        self.car_tree.blockSignals(True)
        self.car_tree.clear()
        self.car_filter.clear()
        if log is None:
            self.car_tree.blockSignals(False)
            return
        groups: dict[str, QtWidgets.QTreeWidgetItem] = {}
        ranked = []
        for s in log.series:
            top = groups.get(s.group)
            if top is None:
                top = QtWidgets.QTreeWidgetItem([s.group, ""])
                top.setFlags(Qt.ItemIsEnabled)
                f = top.font(0)
                f.setBold(True)
                top.setFont(0, f)
                if not s.decoded:
                    top.setForeground(0, QtGui.QColor(MUTED))
                self.car_tree.addTopLevelItem(top)
                groups[s.group] = top
            moving = len(s.values) > 1 and float(np.ptp(s.values)) > 0
            it = QtWidgets.QTreeWidgetItem([s.name + (f"  [{s.unit}]" if s.unit else ""), ""])
            it.setData(0, Qt.UserRole, s.key)
            it.setFlags(Qt.ItemIsEnabled | Qt.ItemIsSelectable | Qt.ItemIsUserCheckable)
            it.setCheckState(0, Qt.Unchecked)
            if not moving:
                it.setForeground(0, QtGui.QColor(MUTED))
            rate = (len(s.t) - 1) / (s.t[-1] - s.t[0]) if len(s.t) > 1 and s.t[-1] > s.t[0] else 0.0
            tip = [f"{s.group}  ·  {s.name}"] + ([s.comment] if s.comment else [])
            tip.append(f"{len(s.t):,} samples at about {rate:.0f} Hz")
            tip.append(f"Range {np.nanmin(s.values):g} to {np.nanmax(s.values):g}" if moving else f"Constant at {s.text_at(1e18)}")
            if s.choices:
                tip.append("States: " + ", ".join(f"{k} = {v}" for k, v in sorted(s.choices.items())))
            it.setToolTip(0, "\n".join(tip))
            top.addChild(it)
            if moving and s.decoded:
                name = s.name.lower()
                rank = next((i for i, k in enumerate(("speed", "steer", "brake", "hyd", "trq", "torque", "throttle", "state"))
                             if k in name), 9)
                ranked.append((rank, len(ranked), it))
        picked, kinds = [], set()
        for rank, _, it in sorted(ranked, key=lambda r: r[:2]):      # one of each kind first: a speed, a steer, a brake…
            if rank not in kinds or rank == 9:
                picked.append(it)
                kinds.add(rank)
        for it in picked[:3]:
            it.setCheckState(0, Qt.Checked)
        self.car_tree.expandAll()
        self.car_tree.blockSignals(False)

    def _filter_car_tree(self, text: str):
        text = text.strip().lower()
        for i in range(self.car_tree.topLevelItemCount()):
            top = self.car_tree.topLevelItem(i)
            shown = 0
            for j in range(top.childCount()):
                child = top.child(j)
                hit = not text or text in child.text(0).lower() or text in top.text(0).lower()
                child.setHidden(not hit)
                shown += hit
            top.setHidden(shown == 0)

    def _car_items(self):
        for i in range(self.car_tree.topLevelItemCount()):
            top = self.car_tree.topLevelItem(i)
            for j in range(top.childCount()):
                yield top.child(j)

    def _car_item_changed(self, item, column):
        if column == 0 and item.data(0, Qt.UserRole):
            self._draw_car_plots()

    def _car_offset(self) -> float:
        return self.car_offsets.get(id(self.run), 0.0) if self.run is not None else 0.0

    def _car_run_changed(self):
        """Works out how the car log lines up with the run now on screen."""
        self._car_controls_enabled()
        log, r = self.carlog, self.run
        if log is None or r is None:
            self._draw_car_plots()
            return
        if id(r) not in self.car_offsets:
            off = canlog.clock_offset(log.start, r.start)
            ok = off is not None and canlog.overlap(log, off, float(r.t[0]), float(r.t[-1])) > 0
            self.car_offsets[id(r)] = off if ok else 0.0
        self.car_offset.blockSignals(True)
        self.car_offset.setValue(self.car_offsets[id(r)])
        self.car_offset.blockSignals(False)
        self._draw_car_plots()

    def _car_offset_changed(self, v: float):
        if self.run is None or self.carlog is None:
            return
        self.car_offsets[id(self.run)] = float(v)
        self._draw_car_plots()
        self._update_car_values(force=True)

    def _car_use_clocks(self):
        log, r = self.carlog, self.run
        if log is None or r is None:
            return
        off = canlog.clock_offset(log.start, r.start)
        if off is None:
            QtWidgets.QMessageBox.information(self, "Car log", "One of the two files has no start time, so the clocks can't be used.")
            return
        self.car_offset.setValue(off)

    def _car_match(self):
        log, r = self.carlog, self.run
        if log is None or r is None:
            return
        item = self.car_tree.currentItem()
        series = log.find(item.data(0, Qt.UserRole)) if item is not None and item.data(0, Qt.UserRole) else None
        if series is None:
            QtWidgets.QMessageBox.information(self, "Match to GPS speed", "Click a vehicle-speed or wheel-speed signal in the list first.")
            return
        if not r.has_gps:
            QtWidgets.QMessageBox.information(self, "Match to GPS speed", "This needs a GPS run from the phone app. Open one, then try again.")
            return
        found = canlog.align_by_signal(series, r.t, r.speed)
        if found is None or found[1] < 0.5:
            QtWidgets.QMessageBox.information(
                self, "Match to GPS speed",
                f"{series.name} doesn't follow the GPS speed closely enough to line the two up"
                + (f" (best match {found[1]:.0%})." if found else ".") + " Pick a speed signal, or type the offset.")
            return
        self.car_offset.setValue(found[0])
        self.car_status.setText(f"Lined up on {series.name}: offset {found[0]:+.2f} s, match {found[1]:.0%}.  " + self._car_summary())

    def _car_summary(self) -> str:
        log, r = self.carlog, self.run
        if log is None:
            return self._car_status
        bits = [log.name]
        if log.start:
            bits.append(log.start.astimezone(timezone.utc).strftime("%d %b %Y %H:%M:%S UTC"))
        bits.append(f"{log.duration / 60:.1f} min")
        if log.frame_count:
            bits.append(f"{log.frame_count:,} frames")
        bits.append(f"DBC: {log.dbc_name}" if log.dbc_name else "no DBC")
        text = "  ·  ".join(bits)
        if r is not None and r.has_gps:
            cover = canlog.overlap(log, self._car_offset(), float(r.t[0]), float(r.t[-1]))
            if cover <= 0:
                clock = canlog.clock_offset(log.start, r.start)
                why = ""
                if clock is not None and r.start is not None and log.start is not None:
                    why = (f" By their clocks the log starts {log.start.astimezone(timezone.utc):%d %b %H:%M:%S} and the run "
                           f"{r.start.astimezone(timezone.utc):%d %b %H:%M:%S} UTC.")
                text += (f"\n<span style='color:{ACCENT}'>The log doesn't overlap this run at the current offset.{why} "
                         "Type an offset, or match a speed signal to the GPS speed.</span>")
            else:
                text += f"\nCovers {cover / max(r.duration, 1e-9):.0%} of this run."
        for n in log.notes[:3]:
            text += "\n" + n
        return text

    def _draw_car_plots(self):
        for plot in [p[1] for p in self.car_plots] + [getattr(self, "_car_gps_plot", None)]:
            if plot is not None:
                self.car_plot_box.removeWidget(plot)
                plot.setParent(None)
                plot.deleteLater()
        self.car_plots = []
        self._car_gps_plot = None
        self._car_master = None
        log, r = self.carlog, self.run
        self.car_empty.setVisible(log is None)
        if log is None or r is None:
            return
        self.car_status.setTextFormat(Qt.RichText)
        chosen = [log.find(it.data(0, Qt.UserRole)) for it in self._car_items() if it.checkState(0) == Qt.Checked]
        chosen = [s for s in chosen if s is not None]
        extra = ""
        if len(chosen) > 8:
            extra = f"\nShowing the first 8 of {len(chosen)} ticked signals."
            chosen = chosen[:8]
        self.car_status.setText((self._car_summary() + extra).replace("\n", "<br>"))
        offset = self._car_offset()
        by_distance = self.x_box.currentIndex() == 1

        def to_x(t_log):
            t_run = t_log + offset
            return np.interp(t_run, r.t, r.dist) if by_distance else t_run

        def cursor_for(plot):
            line = pg.InfiniteLine(angle=90, movable=True, pen=pg.mkPen("white", width=1.5), hoverPen=pg.mkPen(ACCENT, width=2))
            line.setZValue(20)
            line.sigDragged.connect(self._cursor_dragged)
            plot.addItem(line)
            plot.scene().sigMouseClicked.connect(lambda ev, pl=plot: self._plot_clicked(ev, pl))
            return line

        plots = []
        if self.car_gps_box.isChecked() and r.has_gps:
            p = make_plot()
            p.getAxis("left").setWidth(110)
            p.plot(self._xs(), r.speed * UNITS[self.unit], pen=pg.mkPen(ACCENT, width=2))
            p.setTitle(f"<span style='color:{ACCENT}'>GPS speed</span> <span style='color:{MUTED}'>{self.unit}</span>", size="9pt")
            self._car_gps_plot = p
            self._car_gps_cursor = cursor_for(p)
            plots.append(p)
        for n, s in enumerate(chosen):
            p = make_plot()
            p.getAxis("left").setWidth(110)
            color = LAP_COLORS[(n + 1) % len(LAP_COLORS)]
            x = to_x(s.t)
            sparse = s.is_state or len(s.t) < 4000
            if sparse:
                curve = p.plot(x, s.values, pen=pg.mkPen(color, width=1.8), stepMode="left")
            else:
                p.setDownsampling(auto=True, mode="peak")
                p.setClipToView(True)
                curve = p.plot(x, s.values, pen=pg.mkPen(color, width=1.5))
            if s.choices:
                seen = sorted({int(round(v)) for v in np.unique(s.values)[:40]})
                p.getAxis("left").setTicks([[(v, (s.choices.get(v, str(v)))[:15]) for v in seen]])
                lo, hi = (seen[0], seen[-1]) if seen else (0, 1)
                p.setYRange(lo - 0.4, hi + 0.4, padding=0)
            line = cursor_for(p)
            self.car_plots.append((s, p, curve, line, color))
            plots.append(p)
        self._car_master = plots[0] if plots else None
        for p in plots[1:]:
            p.setXLink(plots[0])
        if plots:
            lo, hi = self.p_speed.getViewBox().viewRange()[0]
            plots[0].setXRange(lo, hi, padding=0)
            plots[0].sigXRangeChanged.connect(lambda _, rng: self._sync_x(self.p_speed, rng))
        for i, p in enumerate(plots):
            last = i == len(plots) - 1
            p.getAxis("bottom").setStyle(showValues=last)
            if last:
                p.setLabel("bottom", "Distance (m)" if by_distance else "Time (s)", color=MUTED)
            self.car_plot_box.addWidget(p, 13 if last else 10)      # the last one also carries the time axis
        if not plots:
            hint = make_plot()
            hint.setTitle(f"<span style='color:{MUTED}'>Tick signals in the list to plot them</span>", size="10pt")
            hint.hideAxis("left")
            hint.hideAxis("bottom")
            self._car_gps_plot = hint
            self.car_plot_box.addWidget(hint, 1)
        self._update_cursor()
        self._update_car_values(force=True)

    def _sync_x(self, target, rng):
        """Keeps the Car data graphs and the Run graphs on the same time span."""
        if getattr(self, "_syncing_x", False) or target is None:
            return
        self._syncing_x = True
        try:
            cur = target.getViewBox().viewRange()[0]
            if abs(cur[0] - rng[0]) > 1e-6 or abs(cur[1] - rng[1]) > 1e-6:
                target.setXRange(rng[0], rng[1], padding=0)
        except RuntimeError:
            pass
        finally:
            self._syncing_x = False

    def _update_cursor_extra(self, x: float):
        c = getattr(self, "_car_gps_cursor", None)
        if c is not None and self._car_gps_plot is not None:
            try:
                c.blockSignals(True)
                c.setValue(x)
                c.blockSignals(False)
            except RuntimeError:
                self._car_gps_cursor = None

    def _update_car_values(self, force: bool = False):
        """Live values at the cursor: in the plot titles and the list. Skipped while the tab is hidden."""
        log, r = self.carlog, self.run
        if log is None or r is None or self.tabs.currentIndex() != 2:
            return
        self._update_cursor_extra(self._x_at(self.t))
        now = QtCore.QTime.currentTime().msecsSinceStartOfDay()
        if not force and 0 <= now - self._car_values_at < 90:
            return
        self._car_values_at = now
        t_log = self.t - self._car_offset()
        for s, p, _, _, color in self.car_plots:
            inside = len(s.t) and s.t[0] <= t_log <= s.t[-1] + 1.0
            value = s.text_at(t_log) if inside else "outside the log"
            unit = f" <span style='color:{MUTED}'>{s.unit}</span>" if s.unit and not inside else ""
            p.setTitle(f"<span style='color:{color}'>{s.name}</span>{unit} &nbsp; <b>{value}</b>", size="9pt")
        for it in self._car_items():
            if it.isHidden() or (it.parent() is not None and not it.parent().isExpanded()):
                continue
            s = log.find(it.data(0, Qt.UserRole))
            if s is not None:
                inside = len(s.t) and s.t[0] <= t_log <= s.t[-1] + 1.0
                it.setText(1, s.text_at(t_log) if inside else "–")

    def _xs(self) -> np.ndarray:
        return self.run.dist if self.x_box.currentIndex() == 1 else self.run.t

    def _x_at(self, t: float) -> float:
        return float(np.interp(t, self.run.t, self._xs()))

    def _t_at_x(self, x: float) -> float:
        if self.x_box.currentIndex() == 0:
            return float(x)
        return float(np.interp(x, np.maximum.accumulate(self.run.dist), self.run.t))

    def _draw_traces(self):
        r = self.run
        if r is None:
            return
        x = self._xs()
        f = UNITS[self.unit]
        self.c_speed.setData(x, r.speed * f)
        self.c_long.setData(x, r.long_acc / G)
        self.c_lat.setData(x, r.lat_acc / G)
        self.c_elev.setData(x, r.alt)
        self.p_speed.setLabel("left", self.unit, color=MUTED)
        self.p_elev.setLabel("bottom", "Distance (m)" if self.x_box.currentIndex() == 1 else "Time (s)", color=MUTED)
        self._draw_lap_lines()
        self._draw_car_plots()
        self._apply_range()
        self._update_cursor()

    def _draw_lap_lines(self):
        for l in self._lap_lines:
            self.p_speed.removeItem(l)
        self._lap_lines = []
        if self.run is None:
            return
        edges = []
        for lap in self.laps:
            edges.append((lap.t0, f"L{lap.number}"))
        if self.laps and self._site().get("finish") is None:
            edges.append((self.laps[-1].t1, ""))
        elif self.laps:
            edges += [(lap.t1, "") for lap in self.laps]
        for t, text in edges:
            line = pg.InfiniteLine(pos=self._x_at(t), angle=90, movable=False,
                                   pen=pg.mkPen(GREEN if text else RED, width=1, style=Qt.DashLine),
                                   label=text or None,
                                   labelOpts={"position": 0.93, "color": GREEN, "fill": None})
            line.setZValue(5)
            self.p_speed.addItem(line)
            self._lap_lines.append(line)

    def _draw_gg_cloud(self):
        r = self.run
        idx = self._stride(len(r.t), 2500)
        self.gg_cloud.setData(x=-r.lat_acc[idx] / G, y=r.long_acc[idx] / G)
        lim = max(1.0, float(np.percentile(np.hypot(r.lat_acc, r.long_acc), 99.5)) / G * 1.15)
        for it in self._gg_rings:
            self.gg.removeItem(it)
        self._gg_rings = []
        th = np.linspace(0, 2 * np.pi, 90)
        for g in (0.5, 1.0, 1.5, 2.0):
            if g <= lim * 1.01:
                c = pg.PlotDataItem(g * np.cos(th), g * np.sin(th), pen=pg.mkPen("#3A3B45", width=1))
                c.setZValue(-5)
                self.gg.addItem(c)
                self._gg_rings.append(c)
        for a in (pg.PlotDataItem([-lim, lim], [0, 0], pen=pg.mkPen("#3A3B45")),
                  pg.PlotDataItem([0, 0], [-lim, lim], pen=pg.mkPen("#3A3B45"))):
            a.setZValue(-5)
            self.gg.addItem(a)
            self._gg_rings.append(a)
        self.gg.setRange(xRange=(-lim, lim), yRange=(-lim, lim), padding=0.02)

    # ------------------------------------------------------------ playback

    def toggle_play(self):
        if self.run is None:
            return
        if self.timer.isActive():
            self.pause()
        else:
            if self.t >= self.t_hi - 1e-3:
                self.t = self.t_lo
            self.clock.start()
            self.timer.start()
            self.play_btn.setText("❚❚  Pause")

    def pause(self):
        self.timer.stop()
        self.play_btn.setText("▶  Play")

    def _rate(self) -> float:
        return float(self.rate_box.currentText().replace("×", ""))

    def _tick(self):
        dt = self.clock.restart() / 1000.0
        t = self.t + dt * self._rate()
        if t >= self.t_hi:
            if self.loop_box.isChecked() and self.t_hi > self.t_lo:
                t = self.t_lo
            else:
                t = self.t_hi
                self.pause()
        self.seek(t)

    def _slider_moved(self, v: int):
        if self._updating or self.run is None:
            return
        self.seek(self.t_lo + (self.t_hi - self.t_lo) * v / 10000.0, from_slider=True)

    def seek(self, t: float, from_slider: bool = False):
        r = self.run
        if r is None:
            return
        self.t = min(max(t, self.t_lo), self.t_hi)
        f = UNITS[self.unit]
        if not from_slider:
            self._updating = True
            span = self.t_hi - self.t_lo
            self.slider.setValue(int(round((self.t - self.t_lo) / span * 10000)) if span > 0 else 0)
            self._updating = False
        v = r.value_at(r.speed, self.t)
        la, lt = r.value_at(r.long_acc, self.t) / G, r.value_at(r.lat_acc, self.t) / G
        if r.has_gps:
            self.marker.setData(x=[r.value_at(r.x, self.t)], y=[r.value_at(r.y, self.t)])
        else:
            self.marker.setData(x=[], y=[])
        self.speed_big.setText(f"{v * f:.1f}")
        self.tiles["Time"].set(f"{self.t:.2f} s")
        self.tiles["Distance"].set(f"{r.value_at(r.dist, self.t):.0f} m")
        self.tiles["Accel / brake"].set(f"{la:+.2f} g")
        self.tiles["Cornering"].set(f"{abs(lt):.2f} g {'L' if lt > 0.03 else 'R' if lt < -0.03 else ''}")
        self.tiles["Elevation"].set(f"{r.value_at(r.alt, self.t):.1f} m")
        lap = next((l for l in self.laps if l.t0 <= self.t <= l.t1), None)
        self.tiles["Lap"].set(f"L{lap.number}  {format_lap_time(self.t - lap.t0)}" if lap else "–")
        self.time_label.setText(f"{self.t - self.t_lo:.1f} / {self.t_hi - self.t_lo:.1f} s")
        self.gg_dot.setData(x=[-lt], y=[la])
        m = (r.t >= self.t - 1.5) & (r.t <= self.t)
        self.gg_trail.setData(-r.lat_acc[m] / G, r.long_acc[m] / G)
        self._update_cursor()
        self._update_car_values()

    def _update_cursor(self):
        if self.run is None:
            return
        x = self._x_at(self.t)
        for c in self.cursors + [p[3] for p in self.car_plots]:
            c.blockSignals(True)
            c.setValue(x)
            c.blockSignals(False)

    def _cursor_dragged(self, line):
        self.seek(self._t_at_x(line.value()))

    def _plot_clicked(self, ev, plot):
        if self.run is None or ev.button() != Qt.LeftButton:
            return
        vb = plot.getPlotItem().vb
        if vb.sceneBoundingRect().contains(ev.scenePos()):
            self.seek(self._t_at_x(vb.mapSceneToView(ev.scenePos()).x()))

    # ------------------------------------------------------------ gates

    def _set_pick(self, mode: str | None):
        self.pick_mode = mode
        self.pick_start.setChecked(mode == "start")
        self.pick_finish.setChecked(mode == "finish")
        self.map.setCursor(Qt.CrossCursor if mode else Qt.ArrowCursor)
        self._update_gate_hint()

    def _map_clicked(self, ev):
        r = self.run
        if r is None or not r.has_gps or ev.button() != Qt.LeftButton:
            return
        vb = self.map.getPlotItem().vb
        if not vb.sceneBoundingRect().contains(ev.scenePos()):
            return
        p = vb.mapSceneToView(ev.scenePos())
        if self.pick_mode:
            gate, _ = gate_from_xy(r, p.x(), p.y(), self.width_box.value())
            self._site()[self.pick_mode] = gate
            self._set_pick(None)
            self._gates_changed()
            return
        m = (r.t >= self.t_lo) & (r.t <= self.t_hi)
        d2 = (r.x - p.x()) ** 2 + (r.y - p.y()) ** 2
        d2 = np.where(m, d2, np.inf)
        i = int(np.argmin(d2))
        # Ignore clicks well away from the track (more than ~12 px).
        px = vb.viewPixelSize()[0]
        if math.sqrt(float(d2[i])) <= max(12 * px, 2.0):
            self.seek(float(r.t[i]))

    def _gate_at_cursor(self, which: str):
        r = self.run
        if r is None:
            return
        self._site()[which] = Gate.at_sample(r, r.index_at(self.t), self.width_box.value())
        self._set_pick(None)
        self._gates_changed()

    def _clear_gate(self, which: str):
        if self.run is None:
            return
        site = self._site()
        if which == "all":
            site["start"] = None
        site["finish"] = None
        self._gates_changed()

    def _width_changed(self, w: float):
        if self.run is None:
            return
        for g in self._site().values():
            if g:
                g.width = float(w)
        self._gates_changed()

    def _gates_changed(self):
        self._save_settings()
        self._recompute_laps()

    def _draw_gates(self):
        for it in self._gate_items:
            self.map.removeItem(it)
        self._gate_items = []
        r = self.run
        if r is None or not r.has_gps:
            return
        site = self._site()
        circuit = site.get("finish") is None
        for key, color in (("start", GREEN), ("finish", RED)):
            g: Gate | None = site.get(key)
            if not g:
                continue
            (x1, y1), (x2, y2), (dx, dy) = g.endpoints(r)
            cx, cy = (x1 + x2) / 2, (y1 + y2) / 2
            line = pg.PlotDataItem([x1, x2], [y1, y2], pen=pg.mkPen(color, width=5, cap=Qt.RoundCap))
            arrow = pg.PlotDataItem([cx, cx + dx * g.width * 0.35], [cy, cy + dy * g.width * 0.35],
                                    pen=pg.mkPen(color, width=2))
            text = "START / FINISH" if (key == "start" and circuit) else key.upper()
            lab = pg.TextItem(text, color=color, anchor=(-0.08, 0.5))
            f = lab.textItem.font()
            f.setBold(True)
            f.setPointSize(8)
            lab.setFont(f)
            lab.setPos(x2, y2)
            for it in (line, arrow, lab):
                it.setZValue(8)
                self.map.addItem(it, ignoreBounds=True)
                self._gate_items.append(it)

    def _update_gate_hint(self):
        if self.run is None:
            self.gate_hint.setText("")
            return
        site = self._site()
        self.finish_clear.setEnabled(site.get("finish") is not None)
        self.clear_all.setEnabled(site.get("start") is not None or site.get("finish") is not None)
        if self.pick_mode:
            self.gate_hint.setText(f"<span style='color:{ACCENT}'>Click the track where the {self.pick_mode} line should go. "
                                   "Esc cancels.</span>")
        elif site.get("start") is None:
            self.gate_hint.setText("Set a start line to time laps. With only a start line, each crossing ends one lap and "
                                   "starts the next (circuits). Add a separate finish line for acceleration, sprint or "
                                   "autocross runs.")
        elif site.get("finish") is None:
            self.gate_hint.setText("Circuit: timing from the start line round to the start line. The lines are remembered "
                                   "for every run at this site.")
        else:
            self.gate_hint.setText("Start to finish: each pass from the green line to the red line is timed. The lines "
                                   "are remembered for every run at this site.")

    # ------------------------------------------------------------ laps

    def _recompute_laps(self):
        r = self.run
        if r is None:
            return
        site = self._site()
        self.laps = (find_laps(r, site.get("start"), site.get("finish"), one_way=not self.both_ways.isChecked())
                     if r.has_gps else [])
        self._draw_gates()
        self._update_gate_hint()
        self._fill_lap_table()
        self._draw_lap_lines()
        self._laps_selected()

    def _fill_lap_table(self):
        f = UNITS[self.unit]
        best = best_lap(self.laps)
        self.lap_table.blockSignals(True)
        self.lap_table.clearSelection()
        self.lap_table.setRowCount(len(self.laps))
        for i, l in enumerate(self.laps):
            is_best = best is not None and l is best and len(self.laps) > 1
            cells = [str(l.number), format_lap_time(l.time),
                     "best" if is_best else (f"+{l.time - best.time:.3f}" if len(self.laps) > 1 else ""),
                     f"{l.top_speed * f:.1f}", f"{l.avg_speed * f:.1f}", f"{l.min_speed * f:.1f}", f"{l.max_lat_g:.2f}"]
            for c, text in enumerate(cells):
                it = QtWidgets.QTableWidgetItem(text)
                it.setTextAlignment(Qt.AlignCenter)
                if c == 0:
                    it.setForeground(QtGui.QColor(LAP_COLORS[i % len(LAP_COLORS)]))
                if is_best:
                    font = it.font()
                    font.setBold(True)
                    it.setFont(font)
                    if c in (1, 2):
                        it.setForeground(QtGui.QColor(ACCENT))
                self.lap_table.setItem(i, c, it)
        self.lap_table.blockSignals(False)
        self.export_btn.setEnabled(bool(self.laps))
        if not self.laps:
            site = self._site()
            self.lap_summary.setText("Laps need a GPS run." if not self.run.has_gps else
                                     "No laps yet." if site.get("start") is None else
                                     "The car doesn't complete a timed pass through these lines on this run. "
                                     "Check the line positions, or tick “Either direction”.")
        else:
            times = np.array([l.time for l in self.laps])
            extra = f"   Average {format_lap_time(float(times.mean()))}   Spread {times.max() - times.min():.3f} s" if len(times) > 1 else ""
            self.lap_summary.setText(f"{len(times)} timed   Best {format_lap_time(float(times.min()))}{extra}\n"
                                     f"Speeds in {self.unit}. Click a lap to play just that lap; Ctrl-click to compare several.")

    def _selected_laps(self) -> list[Lap]:
        rows = sorted({i.row() for i in self.lap_table.selectedIndexes()})
        return [self.laps[i] for i in rows if i < len(self.laps)]

    def _laps_selected(self):
        r = self.run
        if r is None:
            return
        sel = self._selected_laps()
        self.whole_btn.setEnabled(bool(sel))
        if sel:
            self.t_lo, self.t_hi = min(l.t0 for l in sel), max(l.t1 for l in sel)
            xs, ys = [], []
            for l in sel:
                m = (r.t >= l.t0) & (r.t <= l.t1)
                xs.append(np.append(r.x[m], np.nan))
                ys.append(np.append(r.y[m], np.nan))
            self.hl_item.setData(np.concatenate(xs), np.concatenate(ys), connect="finite")
        else:
            self.t_lo, self.t_hi = float(r.t[0]), float(r.t[-1])
            self.hl_item.setData([], [])
        self._apply_range()
        self._draw_compare()
        self.seek(self.t_lo if not (self.t_lo <= self.t <= self.t_hi) or sel else self.t)

    def _apply_range(self):
        if self.run is None:
            return
        self.p_speed.enableAutoRange(axis="y")
        self.p_acc.enableAutoRange(axis="y")
        self.p_elev.enableAutoRange(axis="y")
        for p in (self.p_speed, self.p_acc, self.p_elev):
            p.setAutoVisible(y=True)
        self.p_speed.setXRange(self._x_at(self.t_lo), self._x_at(self.t_hi), padding=0.02)

    def _draw_compare(self):
        self.p_cmp.clear()
        self.p_delta.clear()
        r = self.run
        if r is None or not self.laps:
            self.cmp_hint.setText("Set a start line to compare laps here.")
            return
        f = UNITS[self.unit]
        sel = self._selected_laps()
        ref = best_lap(self.laps)
        shown = sel if len(sel) >= 2 else (sel + [ref] if sel and ref not in sel else sel) or self.laps[:12]
        if len(sel) >= 2:
            ref = min(sel, key=lambda l: l.time)
        self.p_cmp.setLabel("left", self.unit, color=MUTED)
        for l in sorted(shown, key=lambda l: l.number):
            col = LAP_COLORS[(l.number - 1) % len(LAP_COLORS)]
            d, v = lap_trace(r, l, r.speed)
            self.p_cmp.plot(d, v * f, pen=pg.mkPen(col, width=2.4 if l is ref else 1.5),
                            name=f"L{l.number}  {format_lap_time(l.time)}" + ("  (reference)" if l is ref else ""))
            if l is not ref:
                dd, dt = delta_to(r, l, r, ref)
                self.p_delta.plot(dd, dt, pen=pg.mkPen(col, width=1.6))
        zero = pg.InfiniteLine(pos=0, angle=0, pen=pg.mkPen("#5E606A", style=Qt.DashLine))
        self.p_delta.addItem(zero)
        self.p_cmp.enableAutoRange()
        if len(shown) > 1:
            self.p_delta.enableAutoRange()
        else:
            self.p_delta.setYRange(-0.5, 0.5)
        self.cmp_hint.setText(f"Speed against distance into the lap. Lower graph: time lost (above zero) or gained (below) "
                              f"against lap {ref.number}, {format_lap_time(ref.time)}. Ctrl-click laps in the table to choose which to compare.")

    def _export_laps(self):
        if not self.laps or self.run is None:
            return
        path, _ = QtWidgets.QFileDialog.getSaveFileName(self, "Export laps", safe_filename(self.run.name) + " laps.csv",
                                                        "CSV (*.csv)")
        if not path:
            return
        try:
            with open(path, "w", encoding="utf-8-sig", newline="") as fh:
                fh.write(laps_csv(self.run, self.laps, self.unit, UNITS[self.unit]))
        except OSError as e:
            QtWidgets.QMessageBox.warning(self, "Couldn't save", str(e.strerror or e))

    # ------------------------------------------------------------ units

    def _unit_changed(self, u: str):
        self.unit = u
        self.speed_unit.setText(u)
        self._save_settings()
        self._refresh_run_items()
        if self.run is not None:
            self._draw_info()
            self._draw_track()
            self._draw_traces()
            sel = [i.row() for i in self.lap_table.selectionModel().selectedRows()]
            self._fill_lap_table()
            for i in sel:
                self.lap_table.selectRow(i) if len(sel) == 1 else None
            self._draw_compare()
            self.seek(self.t)


def run_selftest(win: MainWindow, app: QtWidgets.QApplication, out_dir: str, paths: list[str]) -> int:
    """Loads files, sets a start line, steps playback and saves screenshots. Used by CI on the built .exe."""
    os.makedirs(out_dir, exist_ok=True)
    log = []
    ok = True
    try:
        size = os.environ.get("OBRA_TEST_SIZE")
        if size:
            win.resize(*(int(v) for v in size.split("x")))
        problems = win.open_files(paths, quiet=True)
        log.append(f"runs={len(win.runs)} problems={problems}")
        ok &= len(win.runs) > 0 and not problems
        if win.runs:
            r = win.run
            win.seek(r.t[0] + r.duration * 0.2)
            if r.has_gps:
                win._gate_at_cursor("start")
            log.append(f"laps={[round(l.time, 3) for l in win.laps]}")
            win.seek(r.t[0] + r.duration * 0.6)
            deadline = QtCore.QDeadlineTimer(25000)
            while win._sat_pending and not deadline.hasExpired():
                app.processEvents(QtCore.QEventLoop.AllEvents, 50)
            log.append(win._sat_status or "satellite: no result")
            app.processEvents()
            win.grab().save(os.path.join(out_dir, "selftest-run.png"))
            if win.laps:
                win.lap_table.selectRow(0)
                win.tabs.setCurrentIndex(1)
                app.processEvents()
                win.grab().save(os.path.join(out_dir, "selftest-lap.png"))
                if len(win.laps) >= 3:
                    win.lap_table.clearSelection()
                    win.lap_table.setSelectionMode(QtWidgets.QAbstractItemView.MultiSelection)
                    for i in range(3):
                        win.lap_table.selectRow(i)
                    win.lap_table.setSelectionMode(QtWidgets.QAbstractItemView.ExtendedSelection)
                    app.processEvents()
                    log.append(f"compare laps={[l.number for l in win._selected_laps()]}")
                    ok &= len(win._selected_laps()) == 3
                    win.grab().save(os.path.join(out_dir, "selftest-compare.png"))
                    win.lap_table.clearSelection()
            if win.carlog is not None:
                app.processEvents()
                log.append(f"car log: {len(win.carlog.series)} signals, {win.carlog.frame_count} frames, dbc={win.carlog.dbc_name!r}, "
                           f"offset={win._car_offset():+.2f} s, plots={len(win.car_plots)}")
                ok &= len(win.carlog.series) > 0 and len(win.car_plots) > 0
                win.tabs.setCurrentIndex(2)
                win.seek(r.t[0] + r.duration * 0.45)
                app.processEvents()
                win.grab().save(os.path.join(out_dir, "selftest-car.png"))
            elif any(p.lower().endswith((".mf4", ".dbc")) for p in paths):
                log.append("car log: requested but not loaded")
                ok = False
            win.toggle_play()
            t0 = win.t
            end = QtCore.QTime.currentTime().addMSecs(600)
            while QtCore.QTime.currentTime() < end:
                app.processEvents()
            win.pause()
            log.append(f"playback advanced {win.t - t0:.2f} s")
            ok &= win.t != t0
    except Exception as e:  # noqa: BLE001
        import traceback
        log.append("ERROR " + "".join(traceback.format_exception(e)))
        ok = False
    log.append(f"version={updater.current_label()} self_update={updater.can_self_update()}")
    log.append("SELFTEST OK" if ok else "SELFTEST FAILED")
    with open(os.path.join(out_dir, "selftest.txt"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(log) + "\n")
    return 0 if ok else 1


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv if argv is None else argv)
    if "--selftest-update" in argv:
        # CI only: replace this .exe with the given one, then restart with the remaining arguments.
        i = argv.index("--selftest-update")
        updater.swap_and_restart(argv[i + 1], args=argv[i + 2:])
        return 0
    selftest = None
    if "--selftest" in argv:
        i = argv.index("--selftest")
        selftest = argv[i + 1]
        del argv[i:i + 2]
    pg.setConfigOptions(antialias=True, background=SURFACE, foreground=TEXT)
    app = QtWidgets.QApplication(argv[:1])
    app.setStyle("Fusion")
    app.setStyleSheet(STYLE)
    icon = os.path.join(getattr(sys, "_MEIPASS", os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "icon.png")
    if os.path.exists(icon):
        app.setWindowIcon(QtGui.QIcon(icon))
    win = MainWindow(persist=selftest is None)
    win.show()
    files = [a for a in argv[1:] if os.path.exists(a)]
    if selftest is not None:
        return run_selftest(win, app, selftest, files)
    if files:
        win.open_files(files)
    return app.exec()
