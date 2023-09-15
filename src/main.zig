const std = @import("std");
const ztg = @import("zentig");
const zrl = @import("zrl");
const rl = zrl.rl;

//------------------------------------------------------------------------------------
// Program main entry point
//------------------------------------------------------------------------------------
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var world = try World.init(alloc);
    defer world.deinit(); // Unload loaded data (textures, sounds, models...)

    // Initialization
    //---------------------------------------------------------
    rl.InitWindow(screen_width, screen_height, "classic game: arkanoid");
    defer rl.CloseWindow(); // Close window and OpenGL context

    rl.InitAudioDevice();
    rl.SetTargetFPS(300);

    try world.runStage(.load);
    //---------------------------------------------------------

    // Main game loop
    while (!rl.WindowShouldClose()) // Detect window close button or ESC key
    {
        // Update and Draw
        try world.runStage(.pre_update);
        switch (world.getRes(Game).state) {
            .playing => try world.runStage(.update),
            .paused => try world.runStage(.update_paused),
            .game_over => try world.runStage(.update_gameover),
        }
        try world.runStage(.post_update);

        rl.BeginDrawing();
        rl.ClearBackground(rl.GRAY);
        try world.runStage(.draw);
        rl.EndDrawing();

        world.cleanForNextFrame();
    }
}

//------------------------------------------------------------------------------------
// Data Types
//------------------------------------------------------------------------------------

const Active = struct { bool };

const Player = struct {
    const speed = 300.0;
    const y_pos = screen_height * 7 / 8;
};

const Ball = struct {
    dir: ztg.Vec2,
    radius: i32,

    var sprite_size = ztg.Vec2.zero();

    const speed = 300.0;
    const start_y_pos = Player.y_pos - 30;
    const max_angle = std.math.degreesToRadians(f32, 80);
};

const Brick = struct {
    var size = ztg.Vec2.zero();

    const lines_of_bricks = 5;
    const bricks_per_line = 20;
    const initial_down_position = 50;
};

const screen_width = 800;
const screen_height = 450;

const Game = struct {
    const max_life = 5;

    lives: i32 = max_life,
    state: State = .playing,
    setup: bool = false,

    hit_sfx: rl.Sound = undefined,

    const State = enum {
        playing,
        paused,
        game_over,
    };
};

const World = ztg.WorldBuilder.init(&.{
    ztg.base,
    zrl,
    Input,
    @This(),
}).Build();

const Input = ztg.input.Build(
    zrl.InputWrapper,
    &.{ .pause, .start, .launch_ball },
    &.{.horiz},
    .{ .max_controllers = 1 },
);

//------------------------------------------------------------------------------------
// Systems
//------------------------------------------------------------------------------------

pub fn include(comptime wb: *ztg.WorldBuilder) void {
    wb.addResource(Game, .{});

    wb.addStage(.update_gameover);
    wb.addStage(.update_paused);

    wb.addLabel(.update, .update_collisions, .default);
    wb.addSystems(.{
        .load = load,
        .update_paused = update_paused,
        .update_gameover = update_gameover,
        .update = .{
            update_paused,
            ztg.orderGroup(.update_collisions, .{
                .before = .{ update_ball, update_player },
                .during = ball_collisions,
                .after = check_gameover,
            }),
        },
        .draw = draw,
    });

    wb.addComponents(&.{ Player, Ball, Brick, Active });
}

