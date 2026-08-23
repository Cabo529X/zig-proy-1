const std = @import("std");
const rl = @import("raylib");

const world = @import("world.zig");
const World = world.World;

/// Radio de colision del jugador. Menor a medio tile, que es lo que hace exacta
/// la prueba de las cuatro esquinas de `blocksCircle`.
pub const RADIUS: f32 = 0.22;
/// Tope del delta de tiempo. Sin esto, arrastrar la ventana o pausar en un
/// breakpoint produce un frame de varios segundos y un salto de decenas de
/// tiles, que es la unica forma realista de atravesar una pared.
pub const MAX_DT: f32 = 0.05;

const SPEED_WALK: f32 = 2.5;
const SPEED_RUN: f32 = 4.0;
const TURN_SPEED: f32 = 2.4; // radianes por segundo con teclado o stick
const MOUSE_SENS: f32 = 0.0026; // radianes por pixel de movimiento del mouse
const PITCH_SPEED: f32 = 220.0; // pixeles de horizonte por segundo con teclado
const MOUSE_PITCH: f32 = 0.9; // pixeles de horizonte por pixel de mouse
const BOB_FREQ: f32 = 9.0; // radianes de cabeceo por tile recorrido
const BOB_AMP: f32 = 2.6; // amplitud en pixeles del framebuffer
const STICK_DEADZONE: f32 = 0.18;

/// Estado de entrada ya normalizado, para que `Player.update` no sepa si viene
/// del teclado, del mouse o de un control.
pub const Input = struct {
    forward: f32 = 0, // -1 atras .. +1 adelante
    strafe: f32 = 0, // -1 izquierda .. +1 derecha
    turn: f32 = 0, // ritmo de giro -1..1 (teclado o stick), escalado por dt
    look: f32 = 0, // ritmo de cabeceo -1..1 (teclado o stick), escalado por dt
    // El mouse se guarda aparte porque ya viene como desplazamiento absoluto
    // del frame: multiplicarlo por dt lo haria depender del framerate y la
    // sensibilidad cambiaria segun cuantos FPS este dando la maquina.
    turn_delta: f32 = 0, // radianes de este frame
    look_delta: f32 = 0, // pixeles de horizonte de este frame
    run: bool = false,

    /// Junta teclado, mouse y control en un solo vector de intencion. El mando
    /// se lee solo si esta conectado, asi que el juego funciona igual sin el.
    pub fn gather() Input {
        var in: Input = .{};

        if (rl.isKeyDown(.w) or rl.isKeyDown(.up)) in.forward += 1;
        if (rl.isKeyDown(.s) or rl.isKeyDown(.down)) in.forward -= 1;
        if (rl.isKeyDown(.d)) in.strafe += 1;
        if (rl.isKeyDown(.a)) in.strafe -= 1;
        if (rl.isKeyDown(.right)) in.turn += 1;
        if (rl.isKeyDown(.left)) in.turn -= 1;
        if (rl.isKeyDown(.e)) in.look -= 1;
        if (rl.isKeyDown(.q)) in.look += 1;
        in.run = rl.isKeyDown(.left_shift);

        const md = rl.getMouseDelta();
        in.turn_delta = md.x * MOUSE_SENS;
        in.look_delta = -md.y * MOUSE_PITCH;

        if (rl.isGamepadAvailable(0)) {
            in.forward -= deadzone(rl.getGamepadAxisMovement(0, .left_y));
            in.strafe += deadzone(rl.getGamepadAxisMovement(0, .left_x));
            in.turn += deadzone(rl.getGamepadAxisMovement(0, .right_x));
            in.look -= deadzone(rl.getGamepadAxisMovement(0, .right_y));
            if (rl.isGamepadButtonDown(0, .right_trigger_2)) in.run = true;
        }

        in.forward = std.math.clamp(in.forward, -1, 1);
        in.strafe = std.math.clamp(in.strafe, -1, 1);
        return in;
    }
};

fn deadzone(v: f32) f32 {
    return if (@abs(v) < STICK_DEADZONE) 0 else v;
}

