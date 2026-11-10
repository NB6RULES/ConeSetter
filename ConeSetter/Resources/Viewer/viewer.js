// Bridge between the native app and the Online 3D Viewer engine.
// Native → JS: CS.load(url, name), CS.setView(name), CS.fit(), CS.setEdges(bool),
//              CS.setProjection('perspective'|'orthographic'), CS.setUp('Y'|'Z'), CS.snapshot(px)
// JS → native: window.webkit.messageHandlers.cs.postMessage({ type, ... })
(function () {
    'use strict';

    window.CS_LIB_BASE = new URL('libs/', window.location.href).href;

    const stage = document.getElementById('stage');
    // The engine already turns formats that are Z-up by convention (STL, 3MF, 3DM, ...) so that
    // their up axis is the screen's Y. STEP / IGES / BREP carry no convention, so they are shown
    // as authored (Y up, as in SolidWorks) and the app offers a Y/Z switch.

    const state = { embedded: null, edges: true, projection: 'perspective', up: 'Y', token: 0, name: '', extra: null };

    function post (message) {
        window.__csMessages = window.__csMessages || [];
        window.__csMessages.push(message);
        try {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.cs) {
                window.webkit.messageHandlers.cs.postMessage(message);
            }
        } catch (e) { /* not running inside the app */ }
    }

    window.addEventListener('error', (ev) => {
        post({ type: 'log', message: 'JS error: ' + ev.message });
    });
    window.addEventListener('unhandledrejection', (ev) => {
        post({ type: 'log', message: 'Unhandled rejection: ' + (ev.reason && ev.reason.message ? ev.reason.message : ev.reason) });
    });

    function edgeSettings () {
        return new OV.EdgeSettings(state.edges, new OV.RGBColor(18, 20, 26), 22);
    }

    function core () { return state.embedded ? state.embedded.GetViewer() : null; }

    function sphere () {
        const v = core();
        return v ? v.GetBoundingSphere(() => true) : null;
    }

    function applyUp (animate) {
        const v = core();
        if (!v) { return; }
        v.SetUpVector(state.up === 'Z' ? OV.Direction.Z : OV.Direction.Y, false);
        const s = sphere();
        if (s) { v.AdjustClippingPlanesToSphere(s); v.FitSphereToWindow(s, !!animate); }
    }

    function setView (name, animate) {
        const v = core();
        const s = sphere();
        if (!v || !s) { return; }
        const zUp = state.up === 'Z';
        // Directions from the model centre towards the eye.
        const dirs = zUp ? {
            front: [0, -1, 0], back: [0, 1, 0], left: [-1, 0, 0], right: [1, 0, 0],
            top: [0, -0.0015, 1], bottom: [0, 0.0015, -1], iso: [1, -1, 0.8]
        } : {
            front: [0, 0, 1], back: [0, 0, -1], left: [-1, 0, 0], right: [1, 0, 0],
            top: [0, 1, 0.0015], bottom: [0, -1, -0.0015], iso: [1, 0.8, 1]
        };
        const d = dirs[name] || dirs.iso;
        const len = Math.hypot(d[0], d[1], d[2]);
        const old = v.GetCamera();
        const c = s.center;
        const dist = Math.max(s.radius * 3, 1e-6);
        const eye = new OV.Coord3D(c.x + d[0] / len * dist, c.y + d[1] / len * dist, c.z + d[2] / len * dist);
        const up = zUp ? new OV.Coord3D(0, 0, 1) : new OV.Coord3D(0, 1, 0);
        v.SetCamera(new OV.Camera(eye, new OV.Coord3D(c.x, c.y, c.z), up, old.fov));
        v.FitSphereToWindow(s, false);
        v.Render();
    }

    function info () {
        const emb = state.embedded;
        const model = emb ? emb.GetModel() : null;
        const v = core();
        const out = { name: state.name };
        if (model) {
            out.vertices = model.VertexCount();
            out.triangles = model.TriangleCount();
            out.lines = model.LineSegmentCount ? model.LineSegmentCount() : 0;
            out.meshes = model.MeshInstanceCount();
            out.materials = model.MaterialCount();
            const units = ['', 'mm', 'cm', 'm', 'in', 'ft'];
            out.unit = units[model.GetUnit ? model.GetUnit() : 0] || '';
        }
        if (model) {
            // Size along the file's own X, Y, Z axes.
            try {
                const box = OV.GetBoundingBox(model);
                if (box && isFinite(box.min.x) && isFinite(box.max.x)) {
                    out.size = [box.max.x - box.min.x, box.max.y - box.min.y, box.max.z - box.min.z];
                }
            } catch (e) { /* leave size out */ }
        }
        if (state.extra) { Object.assign(out, state.extra); }
        out.up = state.up;
        return out;
    }

    function snapshot (px) {
        const v = core();
        if (!v) { return null; }
        try { return v.GetImageAsDataUrl(px, px, false); } catch (e) { return null; }
    }

    function create (token, onReady) {
        if (state.embedded) {
            try { state.embedded.Destroy(); } catch (e) { /* ignore */ }
            state.embedded = null;
        }
        stage.innerHTML = '';
        state.embedded = new OV.EmbeddedViewer(stage, {
            backgroundColor: new OV.RGBAColor(13, 14, 17, 255),
            defaultColor: new OV.RGBColor(196, 202, 214),
            defaultLineColor: new OV.RGBColor(236, 240, 248),
            edgeSettings: edgeSettings(),
            projectionMode: state.projection === 'orthographic' ? OV.ProjectionMode.Orthographic : OV.ProjectionMode.Perspective,
            onModelLoaded: () => {
                if (token !== state.token) { return; }
                onReady();
            },
            onModelLoadFailed: () => {
                if (token !== state.token) { return; }
                const div = stage.querySelector('div');
                post({ type: 'error', message: div ? div.textContent : 'Failed to import model.' });
            }
        });
    }

    function finish (flat) {
        applyUp(false);
        if (flat) {
            // 2D drawing in the XY plane: look straight at it.
            state.projection = 'orthographic';
            core().SetProjectionMode(OV.ProjectionMode.Orthographic);
            setView('front');
        } else {
            setView('iso');
        }
        core().Render();
        // Let a frame render before grabbing the thumbnail.
        requestAnimationFrame(() => requestAnimationFrame(() => {
            post({ type: 'loaded', info: info(), projection: state.projection, thumbnail: snapshot(320) });
        }));
    }

    const CS = {
        load: function (url, name) {
            // The web view can still be 0×0 while the app is laying it out; a viewer created
            // then would get a broken camera, so wait until the stage has a real size.
            if (stage.clientWidth < 2 || stage.clientHeight < 2) {
                const wait = ++state.token;
                setTimeout(() => { if (wait === state.token) { CS.load(url, name); } }, 60);
                return;
            }
            const token = ++state.token;
            state.name = name;
            state.extra = null;
            const ext = (name.split('.').pop() || '').toLowerCase();
            state.up = 'Y';
            post({ type: 'loading', name: name });
            try {
                if (ext === 'dxf') {
                    fetch(url).then((r) => {
                        if (!r.ok) { throw new Error('Could not read the file'); }
                        return r.text();
                    }).then((text) => {
                        if (token !== state.token) { return; }
                        if (text.indexOf('AutoCAD Binary DXF') === 0) { throw new Error('Binary DXF is not supported. Save it as ASCII DXF.'); }
                        const result = DXF.convert(text);
                        if (result.vertexCount === 0) { throw new Error('No drawable geometry found in this DXF.'); }
                        state.extra = { unit: result.unit, dxfSkipped: result.skipped, flat: result.flat };
                        state.up = result.flat ? 'Y' : 'Z';
                        create(token, () => finish(result.flat));
                        const base = name.replace(/\.[^.]*$/, '');
                        state.embedded.LoadModelFromFileList([new File([result.obj], base + '.obj', { type: 'text/plain' })]);
                    }).catch((e) => {
                        if (token === state.token) { post({ type: 'error', message: e.message || String(e) }); }
                    });
                } else {
                    create(token, () => finish(false));
                    state.embedded.LoadModelFromUrlList([url]);
                }
            } catch (e) {
                post({ type: 'error', message: e.message || String(e) });
            }
        },
        setView: function (name) { setView(name); },
        fit: function () {
            const v = core(), s = sphere();
            if (v && s) { v.FitSphereToWindow(s, true); }
        },
        setEdges: function (on) {
            state.edges = !!on;
            const v = core();
            if (v) { v.SetEdgeSettings(edgeSettings()); v.Render(); }
        },
        setProjection: function (mode) {
            state.projection = mode;
            const v = core();
            if (v) {
                v.SetProjectionMode(mode === 'orthographic' ? OV.ProjectionMode.Orthographic : OV.ProjectionMode.Perspective);
                v.Render();
            }
        },
        setUp: function (axis) {
            state.up = axis === 'Z' ? 'Z' : 'Y';
            applyUp(false);
            setView('iso');
            post({ type: 'info', info: info() });
        },
        info: info,
        snapshot: snapshot
    };

    window.CS = CS;
    window.addEventListener('resize', () => { if (state.embedded) { state.embedded.Resize(); } });
    post({ type: 'ready' });
})();
