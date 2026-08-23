const std = @import("std");
const rl = @import("raylib");

const world = @import("world.zig");
const textures = @import("textures.zig");
const player = @import("player.zig");

const World = world.World;
const Tile = world.Tile;
const Player = player.Player;
const Atlas = textures.Atlas;
const TEX_SIZE = textures.TEX_SIZE;
const EMISSIVE = textures.EMISSIVE;

/// Tope de celdas que recorre el DDA antes de rendirse. Es la garantia de que
/// el bucle siempre termina, incluso si algun dia un nivel quedara abierto.
pub const MAX_DDA_STEPS: u32 = 128;

/// Constante de la niebla. Mas alto = la oscuridad se come el pasillo antes.
const FOG_K: f32 = 0.22;
const FOG_FLOOR: f32 = 0.13; // luz minima: nunca se llega al negro absoluto
const SIDE_SHADE: f32 = 0.72; // caras norte/sur mas oscuras que este/oeste
const MIN_DIST: f32 = 1e-4;

pub const Framebuffer = struct {
    width: i32,
    height: i32,
    pixels: []rl.Color, // len == width*height, se sube tal cual con updateTexture
    depth: []f32, // distancia perpendicular por columna, para tapar sprites

    pub fn init(gpa: std.mem.Allocator, width: i32, height: i32) !Framebuffer {
        const pixels = try gpa.alloc(rl.Color, @intCast(width * height));
        errdefer gpa.free(pixels);
        const depth = try gpa.alloc(f32, @intCast(width));
        @memset(pixels, textures.VOID);
        @memset(depth, std.math.floatMax(f32));
        return .{ .width = width, .height = height, .pixels = pixels, .depth = depth };
    }

    /// Unica funcion para escribir un pixel suelto. Las coordenadas fuera de
    /// rango se ignoran, igual que en el canvas del lab-01: los bucles internos
    /// que ya vienen acotados escriben directo al slice y se saltan el chequeo.
    pub fn put(self: *Framebuffer, x: i32, y: i32, c: rl.Color) void {
        if (x < 0 or y < 0 or x >= self.width or y >= self.height) return;
        self.pixels[@intCast(y * self.width + x)] = c;
    }
};

pub const Hit = struct {
    dist: f32, // distancia perpendicular al plano de camara
    tile: Tile,
    side: u1, // 0 = cara este/oeste, 1 = cara norte/sur
    wall_x: f32, // posicion fraccionaria del impacto sobre la cara, en [0,1)
    map_x: i32,
    map_y: i32,
    steps: u32,
};

/// Lanza un rayo con DDA sobre la grilla y devuelve la primera celda solida.
///
/// La distancia que devuelve es la proyeccion sobre el eje de la camara, no la
/// longitud euclidiana del rayo. Esa distincion es la correccion de ojo de pez:
/// con la euclidiana las paredes rectas se ven curvadas hacia el espectador.
pub fn castRay(w: *const World, px: f32, py: f32, rdx: f32, rdy: f32) Hit {
    var map_x = world.tileOf(px);
    var map_y = world.tileOf(py);

    const delta_x: f32 = if (rdx == 0) std.math.floatMax(f32) else @abs(1.0 / rdx);
    const delta_y: f32 = if (rdy == 0) std.math.floatMax(f32) else @abs(1.0 / rdy);

    var step_x: i32 = 1;
    var step_y: i32 = 1;
    var side_x: f32 = undefined;
    var side_y: f32 = undefined;

    if (rdx < 0) {
        step_x = -1;
        side_x = (px - @as(f32, @floatFromInt(map_x))) * delta_x;
    } else {
        side_x = (@as(f32, @floatFromInt(map_x)) + 1.0 - px) * delta_x;
    }
    if (rdy < 0) {
        step_y = -1;
        side_y = (py - @as(f32, @floatFromInt(map_y))) * delta_y;
    } else {
        side_y = (@as(f32, @floatFromInt(map_y)) + 1.0 - py) * delta_y;
    }

    var side: u1 = 0;
    var steps: u32 = 0;
    while (steps < MAX_DDA_STEPS) : (steps += 1) {
        if (side_x < side_y) {
            side_x += delta_x;
            map_x += step_x;
            side = 0;
        } else {
            side_y += delta_y;
            map_y += step_y;
            side = 1;
        }
        if (w.isSolid(map_x, map_y)) break;
    }

    const perp = if (side == 0) side_x - delta_x else side_y - delta_y;
    const dist = @max(perp, MIN_DIST);

    // Fraccion del punto de impacto a lo largo de la cara golpeada.
    var wall_x = if (side == 0) py + dist * rdy else px + dist * rdx;
    wall_x -= @floor(wall_x);

    return .{
        .dist = dist,
        .tile = w.at(map_x, map_y),
        .side = side,
        .wall_x = wall_x,
        .map_x = map_x,
        .map_y = map_y,
        .steps = steps,
    };
}

