const std = @import("std");
const rl = @import("raylib");

const world = @import("world.zig");
const textures = @import("textures.zig");
const player = @import("player.zig");

const World = world.World;
const Tile = world.Tile;
const Player = player.Player;
const Atlas = textures.Atlas;
const TEX_SIZE = textures.TEX_SIZE;
const EMISSIVE = textures.EMISSIVE;

/// Tope de celdas que recorre el DDA antes de rendirse. Es la garantia de que
/// el bucle siempre termina, incluso si algun dia un nivel quedara abierto.
pub const MAX_DDA_STEPS: u32 = 128;

/// Constante de la niebla. Mas alto = la oscuridad se come el pasillo antes.
const FOG_K: f32 = 0.22;
const FOG_FLOOR: f32 = 0.13; // luz minima: nunca se llega al negro absoluto
const SIDE_SHADE: f32 = 0.72; // caras norte/sur mas oscuras que este/oeste
const MIN_DIST: f32 = 1e-4;
/// Plano cercano de los sprites. Mas cerca que esto, un billboard se magnifica
/// tanto que llena la pantalla de bloques gigantes y su desplazamiento vertical
/// lo manda fuera de cuadro: se lee como un error de dibujo, no como un objeto.
/// Es preferible que desaparezca cuando ya lo tienes encima.
const SPRITE_NEAR_CLIP: f32 = 0.55;

pub const Framebuffer = struct {
    width: i32,
    height: i32,
    pixels: []rl.Color, // len == width*height, se sube tal cual con updateTexture
    depth: []f32, // distancia perpendicular por columna, para tapar sprites

    pub fn init(gpa: std.mem.Allocator, width: i32, height: i32) !Framebuffer {
        const pixels = try gpa.alloc(rl.Color, @intCast(width * height));
        errdefer gpa.free(pixels);
        const depth = try gpa.alloc(f32, @intCast(width));
        @memset(pixels, textures.VOID);
        @memset(depth, std.math.floatMax(f32));
        return .{ .width = width, .height = height, .pixels = pixels, .depth = depth };
    }

    /// Unica funcion para escribir un pixel suelto. Las coordenadas fuera de
    /// rango se ignoran, igual que en el canvas del lab-01: los bucles internos
    /// que ya vienen acotados escriben directo al slice y se saltan el chequeo.
    pub fn put(self: *Framebuffer, x: i32, y: i32, c: rl.Color) void {
        if (x < 0 or y < 0 or x >= self.width or y >= self.height) return;
        self.pixels[@intCast(y * self.width + x)] = c;
    }
};

pub const Hit = struct {
    dist: f32, // distancia perpendicular al plano de camara
    tile: Tile,
    side: u1, // 0 = cara este/oeste, 1 = cara norte/sur
    wall_x: f32, // posicion fraccionaria del impacto sobre la cara, en [0,1)
    map_x: i32,
    map_y: i32,
    steps: u32,
};

