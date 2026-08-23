const std = @import("std");
const rl = @import("raylib");

const audio = @import("audio.zig");
const hud = @import("hud.zig");
const levels = @import("levels.zig");
const music = @import("music.zig");
const player = @import("player.zig");
const raycaster = @import("raycaster.zig");
const textures = @import("textures.zig");
const world = @import("world.zig");

const Player = player.Player;
const World = world.World;

/// El mundo se dibuja a baja resolucion y se escala a la ventana con un factor
/// entero: los pixeles quedan cuadrados y nitidos, y escribir el framebuffer
/// completo cada frame cuesta una fraccion de milisegundo.
const RENDER_W: i32 = 320;
const RENDER_H: i32 = 180;
const SCALE: i32 = 4;
const WINDOW_W: i32 = RENDER_W * SCALE;
const WINDOW_H: i32 = RENDER_H * SCALE;

const MUSIC_VOLUME: f32 = 0.30;

const State = enum { welcome, playing, success };

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var fb = try raycaster.Framebuffer.init(gpa, RENDER_W, RENDER_H);
    defer gpa.free(fb.pixels);
    defer gpa.free(fb.depth);

    const atlas = try textures.Atlas.init(gpa);
    defer gpa.free(atlas.walls);
    defer gpa.free(atlas.sprites);

    rl.setConfigFlags(.{ .vsync_hint = true });
    rl.initWindow(WINDOW_W, WINDOW_H, "Protocolo de Evacuacion - Ray Caster en Zig");
    defer rl.closeWindow();
    rl.setTargetFPS(60);
    rl.setExitKey(.null); // Esc lo maneja el juego, no raylib

    rl.initAudioDevice();
    defer rl.closeAudioDevice();

    var sfx = try audio.Sfx.init(gpa);
    defer sfx.unload();

    // El WAV vive mientras suene la musica: raylib decodifica desde este mismo
    // buffer, no se queda con una copia. Por eso se libera despues de descargar
    // el stream (los defer corren en orden inverso al de registro).
    const music_wav = try music.renderWav(gpa);
    defer gpa.free(music_wav);
    // Unico catch del proyecto, y esta aqui a proposito: un problema de audio
    // nunca debe tumbar el juego, simplemente se juega en silencio.
    const tune: ?rl.Music = rl.loadMusicStreamFromMemory(".wav", music_wav) catch null;
    defer if (tune) |m| rl.unloadMusicStream(m);
    if (tune) |m| {
        var looped = m;
        looped.looping = true;
        rl.setMusicVolume(looped, MUSIC_VOLUME);
        rl.playMusicStream(looped);
    }

    const image = rl.genImageColor(RENDER_W, RENDER_H, textures.VOID);
    const screen = try rl.loadTextureFromImage(image);
    defer rl.unloadTexture(screen);
    rl.unloadImage(image);

    const src = rl.Rectangle{ .x = 0, .y = 0, .width = @floatFromInt(RENDER_W), .height = @floatFromInt(RENDER_H) };
    const dest = rl.Rectangle{ .x = 0, .y = 0, .width = @floatFromInt(WINDOW_W), .height = @floatFromInt(WINDOW_H) };

    var state: State = .welcome;
    var selected: usize = 0;
    var w = World.load(selected);
    var p = Player.spawn(&w);

    while (!rl.windowShouldClose()) {
        if (tune) |m| rl.updateMusicStream(m);
        const t = rl.getTime();

        switch (state) {
            .welcome => {
                if (levelHotkey()) |i| selected = i;
                if (rl.isKeyPressed(.right)) selected = (selected + 1) % levels.LEVELS.len;
                if (rl.isKeyPressed(.left)) selected = (selected + levels.LEVELS.len - 1) % levels.LEVELS.len;
                if (rl.isKeyPressed(.escape)) break;

                const confirm = rl.isKeyPressed(.enter) or rl.isKeyPressed(.space) or
                    (rl.isGamepadAvailable(0) and rl.isGamepadButtonPressed(0, .right_face_down));
                if (confirm) {
                    w = World.load(selected);
                    p = Player.spawn(&w);
                    state = .playing;
                    rl.disableCursor();
                }
            },

            .playing => {
                if (rl.isKeyPressed(.escape) or rl.isKeyPressed(.m)) {
                    state = .welcome;
                    rl.enableCursor();
                } else if (rl.isKeyPressed(.r)) {
                    w = World.load(w.level_index);
                    p = Player.spawn(&w);
                } else if (levelHotkey()) |i| {
                    // Cambio de nivel en caliente, sin recompilar ni reiniciar.
                    selected = i;
                    w = World.load(i);
                    p = Player.spawn(&w);
                }

                if (state == .playing) {
                    const dt = rl.getFrameTime();
                    const in = player.Input.gather();
                    if (p.update(&w, dt, in)) sfx.playStep();

                    switch (w.update(p.x, p.y, @min(dt, player.MAX_DT))) {
                        .pickup => sfx.play(.pickup),
                        .door_open => sfx.play(.door),
                        .denied => sfx.play(.denied),
                        .win => {
                            sfx.play(.victory);
                            state = .success;
                            rl.enableCursor();
                        },
                        .none => {},
                    }
                }
            },

            .success => {
                if (rl.isKeyPressed(.n)) {
                    selected = (w.level_index + 1) % levels.LEVELS.len;
                    w = World.load(selected);
                    p = Player.spawn(&w);
                    state = .playing;
                    rl.disableCursor();
                } else if (rl.isKeyPressed(.r)) {
                    w = World.load(w.level_index);
                    p = Player.spawn(&w);
                    state = .playing;
                    rl.disableCursor();
                } else if (rl.isKeyPressed(.enter) or rl.isKeyPressed(.escape)) {
                    state = .welcome;
                }
            },
        }

        // El mundo se rasteriza tambien detras de la pantalla de exito, para
        // que el nivel se siga viendo de fondo en vez de un rectangulo negro.
        if (state != .welcome) {
            raycaster.renderWorld(&fb, &w, &p, &atlas);
            raycaster.renderSprites(&fb, &w, &p, &atlas);
            rl.updateTexture(screen, @ptrCast(fb.pixels.ptr));
        }

        rl.beginDrawing();
        defer rl.endDrawing();

        switch (state) {
            .welcome => hud.drawWelcome(selected, t),
            .playing => {
                rl.drawTexturePro(screen, src, dest, .{ .x = 0, .y = 0 }, 0, .white);
                hud.drawHud(&w);
                hud.drawMinimap(&w, &p);
            },
            .success => {
                rl.drawTexturePro(screen, src, dest, .{ .x = 0, .y = 0 }, 0, .white);
                hud.drawMinimap(&w, &p);
                hud.drawSuccess(&w, t);
            },
        }
        rl.drawFPS(12, 12);
    }
}

/// Las teclas 1, 2 y 3 escogen nivel tanto en el menu como en pleno juego.
fn levelHotkey() ?usize {
    if (rl.isKeyPressed(.one)) return 0;
    if (rl.isKeyPressed(.two)) return 1;
    if (rl.isKeyPressed(.three)) return 2;
    return null;
}
