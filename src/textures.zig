const std = @import("std");
const rl = @import("raylib");

const world = @import("world.zig");
const Tile = world.Tile;
const SpriteKind = world.SpriteKind;

/// Potencia de dos a proposito: al muestrear la pared se enmascara el indice
/// con TEX_SIZE-1 en vez de acotarlo, y eso evita el panic cuando el jugador
/// queda pegado a un muro y la altura de la columna se dispara.
pub const TEX_SIZE: i32 = 64;
pub const TEX_MASK: i32 = TEX_SIZE - 1;
pub const SPR_SIZE: i32 = 48;

const TEX_PIXELS: usize = @intCast(TEX_SIZE * TEX_SIZE);
const SPR_PIXELS: usize = @intCast(SPR_SIZE * SPR_SIZE);

/// Alpha reservado para marcar un pixel como emisivo. El renderer lo dibuja sin
/// niebla ni sombreado de cara, asi que el neon sigue brillando de lejos. Es un
/// canal que las paredes no usan para nada mas, o sea que sale gratis.
pub const EMISSIVE: u8 = 254;

pub const VOID = rl.Color.init(8, 10, 20, 255);
pub const STEEL_DARK = rl.Color.init(28, 34, 46, 255);
pub const STEEL_MID = rl.Color.init(58, 68, 86, 255);
pub const STEEL_LIGHT = rl.Color.init(96, 110, 132, 255);
pub const NEON_CYAN = rl.Color.init(60, 240, 255, EMISSIVE);
pub const NEON_AMBER = rl.Color.init(255, 170, 60, EMISSIVE);
pub const ALERT_RED = rl.Color.init(255, 60, 60, EMISSIVE);
pub const HAZARD_YEL = rl.Color.init(220, 190, 60, 255);

/// Indices dentro del atlas de paredes. Las puertas y la esclusa tienen dos
/// variantes porque su indicador cambia de rojo a cian al desbloquearse.
pub const Wall = enum(usize) {
    panel = 0,
    grate = 1,
    neon = 2,
    door_locked = 3,
    door_open = 4,
    exit_locked = 5,
    exit_open = 6,
    floor = 7,
    ceiling = 8,
};
const WALL_COUNT: usize = 9;

const CORE_FRAMES: usize = 6;
const DRONE_FRAMES: usize = 4;
const STEAM_FRAMES: usize = 4;
const SPRITE_FRAMES: usize = CORE_FRAMES + DRONE_FRAMES + STEAM_FRAMES;

/// Hash entero de dos dimensiones (finalizer estilo murmur3). Es la fuente de
/// todo el ruido de las texturas: no necesita allocator ni estado, y al ser
/// determinista la misma textura sale identica en cada corrida, que es lo que
/// permite fijarla en una prueba.
fn hash2(x: u32, y: u32, seed: u32) u32 {
    var h: u32 = x *% 0x27d4_eb2d ^ y *% 0x1656_67b1 ^ seed *% 0x85eb_ca6b;
    h ^= h >> 15;
    h *%= 0x2545_f491;
    h ^= h >> 13;
    h *%= 0x27d4_eb2d;
    h ^= h >> 16;
    return h;
}

fn noise01(x: u32, y: u32, seed: u32) f32 {
    return @as(f32, @floatFromInt(hash2(x, y, seed) >> 8)) / 16777216.0;
}

pub fn mix(a: rl.Color, b: rl.Color, t: f32) rl.Color {
    const k = std.math.clamp(t, 0, 1);
    return rl.Color.init(
        lerpU8(a.r, b.r, k),
        lerpU8(a.g, b.g, k),
        lerpU8(a.b, b.b, k),
        a.a,
    );
}

fn lerpU8(a: u8, b: u8, t: f32) u8 {
    const fa: f32 = @floatFromInt(a);
    const fb: f32 = @floatFromInt(b);
    return @intFromFloat(std.math.clamp(fa + (fb - fa) * t, 0, 255));
}

pub fn shade(c: rl.Color, k: f32) rl.Color {
    return rl.Color.init(mulU8(c.r, k), mulU8(c.g, k), mulU8(c.b, k), c.a);
}