/// Atenua un color por distancia. Los pixeles emisivos se devuelven intactos:
/// una tira de neon o el plasma de una celda tienen que seguir brillando al
/// fondo de un pasillo, que es justo lo que da la lectura de nave iluminada.
fn fog(c: rl.Color, dist: f32) rl.Color {
    if (c.a == EMISSIVE) return c;
    const f = std.math.clamp(1.0 / (1.0 + dist * FOG_K), FOG_FLOOR, 1.0);
    return textures.mix(c, textures.VOID, 1.0 - f);
}

/// Dibuja piso, techo y paredes al framebuffer y deja el z-buffer listo para
/// los sprites. `center` es el horizonte movil: el mismo valor lo consumen las
/// tres pasadas, asi que el cabeceo y la vista vertical salen coherentes sin
/// duplicar codigo.
pub fn renderWorld(fb: *Framebuffer, w: *const World, p: *const Player, atlas: *const Atlas) void {
    const width_f: f32 = @floatFromInt(fb.width);
    const height_f: f32 = @floatFromInt(fb.height);
    const center = height_f * 0.5 + p.pitch + p.bob_offset;

    renderFloorAndCeiling(fb, p, atlas, center);

    var x: i32 = 0;
    while (x < fb.width) : (x += 1) {
        const camera_x = 2.0 * @as(f32, @floatFromInt(x)) / width_f - 1.0;
        const rdx = p.dir_x + p.plane_x * camera_x;
        const rdy = p.dir_y + p.plane_y * camera_x;
        const hit = castRay(w, p.x, p.y, rdx, rdy);
        fb.depth[@intCast(x)] = hit.dist;

        const line_h = height_f / hit.dist;
        const start_f = center - line_h * 0.5;
        // Se acota en punto flotante ANTES de convertir a entero: con el jugador
        // pegado a un muro line_h se dispara y un @intFromFloat directo se
        // saldria del rango de i32.
        const y0: i32 = @intFromFloat(std.math.clamp(@ceil(start_f), 0, height_f));
        const y1: i32 = @intFromFloat(std.math.clamp(@ceil(start_f + line_h), 0, height_f));
        if (y1 <= y0) continue;

        const unlocked = switch (hit.tile) {
            .door => w.doorIsOpen(hit.map_x, hit.map_y),
            .exit => w.exit_open,
            else => false,
        };
        const wall = textures.wallFor(hit.tile, unlocked);

        // Se espeja la coordenada en las caras opuestas para que la textura no
        // salga invertida al mirar la misma pared desde el otro lado.
        var tex_x: i32 = @intFromFloat(hit.wall_x * @as(f32, @floatFromInt(TEX_SIZE)));
        if ((hit.side == 0 and rdx > 0) or (hit.side == 1 and rdy < 0)) {
            tex_x = TEX_SIZE - 1 - tex_x;
        }

        const step = @as(f32, @floatFromInt(TEX_SIZE)) / line_h;
        var tex_pos = (@as(f32, @floatFromInt(y0)) - start_f) * step;

        var idx: usize = @intCast(y0 * fb.width + x);
        var y = y0;
        while (y < y1) : (y += 1) {
            const tex_y: i32 = @intFromFloat(tex_pos);
            tex_pos += step;
            var c = atlas.wallTexel(wall, tex_x, tex_y);
            if (c.a != EMISSIVE) {
                if (hit.side == 1) c = textures.shade(c, SIDE_SHADE);
                c = fog(c, hit.dist);
            }
            fb.pixels[idx] = c;
            idx += @intCast(fb.width);
        }
    }
}