// Initialize game variables
fn load(
    com: ztg.Commands,
    ents: ztg.QueryOpts(.{ztg.Entity}, .{ztg.Without(rl.Camera2D)}),
    input: *Input,
    game: *Game,
    assets: *zrl.Assets,
) !void {
    if (!game.setup) {
        game.setup = true;
        game.hit_sfx = try assets.sound("resources/hit.wav");

        _ = try com.newEntWith(zrl.Camera2dBundle.init());

        // setup controls
        try input.addBindings(0, .{
            .buttons = .{
                .pause = &.{zrl.kbButton(rl.KEY_P)},
                .start = &.{zrl.kbButton(rl.KEY_ENTER)},
                .launch_ball = &.{zrl.kbButton(rl.KEY_SPACE)},
            },
            .axes = .{
                .horiz = &.{zrl.kbAxis(rl.KEY_D, rl.KEY_A)},
            },
        });

        const ball_spr = try assets.texture("resources/ball.png");
        Ball.sprite_size.set(ball_spr.width, ball_spr.height);

        if (Brick.bricks_per_line != 0) {
            Brick.size.set(ztg.math.divf32(rl.GetScreenWidth(), Brick.bricks_per_line) catch unreachable, 40);
        }
    }

    game.state = .playing;
    game.lives = Game.max_life;

    for (ents.items(0)) |ent| try com.removeEnt(ent);

    // Initialize player
    _ = try com.newEntWith(.{
        Player{},
        ztg.base.Transform.initWith(.{
            .pos = ztg.vec3(screen_width / 2, Player.y_pos, 0),
            .scale = ztg.vec3(screen_width / 10, 20, 0),
        }),
    });

    // Initialize ball
    try spawnBall(com, assets, ztg.vec3(screen_width / 2, Ball.start_y_pos, 0), ztg.Vec2.zero(), false);

    // Initialize bricks
    for (0..Brick.lines_of_bricks) |_i| {
        for (0..Brick.bricks_per_line) |_j| {
            const i: f32 = @floatFromInt(_i);
            const j: f32 = @floatFromInt(_j);

            _ = try zrl.util.newCenteredEnt(com, .{
                Brick{},
                Active{true},
                zrl.Sprite.Bundle.initAssert(com, "resources/brick.png", .{
                    .pos = ztg.vec3(j * Brick.size.x + Brick.size.x / 2.0, i * Brick.size.y + Brick.initial_down_position, 0),
                    .scale = ztg.vec3(Brick.size.x / 100, Brick.size.y / 100, 1),
                }),
            });
        }
    }
}

fn spawnBall(com: ztg.Commands, assets: *zrl.Assets, pos: ztg.Vec3, dir: ztg.Vec2, active: bool) !void {
    const radius = 12.0;

    _ = try zrl.util.newCenteredEnt(com, .{
        Ball{ .dir = dir, .radius = radius },
        Active{active},
        zrl.Sprite.Bundle.initAssert(com, "resources/ball.png", .{
            .pos = pos,
            .scale = ztg.Vec3.splat(try ztg.math.divf32(radius * 2, (try assets.texture("resources/ball.png")).width)),
            .color = rl.WHITE,
        }),
    });
}

fn update_paused(input: Input, game: *Game) void {
    if (input.isPressed(0, .pause)) game.state = switch (game.state) {
        .paused => .playing,
        .playing => .paused,
        else => |s| s,
    };
}

fn update_gameover(com: ztg.Commands, input: Input) !void {
    if (input.isPressed(0, .start)) {
        try com.runStage(.load);
    }
}

fn update_player(q: ztg.QueryOpts(.{ztg.base.Transform}, .{ztg.With(Player)}), input: Input, time: ztg.base.Time) !void {
    // Player movement logic
    var horiz = input.getAxis(0, .horiz);

    for (q.items(0)) |tr| {
        tr.translate(.{ .x = horiz * Player.speed * time.dt });

        var pos = tr.getPos();
        if ((pos.x - tr.getScale().x / 2) <= 0) pos.x = tr.getScale().x / 2;
        if ((pos.x + tr.getScale().x / 2) >= screen_width) pos.x = screen_width - tr.getScale().x / 2;
        tr.setPos(pos);
    }
}