fn mulU8(v: u8, k: f32) u8 {
    return @intFromFloat(std.math.clamp(@as(f32, @floatFromInt(v)) * k, 0, 255));
}

fn put(buf: []rl.Color, w: i32, x: i32, y: i32, c: rl.Color) void {
    if (x < 0 or y < 0 or x >= w or y >= w) return;
    buf[@intCast(y * w + x)] = c;
}

fn get(buf: []const rl.Color, w: i32, x: i32, y: i32) rl.Color {
    if (x < 0 or y < 0 or x >= w or y >= w) return VOID;
    return buf[@intCast(y * w + x)];
}

/// Remache de 3x3 con la luz arriba a la izquierda y la sombra abajo a la
/// derecha. Repetido en las juntas es lo que hace que un panel plano se lea
/// como una placa atornillada.
fn rivet(buf: []rl.Color, cx: i32, cy: i32, base: rl.Color) void {
    put(buf, TEX_SIZE, cx, cy, shade(base, 1.35));
    put(buf, TEX_SIZE, cx - 1, cy, shade(base, 1.15));
    put(buf, TEX_SIZE, cx, cy - 1, shade(base, 1.15));
    put(buf, TEX_SIZE, cx + 1, cy, shade(base, 0.7));
    put(buf, TEX_SIZE, cx, cy + 1, shade(base, 0.7));
}

pub const Atlas = struct {
    walls: []rl.Color, // WALL_COUNT texturas de TEX_SIZE x TEX_SIZE
    sprites: []rl.Color, // SPRITE_FRAMES cuadros de SPR_SIZE x SPR_SIZE

    /// Dibuja todo el pixel art una sola vez al arrancar. Nada de esto sube a
    /// la GPU: el renderer de CPU muestrea estos buffers directo, asi que la
    /// unica textura de OpenGL en todo el programa es la del framebuffer.
    pub fn init(gpa: std.mem.Allocator) !Atlas {
        const walls = try gpa.alloc(rl.Color, WALL_COUNT * TEX_PIXELS);
        errdefer gpa.free(walls);
        const sprites = try gpa.alloc(rl.Color, SPRITE_FRAMES * SPR_PIXELS);

        genPanel(wallSlice(walls, .panel), 1337, 1.0);
        genGrate(wallSlice(walls, .grate));
        genNeon(wallSlice(walls, .neon));
        genDoor(wallSlice(walls, .door_locked), false);
        genDoor(wallSlice(walls, .door_open), true);
        genExit(wallSlice(walls, .exit_locked), false);
        genExit(wallSlice(walls, .exit_open), true);
        genGrate(wallSlice(walls, .floor));
        genCeiling(wallSlice(walls, .ceiling));

        for (0..CORE_FRAMES) |f| genCoreFrame(spriteSlice(sprites, f), f);
        for (0..DRONE_FRAMES) |f| genDroneFrame(spriteSlice(sprites, CORE_FRAMES + f), f);
        for (0..STEAM_FRAMES) |f| genSteamFrame(spriteSlice(sprites, CORE_FRAMES + DRONE_FRAMES + f), f);

        return .{ .walls = walls, .sprites = sprites };
    }

    /// Texel de pared. El indice se enmascara en vez de acotarse, asi que
    /// coordenadas fuera de rango envuelven la textura en lugar de hacer panic.
    pub fn wallTexel(self: *const Atlas, kind: Wall, tx: i32, ty: i32) rl.Color {
        const base = @intFromEnum(kind) * TEX_PIXELS;
        const ix: usize = @intCast(tx & TEX_MASK);
        const iy: usize = @intCast(ty & TEX_MASK);
        return self.walls[base + iy * @as(usize, @intCast(TEX_SIZE)) + ix];
    }

    /// Texel de sprite. A diferencia de las paredes aqui si se acota: un sprite
    /// que envuelve se veria repetido en el borde en vez de recortado.
    pub fn spriteTexel(self: *const Atlas, kind: SpriteKind, frame: u32, tx: i32, ty: i32) rl.Color {
        if (tx < 0 or ty < 0 or tx >= SPR_SIZE or ty >= SPR_SIZE) return rl.Color.init(0, 0, 0, 0);
        const first: usize = switch (kind) {
            .core => 0,
            .drone => CORE_FRAMES,
            .steam => CORE_FRAMES + DRONE_FRAMES,
        };
        const count: usize = switch (kind) {
            .core => CORE_FRAMES,
            .drone => DRONE_FRAMES,
            .steam => STEAM_FRAMES,
        };
        const base = (first + (@as(usize, frame) % count)) * SPR_PIXELS;
        return self.sprites[base + @as(usize, @intCast(ty * SPR_SIZE + tx))];
    }
};