/// Piso y techo con un raycast horizontal por fila. Se dibujan antes que las
/// paredes para que estas los tapen sin necesidad de recortar nada.
fn renderFloorAndCeiling(fb: *Framebuffer, p: *const Player, atlas: *const Atlas, center: f32) void {
    const width_f: f32 = @floatFromInt(fb.width);
    const height_f: f32 = @floatFromInt(fb.height);
    const tex_f: f32 = @floatFromInt(TEX_SIZE);

    const rdx0 = p.dir_x - p.plane_x;
    const rdy0 = p.dir_y - p.plane_y;
    const rdx1 = p.dir_x + p.plane_x;
    const rdy1 = p.dir_y + p.plane_y;

    var y: i32 = 0;
    while (y < fb.height) : (y += 1) {
        const p_row = @as(f32, @floatFromInt(y)) + 0.5 - center;
        // Por encima del horizonte no hay piso que proyectar; esa mitad la
        // cubre el techo, que se dibuja espejado respecto de `center`.
        if (p_row <= 0.5) continue;

        const row_dist = (0.5 * height_f) / p_row;
        const step_x = row_dist * (rdx1 - rdx0) / width_f;
        const step_y = row_dist * (rdy1 - rdy0) / width_f;
        var fx = p.x + row_dist * rdx0;
        var fy = p.y + row_dist * rdy0;

        const ceil_y: i32 = @intFromFloat(std.math.clamp(center - p_row, -1.0, height_f));
        const draw_ceiling = ceil_y >= 0 and ceil_y < fb.height;

        var x: i32 = 0;
        while (x < fb.width) : (x += 1) {
            const tx: i32 = @intFromFloat((fx - @floor(fx)) * tex_f);
            const ty: i32 = @intFromFloat((fy - @floor(fy)) * tex_f);
            fx += step_x;
            fy += step_y;

            fb.pixels[@intCast(y * fb.width + x)] = fog(atlas.wallTexel(.floor, tx, ty), row_dist);
            if (draw_ceiling) {
                fb.pixels[@intCast(ceil_y * fb.width + x)] = fog(atlas.wallTexel(.ceiling, tx, ty), row_dist);
            }
        }
    }
}

const Visible = struct { index: usize, dist2: f32 };

fn farToNear(_: void, a: Visible, b: Visible) bool {
    return a.dist2 > b.dist2;
}

