const std = @import("std");
const rl = @import("raylib");

const levels = @import("levels.zig");
const textures = @import("textures.zig");
const world = @import("world.zig");
const player = @import("player.zig");

const World = world.World;
const Player = player.Player;

/// El HUD se dibuja en espacio de ventana, no en el framebuffer de 320x180, y
/// por eso se ve nitido aunque el mundo se renderice a baja resolucion.
const MINIMAP_SIZE: f32 = 186;
const MINIMAP_MARGIN: f32 = 14;

const PANEL_BG = rl.Color.init(8, 10, 20, 205);
const CYAN = rl.Color.init(60, 240, 255, 255);
const CYAN_DIM = rl.Color.init(60, 240, 255, 90);
const AMBER = rl.Color.init(255, 170, 60, 255);
const RED = rl.Color.init(255, 80, 80, 255);
const TEXT = rl.Color.init(214, 228, 245, 255);
const TEXT_DIM = rl.Color.init(120, 140, 165, 255);

/// Minimapa en la esquina superior derecha. Entra el nivel completo para que la
/// posicion del jugador se lea sin ambiguedad, y ademas de su punto se dibuja
/// una linea de orientacion y el cono de vision: la rubrica pide posicion, pero
/// ver hacia donde apunta uno es lo que lo hace realmente util.
pub fn drawMinimap(w: *const World, p: *const Player) void {
    const screen_w: f32 = @floatFromInt(rl.getScreenWidth());
    const ox = screen_w - MINIMAP_SIZE - MINIMAP_MARGIN;
    const oy = MINIMAP_MARGIN;

    rl.drawRectangle(@intFromFloat(ox - 4), @intFromFloat(oy - 4), @intFromFloat(MINIMAP_SIZE + 8), @intFromFloat(MINIMAP_SIZE + 8), PANEL_BG);
    rl.drawRectangleLinesEx(.{ .x = ox - 4, .y = oy - 4, .width = MINIMAP_SIZE + 8, .height = MINIMAP_SIZE + 8 }, 2, CYAN_DIM);

    const dim: f32 = @floatFromInt(@max(w.width, w.height));
    const cell = MINIMAP_SIZE / dim;
    const cell_px: i32 = @intFromFloat(@max(2.0, @ceil(cell)));

    var y: i32 = 0;
    while (y < w.height) : (y += 1) {
        var x: i32 = 0;
        while (x < w.width) : (x += 1) {
            const tile = w.at(x, y);
            if (tile == .empty) continue;
            const color = switch (tile) {
                .panel => textures.STEEL_MID,
                .grate => textures.STEEL_DARK,
                .neon => rl.Color.init(40, 120, 140, 255),
                .door => if (w.doorIsOpen(x, y)) CYAN_DIM else AMBER,
                .exit => blk: {
                    if (!w.exit_open) break :blk RED;
                    // Late entre cian y blanco, pero SIEMPRE opaca. Antes se
                    // pulsaba el alfa y al bajar se confundia con el fondo:
                    // justo cuando la esclusa se abre y mas hay que verla,
                    // parecia que desaparecia del minimapa.
                    const pulse = 0.5 + 0.5 * @sin(@as(f32, @floatCast(rl.getTime())) * 5.0);
                    const lift: u8 = @intFromFloat(pulse * 195.0);
                    break :blk rl.Color.init(60 + lift, 240, 255, 255);
                },
                .empty => unreachable,
            };
            rl.drawRectangle(
                @intFromFloat(ox + @as(f32, @floatFromInt(x)) * cell),
                @intFromFloat(oy + @as(f32, @floatFromInt(y)) * cell),
                cell_px,
                cell_px,
                color,
            );
        }
    }

    // Marco parpadeante alrededor de la esclusa ya abierta: con celdas de 7 px
    // un tile suelto se pierde entre los demas, y este es el objetivo del nivel.
    if (w.exit_open) {
        var ey: i32 = 0;
        while (ey < w.height) : (ey += 1) {
            var ex: i32 = 0;
            while (ex < w.width) : (ex += 1) {
                if (w.at(ex, ey) != .exit) continue;
                rl.drawRectangleLinesEx(.{
                    .x = ox + @as(f32, @floatFromInt(ex)) * cell - 3,
                    .y = oy + @as(f32, @floatFromInt(ey)) * cell - 3,
                    .width = @as(f32, @floatFromInt(cell_px)) + 6,
                    .height = @as(f32, @floatFromInt(cell_px)) + 6,
                }, 2, CYAN);
            }
        }
    }

    // celdas de energia que faltan
    var i: usize = 0;
    while (i < w.sprite_count) : (i += 1) {
        const s = w.sprites[i];
        if (s.kind != .core or !s.alive) continue;
        rl.drawCircle(
            @intFromFloat(ox + s.x * cell),
            @intFromFloat(oy + s.y * cell),
            @max(2.0, cell * 0.3),
            CYAN,
        );
    }

    const pxs = ox + p.x * cell;
    const pys = oy + p.y * cell;

    // cono de vision
    const fov_len = cell * 3.0;
    rl.drawLineEx(
        .{ .x = pxs, .y = pys },
        .{ .x = pxs + (p.dir_x - p.plane_x) * fov_len, .y = pys + (p.dir_y - p.plane_y) * fov_len },
        1,
        CYAN_DIM,
    );
    rl.drawLineEx(
        .{ .x = pxs, .y = pys },
        .{ .x = pxs + (p.dir_x + p.plane_x) * fov_len, .y = pys + (p.dir_y + p.plane_y) * fov_len },
        1,
        CYAN_DIM,
    );
    // linea de orientacion y punto del jugador
    rl.drawLineEx(
        .{ .x = pxs, .y = pys },
        .{ .x = pxs + p.dir_x * cell * 1.6, .y = pys + p.dir_y * cell * 1.6 },
        2,
        rl.Color.white,
    );
    rl.drawCircle(@intFromFloat(pxs), @intFromFloat(pys), @max(2.5, cell * 0.36), CYAN);
}

