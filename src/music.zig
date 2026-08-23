const std = @import("std");

/// Musica de ambiente generada por sintesis, entregada como un WAV completo en
/// memoria. No hay archivo que cargar: eso evita que el juego se quede mudo si
/// se corre el binario desde otra carpeta (raylib resuelve las rutas relativas
/// contra el working directory) y deja el ejecutable autocontenido.
pub const SAMPLE_RATE: u32 = 22050;

/// La duracion del loop no es arbitraria: todas las frecuencias se redondean a
/// un multiplo entero de 1/LOOP_SECONDS, asi que la onda es exactamente
/// periodica en ese intervalo y el loop no tiene costura audible.
const LOOP_SECONDS: f32 = 32.0;
const FRAMES: usize = @intFromFloat(LOOP_SECONDS * @as(f32, @floatFromInt(SAMPLE_RATE)));
const HEADER_BYTES: usize = 44;

/// Redondea una frecuencia al armonico mas cercano del loop. El corrimiento es
/// de centesimas de hertz, inaudible, y es lo que garantiza que la muestra
/// empiece y termine en la misma fase.
fn loopLocked(freq: f32) f32 {
    const base = 1.0 / LOOP_SECONDS;
    return @round(freq / base) * base;
}

fn hash(v: u32) u32 {
    var h: u32 = v *% 0x9e37_79b9;
    h ^= h >> 16;
    h *%= 0x7feb_352d;
    h ^= h >> 15;
    return h;
}

/// Un pad de acorde menor con osciladores desafinados, un sub grave, aire
/// filtrado y campanadas ocasionales. Todo con LFOs lentos amarrados al loop
/// para que la textura evolucione sin repetirse de forma obvia.
fn sampleAt(t: f32) f32 {
    var v: f32 = 0;

    // pad: la menor (A2, C3, E3, A3), cada voz con su propio vibrato de amplitud
    const chord = [_]f32{ 110.0, 130.81, 164.81, 220.0 };
    const lfo_rate = [_]f32{ 0.0625, 0.09375, 0.125, 0.15625 }; // multiplos de 1/32
    const weight = [_]f32{ 0.30, 0.22, 0.20, 0.16 };
    for (chord, lfo_rate, weight) |freq, rate, wgt| {
        const f = loopLocked(freq);
        const detune = loopLocked(freq * 1.004);
        const env = 0.55 + 0.45 * @sin(std.math.tau * loopLocked(rate) * t);
        v += wgt * env * (@sin(std.math.tau * f * t) + 0.6 * @sin(std.math.tau * detune * t));
    }

    // sub: sostiene el fondo y le da peso de sala de maquinas
    v += 0.35 * @sin(std.math.tau * loopLocked(55.0) * t) *
        (0.6 + 0.4 * @sin(std.math.tau * loopLocked(0.03125) * t));

    // brillo lejano, muy tenue, con tremolo lento
    v += 0.07 * @sin(std.math.tau * loopLocked(880.0) * t) *
        (0.5 + 0.5 * @sin(std.math.tau * loopLocked(0.1875) * t));

    // campanadas: una cada 8 segundos, con decaimiento que cierra antes del
    // final del loop para que no se corte a la mitad al repetir
    const bells = [_]f32{ 440.0, 659.25, 880.0, 659.25 };
    for (bells, 0..) |freq, k| {
        const onset = @as(f32, @floatFromInt(k)) * 8.0;
        const dt = t - onset;
        if (dt < 0 or dt > 6.0) continue;
        const env = @exp(-dt * 0.9);
        v += 0.16 * env * @sin(std.math.tau * loopLocked(freq) * t);
    }

    return v;
}

fn putU32(buf: []u8, off: usize, value: u32) void {
    std.mem.writeInt(u32, buf[off..][0..4], value, .little);
}

fn putU16(buf: []u8, off: usize, value: u16) void {
    std.mem.writeInt(u16, buf[off..][0..2], value, .little);
}

/// Devuelve un WAV PCM de 16 bits mono, listo para
/// rl.loadMusicStreamFromMemory(".wav", bytes). El caller libera el slice.
pub fn renderWav(gpa: std.mem.Allocator) ![]u8 {
    const data_bytes = FRAMES * 2;
    const buf = try gpa.alloc(u8, HEADER_BYTES + data_bytes);
    errdefer gpa.free(buf);

    @memcpy(buf[0..4], "RIFF");
    putU32(buf, 4, @intCast(36 + data_bytes));
    @memcpy(buf[8..12], "WAVE");
    @memcpy(buf[12..16], "fmt ");
    putU32(buf, 16, 16); // tamano del bloque fmt
    putU16(buf, 20, 1); // PCM sin comprimir
    putU16(buf, 22, 1); // mono
    putU32(buf, 24, SAMPLE_RATE);
    putU32(buf, 28, SAMPLE_RATE * 2); // bytes por segundo
    putU16(buf, 32, 2); // alineacion de bloque
    putU16(buf, 34, 16); // bits por muestra
    @memcpy(buf[36..40], "data");
    putU32(buf, 40, @intCast(data_bytes));

    // Primera pasada: sintetizar y quedarse con el pico, para normalizar
    // despues en vez de adivinar una amplitud que podria recortar.
    const samples = try gpa.alloc(f32, FRAMES);
    defer gpa.free(samples);
    var peak: f32 = 1e-6;
    for (samples, 0..) |*s, i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(SAMPLE_RATE));
        s.* = sampleAt(t);
        peak = @max(peak, @abs(s.*));
    }

    const gain = 0.82 / peak;
    for (samples, 0..) |s, i| {
        const q: i16 = @intFromFloat(std.math.clamp(s * gain * 32000.0, -32000, 32000));
        std.mem.writeInt(i16, buf[HEADER_BYTES + i * 2 ..][0..2], q, .little);
    }
    return buf;
}

const testing = std.testing;

test "el wav generado tiene una cabecera valida y el largo que declara" {
    const wav = try renderWav(testing.allocator);
    defer testing.allocator.free(wav);

    try testing.expectEqualSlices(u8, "RIFF", wav[0..4]);
    try testing.expectEqualSlices(u8, "WAVE", wav[8..12]);
    try testing.expectEqualSlices(u8, "data", wav[36..40]);
    const declared = std.mem.readInt(u32, wav[40..44], .little);
    try testing.expectEqual(wav.len - HEADER_BYTES, declared);
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, wav[22..24], .little));
    try testing.expectEqual(SAMPLE_RATE, std.mem.readInt(u32, wav[24..28], .little));
    try testing.expectEqual(@as(u16, 16), std.mem.readInt(u16, wav[34..36], .little));
}

test "el loop cierra sin costura: el principio y el final casi coinciden" {
    // Todas las frecuencias estan amarradas a multiplos de 1/LOOP_SECONDS, asi
    // que la onda tiene que volver practicamente al mismo punto.
    const a = sampleAt(0);
    const b = sampleAt(LOOP_SECONDS);
    try testing.expectApproxEqAbs(a, b, 0.02);
}

test "la musica nunca satura" {
    const wav = try renderWav(testing.allocator);
    defer testing.allocator.free(wav);
    var i: usize = HEADER_BYTES;
    while (i + 1 < wav.len) : (i += 2) {
        const s = std.mem.readInt(i16, wav[i..][0..2], .little);
        try testing.expect(s >= -32000 and s <= 32000);
    }
}