/// Lanza un rayo con DDA sobre la grilla y devuelve la primera celda solida.
///
/// La distancia que devuelve es la proyeccion sobre el eje de la camara, no la
/// longitud euclidiana del rayo. Esa distincion es la correccion de ojo de pez:
/// con la euclidiana las paredes rectas se ven curvadas hacia el espectador.
///
/// ======================================================================
/// EXPLICACION PASO A PASO DEL DDA (Digital Differential Analysis)
/// ======================================================================
/// El mapa es una grilla de celdas de 1x1. Un rayo sale del jugador (px, py)
/// con direccion (rdx, rdy) y hay que encontrar la PRIMERA linea de la
/// grilla (vertical u horizontal) que cruza, celda por celda, hasta topar
/// con una celda solida. La idea del DDA es: en vez de avanzar el rayo a
/// pasitos fijos (lento e impreciso), se calcula matematicamente "cuanto
/// tengo que avanzar por el rayo para cruzar la SIGUIENTE linea vertical de
/// la grilla" y "cuanto para cruzar la SIGUIENTE linea horizontal", y en
/// cada paso del bucle se toma el mas chico de los dos (el cruce mas
/// cercano). Asi el algoritmo visita exactamente las celdas por las que
/// pasa el rayo, ni una mas ni una menos.
///
///   map_x, map_y   -> en que celda de la grilla esta el rayo ahora mismo.
///   delta_x         -> cuanto AVANZA el rayo (en su propia longitud) para
///                      moverse una celda entera en el eje X.
///   delta_y         -> lo mismo mas para el eje Y.
///   side_x          -> distancia que falta recorrer para tocar la PROXIMA
///                      linea vertical de la grilla.
///   side_y          -> distancia que falta recorrer para tocar la PROXIMA
///                      linea horizontal de la grilla.
///
/// En cada vuelta del while: si side_x < side_y, la proxima linea que se
/// cruza es una vertical, asi que se avanza una celda en X y se suma
/// delta_x a side_x (ahora side_x apunta a la SIGUIENTE linea vertical).
/// Si no, se hace lo mismo mirando el eje Y. Se repite hasta pisar una
/// celda solida (pared) o agotar MAX_DDA_STEPS.
/// ======================================================================
pub fn castRay(w: *const World, px: f32, py: f32, rdx: f32, rdy: f32) Hit {
    // Celda de la grilla en la que arranca el rayo (la del propio jugador).
    var map_x = world.tileOf(px);
    var map_y = world.tileOf(py);

    // delta_x/delta_y: "por cada unidad que cruzo en X, cuanta longitud de
    // rayo gasto" (y viceversa para Y). Es 1/|rdx| porque rdx,rdy es un
    // vector de direccion (no necesariamente unitario): recorrer 1 unidad
    // completa en X toma 1/rdx unidades de "longitud de rayo". Si rdx es 0
    // el rayo nunca cruza una linea vertical, asi que se usa "infinito" para
    // que ese eje jamas gane la carrera del while de abajo.
    const delta_x: f32 = if (rdx == 0) std.math.floatMax(f32) else @abs(1.0 / rdx);
    const delta_y: f32 = if (rdy == 0) std.math.floatMax(f32) else @abs(1.0 / rdy);

    // Hacia que lado de la grilla avanza el rayo en cada eje (+1 o -1), y la
    // distancia inicial hasta la primera linea de grilla en ese sentido.
    var step_x: i32 = 1;
    var step_y: i32 = 1;
    var side_x: f32 = undefined;
    var side_y: f32 = undefined;

    if (rdx < 0) {
        step_x = -1;
        // El jugador esta a (px - map_x) de la pared izquierda de su celda;
        // multiplicado por delta_x da la distancia de rayo hasta cruzarla.
        side_x = (px - @as(f32, @floatFromInt(map_x))) * delta_x;
    } else {
        // Misma idea pero para la pared derecha de la celda.
        side_x = (@as(f32, @floatFromInt(map_x)) + 1.0 - px) * delta_x;
    }
    if (rdy < 0) {
        step_y = -1;
        side_y = (py - @as(f32, @floatFromInt(map_y))) * delta_y;
    } else {
        side_y = (@as(f32, @floatFromInt(map_y)) + 1.0 - py) * delta_y;
    }

    // side: que tipo de cara se termino golpeando. 0 = se cruzo una linea
    // VERTICAL de la grilla (cara este/oeste de la celda). 1 = se cruzo una
    // linea HORIZONTAL (cara norte/sur). Esto se usa mas abajo para sombrear
    // un lado un poco mas oscuro que el otro y dar sensacion de volumen.
    var side: u1 = 0;
    var steps: u32 = 0;
    while (steps < MAX_DDA_STEPS) : (steps += 1) {
        // Se avanza siempre por la linea de grilla mas cercana: la carrera
        // entre side_x y side_y es la esencia del algoritmo.
        if (side_x < side_y) {
            side_x += delta_x; // ahora side_x mide hasta la SIGUIENTE vertical
            map_x += step_x;
            side = 0;
        } else {
            side_y += delta_y;
            map_y += step_y;
            side = 1;
        }
        if (w.isSolid(map_x, map_y)) break; // pared encontrada, se corta el DDA
    }

    // La distancia PERPENDICULAR (no la euclidiana) es justamente side_x o
    // side_y ANTES de haber sumado el ultimo delta (por eso se resta), porque
    // ese valor mide, en unidades del eje de la camara, cuanto costo llegar
    // a la cara que se golpeo. Usar esto en vez de sqrt(dx^2+dy^2) es lo que
    // evita el efecto "ojo de pez" (ver el test que compara rayo central vs.
    // rayos de los bordes del FOV).
    const perp = if (side == 0) side_x - delta_x else side_y - delta_y;
    const dist = @max(perp, MIN_DIST); // nunca 0: evitaria dividir por cero al proyectar la pared

    // Fraccion del punto de impacto a lo largo de la cara golpeada (0..1),
    // que es exactamente la coordenada horizontal dentro de la textura.
    // Se reconstruye el punto de impacto (mundo real) avanzando `dist` a lo
    // largo del rayo, y se toma solo la parte fraccionaria de la coordenada
    // que corre a lo largo de la pared (y si side==0, x si side==1).
    var wall_x = if (side == 0) py + dist * rdy else px + dist * rdx;
    wall_x -= @floor(wall_x);

    return .{
        .dist = dist,
        .tile = w.at(map_x, map_y),
        .side = side,
        .wall_x = wall_x,
        .map_x = map_x,
        .map_y = map_y,
        .steps = steps,
    };
}

