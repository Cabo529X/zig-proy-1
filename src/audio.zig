const std = @import("std");
const rl = @import("raylib");

/// 22050 Hz alcanza de sobra para efectos cortos y usa la mitad de memoria y de
/// CPU que 44100. Todo se genera mono en enteros de 16 bits.
pub const SAMPLE_RATE: u32 = 22050;
/// El efecto mas largo es el jingle de victoria; el scratch se dimensiona para
/// el peor caso y se reutiliza para todos los demas.
const MAX_SECONDS: f32 = 1.8;
const MAX_SAMPLES: usize = @intFromFloat(MAX_SECONDS * @as(f32, @floatFromInt(SAMPLE_RATE)));

pub const SfxId = enum(usize) {
    step_a = 0,
    step_b = 1,
    door = 2,
    pickup = 3,
    denied = 4,
    victory = 5,
};
const SFX_COUNT: usize = 6;

const Shape = enum { sine, square, saw, noise };

const Spec = struct {
    shape: Shape = .sine,
    freq_start: f32 = 440,
    freq_end: f32 = 440, // barrido lineal: sirve para servos y chirps
    dur: f32 = 0.2,
    attack: f32 = 0.005,
    amp: f32 = 0.8,
    noise_mix: f32 = 0, // 0..1, cuanto ruido blanco se mezcla sobre el tono
    lowpass: f32 = 1.0, // 1 = sin filtro, valores chicos apagan los agudos
    seed: u32 = 1,
};

fn hash(v: u32, seed: u32) u32 {
    var h: u32 = v *% 0x9e37_79b9 ^ seed *% 0x85eb_ca6b;
    h ^= h >> 16;
    h *%= 0x7feb_352d;
    h ^= h >> 15;
    return h;
}

fn noiseAt(i: usize, seed: u32) f32 {
    return @as(f32, @floatFromInt(hash(@truncate(i), seed) >> 8)) / 8388608.0 - 1.0;
}

/// Sintetiza un tono en `out` a partir de `start`, devolviendo el indice donde
/// termino. Con `add` las muestras se suman en vez de reemplazar, que es lo que
/// permite apilar dos senos para un acorde.
///
/// La envolvente termina multiplicada por (1 - u*u), que fuerza la ultima
/// muestra a cero exacto: sin eso, cortar la onda a media oscilacion produce un
/// chasquido audible al final de cada efecto.
fn synth(out: []i16, start: usize, spec: Spec, add: bool) usize {
    const n: usize = @intFromFloat(spec.dur * @as(f32, @floatFromInt(SAMPLE_RATE)));
    const end = @min(out.len, start + n);
    var phase: f32 = 0;
    var lp: f32 = 0;

    var i = start;
    while (i < end) : (i += 1) {
        const k = i - start;
        const t = @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(SAMPLE_RATE));
        const u = t / spec.dur;
        const f = spec.freq_start + (spec.freq_end - spec.freq_start) * u;
        phase += std.math.tau * f / @as(f32, @floatFromInt(SAMPLE_RATE));

        const tone: f32 = switch (spec.shape) {
            .sine => @sin(phase),
            .square => if (@sin(phase) >= 0) @as(f32, 1) else @as(f32, -1),
            .saw => 2.0 * (@mod(phase / std.math.tau, 1.0)) - 1.0,
            .noise => noiseAt(k, spec.seed),
        };
        var v = tone * (1.0 - spec.noise_mix) + noiseAt(k, spec.seed) * spec.noise_mix;
        lp += (v - lp) * spec.lowpass;
        v = lp;

        const env: f32 = if (t < spec.attack)
            t / @max(spec.attack, 1e-6)
        else
            @exp(-4.0 * (t - spec.attack) / @max(spec.dur - spec.attack, 1e-6)) * (1.0 - u * u);

        const sample = v * env * spec.amp * 30000.0;
        const prev: f32 = if (add) @floatFromInt(out[i]) else 0;
        out[i] = @intFromFloat(std.math.clamp(prev + sample, -32000, 32000));
    }
    return end;
}