/// Dibuja los sprites como billboards despues de las paredes. Se ordenan de
/// lejos a cerca para que los cercanos queden encima, y cada columna se
/// compara contra el z-buffer: si la pared de esa columna esta mas cerca que
/// el sprite, la columna entera se salta y el sprite queda tapado.
pub fn renderSprites(fb: *Framebuffer, w: *const World, p: *const Player, atlas: *const Atlas) void {
    var list: [world.MAX_SPRITES]Visible = undefined;
    var count: usize = 0;

    var i: usize = 0;
    while (i < w.sprite_count) : (i += 1) {
        const s = w.sprites[i];
        if (!s.alive) continue;
        const dx = s.x - p.x;
        const dy = s.y - p.y;
        list[count] = .{ .index = i, .dist2 = dx * dx + dy * dy };
        count += 1;
    }
    std.mem.sort(Visible, list[0..count], {}, farToNear);

    const width_f: f32 = @floatFromInt(fb.width);
    const height_f: f32 = @floatFromInt(fb.height);
    const center = height_f * 0.5 + p.pitch + p.bob_offset;
    const spr_f: f32 = @floatFromInt(textures.SPR_SIZE);

    // Determinante inverso de la matriz [plane | dir], que lleva del mundo al
    // espacio de camara.
    const inv_det = 1.0 / (p.plane_x * p.dir_y - p.dir_x * p.plane_y);

    for (list[0..count]) |v| {
        const s = w.sprites[v.index];
        const rel_x = s.x - p.x;
        const rel_y = s.y - p.y;
        const tx = inv_det * (p.dir_y * rel_x - p.dir_x * rel_y);
        const ty = inv_det * (-p.plane_y * rel_x + p.plane_x * rel_y);
        if (ty <= 0.05) continue; // detras de la camara o pegado al ojo

        const screen_x = (width_f * 0.5) * (1.0 + tx / ty);
        const size = @abs(height_f / ty);
        const v_move = (s.z_offset * height_f) / ty;
        const top = center - size * 0.5 - v_move;
        const left = screen_x - size * 0.5;

        const x0: i32 = @intFromFloat(std.math.clamp(@ceil(left), 0, width_f));
        const x1: i32 = @intFromFloat(std.math.clamp(@ceil(left + size), 0, width_f));
        const y0: i32 = @intFromFloat(std.math.clamp(@ceil(top), 0, height_f));
        const y1: i32 = @intFromFloat(std.math.clamp(@ceil(top + size), 0, height_f));
        if (x1 <= x0 or y1 <= y0) continue;

        const frame = s.frame();
        var x = x0;
        while (x < x1) : (x += 1) {
            if (ty >= fb.depth[@intCast(x)]) continue; // tapado por una pared
            const tex_x: i32 = @intFromFloat((@as(f32, @floatFromInt(x)) - left) / size * spr_f);
            var y = y0;
            while (y < y1) : (y += 1) {
                const tex_y: i32 = @intFromFloat((@as(f32, @floatFromInt(y)) - top) / size * spr_f);
                const c = atlas.spriteTexel(s.kind, frame, tex_x, tex_y);
                if (c.a == 0) continue;
                const idx: usize = @intCast(y * fb.width + x);
                if (c.a == EMISSIVE) {
                    fb.pixels[idx] = c;
                } else if (c.a == 255) {
                    fb.pixels[idx] = fog(c, ty);
                } else {
                    // alpha real: es lo que da el halo suave de la celda
                    const a = @as(f32, @floatFromInt(c.a)) / 255.0;
                    fb.pixels[idx] = textures.mix(fb.pixels[idx], fog(c, ty), a);
                }
            }
        }
    }
}

const testing = std.testing;

/// Un cuarto grande y vacio: hace falta que sea alto para que hasta los rayos
/// de los bordes del FOV peguen contra la pared del fondo y no contra el techo.
const ROOM = [_][]const u8{
    "##########",
    "#........#",
    "#........#",
    "#........#",
    "#........#",
    "#........#",
    "#........#",
    "#........#",
    "#........#",
    "#........#",
    "#........#",
    "#........#",
    "#........#",
    "#........#",
    "##########",
};

test "un rayo recto hacia una pared devuelve la distancia perpendicular exacta" {
    const w = World.fromRows(&ROOM, 0);
    const hit = castRay(&w, 1.5, 7.5, 1, 0);
    try testing.expectApproxEqAbs(@as(f32, 7.5), hit.dist, 1e-4);
    try testing.expectEqual(Tile.panel, hit.tile);
    try testing.expectEqual(@as(u1, 0), hit.side);
}

test "la distancia perpendicular corrige el ojo de pez" {
    const w = World.fromRows(&ROOM, 0);
    var p = Player.spawn(&w);
    p.x = 1.5;
    p.y = 7.5;
    p.setAngle(0);

    // Los rayos extremos del FOV contra una pared plana de frente tienen que
    // dar la MISMA distancia perpendicular, aunque sus longitudes euclidianas
    // sean muy distintas. Esa igualdad es literalmente la definicion de no
    // tener ojo de pez.
    const center = castRay(&w, p.x, p.y, p.dir_x, p.dir_y);
    const left = castRay(&w, p.x, p.y, p.dir_x - p.plane_x, p.dir_y - p.plane_y);
    const right = castRay(&w, p.x, p.y, p.dir_x + p.plane_x, p.dir_y + p.plane_y);

    try testing.expectApproxEqAbs(center.dist, left.dist, 1e-4);
    try testing.expectApproxEqAbs(center.dist, right.dist, 1e-4);

    // ...y la euclidiana si tiene que diferir, si no la prueba seria trivial.
    const euclid_left = left.dist * @sqrt(1.0 + Player.FOV_TAN * Player.FOV_TAN);
    try testing.expect(euclid_left > center.dist + 0.5);
}

