const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // El raycaster escribe un framebuffer entero por frame, asi que Debug corre
    // varias veces mas lento. Se cambia el modo por defecto a ReleaseFast para
    // que `zig build run` sin flags ya salga optimizado, sin usar
    // `preferred_optimize_mode`: esa opcion desactiva `-Doptimize`, y aqui se
    // quiere seguir pudiendo pedir Debug para ver el reporte de fugas.
    if (b.release_mode == .off) b.release_mode = .fast;
    const optimize = b.standardOptimizeOption(.{});

    const raylib_dep = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
    });
    const raylib = raylib_dep.module("raylib");
    const raylib_artifact = raylib_dep.artifact("raylib");

    const exe = b.addExecutable(.{
        .name = "proyecto_01",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "raylib", .module = raylib },
            },
        }),
    });
    exe.root_module.linkLibrary(raylib_artifact);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Corre el raycaster de la nave");
    run_step.dependOn(&run_cmd.step);

    // Cada modulo con pruebas se compila como su propio ejecutable de test.
    // Las pruebas solo usan tipos de raylib (rl.Color), nunca sus funciones C,
    // asi que corren headless sin abrir ventana ni tocar la GPU.
    const test_step = b.step("test", "Corre las pruebas");
    const test_files = [_][]const u8{
        "src/world.zig",
        "src/player.zig",
        "src/raycaster.zig",
        "src/textures.zig",
        "src/audio.zig",
        "src/music.zig",
    };
    for (test_files) |path| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(path),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "raylib", .module = raylib },
                },
            }),
        });
        t.root_module.linkLibrary(raylib_artifact);
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