/// Atenua un color por distancia. Los pixeles emisivos se devuelven intactos:
/// una tira de neon o el plasma de una celda tienen que seguir brillando al
/// fondo de un pasillo, que es justo lo que da la lectura de nave iluminada.
fn fog(c: rl.Color, dist: f32) rl.Color {
    if (c.a == EMISSIVE) return c;
    const f = std.math.clamp(1.0 / (1.0 + dist * FOG_K), FOG_FLOOR, 1.0);
    return textures.mix(c, textures.VOID, 1.0 - f);
}

/// Dibuja piso, techo y paredes al framebuffer y deja el z-buffer listo para
/// los sprites. `center` es el horizonte movil: el mismo valor lo consumen las
/// tres pasadas, asi que el cabeceo y la vista vertical salen coherentes sin
/// duplicar codigo.
pub fn renderWorld(fb: *Framebuffer, w: *const World, p: *const Player, atlas: *const Atlas) void {
    const width_f: f32 = @floatFromInt(fb.width);
    const height_f: f32 = @floatFromInt(fb.height);
    // La fila donde cae el horizonte. Normalmente es la mitad exacta de la
    // pantalla; pitch la sube/baja cuando el jugador mira arriba/abajo, y
    // bob_offset la hace oscilar un poco al caminar (efecto de cabeceo).
    const center = height_f * 0.5 + p.pitch + p.bob_offset;

    // El piso y el techo se pintan primero, de fondo; las paredes se dibujan
    // encima y las tapan donde corresponde, columna por columna.
    renderFloorAndCeiling(fb, p, atlas, center);

    // --- Bucle principal: UN rayo por cada columna de pixeles de pantalla ---
    // Esta es la idea central de un raycaster 2.5D: no se simula un mundo 3D
    // de verdad, solo se lanza un rayo por columna, se mide que tan lejos
    // esta la pared que lo detiene, y esa distancia decide que tan alta se
    // dibuja la franja vertical de pared en esa columna. Mientras mas lejos
    // la pared, mas corta (y mas chica en pantalla) sale la franja -- igual
    // que la perspectiva real.
    var x: i32 = 0;
    while (x < fb.width) : (x += 1) {
        // camera_x recorre de -1 (borde izquierdo de pantalla) a +1 (borde
        // derecho), pasando por 0 en la columna central. Es la coordenada
        // que se usa para "abrir" el abanico de rayos con el plano de camara.
        const camera_x = 2.0 * @as(f32, @floatFromInt(x)) / width_f - 1.0;
        // El rayo de esta columna = direccion de vista + una fraccion del
        // plano de camara. En camera_x = 0 el rayo es exactamente dir_x/dir_y
        // (mirando al frente); en camera_x = -1/+1 el rayo se desvia hacia el
        // borde izquierdo/derecho del plano, que es lo que da el FOV completo.
        const rdx = p.dir_x + p.plane_x * camera_x;
        const rdy = p.dir_y + p.plane_y * camera_x;
        const hit = castRay(w, p.x, p.y, rdx, rdy);
        // Se guarda la distancia de esta columna en el z-buffer: mas tarde,
        // renderSprites la usa para saber si un sprite queda tapado por la
        // pared de esa misma columna.
        fb.depth[@intCast(x)] = hit.dist;

        // Cuanto mas cerca la pared, mas "alta" se ve: line_h es
        // inversamente proporcional a la distancia (proyeccion en
        // perspectiva clasica: altura_en_pantalla = altura_real / distancia).
        const line_h = height_f / hit.dist;
        // La franja de pared se centra verticalmente sobre `center`.
        const start_f = center - line_h * 0.5;
        // Se acota en punto flotante ANTES de convertir a entero: con el jugador
        // pegado a un muro line_h se dispara y un @intFromFloat directo se
        // saldria del rango de i32.
        const y0: i32 = @intFromFloat(std.math.clamp(@ceil(start_f), 0, height_f));
        const y1: i32 = @intFromFloat(std.math.clamp(@ceil(start_f + line_h), 0, height_f));
        if (y1 <= y0) continue; // la franja de pared no cae dentro de la pantalla

        const unlocked = switch (hit.tile) {
            .door => w.doorIsOpen(hit.map_x, hit.map_y),
            .exit => w.exit_open,
            else => false,
        };
        const wall = textures.wallFor(hit.tile, unlocked);

        // La columna X de la textura a usar es directamente hit.wall_x (0..1)
        // escalado al tamano de la textura: es la posicion exacta donde el
        // rayo toco la pared, medida a lo largo de esa cara.
        //
        // Se espeja la coordenada en las caras opuestas para que la textura no
        // salga invertida al mirar la misma pared desde el otro lado.
        var tex_x: i32 = @intFromFloat(hit.wall_x * @as(f32, @floatFromInt(TEX_SIZE)));
        if ((hit.side == 0 and rdx > 0) or (hit.side == 1 and rdy < 0)) {
            tex_x = TEX_SIZE - 1 - tex_x;
        }

        // Recorrido vertical de la franja: hay que mapear los `line_h` pixeles
        // de pantalla (que pueden ser mucho mas o mucho menos que TEX_SIZE) a
        // las TEX_SIZE filas de la textura. `step` es cuanto avanza la
        // coordenada de textura por cada pixel de pantalla que se dibuja;
        // tex_pos arranca ya adelantado a la fila que le toca al primer pixel
        // visible y0 (que puede no ser el primer pixel de la franja si esta
        // fue recortada arriba de la pantalla).
        const step = @as(f32, @floatFromInt(TEX_SIZE)) / line_h;
        var tex_pos = (@as(f32, @floatFromInt(y0)) - start_f) * step;

        var idx: usize = @intCast(y0 * fb.width + x);
        var y = y0;
        while (y < y1) : (y += 1) {
            const tex_y: i32 = @intFromFloat(tex_pos);
            tex_pos += step;
            var c = atlas.wallTexel(wall, tex_x, tex_y);
            if (c.a != EMISSIVE) {
                // Las caras norte/sur (side==1) se oscurecen un poco respecto
                // a las este/oeste: ese contraste falso es lo que hace que las
                // esquinas entre dos paredes se lean como un borde, aunque no
                // haya ninguna luz real en la escena.
                if (hit.side == 1) c = textures.shade(c, SIDE_SHADE);
                c = fog(c, hit.dist); // atenua por distancia (niebla)
            }
            fb.pixels[idx] = c;
            idx += @intCast(fb.width); // baja una fila = saltar `width` pixeles en el buffer 1D
        }
    }
}