test "la coordenada de textura cae dentro de la cara golpeada" {
    const w = World.fromRows(&ROOM, 0);
    var a: f32 = 0;
    while (a < std.math.tau) : (a += 0.031) {
        const hit = castRay(&w, 4.5, 7.5, @cos(a), @sin(a));
        try testing.expect(hit.wall_x >= 0 and hit.wall_x < 1.0);
        try testing.expect(hit.dist > 0);
    }
}

test "el DDA siempre termina dentro del limite de pasos" {
    for (0..3) |lvl| {
        const w = World.load(lvl);
        var a: f32 = 0;
        while (a < std.math.tau) : (a += 0.017) {
            const hit = castRay(&w, w.spawn_x, w.spawn_y, @cos(a), @sin(a));
            try testing.expect(hit.steps < MAX_DDA_STEPS);
            try testing.expect(w.isSolid(hit.map_x, hit.map_y));
        }
    }
}

test "escribir fuera del framebuffer no hace nada" {
    var fb = try Framebuffer.init(testing.allocator, 16, 9);
    defer testing.allocator.free(fb.pixels);
    defer testing.allocator.free(fb.depth);
    fb.put(-1, 0, textures.NEON_CYAN);
    fb.put(0, -1, textures.NEON_CYAN);
    fb.put(16, 0, textures.NEON_CYAN);
    fb.put(0, 9, textures.NEON_CYAN);
    for (fb.pixels) |c| try testing.expectEqual(textures.VOID, c);
}

test "renderizar desde cualquier angulo y cualquier pitch nunca se sale del buffer" {
    const atlas = try textures.Atlas.init(testing.allocator);
    defer testing.allocator.free(atlas.walls);
    defer testing.allocator.free(atlas.sprites);
    var fb = try Framebuffer.init(testing.allocator, 64, 36);
    defer testing.allocator.free(fb.pixels);
    defer testing.allocator.free(fb.depth);

    for (0..3) |lvl| {
        const w = World.load(lvl);
        var p = Player.spawn(&w);
        var a: f32 = 0;
        while (a < std.math.tau) : (a += 0.2) {
            p.setAngle(a);
            for ([_]f32{ -player.PITCH_LIMIT, 0, player.PITCH_LIMIT }) |pitch| {
                p.pitch = pitch;
                renderWorld(&fb, &w, &p, &atlas);
                renderSprites(&fb, &w, &p, &atlas);
            }
        }
    }
}

test "una pared tapa un sprite que esta detras de ella" {
    const atlas = try textures.Atlas.init(testing.allocator);
    defer testing.allocator.free(atlas.walls);
    defer testing.allocator.free(atlas.sprites);
    var fb = try Framebuffer.init(testing.allocator, 64, 36);
    defer testing.allocator.free(fb.pixels);
    defer testing.allocator.free(fb.depth);

    // Celda de energia justo del otro lado de la pared del fondo.
    var w = World.fromRows(&ROOM, 0);
    w.sprite_count = 1;
    w.sprites[0] = .{ .x = 9.5, .y = 7.5, .kind = .core };

    var p = Player.spawn(&w);
    p.x = 1.5;
    p.y = 7.5;
    p.setAngle(0);

    renderWorld(&fb, &w, &p, &atlas);
    const before = fb.pixels[@intCast(18 * fb.width + 32)];
    renderSprites(&fb, &w, &p, &atlas);
    try testing.expectEqual(before, fb.pixels[@intCast(18 * fb.width + 32)]);

    // Sin la pared de por medio, el mismo sprite si tiene que pintarse.
    w.sprites[0] = .{ .x = 5.5, .y = 7.5, .kind = .core };
    renderWorld(&fb, &w, &p, &atlas);
    const wall_only = fb.pixels[@intCast(18 * fb.width + 32)];
    renderSprites(&fb, &w, &p, &atlas);
    try testing.expect(!std.meta.eql(wall_only, fb.pixels[@intCast(18 * fb.width + 32)]));
}
