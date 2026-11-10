// Blender .blend → OBJ (+MTL) converter for the 3D viewer.
// Reads the file's own structure description (SDNA), so it adapts to the layout of whichever
// Blender version wrote the file. Mesh objects are exported in world space with their viewport
// material colours. Handles gzip (before 3.0) and Zstandard (3.0+) compressed files, the classic
// MVert / MPoly / MLoop layout, the CustomData attribute layout (3.5 – 4.x) and the
// AttributeStorage layout (5.0+).
// Not handled: modifiers (the base mesh is shown), curves, text, metaballs, instanced
// collections and linked libraries.
(function (root) {
    'use strict';

    function fail (message) { throw new Error(message); }

    async function inflate (bytes) {
        if (bytes[0] === 0x1f && bytes[1] === 0x8b) {
            if (typeof DecompressionStream === 'undefined') { fail('This compressed .blend needs a newer iOS version to open.'); }
            const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream('gzip'));
            return new Uint8Array(await new Response(stream).arrayBuffer());
        }
        if (bytes[0] === 0x28 && bytes[1] === 0xb5 && bytes[2] === 0x2f && bytes[3] === 0xfd) {
            const z = root.fzstd;
            if (!z) { fail('Zstandard support is missing.'); }
            // Blender writes many frames plus a skippable seek table; the decoder handles both.
            return z.decompress(bytes);
        }
        return bytes;
    }

    function parse (bytes) {
        const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
        const ascii = (o, n) => String.fromCharCode.apply(null, bytes.subarray(o, o + n));
        if (ascii(0, 7) !== 'BLENDER') { fail('This is not a Blender file.'); }

        let headerSize, ptrSize, large = false, version;
        const c7 = ascii(7, 1);
        if (c7 === '_' || c7 === '-') {
            headerSize = 12;
            ptrSize = c7 === '-' ? 8 : 4;
            if (ascii(8, 1) === 'V') { fail('Big-endian .blend files are not supported.'); }
            version = parseInt(ascii(9, 3), 10);
        } else {
            headerSize = parseInt(ascii(7, 2), 10);
            if (!(headerSize >= 17)) { fail('Unrecognised .blend header.'); }
            ptrSize = 8;
            large = parseInt(ascii(10, 2), 10) >= 1;
            if (ascii(12, 1) === 'V') { fail('Big-endian .blend files are not supported.'); }
            version = parseInt(ascii(13, 4), 10);
        }

        const readPtr = ptrSize === 8
            ? (o) => view.getBigUint64(o, true)
            : (o) => BigInt(view.getUint32(o, true));

        // File blocks
        const blocks = [];
        // Blender reuses memory addresses between data-blocks, so one address can map to several
        // file blocks. Each DATA block belongs to the ID block written just before it ("owner"),
        // and pointers are resolved within the owner first.
        const byAddress = new Map();
        let dna = null;
        let owner = null;
        let pos = headerSize;
        while (pos + 16 <= bytes.length) {
            const code = ascii(pos, 4).replace(/\0+$/, '');
            let len, old, sdna, count, head;
            if (large) {
                sdna = view.getInt32(pos + 4, true);
                old = view.getBigUint64(pos + 8, true);
                len = Number(view.getBigInt64(pos + 16, true));
                count = Number(view.getBigInt64(pos + 24, true));
                head = 32;
            } else if (ptrSize === 8) {
                len = view.getInt32(pos + 4, true);
                old = view.getBigUint64(pos + 8, true);
                sdna = view.getInt32(pos + 16, true);
                count = view.getInt32(pos + 20, true);
                head = 24;
            } else {
                len = view.getInt32(pos + 4, true);
                old = BigInt(view.getUint32(pos + 8, true));
                sdna = view.getInt32(pos + 12, true);
                count = view.getInt32(pos + 16, true);
                head = 20;
            }
            if (code === 'ENDB') { break; }
            if (len < 0 || pos + head + len > bytes.length) { fail('The .blend file is cut short or damaged.'); }
            const block = { code, old, sdna, count, offset: pos + head, length: len, owner: null };
            if (code !== 'DATA') { owner = block; }
            block.owner = owner;
            blocks.push(block);
            if (code === 'DNA1') {
                dna = block;
            } else {
                const list = byAddress.get(old);
                if (list) { list.push(block); } else { byAddress.set(old, [block]); }
            }
            pos += head + len;
        }
        if (!dna) { fail('The .blend file has no structure table (DNA).'); }

        // SDNA
        let p = dna.offset;
        const expect = (tag) => {
            for (let k = 0; k < 8; k++) {
                if (ascii(p + k, 4) === tag) { p += k + 4; return; }
            }
            fail('Unexpected .blend structure table.');
        };
        const readStrings = () => {
            const n = view.getInt32(p, true); p += 4;
            const out = [];
            for (let i = 0; i < n; i++) {
                let e = p;
                while (bytes[e] !== 0) { e++; }
                out.push(ascii(p, e - p));
                p = e + 1;
            }
            return out;
        };
        expect('SDNA'); expect('NAME');
        const names = readStrings();
        expect('TYPE');
        const types = readStrings();
        expect('TLEN');
        const typeLen = [];
        for (let i = 0; i < types.length; i++) { typeLen.push(view.getInt16(p + 2 * i, true)); }
        p += 2 * types.length;
        expect('STRC');
        const structCount = view.getInt32(p, true); p += 4;
        const structs = [];          // by SDNA index
        const structByName = {};
        for (let i = 0; i < structCount; i++) {
            const typeIndex = view.getInt16(p, true);
            const nFields = view.getInt16(p + 2, true);
            p += 4;
            const fields = {};
            let off = 0;
            for (let f = 0; f < nFields; f++) {
                const ft = view.getInt16(p, true);
                const fn = names[view.getInt16(p + 2, true)];
                p += 4;
                const isPtr = fn[0] === '*' || fn[0] === '(';
                let dims = 1;
                const re = /\[(\d+)\]/g;
                let m;
                while ((m = re.exec(fn)) !== null) { dims *= parseInt(m[1], 10); }
                const base = fn.replace(/^[*(]+/, '').replace(/[\[)].*$/, '');
                const size = (isPtr ? ptrSize : typeLen[ft]) * dims;
                fields[base] = { type: types[ft], offset: off, size: size, isPtr: isPtr, dims: dims };
                off += size;
            }
            const s = { name: types[typeIndex], size: typeLen[typeIndex], fields: fields };
            structs.push(s);
            structByName[s.name] = s;
        }

        return { bytes, view, version, ptrSize, readPtr, blocks, byAddress, structs, structByName };
    }

    function convertParsed (f) {
        const { bytes, view, readPtr, byAddress, structByName } = f;
        const S = (name) => structByName[name] || fail('This .blend file has no "' + name + '" description.');
        const has = (sn, field) => !!(structByName[sn] && structByName[sn].fields[field]);
        const off = (sn, field) => {
            const fl = S(sn).fields[field];
            if (!fl) { fail('Unsupported .blend layout (' + sn + '.' + field + ' missing).'); }
            return fl.offset;
        };
        let scope = null;       // the ID block whose data is being read
        const deref = (ptr) => {
            if (ptr === 0n) { return null; }
            const list = byAddress.get(ptr);
            if (!list) { return null; }
            if (list.length === 1) { return list[0]; }
            return list.find((b) => b.owner === scope) || list.find((b) => b.code !== 'DATA') || list[0];
        };
        const ptrAt = (o) => readPtr(o);
        const cstr = (o, max) => {
            let e = o;
            const end = Math.min(o + max, bytes.length);
            while (e < end && bytes[e] !== 0) { e++; }
            try { return new TextDecoder('utf-8').decode(bytes.subarray(o, e)); } catch (err) { return ''; }
        };
        const idName = (base) => cstr(base + off('ID', 'name') + 2, S('ID').fields.name.size - 2);
        const floats = (o, n) => { const a = []; for (let i = 0; i < n; i++) { a.push(view.getFloat32(o + 4 * i, true)); } return a; };

        // ---- matrices (column-major 4×4, as Blender stores them) ----
        const identity = () => [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
        const mul = (a, b) => {
            const o = new Array(16);
            for (let c = 0; c < 4; c++) {
                for (let r = 0; r < 4; r++) {
                    let s = 0;
                    for (let k = 0; k < 4; k++) { s += a[k * 4 + r] * b[c * 4 + k]; }
                    o[c * 4 + r] = s;
                }
            }
            return o;
        };
        const rotAxis = (axis, a) => {
            const c = Math.cos(a), s = Math.sin(a);
            if (axis === 0) { return [1, 0, 0, 0, 0, c, s, 0, 0, -s, c, 0, 0, 0, 0, 1]; }
            if (axis === 1) { return [c, 0, -s, 0, 0, 1, 0, 0, s, 0, c, 0, 0, 0, 0, 1]; }
            return [c, s, 0, 0, -s, c, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
        };
        const quatMatrix = (q) => {
            let [w, x, y, z] = q;
            const n = Math.hypot(w, x, y, z) || 1;
            w /= n; x /= n; y /= n; z /= n;
            return [
                1 - 2 * (y * y + z * z), 2 * (x * y + z * w), 2 * (x * z - y * w), 0,
                2 * (x * y - z * w), 1 - 2 * (x * x + z * z), 2 * (y * z + x * w), 0,
                2 * (x * z + y * w), 2 * (y * z - x * w), 1 - 2 * (x * x + y * y), 0,
                0, 0, 0, 1
            ];
        };
        const EULER_ORDERS = { 1: [0, 1, 2], 2: [0, 2, 1], 3: [1, 0, 2], 4: [1, 2, 0], 5: [2, 0, 1], 6: [2, 1, 0] };

        const worldCache = new Map();
        function localMatrix (ob) {
            const O = 'Object';
            const loc = floats(ob + off(O, 'loc'), 3);
            const dloc = has(O, 'dloc') ? floats(ob + off(O, 'dloc'), 3) : [0, 0, 0];
            const scale = floats(ob + off(O, 'size'), 3);
            const dscale = has(O, 'dscale') ? floats(ob + off(O, 'dscale'), 3) : [1, 1, 1];
            const mode = has(O, 'rotmode') ? view.getInt16(ob + off(O, 'rotmode'), true) : 1;
            let rot;
            if (mode === 0) {
                rot = quatMatrix(floats(ob + off(O, 'quat'), 4));
            } else if (mode === -1) {
                const ax = floats(ob + off(O, 'rotAxis'), 3);
                const ang = view.getFloat32(ob + off(O, 'rotAngle'), true);
                const n = Math.hypot(ax[0], ax[1], ax[2]) || 1;
                const h = ang / 2, s = Math.sin(h);
                rot = quatMatrix([Math.cos(h), ax[0] / n * s, ax[1] / n * s, ax[2] / n * s]);
            } else {
                const e = floats(ob + off(O, 'rot'), 3);
                const order = EULER_ORDERS[mode] || EULER_ORDERS[1];
                rot = identity();
                // First axis in the order is applied first, so it ends up rightmost.
                for (const axis of order) { rot = mul(rotAxis(axis, e[axis]), rot); }
            }
            const m = rot.slice();
            for (let c = 0; c < 3; c++) {
                const s = scale[c] * (dscale[c] === 0 ? 1 : dscale[c]);
                for (let r = 0; r < 3; r++) { m[c * 4 + r] *= s; }
            }
            m[12] = loc[0] + dloc[0]; m[13] = loc[1] + dloc[1]; m[14] = loc[2] + dloc[2];
            return m;
        }
        function worldMatrix (block, depth) {
            if (worldCache.has(block.old)) { return worldCache.get(block.old); }
            const ob = block.offset;
            let m = localMatrix(ob);
            const parentList = byAddress.get(ptrAt(ob + off('Object', 'parent')));
            const parent = parentList ? parentList.find((b) => b.code === 'OB') : null;
            if (parent && parent.code === 'OB' && depth < 64) {
                const inv = floats(ob + off('Object', 'parentinv'), 16);
                m = mul(worldMatrix(parent, depth + 1), mul(inv, m));
            }
            worldCache.set(block.old, m);
            return m;
        }

        // ---- attribute lookup across the three mesh layouts ----
        function customDataLayer (cd, name, type) {
            const CD = 'CustomData', L = 'CustomDataLayer';
            if (!structByName[CD] || !structByName[L]) { return null; }
            const layers = deref(ptrAt(cd + off(CD, 'layers')));
            if (!layers) { return null; }
            const total = view.getInt32(cd + off(CD, 'totlayer'), true);
            const size = S(L).size;
            for (let i = 0; i < total && (i + 1) * size <= layers.length; i++) {
                const base = layers.offset + i * size;
                const ltype = view.getInt32(base + off(L, 'type'), true);
                const lname = cstr(base + off(L, 'name'), S(L).fields.name.size);
                if (lname === name && (type === undefined || ltype === type)) {
                    return deref(ptrAt(base + off(L, 'data')));
                }
            }
            return null;
        }
        // Returns { block, single } for a named attribute in AttributeStorage (Blender 5+).
        function storageAttribute (mesh, name, domain) {
            if (!has('Mesh', 'attribute_storage') || !structByName.Attribute) { return null; }
            const st = mesh + off('Mesh', 'attribute_storage');
            const arr = deref(ptrAt(st + off('AttributeStorage', 'dna_attributes')));
            if (!arr) { return null; }
            const n = view.getInt32(st + off('AttributeStorage', 'dna_attributes_num'), true);
            const size = S('Attribute').size;
            for (let i = 0; i < n && (i + 1) * size <= arr.length; i++) {
                const base = arr.offset + i * size;
                const nameBlock = deref(ptrAt(base + off('Attribute', 'name')));
                if (!nameBlock || cstr(nameBlock.offset, nameBlock.length) !== name) { continue; }
                if (domain !== undefined && view.getInt8(base + off('Attribute', 'domain')) !== domain) { continue; }
                const storage = view.getInt8(base + off('Attribute', 'storage_type'));
                const holder = deref(ptrAt(base + off('Attribute', 'data')));
                if (!holder) { return null; }
                // Both AttributeArray and AttributeSingle start with the data pointer.
                const data = deref(ptrAt(holder.offset));
                return data ? { block: data, single: storage === 1 } : null;
            }
            return null;
        }

        const lines = ['# converted from a Blender file by Cone Setter'];
        const mtl = ['# materials from a Blender file'];
        const materialNames = new Map();
        const warnings = [];
        let vertexBase = 0;
        let meshObjects = 0, otherObjects = 0, withModifiers = 0, faceTotal = 0;

        function materialName (ptr) {
            if (ptr === 0n) { return null; }
            if (materialNames.has(ptr)) { return materialNames.get(ptr); }
            const block = deref(ptr);
            if (!block || block.code !== 'MA') { return null; }
            const base = block.offset;
            const name = 'm' + materialNames.size + '_' + idName(base).replace(/[^A-Za-z0-9_.-]/g, '_');
            let rgb = [0.8, 0.8, 0.8];
            if (has('Material', 'r')) { rgb = floats(base + off('Material', 'r'), 3); }
            // Viewport colours are linear; convert to sRGB for display.
            const srgb = rgb.map((c) => {
                const v = Math.min(Math.max(c, 0), 1);
                return v <= 0.0031308 ? v * 12.92 : 1.055 * Math.pow(v, 1 / 2.4) - 0.055;
            });
            mtl.push('newmtl ' + name, 'Kd ' + srgb.map((v) => v.toFixed(4)).join(' '), 'd 1', '');
            materialNames.set(ptr, name);
            return name;
        }

        const objects = f.blocks.filter((b) => b.code === 'OB');
        for (const block of objects) {
            const ob = block.offset;
            scope = block;
            const type = view.getInt16(ob + off('Object', 'type'), true);
            const data = deref(ptrAt(ob + off('Object', 'data')));
            if (type !== 1 || !data || data.code !== 'ME') {
                if (type !== 0) { otherObjects++; }
                continue;
            }
            if (has('Object', 'modifiers') && ptrAt(ob + off('Object', 'modifiers')) !== 0n) { withModifiers++; }

            const mesh = data.offset;
            const M = 'Mesh';
            scope = data;
            const totvert = view.getInt32(mesh + off(M, 'totvert'), true);
            const totpoly = has(M, 'totpoly') ? view.getInt32(mesh + off(M, 'totpoly'), true) : 0;
            const totloop = has(M, 'totloop') ? view.getInt32(mesh + off(M, 'totloop'), true) : 0;
            if (totvert <= 0) { continue; }

            // Positions
            let posBlock = null, posStride = 12;
            const mvert = has(M, 'mvert') ? deref(ptrAt(mesh + off(M, 'mvert'))) : null;
            if (mvert && structByName.MVert) {
                posBlock = mvert; posStride = S('MVert').size;
            } else {
                posBlock = has(M, 'vdata') ? customDataLayer(mesh + off(M, 'vdata'), 'position') : null;
                if (!posBlock) { const a = storageAttribute(mesh, 'position'); posBlock = a ? a.block : null; }
            }
            if (!posBlock || posBlock.length < totvert * posStride) {
                warnings.push('Skipped "' + idName(ob) + '": no vertex data found.');
                continue;
            }

            // Corner → vertex indices
            let cornerBlock = null, cornerStride = 4;
            const mloop = has(M, 'mloop') ? deref(ptrAt(mesh + off(M, 'mloop'))) : null;
            if (mloop && structByName.MLoop) {
                cornerBlock = mloop; cornerStride = S('MLoop').size;
            } else {
                cornerBlock = has(M, 'ldata') ? customDataLayer(mesh + off(M, 'ldata'), '.corner_vert') : null;
                if (!cornerBlock) { const a = storageAttribute(mesh, '.corner_vert'); cornerBlock = a ? a.block : null; }
            }

            // Faces
            const faces = [];       // [start, count, materialIndex]
            const mpoly = has(M, 'mpoly') ? deref(ptrAt(mesh + off(M, 'mpoly'))) : null;
            const offsets = has(M, 'poly_offset_indices') ? deref(ptrAt(mesh + off(M, 'poly_offset_indices'))) : null;
            let matIndex = null;    // function(faceIndex) → material slot
            if (mpoly && structByName.MPoly && has('MPoly', 'loopstart')) {
                const ps = S('MPoly').size;
                const oStart = off('MPoly', 'loopstart'), oCount = off('MPoly', 'totloop');
                const oMat = has('MPoly', 'mat_nr') ? off('MPoly', 'mat_nr') : -1;
                for (let i = 0; i < totpoly && (i + 1) * ps <= mpoly.length; i++) {
                    const b = mpoly.offset + i * ps;
                    faces.push([view.getInt32(b + oStart, true), view.getInt32(b + oCount, true),
                        oMat >= 0 ? view.getInt16(b + oMat, true) : 0]);
                }
            } else if (offsets && offsets.length >= (totpoly + 1) * 4) {
                for (let i = 0; i < totpoly; i++) {
                    const a = view.getInt32(offsets.offset + 4 * i, true);
                    const b = view.getInt32(offsets.offset + 4 * (i + 1), true);
                    faces.push([a, b - a, 0]);
                }
            }
            if (faces.length && !(mpoly && has('MPoly', 'mat_nr'))) {
                let layer = has(M, 'pdata') ? customDataLayer(mesh + off(M, 'pdata'), 'material_index') : null;
                let single = false;
                if (!layer) {
                    const a = storageAttribute(mesh, 'material_index');
                    if (a) { layer = a.block; single = a.single; }
                }
                if (layer) {
                    matIndex = (i) => {
                        const o = layer.offset + (single ? 0 : 4 * i);
                        return o + 4 <= layer.offset + layer.length ? view.getInt32(o, true) : 0;
                    };
                }
            }

            // Very old files (before 2.63) only have tessellated faces.
            let legacyFaces = null;
            if (!faces.length && has(M, 'mface') && structByName.MFace) {
                const mface = deref(ptrAt(mesh + off(M, 'mface')));
                const totface = has(M, 'totface') ? view.getInt32(mesh + off(M, 'totface'), true) : 0;
                if (mface && totface > 0) {
                    legacyFaces = [];
                    const fs = S('MFace').size;
                    for (let i = 0; i < totface && (i + 1) * fs <= mface.length; i++) {
                        const b = mface.offset + i * fs;
                        const v = [0, 1, 2, 3].map((k) => view.getUint32(b + 4 * k, true));
                        const mat = has('MFace', 'mat_nr') ? view.getInt16(b + off('MFace', 'mat_nr'), true) : 0;
                        legacyFaces.push([v[3] === 0 ? v.slice(0, 3) : v, mat]);
                    }
                }
            }
            if (!legacyFaces && (!faces.length || !cornerBlock)) {
                if (totpoly > 0) { warnings.push('Skipped "' + idName(ob) + '": unsupported face layout.'); }
                continue;
            }

            // Material slots: the object can override the mesh's slots.
            const slotNames = [];
            const totcol = has(M, 'totcol') ? view.getInt16(mesh + off(M, 'totcol'), true) : 0;
            const meshMats = totcol > 0 ? deref(ptrAt(mesh + off(M, 'mat'))) : null;
            scope = block;
            const obMats = has('Object', 'mat') ? deref(ptrAt(ob + off('Object', 'mat'))) : null;
            const matbits = has('Object', 'matbits') ? deref(ptrAt(ob + off('Object', 'matbits'))) : null;
            for (let i = 0; i < totcol; i++) {
                let ptr = 0n;
                const useObject = matbits && i < matbits.length && bytes[matbits.offset + i] !== 0;
                if (useObject && obMats && (i + 1) * f.ptrSize <= obMats.length) { ptr = ptrAt(obMats.offset + i * f.ptrSize); }
                else if (meshMats && (i + 1) * f.ptrSize <= meshMats.length) { ptr = ptrAt(meshMats.offset + i * f.ptrSize); }
                slotNames.push(materialName(ptr));
            }

            const m = worldMatrix(block, 0);
            const name = idName(ob).replace(/\s+/g, '_') || 'object';
            lines.push('o ' + name);
            for (let i = 0; i < totvert; i++) {
                const b = posBlock.offset + i * posStride;
                const x = view.getFloat32(b, true), y = view.getFloat32(b + 4, true), z = view.getFloat32(b + 8, true);
                lines.push('v ' + (+(m[0] * x + m[4] * y + m[8] * z + m[12]).toFixed(6)) + ' ' +
                    (+(m[1] * x + m[5] * y + m[9] * z + m[13]).toFixed(6)) + ' ' +
                    (+(m[2] * x + m[6] * y + m[10] * z + m[14]).toFixed(6)));
            }

            let current;
            const useMaterial = (slot) => {
                const mn = slot >= 0 && slot < slotNames.length ? slotNames[slot] : null;
                if (mn !== current) {
                    current = mn;
                    if (mn) { lines.push('usemtl ' + mn); }
                }
            };
            if (legacyFaces) {
                for (const [v, mat] of legacyFaces) {
                    if (v.some((k) => k >= totvert)) { continue; }
                    useMaterial(mat);
                    lines.push('f ' + v.map((k) => k + 1 + vertexBase).join(' '));
                    faceTotal++;
                }
            } else {
                const corners = Math.min(totloop, Math.floor(cornerBlock.length / cornerStride));
                for (let i = 0; i < faces.length; i++) {
                    const [start, count, mat] = faces[i];
                    if (count < 3 || start < 0 || start + count > corners) { continue; }
                    useMaterial(matIndex ? matIndex(i) : mat);
                    let line = 'f';
                    let ok = true;
                    for (let k = 0; k < count; k++) {
                        const v = view.getUint32(cornerBlock.offset + (start + k) * cornerStride, true);
                        if (v >= totvert) { ok = false; break; }
                        line += ' ' + (v + 1 + vertexBase);
                    }
                    if (ok) { lines.push(line); faceTotal++; }
                }
            }
            vertexBase += totvert;
            meshObjects++;
        }

        if (meshObjects === 0) {
            fail(otherObjects > 0
                ? 'This .blend has no mesh objects (only curves, text or other object types, which are not supported).'
                : 'This .blend has no mesh objects.');
        }
        const v = f.version;
        return {
            obj: 'mtllib materials.mtl\n' + lines.join('\n') + '\n',
            mtl: mtl.join('\n') + '\n',
            meshObjects: meshObjects,
            otherObjects: otherObjects,
            withModifiers: withModifiers,
            faces: faceTotal,
            version: v >= 300 ? Math.floor(v / 100) + '.' + (v % 100) : Math.floor(v / 100) + '.' + String(v % 100).padStart(2, '0'),
            warnings: warnings
        };
    }

    async function convert (buffer) {
        const raw = new Uint8Array(buffer);
        const bytes = await inflate(raw);
        return convertParsed(parse(bytes));
    }

    root.BLEND = { convert: convert };
})(typeof window !== 'undefined' ? window : globalThis);