/// Piso y techo con un raycast horizontal por fila. Se dibujan antes que las
/// paredes para que estas los tapen sin necesidad de recortar nada.
///
/// Cada fila se resuelve sola: su distancia al horizonte decide si es piso o
/// techo y a que distancia esta. Antes el techo se dibujaba espejando las filas
/// de piso, y eso dejaba la parte de arriba de la pantalla sin repintar cuando
/// el jugador miraba hacia arriba (pocas filas de piso => pocas filas de techo),
/// con lo que sobrevivian pixeles del cuadro anterior como manchas pegadas.
fn renderFloorAndCeiling(fb: *Framebuffer, p: *const Player, atlas: *const Atlas, center: f32) void {
    const width_f: f32 = @floatFromInt(fb.width);
    const height_f: f32 = @floatFromInt(fb.height);
    const tex_f: f32 = @floatFromInt(TEX_SIZE);

    // Los rayos que tocan el extremo izquierdo y derecho de la pantalla (los
    // mismos limites que usa el bucle de paredes con camera_x = -1 y +1).
    const rdx0 = p.dir_x - p.plane_x;
    const rdy0 = p.dir_y - p.plane_y;
    const rdx1 = p.dir_x + p.plane_x;
    const rdy1 = p.dir_y + p.plane_y;

    // A diferencia de las paredes (un rayo por COLUMNA), aqui se recorre
    // una fila horizontal completa a la vez: todos los pixeles de una misma
    // fila de piso/techo estan a la MISMA distancia del jugador (piensa en
    // mirar al suelo: una linea horizontal frente a ti esta toda a la misma
    // distancia). Eso permite resolver la posicion en el mundo de cada fila
    // con una sola formula, sin necesitar DDA.
    var y: i32 = 0;
    while (y < fb.height) : (y += 1) {
        const offset = @as(f32, @floatFromInt(y)) + 0.5 - center;
        const below_horizon = offset > 0;
        // La fila exacta del horizonte proyecta al infinito. Se le pone un piso
        // de medio pixel para que la distancia quede acotada: asi esa fila sale
        // del color de la niebla en vez de quedarse sin pintar.
        const p_row = @max(@abs(offset), 0.5);

        // Que tan lejos, en el mundo, esta la franja de piso/techo que cae en
        // esta fila de pantalla. Es la misma proyeccion en perspectiva que
        // line_h en renderWorld, pero despejada al reves: en vez de "conozco
        // la distancia, dame la altura en pantalla" es "conozco la fila de
        // pantalla, dame la distancia en el mundo".
        const row_dist = (0.5 * height_f) / p_row;
        // Posicion en el mundo del extremo izquierdo (fx0,fy0) de esta franja,
        // y cuanto avanza esa posicion por cada pixel hacia la derecha.
        const step_x = row_dist * (rdx1 - rdx0) / width_f;
        const step_y = row_dist * (rdy1 - rdy0) / width_f;
        var fx = p.x + row_dist * rdx0;
        var fy = p.y + row_dist * rdy0;

        const kind: textures.Wall = if (below_horizon) .floor else .ceiling;
        var idx: usize = @intCast(y * fb.width);

        var x: i32 = 0;
        while (x < fb.width) : (x += 1) {
            const tx: i32 = @intFromFloat((fx - @floor(fx)) * tex_f);
            const ty: i32 = @intFromFloat((fy - @floor(fy)) * tex_f);
            fx += step_x;
            fy += step_y;
            fb.pixels[idx] = fog(atlas.wallTexel(kind, tx, ty), row_dist);
            idx += 1;
        }
    }
}

