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
pub const NEON_CYAN = rl.Color.init(60, 240, 255, EMISSIVE);

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
const STEAM_FRAMES: usize = 4;
const SPRITE_FRAMES: usize = CORE_FRAMES + STEAM_FRAMES;

/// PNG de cada pared, empacados dentro del ejecutable con @embedFile: el
/// binario sigue siendo un solo archivo, no hay que repartir una carpeta
/// assets/ junto a el.
const WALL_PNGS = [WALL_COUNT][]const u8{
    @embedFile("assets/textures/wall_panel.png"),
    @embedFile("assets/textures/wall_grate.png"),
    @embedFile("assets/textures/wall_neon.png"),
    @embedFile("assets/textures/wall_door_locked.png"),
    @embedFile("assets/textures/wall_door_open.png"),
    @embedFile("assets/textures/wall_exit_locked.png"),
    @embedFile("assets/textures/wall_exit_open.png"),
    @embedFile("assets/textures/wall_floor.png"),
    @embedFile("assets/textures/wall_ceiling.png"),
};

const CORE_PNGS = [CORE_FRAMES][]const u8{
    @embedFile("assets/textures/sprite_core_0.png"),
    @embedFile("assets/textures/sprite_core_1.png"),
    @embedFile("assets/textures/sprite_core_2.png"),
    @embedFile("assets/textures/sprite_core_3.png"),
    @embedFile("assets/textures/sprite_core_4.png"),
    @embedFile("assets/textures/sprite_core_5.png"),
};

const STEAM_PNGS = [STEAM_FRAMES][]const u8{
    @embedFile("assets/textures/sprite_steam_0.png"),
    @embedFile("assets/textures/sprite_steam_1.png"),
    @embedFile("assets/textures/sprite_steam_2.png"),
    @embedFile("assets/textures/sprite_steam_3.png"),
};

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

pub const Atlas = struct {
    walls: []rl.Color, // WALL_COUNT texturas de TEX_SIZE x TEX_SIZE
    sprites: []rl.Color, // SPRITE_FRAMES cuadros de SPR_SIZE x SPR_SIZE

    /// Decodifica los PNG embebidos una sola vez al arrancar. Nada de esto
    /// sube a la GPU: el renderer de CPU muestrea estos buffers directo, asi
    /// que la unica textura de OpenGL en todo el programa es la del
    /// framebuffer.
    pub fn init(gpa: std.mem.Allocator) !Atlas {
        const walls = try gpa.alloc(rl.Color, WALL_COUNT * TEX_PIXELS);
        errdefer gpa.free(walls);
        const sprites = try gpa.alloc(rl.Color, SPRITE_FRAMES * SPR_PIXELS);
        errdefer gpa.free(sprites);

        for (WALL_PNGS, 0..) |png, i| {
            try loadPng(walls[i * TEX_PIXELS ..][0..TEX_PIXELS], png, TEX_SIZE, TEX_SIZE);
        }
        for (CORE_PNGS, 0..) |png, i| {
            try loadPng(sprites[i * SPR_PIXELS ..][0..SPR_PIXELS], png, SPR_SIZE, SPR_SIZE);
        }
        for (STEAM_PNGS, 0..) |png, i| {
            try loadPng(sprites[(CORE_FRAMES + i) * SPR_PIXELS ..][0..SPR_PIXELS], png, SPR_SIZE, SPR_SIZE);
        }

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
            .steam => CORE_FRAMES,
        };
        const count: usize = switch (kind) {
            .core => CORE_FRAMES,
            .steam => STEAM_FRAMES,
        };
        const base = (first + (@as(usize, frame) % count)) * SPR_PIXELS;
        return self.sprites[base + @as(usize, @intCast(ty * SPR_SIZE + tx))];
    }
};

/// Decodifica un PNG embebido y copia sus pixeles a `dst`. Los PNG estan al
/// tamano exacto que espera el atlas, asi que un tamano distinto es un error
/// de build, no algo que tolerar en tiempo de ejecucion.
fn loadPng(dst: []rl.Color, png_bytes: []const u8, w: i32, h: i32) !void {
    const image = try rl.loadImageFromMemory(".png", png_bytes);
    defer rl.unloadImage(image);
    std.debug.assert(image.width == w and image.height == h);
    const colors = try rl.loadImageColors(image);
    defer rl.unloadImageColors(colors);
    @memcpy(dst, colors);
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

const testing = std.testing;

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

    const kinds = [_]SpriteKind{ .core, .steam };
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
