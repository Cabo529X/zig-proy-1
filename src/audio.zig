const std = @import("std");
const rl = @import("raylib");

pub const SfxId = enum(usize) {
    step_a = 0,
    step_b = 1,
    door = 2,
    pickup = 3,
    denied = 4,
    victory = 5,
};
const SFX_COUNT: usize = 6;

/// WAV de cada efecto, empacados dentro del ejecutable con @embedFile: el
/// binario sigue siendo un solo archivo, no hay que repartir una carpeta
/// assets/ junto a el.
const SFX_WAVS = [SFX_COUNT][]const u8{
    @embedFile("assets/audio/sfx_step_a.wav"),
    @embedFile("assets/audio/sfx_step_b.wav"),
    @embedFile("assets/audio/sfx_door.wav"),
    @embedFile("assets/audio/sfx_pickup.wav"),
    @embedFile("assets/audio/sfx_denied.wav"),
    @embedFile("assets/audio/sfx_victory.wav"),
};

fn hash(v: u32, seed: u32) u32 {
    var h: u32 = v *% 0x9e37_79b9 ^ seed *% 0x85eb_ca6b;
    h ^= h >> 16;
    h *%= 0x7feb_352d;
    h ^= h >> 15;
    return h;
}

pub const Sfx = struct {
    sounds: [SFX_COUNT]rl.Sound,
    step_toggle: bool = false,
    pitch_seed: u32 = 1,

    pub fn init() !Sfx {
        var self: Sfx = .{ .sounds = undefined };
        for (SFX_WAVS, 0..) |bytes, i| {
            const wave = try rl.loadWaveFromMemory(".wav", bytes);
            defer rl.unloadWave(wave);
            self.sounds[i] = rl.loadSoundFromWave(wave);
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