fn update_ball(
    q: ztg.Query(.{ Ball, Active, ztg.base.Transform }),
    player_q: ztg.QueryOpts(.{ztg.base.Transform}, .{ztg.With(Player)}),
    input: Input,
    time: ztg.base.Time,
) void {
    const player_tr = player_q.single(0);

    for (q.items(0), q.items(1), q.items(2)) |ball, active, tr| {
        // Ball launching logic
        if (!active[0] and input.isPressed(0, .launch_ball)) {
            active[0] = true;
            ball.dir.set(0, -1);
        }

        // Ball movement logic
        if (active[0]) {
            tr.translate(ball.dir.mul(Ball.speed * time.dt).extend(0));
        } else {
            tr.setPos(ztg.vec3(player_tr.getPos().x, Ball.start_y_pos, 0));
        }
    }
}

fn ball_collisions(
    game: Game,
    com: ztg.Commands,
    time: ztg.base.Time,
    ball_q: ztg.Query(.{ ztg.Entity, Ball, ztg.base.Transform }),
    player_q: ztg.Query(.{ ztg.base.Transform, Player }),
    brick_q: ztg.QueryOpts(.{ ztg.Entity, ztg.base.Transform, Active }, .{ztg.With(Brick)}),
) !void {
    const player_tr = player_q.single(0);
    const player_pos = player_tr.getPos();
    const player_size = player_tr.getScale();

    for (ball_q.items(0), ball_q.items(1), ball_q.items(2)) |ball_ent, ball, ball_tr| {
        const radius_f: f32 = @floatFromInt(ball.radius);
        const ball_pos = ball_tr.getPos();

        var hit = false;

        // Collision logic: ball vs walls
        if ((ball.dir.x > 0 and ball_pos.x + radius_f >= screen_width) or (ball.dir.x < 0 and ball_pos.x - radius_f <= 0)) {
            ball.dir.x *= -1;
            hit = true;
        }
        if (ball.dir.y < 0 and ball_pos.y - radius_f <= 0) {
            ball.dir.y *= -1;
            hit = true;
        }
        if (ball.dir.y > 0 and ball_pos.y + radius_f >= screen_height) {
            try com.removeEnt(ball_ent);
        }

        // Collision logic: ball vs player
        if (ball.dir.y > 0 and rl.CheckCollisionCircleRec(
            ball_pos.intoVec2(rl.Vector2),
            radius_f,
            rl.rectangle(player_pos.x - player_size.x / 2, player_pos.y - player_size.y / 2, player_size.x, player_size.y),
        )) {
            ball.dir.y *= -1;

            const range = comptime std.math.pi / 6.0;

            // 0-1 depending on if the ball hit the left or right of the paddle
            const hit_t = (ball_pos.x - (player_pos.x - player_size.x / 2)) / player_size.x;

            const desired = ball.dir.getRotated(std.math.lerp(-range, range, ztg.math.clamp01(hit_t)));

            // only rotate if the desired direction is within the angle constraint
            // (so you cant make the ball have a perfect left-right bounce just by hitting it on one side repeatedly)
            if (@fabs(desired.angleSigned(ztg.Vec2.down())) < Ball.max_angle) {
                ball.dir = desired;
            }

            hit = true;
        }

        const ball_move_delta = ball.dir.mul(Ball.speed * time.dt);

        for (brick_q.items(0), brick_q.items(1), brick_q.items(2)) |brick_ent, brick_tr, brick_active| {
            const brick_pos = brick_tr.getPos();
            var hit_brick = false;

            if (brick_active[0]) {
                // Hit below
                if (ball_pos.y - radius_f <= brick_pos.y + Brick.size.y / 2.0 and
                    ball_pos.y - radius_f > brick_pos.y + Brick.size.y / 2.0 + ball_move_delta.y and
                    @fabs(ball_pos.x - brick_pos.x) < Brick.size.x / 2.0 + radius_f * 2.0 / 3.0 and
                    ball_move_delta.y < 0)
                {
                    ball.dir.y *= -1;
                    hit_brick = true;
                }
                // Hit above
                else if (ball_pos.y + radius_f >= brick_pos.y - Brick.size.y / 2.0 and
                    ball_pos.y + radius_f < brick_pos.y - Brick.size.y / 2.0 + ball_move_delta.y and
                    @fabs(ball_pos.x - brick_pos.x) < Brick.size.x / 2.0 + radius_f * 2.0 / 3.0 and
                    ball_move_delta.y > 0)
                {
                    ball.dir.y *= -1;
                    hit_brick = true;
                }
                // Hit left
                else if (ball_pos.x + radius_f >= brick_pos.x - Brick.size.x / 2.0 and
                    ball_pos.x + radius_f < brick_pos.x - Brick.size.x / 2.0 + ball_move_delta.x and
                    @fabs(ball_pos.y - brick_pos.y) < Brick.size.y / 2.0 + radius_f * 2.0 / 3.0 and
                    ball_move_delta.x > 0)
                {
                    ball.dir.x *= -1;
                    hit_brick = true;
                }
                // Hit right
                else if (ball_pos.x - radius_f <= brick_pos.x + Brick.size.x / 2.0 and
                    ball_pos.x - radius_f > brick_pos.x + Brick.size.x / 2.0 + ball_move_delta.x and
                    @fabs(ball_pos.y - brick_pos.y) < Brick.size.y / 2.0 + radius_f * 2.0 / 3.0 and
                    ball_move_delta.x < 0)
                {
                    ball.dir.x *= -1;
                    hit_brick = true;
                }
            }

            hit = hit or hit_brick;

            if (hit_brick) {
                brick_active[0] = false;
                try com.removeEnt(brick_ent);
                break;
            }
        }

        if (hit) {
            rl.PlaySound(game.hit_sfx);
        }
    }
}