const Visible = struct { index: usize, dist2: f32 };

fn farToNear(_: void, a: Visible, b: Visible) bool {
    return a.dist2 > b.dist2;
}

/// Dibuja los sprites como billboards despues de las paredes. Se ordenan de
/// lejos a cerca para que los cercanos queden encima, y cada columna se
/// compara contra el z-buffer: si la pared de esa columna esta mas cerca que
/// el sprite, la columna entera se salta y el sprite queda tapado.
///
/// "Billboard" = el sprite es una imagen plana (como una foto en un palito)
/// que SIEMPRE mira de frente a la camara, sin importar el angulo. No es un
/// objeto 3D real, es un rectangulo 2D que se escala y se ubica en pantalla
/// segun que tan lejos y en que direccion esta respecto al jugador.
pub fn renderSprites(fb: *Framebuffer, w: *const World, p: *const Player, atlas: *const Atlas) void {
    var list: [world.MAX_SPRITES]Visible = undefined;
    var count: usize = 0;

    var i: usize = 0;
    while (i < w.sprite_count) : (i += 1) {
        const s = w.sprites[i];
        if (!s.alive) continue;
        const dx = s.x - p.x;
        const dy = s.y - p.y;
        list[count] = .{ .index = i, .dist2 = dx * dx + dy * dy };
        count += 1;
    }
    std.mem.sort(Visible, list[0..count], {}, farToNear);

    const width_f: f32 = @floatFromInt(fb.width);
    const height_f: f32 = @floatFromInt(fb.height);
    const center = height_f * 0.5 + p.pitch + p.bob_offset;
    const spr_f: f32 = @floatFromInt(textures.SPR_SIZE);

    // Determinante inverso de la matriz [plane | dir], que lleva del mundo al
    // espacio de camara.
    //
    // Para dibujar un sprite hay que saber dos cosas en "espacio de camara":
    // que tan a la izquierda/derecha cae (tx) y que tan lejos esta en la
    // direccion en la que se mira (ty, equivalente a la `dist` de las
    // paredes). El vector (rel_x, rel_y) es la posicion del sprite relativa
    // al jugador EN COORDENADAS DEL MUNDO; para pasarlo a coordenadas de
    // camara (las mismas que usa dir/plane) hace falta invertir la matriz
    // [plane_x dir_x; plane_y dir_y]. inv_det es 1/determinante de esa
    // matriz 2x2, el factor que hace posible la inversion.
    const inv_det = 1.0 / (p.plane_x * p.dir_y - p.dir_x * p.plane_y);

    for (list[0..count]) |v| {
        const s = w.sprites[v.index];
        const rel_x = s.x - p.x;
        const rel_y = s.y - p.y;
        // tx: posicion horizontal del sprite en espacio de camara (negativo
        // = a la izquierda, positivo = a la derecha).
        // ty: "profundidad" del sprite, equivalente a la distancia perpendicular
        //     de un rayo de pared -- por eso se compara mas abajo contra fb.depth.
        const tx = inv_det * (p.dir_y * rel_x - p.dir_x * rel_y);
        const ty = inv_det * (-p.plane_y * rel_x + p.plane_x * rel_y);
        if (ty <= SPRITE_NEAR_CLIP) continue; // detras de la camara o encima del ojo

        // Mismo principio de perspectiva que las paredes: se proyecta tx/ty
        // al ancho de pantalla, y el tamano en pantalla es inversamente
        // proporcional a ty (mas lejos = mas chico).
        const screen_x = (width_f * 0.5) * (1.0 + tx / ty);
        const size = @abs(height_f / ty);
        const v_move = (s.z_offset * height_f) / ty;
        const top = center - size * 0.5 - v_move;
        const left = screen_x - size * 0.5;

        const x0: i32 = @intFromFloat(std.math.clamp(@ceil(left), 0, width_f));
        const x1: i32 = @intFromFloat(std.math.clamp(@ceil(left + size), 0, width_f));
        const y0: i32 = @intFromFloat(std.math.clamp(@ceil(top), 0, height_f));
        const y1: i32 = @intFromFloat(std.math.clamp(@ceil(top + size), 0, height_f));
        if (x1 <= x0 or y1 <= y0) continue;

        const frame = s.frame();
        var x = x0;
        while (x < x1) : (x += 1) {
            if (ty >= fb.depth[@intCast(x)]) continue; // tapado por una pared
            const tex_x: i32 = @intFromFloat((@as(f32, @floatFromInt(x)) - left) / size * spr_f);
            var y = y0;
            while (y < y1) : (y += 1) {
                const tex_y: i32 = @intFromFloat((@as(f32, @floatFromInt(y)) - top) / size * spr_f);
                const c = atlas.spriteTexel(s.kind, frame, tex_x, tex_y);
                if (c.a == 0) continue;
                const idx: usize = @intCast(y * fb.width + x);
                if (c.a == EMISSIVE) {
                    fb.pixels[idx] = c;
                } else if (c.a == 255) {
                    fb.pixels[idx] = fog(c, ty);
                } else {
                    // alpha real: es lo que da el halo suave de la celda
                    const a = @as(f32, @floatFromInt(c.a)) / 255.0;
                    fb.pixels[idx] = textures.mix(fb.pixels[idx], fog(c, ty), a);
                }
            }
        }
    }
}