/// Contador de celdas, nombre del nivel, tiempo y mira. El estado de la esclusa
/// se dice con palabras para que el objetivo del nivel no necesite explicacion.
pub fn drawHud(w: *const World) void {
    var buf: [96]u8 = undefined;

    const name = std.fmt.bufPrintZ(&buf, "{s}", .{levels.LEVELS[w.level_index].name}) catch "nivel";
    rl.drawText(name, 12, 40, 20, TEXT_DIM);

    var buf2: [96]u8 = undefined;
    const counter = std.fmt.bufPrintZ(&buf2, "CELDAS {d}/{d}", .{ w.coresTaken(), w.cores_total }) catch "CELDAS";
    rl.drawText(counter, 12, 66, 28, CYAN);

    var buf3: [96]u8 = undefined;
    const status = if (w.exit_open)
        (std.fmt.bufPrintZ(&buf3, "ESCLUSA ABIERTA - BUSCA LA SALIDA", .{}) catch "")
    else
        (std.fmt.bufPrintZ(&buf3, "LA ESCLUSA ESTA SELLADA", .{}) catch "");
    rl.drawText(status, 12, 98, 18, if (w.exit_open) CYAN else RED);

    var buf4: [64]u8 = undefined;
    const time = std.fmt.bufPrintZ(&buf4, "{d:.1}s", .{w.elapsed}) catch "";
    rl.drawText(time, 12, 122, 18, TEXT_DIM);

    rl.drawText("1/2/3 nivel   M menu   R reiniciar", 12, @intFromFloat(@as(f32, @floatFromInt(rl.getScreenHeight())) - 28), 16, TEXT_DIM);

    drawCrosshair();
}

fn drawCrosshair() void {
    const cx = @divTrunc(rl.getScreenWidth(), 2);
    const cy = @divTrunc(rl.getScreenHeight(), 2);
    rl.drawRectangle(cx - 7, cy - 1, 5, 2, CYAN_DIM);
    rl.drawRectangle(cx + 2, cy - 1, 5, 2, CYAN_DIM);
    rl.drawRectangle(cx - 1, cy - 7, 2, 5, CYAN_DIM);
    rl.drawRectangle(cx - 1, cy + 2, 2, 5, CYAN_DIM);
}

/// Barrido de lineas horizontales translucidas. Es un truco barato de monitor
/// viejo que amarra las pantallas de menu con la estetica de la nave.
fn drawScanlines(t: f64) void {
    const h = rl.getScreenHeight();
    const w = rl.getScreenWidth();
    var y: i32 = 0;
    while (y < h) : (y += 3) {
        rl.drawRectangle(0, y, w, 1, rl.Color.init(0, 0, 0, 60));
    }
    const sweep: i32 = @intFromFloat(@mod(t * 90.0, @as(f64, @floatFromInt(h + 200))) - 100.0);
    var k: i32 = 0;
    while (k < 40) : (k += 1) {
        const a: u8 = @intFromFloat(18.0 * (1.0 - @as(f32, @floatFromInt(k)) / 40.0));
        rl.drawRectangle(0, sweep + k, w, 1, rl.Color.init(60, 240, 255, a));
    }
}