fn wallSlice(walls: []rl.Color, kind: Wall) []rl.Color {
    const base = @intFromEnum(kind) * TEX_PIXELS;
    return walls[base .. base + TEX_PIXELS];
}

fn spriteSlice(sprites: []rl.Color, frame: usize) []rl.Color {
    const base = frame * SPR_PIXELS;
    return sprites[base .. base + SPR_PIXELS];
}

/// Traduce un tile del mundo a la textura que le toca, resolviendo aqui las dos
/// variantes de puerta y esclusa segun esten bloqueadas o no.
pub fn wallFor(tile: Tile, unlocked: bool) Wall {
    return switch (tile) {
        .panel, .empty => .panel,
        .grate => .grate,
        .neon => .neon,
        .door => if (unlocked) .door_open else .door_locked,
        .exit => if (unlocked) .exit_open else .exit_locked,
    };
}

// ---------------------------------------------------------------- generadores

fn genPanel(buf: []rl.Color, seed: u32, brightness: f32) void {
    var y: i32 = 0;
    while (y < TEX_SIZE) : (y += 1) {
        var x: i32 = 0;
        while (x < TEX_SIZE) : (x += 1) {
            const ux: u32 = @intCast(x);
            const uy: u32 = @intCast(y);
            // El segundo termino depende solo de x, asi que el grano queda
            // alineado en vertical y se lee como metal cepillado en vez de
            // estatica de television.
            const g = 0.25 * noise01(ux, uy, seed) + 0.15 * noise01(ux, 0, seed);
            var c = mix(STEEL_MID, STEEL_DARK, g);
            if (@rem(x, 16) == 0 or @rem(y, 32) == 0) c = shade(STEEL_DARK, 0.6);
            if (@rem(x, 16) == 1 or @rem(y, 32) == 1) c = STEEL_LIGHT;
            if (noise01(ux / 8, uy / 8, seed +% 1) > 0.93) c = shade(c, 0.85);
            put(buf, TEX_SIZE, x, y, shade(c, brightness));
        }
    }
    var ry: i32 = 3;
    while (ry < TEX_SIZE) : (ry += 32) {
        var rx: i32 = 3;
        while (rx < TEX_SIZE) : (rx += 16) {
            rivet(buf, rx, ry, shade(STEEL_LIGHT, brightness));
        }
    }
}

fn genGrate(buf: []rl.Color) void {
    var y: i32 = 0;
    while (y < TEX_SIZE) : (y += 1) {
        var x: i32 = 0;
        while (x < TEX_SIZE) : (x += 1) {
            const mx = @rem(x, 8);
            const my = @rem(y, 8);
            var c: rl.Color = undefined;
            if (mx < 3 or my < 3) {
                c = STEEL_MID;
                if (mx == 0 or my == 0) c = STEEL_LIGHT; // canto iluminado
                if (mx == 2 or my == 2) c = STEEL_DARK; // canto en sombra
            } else {
                // resplandor de la maquinaria de abajo, mas fuerte al centro
                const fx = @as(f32, @floatFromInt(mx)) - 5.0;
                const fy = @as(f32, @floatFromInt(my)) - 5.0;
                const d = @sqrt(fx * fx + fy * fy);
                c = mix(VOID, rl.Color.init(255, 170, 60, 255), 0.16 * (1.0 - @min(1.0, d / 3.5)));
            }
            put(buf, TEX_SIZE, x, y, c);
        }
    }
}