pub const Player = struct {
    x: f32,
    y: f32,
    dir_x: f32, // vector unitario de vista
    dir_y: f32,
    plane_x: f32, // plano de camara, perpendicular a dir; su largo fija el FOV
    plane_y: f32,
    pitch: f32, // desplazamiento del horizonte en pixeles del framebuffer
    bob_phase: f32, // avanza con la distancia recorrida, no con el tiempo
    bob_offset: f32,

    /// Medio ancho del plano de camara. tan(33 grados) ~ 0.66 da un FOV de 66,
    /// que es el clasico de este tipo de raycaster.
    pub const FOV_TAN: f32 = 0.66;

    pub fn spawn(w: *const World) Player {
        var p: Player = .{
            .x = w.spawn_x,
            .y = w.spawn_y,
            .dir_x = 1,
            .dir_y = 0,
            .plane_x = 0,
            .plane_y = FOV_TAN,
            .pitch = 0,
            .bob_phase = 0,
            .bob_offset = 0,
        };
        p.setAngle(w.spawn_angle);
        return p;
    }

    pub fn setAngle(self: *Player, radians: f32) void {
        self.dir_x = @cos(radians);
        self.dir_y = @sin(radians);
        self.plane_x = -self.dir_y * FOV_TAN;
        self.plane_y = self.dir_x * FOV_TAN;
    }

    /// Rota la vista aplicando la misma matriz 2x2 a la direccion y al plano de
    /// camara. Tienen que girar juntos: si se desincronizan, el plano deja de
    /// ser perpendicular a la vista y toda la imagen sale deformada.
    pub fn rotate(self: *Player, radians: f32) void {
        const c = @cos(radians);
        const s = @sin(radians);
        const dx = self.dir_x;
        const px = self.plane_x;
        self.dir_x = dx * c - self.dir_y * s;
        self.dir_y = dx * s + self.dir_y * c;
        self.plane_x = px * c - self.plane_y * s;
        self.plane_y = px * s + self.plane_y * c;
    }

    /// Avanza un frame. Devuelve true en el instante en que el cabeceo toca su
    /// punto mas bajo, que es cuando main dispara el sonido de pisada.
    pub fn update(self: *Player, w: *const World, raw_dt: f32, in: Input) bool {
        const dt = @min(raw_dt, MAX_DT);

        const turn = in.turn * TURN_SPEED * dt + in.turn_delta;
        if (turn != 0) self.rotate(turn);

        const look = in.look * PITCH_SPEED * dt + in.look_delta;
        self.pitch = std.math.clamp(self.pitch + look, -PITCH_LIMIT, PITCH_LIMIT);

        const speed: f32 = if (in.run) SPEED_RUN else SPEED_WALK;
        // El strafe usa la perpendicular unitaria a la vista, no el plano de
        // camara, porque ese esta escalado por el FOV y moveria mas despacio.
        const dx = (self.dir_x * in.forward - self.dir_y * in.strafe) * speed * dt;
        const dy = (self.dir_y * in.forward + self.dir_x * in.strafe) * speed * dt;

        const before_x = self.x;
        const before_y = self.y;
        self.moveSubstepped(w, dx, dy);

        const moved_x = self.x - before_x;
        const moved_y = self.y - before_y;
        const moved = @sqrt(moved_x * moved_x + moved_y * moved_y);

        const prev_phase = self.bob_phase;
        self.bob_phase += moved * BOB_FREQ;
        const amp: f32 = if (in.run) BOB_AMP * 1.7 else BOB_AMP;
        self.bob_offset = @sin(self.bob_phase) * amp;

        const half_turns_before = @floor(prev_phase / std.math.pi);
        const half_turns_now = @floor(self.bob_phase / std.math.pi);
        return half_turns_now != half_turns_before;
    }

    /// Parte el desplazamiento en trozos menores a medio radio. Con un solo
    /// paso, correr a 4 tiles/s durante un frame largo movería 0.2 tiles y una
    /// pared delgada podria quedar entre la posicion vieja y la nueva sin que
    /// ninguna de las dos la toque.
    fn moveSubstepped(self: *Player, w: *const World, dx: f32, dy: f32) void {
        const len = @sqrt(dx * dx + dy * dy);
        if (len == 0) return;
        const max_step = RADIUS * 0.5;
        const steps: usize = @intFromFloat(@ceil(len / max_step));
        const n: f32 = @floatFromInt(steps);
        var i: usize = 0;
        while (i < steps) : (i += 1) self.tryMove(w, dx / n, dy / n);
    }

    /// Resuelve cada eje por separado: si el avance en X choca se descarta solo
    /// X y se conserva Y, y al reves. Eso es lo que hace que uno se deslice a lo
    /// largo de una pared en diagonal en vez de frenarse en seco al tocarla.
    fn tryMove(self: *Player, w: *const World, dx: f32, dy: f32) void {
        const nx = self.x + dx;
        if (!w.blocksCircle(nx, self.y, RADIUS)) self.x = nx;
        const ny = self.y + dy;
        if (!w.blocksCircle(self.x, ny, RADIUS)) self.y = ny;
    }
};

/// Tope del pitch en pixeles. Mas alla de esto la deformacion del y-shearing se
/// vuelve obvia y el horizonte se sale del framebuffer.
pub const PITCH_LIMIT: f32 = 78;

const testing = std.testing;

