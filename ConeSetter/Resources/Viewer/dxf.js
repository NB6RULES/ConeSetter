// DXF → OBJ converter for the 3D viewer.
// Reads the ENTITIES and BLOCKS sections of an ASCII DXF and emits OBJ text with
// polylines ("l") and faces ("f"), which the viewer engine can display.
// Supported: LINE, LWPOLYLINE (with bulges), POLYLINE/VERTEX (2D, 3D, polyface mesh),
// CIRCLE, ARC, ELLIPSE, SPLINE, 3DFACE, SOLID, TRACE, INSERT and DIMENSION blocks.
(function () {
    'use strict';

    const ARC_SEGMENTS = 64;

    function parsePairs (text) {
        const lines = text.split(/\r\n|\r|\n/);
        const pairs = [];
        for (let i = 0; i + 1 < lines.length; i += 2) {
            const code = parseInt(lines[i].trim(), 10);
            if (isNaN(code)) { continue; }
            pairs.push([code, lines[i + 1].trim()]);
        }
        return pairs;
    }

    // Groups pairs into entities: { type, pairs: [[code, value], ...] }
    function readEntities (pairs, start, endMarker) {
        const list = [];
        let cur = null;
        let i = start;
        for (; i < pairs.length; i++) {
            const [code, value] = pairs[i];
            if (code === 0) {
                if (cur) { list.push(cur); }
                if (value === endMarker) { cur = null; break; }
                cur = { type: value, pairs: [] };
            } else if (cur) {
                cur.pairs.push([code, value]);
            }
        }
        if (cur) { list.push(cur); }
        return { list, next: i };
    }

    function num (e, code, def) {
        for (const p of e.pairs) { if (p[0] === code) { const v = parseFloat(p[1]); return isNaN(v) ? def : v; } }
        return def;
    }
    function str (e, code, def) {
        for (const p of e.pairs) { if (p[0] === code) { return p[1]; } }
        return def;
    }
    function all (e, code) {
        const out = [];
        for (const p of e.pairs) { if (p[0] === code) { out.push(parseFloat(p[1])); } }
        return out;
    }

    function arcPoints (cx, cy, cz, r, a0, a1, flipX) {
        while (a1 <= a0) { a1 += Math.PI * 2; }
        const span = a1 - a0;
        const n = Math.max(2, Math.ceil(ARC_SEGMENTS * span / (Math.PI * 2)));
        const pts = [];
        for (let i = 0; i <= n; i++) {
            const a = a0 + span * i / n;
            const x = cx + r * Math.cos(a);
            pts.push([flipX ? -x : x, cy + r * Math.sin(a), cz]);
        }
        return pts;
    }

    // Points along a bulged polyline segment from p to q (bulge = tan(angle / 4)).
    function bulgePoints (p, q, bulge) {
        const dx = q[0] - p[0], dy = q[1] - p[1];
        const chord = Math.hypot(dx, dy);
        if (chord < 1e-12 || Math.abs(bulge) < 1e-9) { return [q]; }
        const theta = 4 * Math.atan(bulge);
        const r = chord / (2 * Math.sin(theta / 2));
        const mx = (p[0] + q[0]) / 2, my = (p[1] + q[1]) / 2;
        const d = r * Math.cos(theta / 2);
        const cx = mx - d * dy / chord, cy = my + d * dx / chord;
        const a0 = Math.atan2(p[1] - cy, p[0] - cx);
        const n = Math.max(2, Math.ceil(ARC_SEGMENTS * Math.abs(theta) / (Math.PI * 2)));
        const pts = [];
        for (let i = 1; i <= n; i++) {
            const a = a0 + theta * i / n;
            pts.push([cx + Math.abs(r) * Math.cos(a), cy + Math.abs(r) * Math.sin(a), p[2]]);
        }
        pts[pts.length - 1] = q;
        return pts;
    }

    function bspline (degree, knots, ctrl, samples) {
        const n = ctrl.length - 1;
        if (n < degree || knots.length < n + degree + 2) { return ctrl; }
        const lo = knots[degree], hi = knots[n + 1];
        const pts = [];
        for (let s = 0; s <= samples; s++) {
            let t = lo + (hi - lo) * s / samples;
            if (s === samples) { t = hi - 1e-9 * Math.max(1, Math.abs(hi)); }
            let k = degree;
            while (k < n && t >= knots[k + 1]) { k++; }
            const d = [];
            for (let j = 0; j <= degree; j++) { d.push(ctrl[j + k - degree].slice()); }
            for (let r = 1; r <= degree; r++) {
                for (let j = degree; j >= r; j--) {
                    const i0 = j + k - degree;
                    const den = knots[i0 + degree - r + 1] - knots[i0];
                    const a = den === 0 ? 0 : (t - knots[i0]) / den;
                    for (let c = 0; c < 3; c++) { d[j][c] = (1 - a) * d[j - 1][c] + a * d[j][c]; }
                }
            }
            pts.push(d[degree]);
        }
        return pts;
    }

    function convert (text) {
        const pairs = parsePairs(text);
        const blocks = {};
        let entities = [];
        let units = 0;

        for (let i = 0; i < pairs.length; i++) {
            if (pairs[i][0] === 9 && pairs[i][1] === '$INSUNITS' && i + 1 < pairs.length) {
                units = parseInt(pairs[i + 1][1], 10) || 0;
            }
            if (pairs[i][0] === 0 && pairs[i][1] === 'SECTION' && i + 1 < pairs.length && pairs[i + 1][0] === 2) {
                const name = pairs[i + 1][1];
                if (name === 'ENTITIES') {
                    const r = readEntities(pairs, i + 2, 'ENDSEC');
                    entities = r.list;
                    i = r.next;
                } else if (name === 'BLOCKS') {
                    const r = readEntities(pairs, i + 2, 'ENDSEC');
                    let cur = null;
                    for (const e of r.list) {
                        if (e.type === 'BLOCK') {
                            cur = { name: str(e, 2, ''), base: [num(e, 10, 0), num(e, 20, 0), num(e, 30, 0)], entities: [] };
                        } else if (e.type === 'ENDBLK') {
                            if (cur) { blocks[cur.name] = cur; }
                            cur = null;
                        } else if (cur) {
                            cur.entities.push(e);
                        }
                    }
                    i = r.next;
                }
            }
        }

        const verts = [];
        const lines = [];
        const faces = [];
        const stats = { entities: 0, skipped: {} };

        function addVertex (p, m) {
            const q = m ? m(p) : p;
            verts.push(q);
            return verts.length;
        }
        function addLine (pts, closed, m) {
            if (pts.length < 2) { return; }
            const idx = pts.map((p) => addVertex(p, m));
            if (closed) { idx.push(idx[0]); }
            lines.push(idx);
        }
        function addFace (pts, m) {
            if (pts.length < 3) { return; }
            faces.push(pts.map((p) => addVertex(p, m)));
        }

        function emit (list, m, depth) {
            for (let i = 0; i < list.length; i++) {
                const e = list[i];
                stats.entities++;
                const flip = num(e, 230, 1) < 0;
                switch (e.type) {
                    case 'LINE':
                        addLine([[num(e, 10, 0), num(e, 20, 0), num(e, 30, 0)], [num(e, 11, 0), num(e, 21, 0), num(e, 31, 0)]], false, m);
                        break;
                    case 'CIRCLE':
                        addLine(arcPoints(num(e, 10, 0), num(e, 20, 0), num(e, 30, 0), num(e, 40, 0), 0, Math.PI * 2, flip), false, m);
                        break;
                    case 'ARC':
                        addLine(arcPoints(num(e, 10, 0), num(e, 20, 0), num(e, 30, 0), num(e, 40, 0),
                            num(e, 50, 0) * Math.PI / 180, num(e, 51, 360) * Math.PI / 180, flip), false, m);
                        break;
                    case 'ELLIPSE': {
                        const c = [num(e, 10, 0), num(e, 20, 0), num(e, 30, 0)];
                        const mj = [num(e, 11, 1), num(e, 21, 0), num(e, 31, 0)];
                        const ratio = num(e, 40, 1);
                        let a0 = num(e, 41, 0), a1 = num(e, 42, Math.PI * 2);
                        while (a1 <= a0) { a1 += Math.PI * 2; }
                        const mn = [-mj[1] * ratio, mj[0] * ratio, 0];
                        const n = Math.max(8, Math.ceil(ARC_SEGMENTS * (a1 - a0) / (Math.PI * 2)));
                        const pts = [];
                        for (let k = 0; k <= n; k++) {
                            const a = a0 + (a1 - a0) * k / n;
                            pts.push([c[0] + mj[0] * Math.cos(a) + mn[0] * Math.sin(a),
                                c[1] + mj[1] * Math.cos(a) + mn[1] * Math.sin(a), c[2] + mj[2] * Math.cos(a)]);
                        }
                        addLine(pts, false, m);
                        break;
                    }
                    case 'LWPOLYLINE': {
                        const elev = num(e, 38, 0);
                        const closed = (num(e, 70, 0) & 1) === 1;
                        const vs = [];
                        for (const p of e.pairs) {
                            if (p[0] === 10) { vs.push({ x: parseFloat(p[1]), y: 0, b: 0 }); }
                            else if (p[0] === 20 && vs.length) { vs[vs.length - 1].y = parseFloat(p[1]); }
                            else if (p[0] === 42 && vs.length) { vs[vs.length - 1].b = parseFloat(p[1]); }
                        }
                        if (vs.length < 2) { break; }
                        const pts = [[vs[0].x, vs[0].y, elev]];
                        const count = closed ? vs.length : vs.length - 1;
                        for (let k = 0; k < count; k++) {
                            const a = vs[k], b = vs[(k + 1) % vs.length];
                            for (const q of bulgePoints([a.x, a.y, elev], [b.x, b.y, elev], a.b)) { pts.push(q); }
                        }
                        addLine(flip ? pts.map((p) => [-p[0], p[1], p[2]]) : pts, false, m);
                        break;
                    }
                    case 'POLYLINE': {
                        const flags = num(e, 70, 0);
                        const vs = [];
                        const faceRecords = [];
                        let j = i + 1;
                        for (; j < list.length && list[j].type === 'VERTEX'; j++) {
                            const v = list[j];
                            const vf = num(v, 70, 0);
                            if ((vf & 128) && !(vf & 64)) {
                                faceRecords.push([num(v, 71, 0), num(v, 72, 0), num(v, 73, 0), num(v, 74, 0)]);
                            } else {
                                vs.push({ p: [num(v, 10, 0), num(v, 20, 0), num(v, 30, 0)], b: num(v, 42, 0) });
                            }
                        }
                        if (j < list.length && list[j].type === 'SEQEND') { j++; }
                        i = j - 1;
                        if (flags & 64) {
                            for (const f of faceRecords) {
                                const pts = f.filter((k) => k !== 0).map((k) => vs[Math.abs(k) - 1]).filter(Boolean).map((v) => v.p);
                                addFace(pts, m);
                            }
                        } else if (flags & 16) {
                            const mCount = num(e, 71, 0), nCount = num(e, 72, 0);
                            for (let a = 0; a + 1 < mCount; a++) {
                                for (let b = 0; b + 1 < nCount; b++) {
                                    const q = [vs[a * nCount + b], vs[a * nCount + b + 1], vs[(a + 1) * nCount + b + 1], vs[(a + 1) * nCount + b]];
                                    if (q.every(Boolean)) { addFace(q.map((v) => v.p), m); }
                                }
                            }
                        } else if (vs.length >= 2) {
                            const closed = (flags & 1) === 1;
                            const pts = [vs[0].p];
                            const count = closed ? vs.length : vs.length - 1;
                            for (let k = 0; k < count; k++) {
                                const a = vs[k], b = vs[(k + 1) % vs.length];
                                if (flags & 8) { pts.push(b.p); }
                                else { for (const q of bulgePoints(a.p, b.p, a.b)) { pts.push(q); } }
                            }
                            addLine(pts, false, m);
                        }
                        break;
                    }
                    case 'SPLINE': {
                        const degree = num(e, 71, 3);
                        const knots = all(e, 40);
                        const xs = all(e, 10), ys = all(e, 20), zs = all(e, 30);
                        const ctrl = xs.map((x, k) => [x, ys[k] || 0, zs[k] || 0]);
                        const fx = all(e, 11), fy = all(e, 21), fz = all(e, 31);
                        let pts;
                        if (ctrl.length > degree) {
                            pts = bspline(degree, knots, ctrl, Math.max(24, ctrl.length * 8));
                        } else {
                            pts = fx.map((x, k) => [x, fy[k] || 0, fz[k] || 0]);
                        }
                        addLine(pts, false, m);
                        break;
                    }
                    case '3DFACE':
                    case 'SOLID':
                    case 'TRACE': {
                        const p = [0, 1, 2, 3].map((k) => [num(e, 10 + k, NaN), num(e, 20 + k, NaN), num(e, 30 + k, 0)]).filter((q) => !isNaN(q[0]) && !isNaN(q[1]));
                        // SOLID / TRACE list the last two corners in swapped order.
                        if (e.type !== '3DFACE' && p.length === 4) { const t = p[2]; p[2] = p[3]; p[3] = t; }
                        if (p.length === 4 && p[2][0] === p[3][0] && p[2][1] === p[3][1] && p[2][2] === p[3][2]) { p.pop(); }
                        addFace(p, m);
                        break;
                    }
                    case 'INSERT':
                    case 'DIMENSION': {
                        const block = blocks[str(e, 2, '')];
                        if (!block || depth > 8) { break; }
                        let child;
                        if (e.type === 'DIMENSION') {
                            child = m;
                        } else {
                            const ins = [num(e, 10, 0), num(e, 20, 0), num(e, 30, 0)];
                            const sx = num(e, 41, 1), sy = num(e, 42, 1), sz = num(e, 43, 1);
                            const rot = num(e, 50, 0) * Math.PI / 180;
                            const cs = Math.cos(rot), sn = Math.sin(rot);
                            const base = block.base;
                            child = (p) => {
                                const x = (p[0] - base[0]) * sx, y = (p[1] - base[1]) * sy, z = (p[2] - base[2]) * sz;
                                const q = [ins[0] + x * cs - y * sn, ins[1] + x * sn + y * cs, ins[2] + z];
                                return m ? m(q) : q;
                            };
                        }
                        emit(block.entities, child, depth + 1);
                        break;
                    }
                    case 'VERTEX':
                    case 'SEQEND':
                    case 'ATTRIB':
                    case 'ATTDEF':
                        break;
                    default:
                        stats.skipped[e.type] = (stats.skipped[e.type] || 0) + 1;
                }
            }
        }

        emit(entities, null, 0);

        let flat = true;
        let z0 = verts.length ? verts[0][2] : 0;
        const out = ['# converted from DXF by Cone Setter', 'o drawing'];
        for (const v of verts) {
            if (Math.abs(v[2] - z0) > 1e-6) { flat = false; }
            out.push('v ' + (+v[0].toFixed(6)) + ' ' + (+v[1].toFixed(6)) + ' ' + (+v[2].toFixed(6)));
        }
        for (const f of faces) { out.push('f ' + f.join(' ')); }
        for (const l of lines) { out.push('l ' + l.join(' ')); }

        const unitNames = { 1: 'in', 2: 'ft', 4: 'mm', 5: 'cm', 6: 'm' };
        return {
            obj: out.join('\n') + '\n',
            flat: flat,
            lineCount: lines.length,
            faceCount: faces.length,
            vertexCount: verts.length,
            unit: unitNames[units] || '',
            skipped: stats.skipped
        };
    }

    window.DXF = { convert: convert };
})();