fn genNeon(buf: []rl.Color) void {
    genPanel(buf, 90210, 0.75);
    var y: i32 = 0;
    while (y < TEX_SIZE) : (y += 1) {
        const fy = @abs(@as(f32, @floatFromInt(y)) - 32.0);
        var x: i32 = 0;
        while (x < TEX_SIZE) : (x += 1) {
            var c = get(buf, TEX_SIZE, x, y);
            if (fy <= 12) c = mix(c, NEON_CYAN, 0.30 * (1.0 - fy / 12.0));
            if (fy <= 4) c = mix(STEEL_DARK, NEON_CYAN, 0.45);
            if (fy <= 2) c = NEON_CYAN; // nucleo emisivo
            if ((x == 6 or x == 7 or x == 56 or x == 57) and fy <= 6) c = STEEL_LIGHT;
            put(buf, TEX_SIZE, x, y, c);
        }
    }
}

fn genDoor(buf: []rl.Color, unlocked: bool) void {
    genPanel(buf, 4242, 0.9);
    var y: i32 = 0;
    while (y < TEX_SIZE) : (y += 1) {
        var x: i32 = 0;
        while (x < TEX_SIZE) : (x += 1) {
            var c = get(buf, TEX_SIZE, x, y);
            if (x == 31 or x == 32) c = VOID; // junta entre las dos hojas
            if ((x == 10 or x == 11 or x == 52 or x == 53) and y >= 8 and y <= 26) {
                c = if (@rem(x, 2) == 0) STEEL_LIGHT else STEEL_MID; // piston
            }
            if ((y == 7 or y == 27) and ((x >= 9 and x <= 12) or (x >= 51 and x <= 54))) c = STEEL_DARK;
            if (y >= 40 and y <= 56) {
                c = if (@rem(@divFloor(x + y, 6), 2) == 0) HAZARD_YEL else STEEL_DARK;
            }
            if (x >= 29 and x <= 34 and y >= 15 and y <= 20) {
                c = if (unlocked) NEON_CYAN else ALERT_RED;
            }
            put(buf, TEX_SIZE, x, y, c);
        }
    }
}

fn genExit(buf: []rl.Color, unlocked: bool) void {
    var y: i32 = 0;
    while (y < TEX_SIZE) : (y += 1) {
        var x: i32 = 0;
        while (x < TEX_SIZE) : (x += 1) {
            const fx = @as(f32, @floatFromInt(x)) - 32.0;
            const fy = @as(f32, @floatFromInt(y)) - 32.0;
            const d = @sqrt(fx * fx + fy * fy);
            var c = if (@rem(@as(i32, @intFromFloat(d / 6.0)), 2) == 0) STEEL_LIGHT else STEEL_DARK;
            if (d >= 19 and d <= 22) c = if (unlocked) NEON_CYAN else ALERT_RED;
            if (d < 8) c = VOID; // ventana oscura al centro
            put(buf, TEX_SIZE, x, y, c);
        }
    }
    // ocho pernos radiales en el anillo exterior
    var k: usize = 0;
    while (k < 8) : (k += 1) {
        const a = @as(f32, @floatFromInt(k)) * std.math.tau / 8.0;
        const bx: i32 = @intFromFloat(32.0 + 26.0 * @cos(a));
        const by: i32 = @intFromFloat(32.0 + 26.0 * @sin(a));
        rivet(buf, bx, by, STEEL_LIGHT);
    }
}

fn genCeiling(buf: []rl.Color) void {
    genPanel(buf, 777, 0.5);
    var y: i32 = 25;
    while (y <= 39) : (y += 1) {
        var x: i32 = 25;
        while (x <= 39) : (x += 1) {
            const border = x == 25 or x == 39 or y == 25 or y == 39;
            put(buf, TEX_SIZE, x, y, if (border) STEEL_LIGHT else NEON_AMBER);
        }
    }
}

fn clearSprite(buf: []rl.Color) void {
    @memset(buf, rl.Color.init(0, 0, 0, 0));
}

