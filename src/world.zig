const std = @import("std");
const levels = @import("levels.zig");

pub const MAX_DIM: i32 = 32;
pub const MAX_SPRITES: usize = 48;

/// Cuantos tiles alrededor del jugador se abre una puerta hidraulica sola.
const DOOR_RANGE: f32 = 1.9;
/// Radio para recoger una celda de energia. Generoso a proposito: fallar un
/// pickup por medio tile se siente a bug, no a dificultad.
const PICKUP_RADIUS: f32 = 0.55;
/// Segundos de silencio entre dos avisos de "esclusa sellada", para que
/// caminar pegado a la esclusa no dispare el sonido en cada frame.
const DENIED_COOLDOWN: f32 = 1.6;

pub const Tile = enum(u8) {
    empty,
    panel,
    grate,
    neon,
    door,
    exit,
};

pub const SpriteKind = enum(u8) {
    core,
    steam,

    pub fn frameCount(self: SpriteKind) u32 {
        return switch (self) {
            .core => 6,
            .steam => 4,
        };
    }

    pub fn framesPerSecond(self: SpriteKind) f32 {
        return switch (self) {
            .core => 10,
            .steam => 7,
        };
    }
};

pub const Sprite = struct {
    x: f32,
    y: f32,
    kind: SpriteKind,
    anim_time: f32 = 0, // acumulador de animacion en segundos
    z_offset: f32 = 0, // desplazamiento vertical en unidades de mundo
    alive: bool = true, // las celdas recogidas se apagan, no se borran

    pub fn frame(self: Sprite) u32 {
        const n = self.kind.frameCount();
        const raw: u32 = @intFromFloat(@max(0, self.anim_time * self.kind.framesPerSecond()));
        return raw % n;
    }
};

/// Lo que paso en el mundo durante un `update`. main lo traduce a un sonido y,
/// en el caso de `.win`, a un cambio de estado.
pub const Event = enum { none, pickup, door_open, denied, win };