const testing = std.testing;

/// Un cuarto grande y vacio: hace falta que sea alto para que hasta los rayos
/// de los bordes del FOV peguen contra la pared del fondo y no contra el techo.
const ROOM = [_][]const u8{
    "##########",
    "#........#",
    "#........#",
    "#........#",
    "#........#",
    "#........#",
    "#........#",
    "#........#",
    "#........#",
    "#........#",
    "#........#",
    "#........#",
    "#........#",
    "#........#",
    "##########",
};

test "un rayo recto hacia una pared devuelve la distancia perpendicular exacta" {
    const w = World.fromRows(&ROOM, 0);
    const hit = castRay(&w, 1.5, 7.5, 1, 0);
    try testing.expectApproxEqAbs(@as(f32, 7.5), hit.dist, 1e-4);
    try testing.expectEqual(Tile.panel, hit.tile);
    try testing.expectEqual(@as(u1, 0), hit.side);
}

test "la distancia perpendicular corrige el ojo de pez" {
    const w = World.fromRows(&ROOM, 0);
    var p = Player.spawn(&w);
    p.x = 1.5;
    p.y = 7.5;
    p.setAngle(0);

    // Los rayos extremos del FOV contra una pared plana de frente tienen que
    // dar la MISMA distancia perpendicular, aunque sus longitudes euclidianas
    // sean muy distintas. Esa igualdad es literalmente la definicion de no
    // tener ojo de pez.
    const center = castRay(&w, p.x, p.y, p.dir_x, p.dir_y);
    const left = castRay(&w, p.x, p.y, p.dir_x - p.plane_x, p.dir_y - p.plane_y);
    const right = castRay(&w, p.x, p.y, p.dir_x + p.plane_x, p.dir_y + p.plane_y);

    try testing.expectApproxEqAbs(center.dist, left.dist, 1e-4);
    try testing.expectApproxEqAbs(center.dist, right.dist, 1e-4);

    // ...y la euclidiana si tiene que diferir, si no la prueba seria trivial.
    const euclid_left = left.dist * @sqrt(1.0 + Player.FOV_TAN * Player.FOV_TAN);
    try testing.expect(euclid_left > center.dist + 0.5);
}