/// Escribe el efecto pedido en `out` y devuelve cuantas muestras ocupa. Es
/// codigo puro: no toca raylib, asi que las pruebas lo corren headless.
pub fn renderSfx(out: []i16, id: SfxId) usize {
    @memset(out, 0);
    return switch (id) {
        // Pisada: golpe de ruido filtrado con un seno grave por debajo que le
        // da el cuerpo del taco contra la plancha metalica.
        .step_a, .step_b => blk: {
            const seed: u32 = if (id == .step_a) 11 else 29;
            const n = synth(out, 0, .{ .shape = .noise, .dur = 0.09, .attack = 0.004, .amp = 0.55, .noise_mix = 1.0, .lowpass = 0.25, .seed = seed }, false);
            _ = synth(out, 0, .{ .shape = .sine, .freq_start = 95, .freq_end = 62, .dur = 0.09, .attack = 0.004, .amp = 0.45 }, true);
            break :blk n;
        },
        // Puerta: sierra descendente (el servo) + silbido neumatico de ataque
        // lento + un golpe grave al final, cuando la hoja encaja.
        .door => blk: {
            const n = synth(out, 0, .{ .shape = .saw, .freq_start = 320, .freq_end = 90, .dur = 0.55, .attack = 0.02, .amp = 0.42, .lowpass = 0.35 }, false);
            _ = synth(out, 0, .{ .shape = .noise, .dur = 0.55, .attack = 0.16, .amp = 0.30, .noise_mix = 1.0, .lowpass = 0.12, .seed = 7 }, true);
            _ = synth(out, @intFromFloat(0.47 * @as(f32, @floatFromInt(SAMPLE_RATE))), .{ .shape = .sine, .freq_start = 48, .freq_end = 34, .dur = 0.08, .attack = 0.003, .amp = 0.6 }, true);
            break :blk n;
        },
        // Recoleccion: dos senos ascendentes separados por una quinta justa,
        // con un poco de cuadrada encima para el filo chiptune.
        .pickup => blk: {
            const n = synth(out, 0, .{ .shape = .sine, .freq_start = 660, .freq_end = 1320, .dur = 0.30, .amp = 0.5 }, false);
            _ = synth(out, 0, .{ .shape = .sine, .freq_start = 990, .freq_end = 1980, .dur = 0.30, .amp = 0.33 }, true);
            _ = synth(out, 0, .{ .shape = .square, .freq_start = 660, .freq_end = 1320, .dur = 0.30, .amp = 0.15 }, true);
            break :blk n;
        },
        // Denegado: dos blips graves iguales con un silencio en medio.
        .denied => blk: {
            _ = synth(out, 0, .{ .shape = .square, .freq_start = 220, .freq_end = 200, .dur = 0.06, .amp = 0.45, .lowpass = 0.6 }, false);
            const gap: usize = @intFromFloat(0.09 * @as(f32, @floatFromInt(SAMPLE_RATE)));
            break :blk synth(out, gap, .{ .shape = .square, .freq_start = 220, .freq_end = 200, .dur = 0.06, .amp = 0.45, .lowpass = 0.6 }, false);
        },
        // Victoria: arpegio de triada mayor C5-E5-G5-C6, cada nota encimada un
        // poco sobre la anterior para que suene ligado y no picado.
        .victory => blk: {
            const notes = [_]f32{ 523.25, 659.25, 783.99, 1046.5 };
            const step: f32 = 0.26;
            var last: usize = 0;
            for (notes, 0..) |freq, k| {
                const start: usize = @intFromFloat(@as(f32, @floatFromInt(k)) * step * @as(f32, @floatFromInt(SAMPLE_RATE)));
                last = synth(out, start, .{ .shape = .sine, .freq_start = freq, .freq_end = freq, .dur = 0.55, .amp = 0.45 }, true);
                _ = synth(out, start, .{ .shape = .square, .freq_start = freq, .freq_end = freq, .dur = 0.5, .amp = 0.12 }, true);
            }
            break :blk last;
        },
    };
}