pub const World = struct {
    width: i32,
    height: i32,
    tiles: [@intCast(MAX_DIM * MAX_DIM)]Tile, // row-major, solo [0,width)x[0,height) es valido
    door_open: [@intCast(MAX_DIM * MAX_DIM)]bool, // puertas abiertas por cercania del jugador
    sprites: [MAX_SPRITES]Sprite,
    sprite_count: usize,
    spawn_x: f32,
    spawn_y: f32,
    spawn_angle: f32,
    cores_total: u32,
    cores_left: u32,
    exit_open: bool, // la esclusa deja de ser solida cuando esto es true
    elapsed: f32,
    won: bool,
    level_index: usize,
    denied_timer: f32,

    /// Construye el mundo a partir del arte ASCII del nivel. No asigna memoria
    /// ni hace I/O, asi que no puede fallar: cambiar de nivel es una asignacion
    /// por valor. Las filas mas largas que MAX_DIM se recortan en silencio, que
    /// es el mismo criterio que se usa para todo acceso fuera de rango.
    pub fn load(level_index: usize) World {
        const i = level_index % levels.LEVELS.len;
        const level = levels.LEVELS[i];
        var w = fromRows(level.rows, level.spawn_angle);
        w.level_index = i;
        return w;
    }

    /// Construye el mundo directo de un arte ASCII. `load` es una envoltura
    /// sobre esta funcion; tenerla separada permite armar mapas chiquitos a
    /// mano en las pruebas sin agregarlos a la lista de niveles del juego.
    pub fn fromRows(rows: []const []const u8, spawn_angle_deg: f32) World {
        var self: World = .{
            .width = 0,
            .height = 0,
            .tiles = undefined,
            .door_open = undefined,
            .sprites = undefined,
            .sprite_count = 0,
            .spawn_x = 1.5,
            .spawn_y = 1.5,
            .spawn_angle = spawn_angle_deg * std.math.pi / 180.0,
            .cores_total = 0,
            .cores_left = 0,
            .exit_open = false,
            .elapsed = 0,
            .won = false,
            .level_index = 0,
            .denied_timer = 0,
        };
        @memset(&self.tiles, .empty);
        @memset(&self.door_open, false);

        self.height = @intCast(@min(rows.len, @as(usize, @intCast(MAX_DIM))));
        self.width = @intCast(@min(rows[0].len, @as(usize, @intCast(MAX_DIM))));

        var y: i32 = 0;
        while (y < self.height) : (y += 1) {
            const row = rows[@intCast(y)];
            var x: i32 = 0;
            while (x < self.width and x < @as(i32, @intCast(row.len))) : (x += 1) {
                const idx: usize = @intCast(y * MAX_DIM + x);
                const cx: f32 = @as(f32, @floatFromInt(x)) + 0.5;
                const cy: f32 = @as(f32, @floatFromInt(y)) + 0.5;
                switch (row[@intCast(x)]) {
                    '#' => self.tiles[idx] = .panel,
                    '=' => self.tiles[idx] = .grate,
                    '!' => self.tiles[idx] = .neon,
                    'D' => self.tiles[idx] = .door,
                    'X' => self.tiles[idx] = .exit,
                    '@' => {
                        self.spawn_x = cx;
                        self.spawn_y = cy;
                    },
                    'c' => {
                        self.addSprite(.{ .x = cx, .y = cy, .kind = .core });
                        self.cores_total += 1;
                    },
                    's' => self.addSprite(.{ .x = cx, .y = cy, .kind = .steam }),
                    else => {},
                }
            }
        }
        self.cores_left = self.cores_total;
        // Un nivel sin celdas no tendria condicion de victoria, asi que la
        // esclusa arranca abierta en vez de quedar imposible de cruzar.
        self.exit_open = self.cores_total == 0;
        return self;
    }

    fn addSprite(self: *World, s: Sprite) void {
        if (self.sprite_count >= MAX_SPRITES) return;
        self.sprites[self.sprite_count] = s;
        self.sprite_count += 1;
    }

    /// Unica funcion para leer el mapa. Fuera de rango siempre devuelve panel
    /// solido: es lo que garantiza que el DDA termine chocando contra algo y
    /// que el jugador quede encerrado dentro del arreglo pase lo que pase.
    pub fn at(self: *const World, x: i32, y: i32) Tile {
        if (x < 0 or y < 0 or x >= self.width or y >= self.height) return .panel;
        return self.tiles[@intCast(y * MAX_DIM + x)];
    }

    /// Una celda bloquea el paso salvo que sea piso, una puerta ya abierta, o
    /// la esclusa una vez que se juntaron todas las celdas de energia.
    pub fn isSolid(self: *const World, x: i32, y: i32) bool {
        return switch (self.at(x, y)) {
            .empty => false,
            .door => !self.doorIsOpen(x, y),
            .exit => !self.exit_open,
            else => true,
        };
    }

    pub fn doorIsOpen(self: *const World, x: i32, y: i32) bool {
        if (x < 0 or y < 0 or x >= self.width or y >= self.height) return false;
        return self.door_open[@intCast(y * MAX_DIM + x)];
    }

    /// Prueba las cuatro esquinas del cuadrado que envuelve al jugador. Con un
    /// radio menor a medio tile esto es exacto: ninguna esquina de muro puede
    /// colarse entre dos muestras sin tocar alguna de ellas.
    pub fn blocksCircle(self: *const World, x: f32, y: f32, radius: f32) bool {
        const x0: i32 = @intFromFloat(@floor(x - radius));
        const x1: i32 = @intFromFloat(@floor(x + radius));
        const y0: i32 = @intFromFloat(@floor(y - radius));
        const y1: i32 = @intFromFloat(@floor(y + radius));
        return self.isSolid(x0, y0) or self.isSolid(x1, y0) or
            self.isSolid(x0, y1) or self.isSolid(x1, y1);
    }

    /// Avanza animaciones, puertas y pickups. Devuelve el evento mas
    /// importante del frame (victoria > pickup > puerta > esclusa sellada), que
    /// es lo que main convierte en sonido.
    pub fn update(self: *World, px: f32, py: f32, dt: f32) Event {
        self.elapsed += dt;
        if (self.denied_timer > 0) self.denied_timer -= dt;

        var event: Event = .none;

        if (self.updateDoors(px, py)) event = .door_open;

        var i: usize = 0;
        while (i < self.sprite_count) : (i += 1) {
            const s = &self.sprites[i];
            s.anim_time += dt;
            switch (s.kind) {
                .core => {
                    if (!s.alive) continue;
                    s.z_offset = @sin(self.elapsed * 2.0 + @as(f32, @floatFromInt(i))) * 0.10;
                    const dx = s.x - px;
                    const dy = s.y - py;
                    if (dx * dx + dy * dy <= PICKUP_RADIUS * PICKUP_RADIUS) {
                        s.alive = false;
                        if (self.cores_left > 0) self.cores_left -= 1;
                        if (self.cores_left == 0) self.exit_open = true;
                        event = .pickup;
                    }
                },
                .steam => s.z_offset = -0.18,
            }
        }

        if (self.exit_open and !self.won and self.at(tileOf(px), tileOf(py)) == .exit) {
            self.won = true;
            return .win;
        }
        if (event != .none) return event;

        // Aviso de esclusa sellada: solo al acercarse y con enfriamiento, para
        // que no se dispare en todos los frames mientras uno la empuja.
        if (!self.exit_open and self.denied_timer <= 0 and self.nearExit(px, py)) {
            self.denied_timer = DENIED_COOLDOWN;
            return .denied;
        }
        return .none;
    }

    fn updateDoors(self: *World, px: f32, py: f32) bool {
        var opened_now = false;
        var y: i32 = 0;
        while (y < self.height) : (y += 1) {
            var x: i32 = 0;
            while (x < self.width) : (x += 1) {
                const idx: usize = @intCast(y * MAX_DIM + x);
                if (self.tiles[idx] != .door) continue;
                const dx = (@as(f32, @floatFromInt(x)) + 0.5) - px;
                const dy = (@as(f32, @floatFromInt(y)) + 0.5) - py;
                const near = dx * dx + dy * dy <= DOOR_RANGE * DOOR_RANGE;
                if (near and !self.door_open[idx]) opened_now = true;
                self.door_open[idx] = near;
            }
        }
        return opened_now;
    }

    fn nearExit(self: *const World, px: f32, py: f32) bool {
        var y: i32 = 0;
        while (y < self.height) : (y += 1) {
            var x: i32 = 0;
            while (x < self.width) : (x += 1) {
                if (self.at(x, y) != .exit) continue;
                const dx = (@as(f32, @floatFromInt(x)) + 0.5) - px;
                const dy = (@as(f32, @floatFromInt(y)) + 0.5) - py;
                if (dx * dx + dy * dy <= 1.6 * 1.6) return true;
            }
        }
        return false;
    }

    pub fn coresTaken(self: *const World) u32 {
        return self.cores_total - self.cores_left;
    }
};