test "la coordenada de textura cae dentro de la cara golpeada" {
    const w = World.fromRows(&ROOM, 0);
    var a: f32 = 0;
    while (a < std.math.tau) : (a += 0.031) {
        const hit = castRay(&w, 4.5, 7.5, @cos(a), @sin(a));
        try testing.expect(hit.wall_x >= 0 and hit.wall_x < 1.0);
        try testing.expect(hit.dist > 0);
    }
}

test "el DDA siempre termina dentro del limite de pasos" {
    for (0..3) |lvl| {
        const w = World.load(lvl);
        var a: f32 = 0;
        while (a < std.math.tau) : (a += 0.017) {
            const hit = castRay(&w, w.spawn_x, w.spawn_y, @cos(a), @sin(a));
            try testing.expect(hit.steps < MAX_DDA_STEPS);
            try testing.expect(w.isSolid(hit.map_x, hit.map_y));
        }
    }
}

test "escribir fuera del framebuffer no hace nada" {
    var fb = try Framebuffer.init(testing.allocator, 16, 9);
    defer testing.allocator.free(fb.pixels);
    defer testing.allocator.free(fb.depth);
    fb.put(-1, 0, textures.NEON_CYAN);
    fb.put(0, -1, textures.NEON_CYAN);
    fb.put(16, 0, textures.NEON_CYAN);
    fb.put(0, 9, textures.NEON_CYAN);
    for (fb.pixels) |c| try testing.expectEqual(textures.VOID, c);
}

test "renderizar desde cualquier angulo y cualquier pitch nunca se sale del buffer" {
    const atlas = try textures.Atlas.init(testing.allocator);
    defer testing.allocator.free(atlas.walls);
    defer testing.allocator.free(atlas.sprites);
    var fb = try Framebuffer.init(testing.allocator, 64, 36);
    defer testing.allocator.free(fb.pixels);
    defer testing.allocator.free(fb.depth);

    for (0..3) |lvl| {
        const w = World.load(lvl);
        var p = Player.spawn(&w);
        var a: f32 = 0;
        while (a < std.math.tau) : (a += 0.2) {
            p.setAngle(a);
            for ([_]f32{ -player.PITCH_LIMIT, 0, player.PITCH_LIMIT }) |pitch| {
                p.pitch = pitch;
                renderWorld(&fb, &w, &p, &atlas);
                renderSprites(&fb, &w, &p, &atlas);
            }
        }
    }
}