pub const Sfx = struct {
    sounds: [SFX_COUNT]rl.Sound,
    step_toggle: bool = false,
    pitch_seed: u32 = 1,

    /// Sintetiza los seis efectos reutilizando un solo buffer y los sube al
    /// dispositivo de audio. raylib copia las muestras dentro de
    /// loadSoundFromWave, asi que el scratch se libera antes de retornar.
    pub fn init(gpa: std.mem.Allocator) !Sfx {
        const scratch = try gpa.alloc(i16, MAX_SAMPLES);
        defer gpa.free(scratch);

        var self: Sfx = .{ .sounds = undefined };
        for (0..SFX_COUNT) |i| {
            const id: SfxId = @enumFromInt(i);
            const frames = renderSfx(scratch, id);
            self.sounds[i] = upload(scratch, frames);
        }
        rl.setSoundVolume(self.sounds[@intFromEnum(SfxId.step_a)], 0.35);
        rl.setSoundVolume(self.sounds[@intFromEnum(SfxId.step_b)], 0.35);
        rl.setSoundVolume(self.sounds[@intFromEnum(SfxId.denied)], 0.5);
        return self;
    }

    pub fn unload(self: *const Sfx) void {
        for (self.sounds) |s| rl.unloadSound(s);
    }

    pub fn play(self: *const Sfx, id: SfxId) void {
        rl.playSound(self.sounds[@intFromEnum(id)]);
    }

    /// Alterna entre las dos pisadas y les mueve un poco el tono. Sin esa
    /// variacion, caminar suena a metronomo y delata que es un solo sample.
    pub fn playStep(self: *Sfx) void {
        self.step_toggle = !self.step_toggle;
        const id: SfxId = if (self.step_toggle) .step_a else .step_b;
        self.pitch_seed = hash(self.pitch_seed, 3);
        const jitter = @as(f32, @floatFromInt(self.pitch_seed >> 24)) / 255.0;
        const sound = self.sounds[@intFromEnum(id)];
        rl.setSoundPitch(sound, 0.92 + jitter * 0.16);
        rl.playSound(sound);
    }
};

/// Envuelve las muestras en un Wave y las sube al dispositivo.
///
/// Importante: NUNCA llamar rl.unloadWave sobre este Wave. Su campo `data`
/// apunta a memoria del allocator de Zig, y raylib intentaria liberarla con
/// free(), corrompiendo el heap. El buffer lo libera quien lo asigno.
fn upload(scratch: []i16, frames: usize) rl.Sound {
    const wave = rl.Wave{
        .frameCount = @intCast(frames),
        .sampleRate = SAMPLE_RATE,
        .sampleSize = 16,
        .channels = 1,
        .data = @ptrCast(scratch.ptr),
    };
    return rl.loadSoundFromWave(wave);
}

const testing = std.testing;

test "la sintesis nunca satura fuera del rango de i16" {
    const buf = try testing.allocator.alloc(i16, MAX_SAMPLES);
    defer testing.allocator.free(buf);
    for (0..SFX_COUNT) |i| {
        const n = renderSfx(buf, @enumFromInt(i));
        try testing.expect(n > 0 and n <= MAX_SAMPLES);
        for (buf[0..n]) |s| try testing.expect(s >= -32000 and s <= 32000);
    }
}

test "cada efecto empieza y termina en silencio" {
    const buf = try testing.allocator.alloc(i16, MAX_SAMPLES);
    defer testing.allocator.free(buf);
    for (0..SFX_COUNT) |i| {
        const n = renderSfx(buf, @enumFromInt(i));
        // Arrancar o cortar la onda a media oscilacion produce un chasquido.
        try testing.expect(@abs(buf[0]) < 600);
        try testing.expect(@abs(buf[n - 1]) < 600);
    }
}

test "cada efecto suena de verdad y no es puro silencio" {
    const buf = try testing.allocator.alloc(i16, MAX_SAMPLES);
    defer testing.allocator.free(buf);
    for (0..SFX_COUNT) |i| {
        const n = renderSfx(buf, @enumFromInt(i));
        var peak: i32 = 0;
        for (buf[0..n]) |s| peak = @max(peak, @as(i32, @intCast(@abs(s))));
        try testing.expect(peak > 3000);
    }
}

test "la sintesis es determinista" {
    const a = try testing.allocator.alloc(i16, MAX_SAMPLES);
    defer testing.allocator.free(a);
    const b = try testing.allocator.alloc(i16, MAX_SAMPLES);
    defer testing.allocator.free(b);
    _ = renderSfx(a, .door);
    _ = renderSfx(b, .door);
    try testing.expectEqualSlices(i16, a, b);
}