pub fn tileOf(v: f32) i32 {
    return @intFromFloat(@floor(v));
}

const testing = std.testing;

test "las coordenadas fuera del mapa cuentan como pared" {
    const w = World.load(0);
    try testing.expectEqual(Tile.panel, w.at(-1, 0));
    try testing.expectEqual(Tile.panel, w.at(0, -1));
    try testing.expectEqual(Tile.panel, w.at(9999, 9999));
    try testing.expect(w.isSolid(-1, -1));
    try testing.expect(w.isSolid(w.width, w.height));
}

test "cada nivel esta cerrado por paredes en todo su borde" {
    for (0..levels.LEVELS.len) |i| {
        const w = World.load(i);
        var x: i32 = 0;
        while (x < w.width) : (x += 1) {
            try testing.expect(w.isSolid(x, 0));
            try testing.expect(w.isSolid(x, w.height - 1));
        }
        var y: i32 = 0;
        while (y < w.height) : (y += 1) {
            try testing.expect(w.isSolid(0, y));
            try testing.expect(w.isSolid(w.width - 1, y));
        }
    }
}

test "todos los niveles tienen filas del mismo largo" {
    for (levels.LEVELS) |lvl| {
        const expected = lvl.rows[0].len;
        for (lvl.rows) |row| try testing.expectEqual(expected, row.len);
    }
}

test "el spawn de cada nivel cae en una celda libre" {
    for (0..levels.LEVELS.len) |i| {
        const w = World.load(i);
        try testing.expect(!w.blocksCircle(w.spawn_x, w.spawn_y, 0.22));
    }
}

test "cada nivel tiene celdas de energia y una sola esclusa" {
    for (0..levels.LEVELS.len) |i| {
        const w = World.load(i);
        try testing.expect(w.cores_total > 0);
        var exits: u32 = 0;
        var y: i32 = 0;
        while (y < w.height) : (y += 1) {
            var x: i32 = 0;
            while (x < w.width) : (x += 1) {
                if (w.at(x, y) == .exit) exits += 1;
            }
        }
        try testing.expectEqual(@as(u32, 1), exits);
    }
}

test "la esclusa es solida hasta juntar todas las celdas" {
    var w = World.load(0);
    var ex: i32 = -1;
    var ey: i32 = -1;
    var y: i32 = 0;
    while (y < w.height) : (y += 1) {
        var x: i32 = 0;
        while (x < w.width) : (x += 1) {
            if (w.at(x, y) == .exit) {
                ex = x;
                ey = y;
            }
        }
    }
    try testing.expect(ex >= 0);
    try testing.expect(w.isSolid(ex, ey));

    // recoger todas las celdas caminando encima de cada una
    var i: usize = 0;
    while (i < w.sprite_count) : (i += 1) {
        const s = w.sprites[i];
        if (s.kind != .core) continue;
        _ = w.update(s.x, s.y, 1.0 / 60.0);
    }
    try testing.expectEqual(@as(u32, 0), w.cores_left);
    try testing.expect(w.exit_open);
    try testing.expect(!w.isSolid(ex, ey));
}