test "una pared tapa un sprite que esta detras de ella" {
    const atlas = try textures.Atlas.init(testing.allocator);
    defer testing.allocator.free(atlas.walls);
    defer testing.allocator.free(atlas.sprites);
    var fb = try Framebuffer.init(testing.allocator, 64, 36);
    defer testing.allocator.free(fb.pixels);
    defer testing.allocator.free(fb.depth);

    // Celda de energia justo del otro lado de la pared del fondo.
    var w = World.fromRows(&ROOM, 0);
    w.sprite_count = 1;
    w.sprites[0] = .{ .x = 9.5, .y = 7.5, .kind = .core };

    var p = Player.spawn(&w);
    p.x = 1.5;
    p.y = 7.5;
    p.setAngle(0);

    renderWorld(&fb, &w, &p, &atlas);
    const before = fb.pixels[@intCast(18 * fb.width + 32)];
    renderSprites(&fb, &w, &p, &atlas);
    try testing.expectEqual(before, fb.pixels[@intCast(18 * fb.width + 32)]);

    // Sin la pared de por medio, el mismo sprite si tiene que pintarse.
    w.sprites[0] = .{ .x = 5.5, .y = 7.5, .kind = .core };
    renderWorld(&fb, &w, &p, &atlas);
    const wall_only = fb.pixels[@intCast(18 * fb.width + 32)];
    renderSprites(&fb, &w, &p, &atlas);
    try testing.expect(!std.meta.eql(wall_only, fb.pixels[@intCast(18 * fb.width + 32)]));
}

test "el frame se repinta completo con cualquier pitch" {
    const atlas = try textures.Atlas.init(testing.allocator);
    defer testing.allocator.free(atlas.walls);
    defer testing.allocator.free(atlas.sprites);
    var fb = try Framebuffer.init(testing.allocator, 96, 54);
    defer testing.allocator.free(fb.pixels);
    defer testing.allocator.free(fb.depth);

    // Si un pixel del cuadro anterior sobrevive al render, se ve como una
    // mancha pegada en pantalla. Se marca todo con un color imposible y se
    // exige que no quede ni uno solo.
    const STALE = rl.Color.init(255, 0, 255, 7);

    const w = World.load(0);
    var p = Player.spawn(&w);
    var a: f32 = 0;
    while (a < std.math.tau) : (a += 0.35) {
        p.setAngle(a);
        for ([_]f32{ -player.PITCH_LIMIT, -40, 0, 40, player.PITCH_LIMIT }) |pitch| {
            p.pitch = pitch;
            @memset(fb.pixels, STALE);
            renderWorld(&fb, &w, &p, &atlas);
            for (fb.pixels, 0..) |c, i| {
                if (std.meta.eql(c, STALE)) {
                    std.debug.print("pixel sin pintar en fila {d} con pitch {d}\n", .{ i / @as(usize, @intCast(fb.width)), pitch });
                    return error.FrameIncompleto;
                }
            }
        }
    }
}

test "un sprite encima de la camara no se dibuja" {
    const atlas = try textures.Atlas.init(testing.allocator);
    defer testing.allocator.free(atlas.walls);
    defer testing.allocator.free(atlas.sprites);
    var fb = try Framebuffer.init(testing.allocator, 64, 36);
    defer testing.allocator.free(fb.pixels);
    defer testing.allocator.free(fb.depth);

    var w = World.fromRows(&ROOM, 0);
    var p = Player.spawn(&w);
    p.x = 4.5;
    p.y = 7.5;
    p.setAngle(0);

    // Sin sprites: la referencia.
    w.sprite_count = 0;
    renderWorld(&fb, &w, &p, &atlas);
    renderSprites(&fb, &w, &p, &atlas);
    const reference = try testing.allocator.dupe(rl.Color, fb.pixels);
    defer testing.allocator.free(reference);

    // Un sprite practicamente pegado al ojo: magnificado llenaria la pantalla
    // de bloques, asi que tiene que quedar recortado por el plano cercano.
    w.sprite_count = 1;
    w.sprites[0] = .{ .x = 4.7, .y = 7.5, .kind = .core, .z_offset = 0.28 };
    renderWorld(&fb, &w, &p, &atlas);
    renderSprites(&fb, &w, &p, &atlas);
    for (reference, fb.pixels) |a, b| try testing.expect(std.meta.eql(a, b));

    // Pero a una distancia normal si tiene que verse.
    w.sprites[0] = .{ .x = 6.5, .y = 7.5, .kind = .core, .z_offset = 0.28 };
    renderWorld(&fb, &w, &p, &atlas);
    renderSprites(&fb, &w, &p, &atlas);
    var changed: u32 = 0;
    for (reference, fb.pixels) |a, b| {
        if (!std.meta.eql(a, b)) changed += 1;
    }
    try testing.expect(changed > 0);
}