fn check_gameover(com: ztg.Commands, assets: *zrl.Assets, game: *Game, balls: ztg.Query(.{ Ball, ztg.Entity }), bricks: ztg.QueryOpts(.{Active}, .{ztg.With(Brick)})) !void {
    if (balls.len == 0) {
        if (game.lives <= 0) game.state = .game_over else try spawnBall(com, assets, ztg.Vec3.zero(), ztg.Vec2.zero(), false);
        game.lives -= 1;
    }

    for (bricks.items(0)) |brick_active| {
        if (brick_active[0]) break;
    } else {
        game.state = .game_over;
        for (balls.items(1)) |ball_ent| try com.removeEnt(ball_ent);
    }
}

// Draw game (one frame)
fn draw(
    game: Game,
    player_q: ztg.QueryOpts(.{ztg.base.Transform}, .{ztg.With(Player)}),
) void {
    if (game.state != .game_over) {
        // Draw player bar
        for (player_q.items(0)) |player_tr| {
            const pos = player_tr.getPos();
            const size = player_tr.getScale();
            rl.DrawRectangle(@intFromFloat(pos.x - size.x / 2), @intFromFloat(pos.y - size.y / 2), @intFromFloat(size.x), @intFromFloat(size.y), rl.BLACK);
        }

        // Draw player lives
        for (0..@intCast(game.lives)) |i| rl.DrawRectangle(@intCast(20 + 40 * i), screen_height - 30, 35, 10, rl.LIGHTGRAY);

        if (game.state == .paused) rl.DrawText("GAME PAUSED", screen_width / 2 - @divFloor(rl.MeasureText("GAME PAUSED", 40), 2), screen_height / 2 - 40, 40, rl.GRAY);
    } else rl.DrawText("PRESS [ENTER] TO PLAY AGAIN", @divFloor(rl.GetScreenWidth(), 2) - @divFloor(rl.MeasureText("PRESS [ENTER] TO PLAY AGAIN", 20), 2), @divFloor(rl.GetScreenHeight(), 2) - 50, 20, rl.BLACK);
}