test "rotar 2 pi deja la direccion y el plano como estaban" {
    var p: Player = undefined;
    p.setAngle(0.7);
    const d0x = p.dir_x;
    const d0y = p.dir_y;
    const p0x = p.plane_x;
    const p0y = p.plane_y;
    for (0..360) |_| p.rotate(std.math.tau / 360.0);
    try testing.expectApproxEqAbs(d0x, p.dir_x, 1e-4);
    try testing.expectApproxEqAbs(d0y, p.dir_y, 1e-4);
    try testing.expectApproxEqAbs(p0x, p.plane_x, 1e-4);
    try testing.expectApproxEqAbs(p0y, p.plane_y, 1e-4);
}

test "el plano de camara siempre es perpendicular a la vista" {
    var p: Player = undefined;
    p.setAngle(0);
    for (0..50) |_| {
        p.rotate(0.13);
        try testing.expectApproxEqAbs(@as(f32, 0), p.dir_x * p.plane_x + p.dir_y * p.plane_y, 1e-4);
    }
}

test "el jugador no atraviesa una pared aunque empuje mil frames contra ella" {
    const w = World.load(0);
    var p = Player.spawn(&w);
    p.setAngle(0);
    for (0..1000) |_| {
        _ = p.update(&w, MAX_DT, .{ .forward = 1, .run = true });
    }
    try testing.expect(!w.blocksCircle(p.x, p.y, RADIUS));
    try testing.expect(p.x > 0 and p.x < @as(f32, @floatFromInt(w.width)));
    try testing.expect(p.y > 0 and p.y < @as(f32, @floatFromInt(w.height)));
}

test "el jugador no se sale del mapa empujando en las ocho direcciones" {
    const w = World.load(0);
    var p = Player.spawn(&w);
    var a: f32 = 0;
    while (a < std.math.tau) : (a += std.math.tau / 8.0) {
        p.setAngle(a);
        for (0..400) |_| _ = p.update(&w, MAX_DT, .{ .forward = 1, .strafe = 1, .run = true });
        try testing.expect(!w.blocksCircle(p.x, p.y, RADIUS));
    }
}

test "el jugador se desliza a lo largo de una pared en vez de frenarse" {
    const w = World.load(0);
    var p = Player.spawn(&w);
    // pegado al muro norte, empujando en diagonal hacia arriba y hacia +x
    p.x = 3.5;
    p.y = 1.0 + RADIUS + 0.01;
    p.setAngle(-std.math.pi / 4.0); // hacia arriba-derecha
    const x0 = p.x;
    for (0..30) |_| _ = p.update(&w, 1.0 / 60.0, .{ .forward = 1 });
    try testing.expect(p.x > x0 + 0.2); // avanzo en la tangente
    try testing.expect(!w.blocksCircle(p.x, p.y, RADIUS));
}

test "un dt gigante no teletransporta al jugador a traves de una pared" {
    const w = World.load(0);
    var p = Player.spawn(&w);
    p.setAngle(0);
    const x0 = p.x;
    const y0 = p.y;
    _ = p.update(&w, 5.0, .{ .forward = 1, .run = true });
    const moved = @sqrt((p.x - x0) * (p.x - x0) + (p.y - y0) * (p.y - y0));
    try testing.expect(moved <= SPEED_RUN * MAX_DT + 1e-3);
    try testing.expect(!w.blocksCircle(p.x, p.y, RADIUS));
}

test "el cabeceo solo avanza cuando el jugador se mueve" {
    const w = World.load(0);
    var p = Player.spawn(&w);
    const phase0 = p.bob_phase;
    for (0..60) |_| _ = p.update(&w, 1.0 / 60.0, .{});
    try testing.expectEqual(phase0, p.bob_phase);
    for (0..60) |_| _ = p.update(&w, 1.0 / 60.0, .{ .forward = 1 });
    try testing.expect(p.bob_phase > phase0);
}

test "el pitch nunca se sale de su limite" {
    const w = World.load(0);
    var p = Player.spawn(&w);
    for (0..600) |_| _ = p.update(&w, MAX_DT, .{ .look = 1 });
    try testing.expectApproxEqAbs(PITCH_LIMIT, p.pitch, 1e-3);
    for (0..1200) |_| _ = p.update(&w, MAX_DT, .{ .look = -1 });
    try testing.expectApproxEqAbs(-PITCH_LIMIT, p.pitch, 1e-3);
}

test "el mouse gira lo mismo sin importar el framerate" {
    const w = World.load(0);
    var slow = Player.spawn(&w);
    var fast = Player.spawn(&w);
    slow.setAngle(0);
    fast.setAngle(0);
    // mismo desplazamiento total de mouse, repartido en 1 frame o en 10
    _ = slow.update(&w, 1.0 / 6.0, .{ .turn_delta = 0.5 });
    for (0..10) |_| _ = fast.update(&w, 1.0 / 60.0, .{ .turn_delta = 0.05 });
    try testing.expectApproxEqAbs(slow.dir_x, fast.dir_x, 1e-4);
    try testing.expectApproxEqAbs(slow.dir_y, fast.dir_y, 1e-4);
}
