//! Los niveles viven embebidos en el binario como arte ASCII, igual que los
//! patrones de Conway del lab-02. Asi cargar un nivel no necesita allocator ni
//! I/O y no puede fallar: el juego no se puede caer por un archivo que falta.

/// Leyenda del arte ASCII:
///   '#' panel metalico   '=' rejilla de ventilacion   '!' pared con neon
///   'D' puerta hidraulica (se abre al acercarse)      'X' esclusa de salida
///   '.' piso libre       '@' spawn del jugador        'c' celda de energia
///   'r' dron de mantenimiento                         's' fuga de vapor
pub const Level = struct {
    name: []const u8, // se muestra en el menu y en el HUD
    rows: []const []const u8, // todas las filas tienen que medir lo mismo
    spawn_angle: f32, // grados, 0 = mirando hacia +x
};

const CARGO_BAY = Level{
    .name = "Bahia de carga",
    .rows = &.{
        "################",
        "#@....c........#",
        "#..##......##..#",
        "#..##..r...##..#",
        "#.....s........#",
        "#..!!......!!..#",
        "#..!!......!!..#",
        "#......==......#",
        "#......==......#",
        "#..!!......!!..#",
        "#..!!......!!..#",
        "#..............#",
        "#..##...c..##..#",
        "#..##......##..#",
        "#....c.......X.#",
        "################",
    },
    .spawn_angle = 0,
};

const ENGINE_ROOM = Level{
    .name = "Sala de maquinas",
    .rows = &.{
        "####################",
        "#@...#........#....#",
        "#.##.#.######.#.##.#",
        "#.##...#....#...##.#",
        "#....#.#.==.#.#....#",
        "####.#.#....#.#.####",
        "#c...#.#.##.#.#...c#",
        "#.####.#.##.#.####.#",
        "#...s..D....D..s...#",
        "#.####.#.##.#.####.#",
        "#!!..#.#.##.#.#..!!#",
        "####.#.#....#.#.####",
        "#....#.#.==.#.#....#",
        "#.##...#....#...##.#",
        "#.##.#.######.#.##.#",
        "#....#...r..c.#....#",
        "#.##########.#####.#",
        "#..c......#....#.X.#",
        "#.#....r..#....#...#",
        "####################",
    },
    .spawn_angle = 0,
};

const REACTOR_CORE = Level{
    .name = "Nucleo del reactor",
    .rows = &.{
        "########################",
        "#@...................c.#",
        "#.#########..#########.#",
        "#.#c................r#.#",
        "#.#.!!!!!!!!!!!!!!!!.#.#",
        "#.#.!s............c!.#.#",
        "#.#.!.############.!.#.#",
        "#.#.!.#c.........#.!.#.#",
        "#.#.!.#.========.#.!.#.#",
        "#.#.!.#.=......=.#.!.#.#",
        "#.#.!.#.=......=.#.!.#.#",
        "#.#.!.#.D......=.#...#.#",
        "#.#.!.#.D...X..=.#...#.#",
        "#.#.!.#.=.....c=.#.!.#.#",
        "#.#.!.#.=.r....=.#.!.#.#",
        "#.#.!.#.========.#.!.#.#",
        "#.#.!.#..........#.!.#.#",
        "#.#.!.#####DD#####.!.#.#",
        "#.#.!.............s!.#.#",
        "#.#.!!!!!!!!!!!!!!!!.#.#",
        "#.#r.................#.#",
        "#.####################.#",
        "#......................#",
        "########################",
    },
    .spawn_angle = 0,
};

pub const LEVELS = [_]Level{ CARGO_BAY, ENGINE_ROOM, REACTOR_CORE };