fn centerText(text: [:0]const u8, y: i32, size: i32, color: rl.Color) void {
    const wpx = rl.measureText(text, size);
    rl.drawText(text, @divTrunc(rl.getScreenWidth() - wpx, 2), y, size, color);
}

pub fn drawWelcome(selected: usize, t: f64) void {
    const sw = rl.getScreenWidth();
    const sh = rl.getScreenHeight();
    rl.clearBackground(rl.Color.init(8, 10, 20, 255));

    // rejilla de fondo en perspectiva falsa, solo decorativa
    var gx: i32 = 0;
    while (gx < sw) : (gx += 40) rl.drawRectangle(gx, 0, 1, sh, rl.Color.init(30, 60, 80, 40));
    var gy: i32 = 0;
    while (gy < sh) : (gy += 40) rl.drawRectangle(0, gy, sw, 1, rl.Color.init(30, 60, 80, 40));

    const pulse = 0.5 + 0.5 * @sin(t * 2.0);
    const glow: u8 = @intFromFloat(150.0 + 105.0 * pulse);

    centerText("PROTOCOLO DE EVACUACION", 92, 52, rl.Color.init(60, 240, 255, glow));
    centerText("un ray caster en Zig + raylib", 152, 20, TEXT_DIM);

    centerText("SELECCIONA UN SECTOR", 214, 20, TEXT);
    var i: usize = 0;
    while (i < levels.LEVELS.len) : (i += 1) {
        var buf: [96]u8 = undefined;
        const marker: []const u8 = if (i == selected) ">" else " ";
        const line = std.fmt.bufPrintZ(&buf, "{s} {d}. {s}", .{ marker, i + 1, levels.LEVELS[i].name }) catch continue;
        centerText(line, @intCast(252 + i * 32), 26, if (i == selected) CYAN else TEXT_DIM);
    }

    centerText("ENTER para entrar     1 / 2 / 3 o flechas para escoger", 372, 18, TEXT);

    const controls = [_][:0]const u8{
        "W / S    avanzar y retroceder",
        "A / D    desplazarse de lado",
        "MOUSE    girar y mirar arriba/abajo",
        "SHIFT    correr",
        "Q / E    mirar arriba / abajo",
        "1 2 3    cambiar de nivel en el acto",
        "M / R    menu / reiniciar nivel",
        "ESC      salir",
    };
    var k: usize = 0;
    while (k < controls.len) : (k += 1) {
        rl.drawText(controls[k], @divTrunc(sw, 2) - 190, @intCast(430 + k * 24), 18, TEXT_DIM);
    }

    centerText("Se juega con teclado y mouse, o con control conectado", sh - 46, 16, TEXT_DIM);
    drawScanlines(t);
}

pub fn drawSuccess(w: *const World, t: f64) void {
    const sw = rl.getScreenWidth();
    const sh = rl.getScreenHeight();
    rl.drawRectangle(0, 0, sw, sh, rl.Color.init(8, 10, 20, 225));

    const pulse = 0.5 + 0.5 * @sin(t * 3.0);
    const glow: u8 = @intFromFloat(150.0 + 105.0 * pulse);
    centerText("ESCLUSA ASEGURADA", 200, 56, rl.Color.init(60, 240, 255, glow));

    var buf: [96]u8 = undefined;
    const name = std.fmt.bufPrintZ(&buf, "{s}", .{levels.LEVELS[w.level_index].name}) catch "";
    centerText(name, 272, 26, TEXT);

    var buf2: [96]u8 = undefined;
    const stats = std.fmt.bufPrintZ(&buf2, "{d} celdas recuperadas en {d:.1} segundos", .{ w.cores_total, w.elapsed }) catch "";
    centerText(stats, 322, 22, TEXT_DIM);

    const last = w.level_index + 1 >= levels.LEVELS.len;
    if (last) {
        centerText("Has despejado toda la nave", 380, 22, AMBER);
    }
    centerText("N: siguiente sector     ENTER: menu     R: repetir", 440, 20, CYAN);
    drawScanlines(t);
}