/// Celda de energia: hexagono de plasma emisivo, un anillo de contencion de
/// tres arcos que gira un sexto por cuadro, y un halo con alpha real que es lo
/// que la hace verse encendida en vez de pegada encima del fondo.
fn genCoreFrame(buf: []rl.Color, frame: usize) void {
    clearSprite(buf);
    const ff: f32 = @floatFromInt(frame);
    const pulse = 0.5 + 0.5 * @sin(std.math.tau * ff / @as(f32, CORE_FRAMES));
    const spin = ff * 60.0;

    var y: i32 = 0;
    while (y < SPR_SIZE) : (y += 1) {
        var x: i32 = 0;
        while (x < SPR_SIZE) : (x += 1) {
            const dx = @as(f32, @floatFromInt(x)) - 24.0;
            const dy = @as(f32, @floatFromInt(y)) - 24.0;
            const d = @sqrt(dx * dx + dy * dy);

            if (inHexagon(dx, dy, 11.0)) {
                const c = mix(NEON_CYAN, rl.Color.init(255, 255, 255, EMISSIVE), pulse * 0.6);
                put(buf, SPR_SIZE, x, y, rl.Color.init(c.r, c.g, c.b, EMISSIVE));
                continue;
            }
            if (d >= 15.5 and d <= 17.5) {
                var deg = std.math.radiansToDegrees(std.math.atan2(dy, dx)) - spin;
                deg = @mod(deg, 120.0);
                if (deg < 80.0) {
                    put(buf, SPR_SIZE, x, y, STEEL_LIGHT);
                    continue;
                }
            }
            if (d < 21.0) {
                const a: u8 = @intFromFloat(255.0 * (1.0 - d / 21.0) * 0.35 * (0.6 + 0.4 * pulse));
                if (a > 4) put(buf, SPR_SIZE, x, y, rl.Color.init(NEON_CYAN.r, NEON_CYAN.g, NEON_CYAN.b, a));
            }
        }
    }
}

fn inHexagon(dx: f32, dy: f32, r: f32) bool {
    const ax = @abs(dx);
    const ay = @abs(dy);
    return ay <= r and ax <= 0.866 * r and (0.866 * ax + 0.5 * ay) <= 0.866 * r;
}

/// Dron de mantenimiento: chasis con bisel, ojo escaner que barre de lado a
/// lado, rotor con alpha alternado para simular el giro, y un LED que
/// parpadea. Cuatro cuadros bastan porque el barrido del ojo ya da la lectura
/// de movimiento.
fn genDroneFrame(buf: []rl.Color, frame: usize) void {
    clearSprite(buf);
    const eye_dx = [_]i32{ -3, 0, 3, 0 };
    const rotor_alpha = [_]u8{ 210, 90, 210, 90 };
    const rotor_w = [_]i32{ 11, 15, 11, 15 };

    // rotor
    var rx: i32 = 24 - rotor_w[frame];
    while (rx <= 24 + rotor_w[frame]) : (rx += 1) {
        var ry: i32 = 14;
        while (ry <= 16) : (ry += 1) {
            put(buf, SPR_SIZE, rx, ry, rl.Color.init(STEEL_LIGHT.r, STEEL_LIGHT.g, STEEL_LIGHT.b, rotor_alpha[frame]));
        }
    }
    // mastil
    var my: i32 = 16;
    while (my <= 21) : (my += 1) {
        put(buf, SPR_SIZE, 23, my, STEEL_MID);
        put(buf, SPR_SIZE, 24, my, STEEL_LIGHT);
    }
    // chasis con esquinas recortadas
    var y: i32 = 21;
    while (y <= 33) : (y += 1) {
        var x: i32 = 14;
        while (x <= 34) : (x += 1) {
            const edge_x = @abs(x - 24) > 8;
            const edge_y = y < 23 or y > 31;
            if (edge_x and edge_y) continue;
            var c = STEEL_MID;
            if (y <= 23) c = STEEL_LIGHT; // bisel superior
            if (y >= 32) c = STEEL_DARK; // sombra inferior
            put(buf, SPR_SIZE, x, y, c);
        }
    }
    // ojo escaner
    const ex = 24 + eye_dx[frame];
    var oy: i32 = -3;
    while (oy <= 3) : (oy += 1) {
        var ox: i32 = -3;
        while (ox <= 3) : (ox += 1) {
            const fx: f32 = @floatFromInt(ox);
            const fy: f32 = @floatFromInt(oy);
            const d = @sqrt(fx * fx + fy * fy);
            if (d <= 3.0) put(buf, SPR_SIZE, ex + ox, 27 + oy, if (d <= 1.6) rl.Color.init(255, 240, 200, EMISSIVE) else NEON_AMBER);
        }
    }
    // LED de estado
    if (frame < 2) {
        put(buf, SPR_SIZE, 18, 31, ALERT_RED);
        put(buf, SPR_SIZE, 30, 31, ALERT_RED);
    }
}

/// Fuga de vapor: anillos que crecen y se desvanecen. Es puro decorado, pero
/// pone movimiento en pasillos que si no se verian muertos.
fn genSteamFrame(buf: []rl.Color, frame: usize) void {
    clearSprite(buf);
    const ff: f32 = @floatFromInt(frame);
    const radius = 6.0 + ff * 4.5;
    const fade = 1.0 - ff / @as(f32, STEAM_FRAMES);

    var y: i32 = 0;
    while (y < SPR_SIZE) : (y += 1) {
        var x: i32 = 0;
        while (x < SPR_SIZE) : (x += 1) {
            const dx = @as(f32, @floatFromInt(x)) - 24.0;
            const dy = (@as(f32, @floatFromInt(y)) - 30.0) * 1.4;
            const d = @sqrt(dx * dx + dy * dy);
            if (d > radius) continue;
            const edge = 1.0 - d / radius;
            const wobble = 0.75 + 0.25 * noise01(@intCast(x), @intCast(y), @intCast(frame + 5));
            const a: u8 = @intFromFloat(std.math.clamp(200.0 * edge * fade * wobble, 0, 210));
            if (a > 6) put(buf, SPR_SIZE, x, y, rl.Color.init(190, 205, 225, a));
        }
    }
}

const testing = std.testing;

test "el hash de ruido es determinista" {
    try testing.expectEqual(hash2(3, 7, 99), hash2(3, 7, 99));
    try testing.expect(hash2(3, 7, 99) != hash2(3, 8, 99));
    for (0..64) |x| for (0..64) |y| {
        const n = noise01(@intCast(x), @intCast(y), 1);
        try testing.expect(n >= 0 and n < 1);
    };
}

test "ninguna textura de pared tiene pixeles transparentes" {
    const atlas = try Atlas.init(testing.allocator);
    defer testing.allocator.free(atlas.walls);
    defer testing.allocator.free(atlas.sprites);
    // Un alpha 0 en una pared abriria un agujero por el que se veria el vacio.
    for (atlas.walls) |c| try testing.expect(c.a >= EMISSIVE);
}

test "cada cuadro de sprite tiene pixeles opacos y pixeles vacios" {
    const atlas = try Atlas.init(testing.allocator);
    defer testing.allocator.free(atlas.walls);
    defer testing.allocator.free(atlas.sprites);

    const kinds = [_]SpriteKind{ .core, .drone, .steam };
    for (kinds) |kind| {
        var f: u32 = 0;
        while (f < kind.frameCount()) : (f += 1) {
            var opaque_count: u32 = 0;
            var clear_count: u32 = 0;
            var y: i32 = 0;
            while (y < SPR_SIZE) : (y += 1) {
                var x: i32 = 0;
                while (x < SPR_SIZE) : (x += 1) {
                    const c = atlas.spriteTexel(kind, f, x, y);
                    if (c.a == 0) clear_count += 1 else opaque_count += 1;
                }
            }
            try testing.expect(opaque_count > 20);
            try testing.expect(clear_count > 20); // tiene que recortarse contra el fondo
        }
    }
}

test "muestrear una pared fuera de rango envuelve en vez de hacer panic" {
    const atlas = try Atlas.init(testing.allocator);
    defer testing.allocator.free(atlas.walls);
    defer testing.allocator.free(atlas.sprites);
    const a = atlas.wallTexel(.panel, 5, 9);
    try testing.expectEqual(a, atlas.wallTexel(.panel, 5 + TEX_SIZE * 3, 9 - TEX_SIZE * 2));
}
