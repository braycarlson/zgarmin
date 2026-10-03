const std = @import("std");

const core = @import("zgarmin");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Command = enum {
    consumer,
    login,
    activities,
    activity,
    download,
    download_all,
    raw,
    summary,
    sleep,
    steps,
    heart_rate,
    hrv,
    stress,
    spo2,
    respiration,
    intensity,
    weight,
    profile,
    settings,
    devices,
    badges,
    goals,
};

const ConsumerKeys = struct {
    key: []const u8,
    secret: []const u8,
};

const StdinMfa = struct {
    io: std.Io,
    out: *std.Io.Writer,

    fn provider(mfa: *StdinMfa) core.MfaProvider {
        return .{ .context = mfa, .get_code = get_code };
    }

    fn get_code(context: ?*anyopaque, buffer: []u8) anyerror![]const u8 {
        const mfa: *StdinMfa = @ptrCast(@alignCast(context.?));

        try mfa.out.writeAll("MFA code: ");
        try mfa.out.flush();

        var stdin_buffer: [256]u8 = undefined;
        var reader = std.Io.File.stdin().reader(mfa.io, &stdin_buffer);

        const line = try reader.interface.takeDelimiterExclusive('\n');
        const code = std.mem.trim(u8, line, " \r\n\t");

        if (code.len > buffer.len) return error.MfaCodeTooLong;

        @memcpy(buffer[0..code.len], code);

        return buffer[0..code.len];
    }
};

const DownloadOutcome = union(enum) {
    downloaded: u64,
    skipped,
    failed,
};

const ActivityEntry = struct {
    activityId: i64,
};

const activities_start_default: u32 = 0;
const activities_limit_default: u32 = 20;
const download_all_delay_ms: i64 = 350;
const download_all_pages_max: u32 = 100_000;
const tokens_directory_name: []const u8 = ".zgarmin";
const tokens_file_name: []const u8 = "tokens.json";

const command_map = std.StaticStringMap(Command).initComptime(.{
    .{ "activities", .activities },
    .{ "activity", .activity },
    .{ "badges", .badges },
    .{ "consumer", .consumer },
    .{ "devices", .devices },
    .{ "download", .download },
    .{ "download-all", .download_all },
    .{ "goals", .goals },
    .{ "hr", .heart_rate },
    .{ "hrv", .hrv },
    .{ "intensity", .intensity },
    .{ "login", .login },
    .{ "profile", .profile },
    .{ "raw", .raw },
    .{ "respiration", .respiration },
    .{ "settings", .settings },
    .{ "sleep", .sleep },
    .{ "spo2", .spo2 },
    .{ "steps", .steps },
    .{ "stress", .stress },
    .{ "summary", .summary },
    .{ "weight", .weight },
});

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_writer.interface;
    defer out.flush() catch |err| switch (err) {
        else => {},
    };

    try run(init, out);
}

fn run(init: std.process.Init, out: *std.Io.Writer) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len <= 1) {
        try usage(out);
        return;
    }

    const command = parse_command(args[1]) orelse {
        try usage(out);
        return;
    };

    if (command == .consumer) {
        try run_consumer(init, out);
        return;
    }

    const gpa = if (command == .download_all) init.gpa else init.arena.allocator();

    var session = try core.Session.init(gpa, init.io);
    defer session.deinit();

    try authenticate(init, out, &session);

    switch (command) {
        .consumer => unreachable,
        .login => try print_tokens(out, &session),
        .activities => try cmd_activities(out, &session, args),
        .activity => try cmd_activity(out, &session, args),
        .download => try cmd_download(init, out, &session, args),
        .download_all => try cmd_download_all(init, out, &session, args),
        .raw => try cmd_raw(out, &session, args),
        .summary => try emit_user_date(out, &session, args, core.wellness.daily_summary),
        .sleep => try emit_user_date(out, &session, args, core.wellness.sleep),
        .steps => try emit_user_date(out, &session, args, core.wellness.steps),
        .heart_rate => try emit_user_date(out, &session, args, core.wellness.heart_rate),
        .hrv => try emit_date(out, &session, args, core.wellness.hrv),
        .stress => try emit_date(out, &session, args, core.wellness.stress),
        .spo2 => try emit_date(out, &session, args, core.wellness.spo2),
        .respiration => try emit_date(out, &session, args, core.wellness.respiration),
        .intensity => try emit_date(out, &session, args, core.wellness.intensity_minutes),
        .weight => try cmd_weight(out, &session, args),
        .profile => try emit_simple(out, &session, core.account.social_profile),
        .settings => try emit_simple(out, &session, core.account.user_settings),
        .devices => try emit_simple(out, &session, core.devices.list),
        .badges => try emit_simple(out, &session, core.badges.earned),
        .goals => try emit_simple(out, &session, core.goals.list),
    }

    persist_if_refreshed(init, out, &session);
}

fn run_consumer(init: std.process.Init, out: *std.Io.Writer) !void {
    var env = try core.env.load(init.gpa, init.io, core.env.path_default);
    defer env.deinit();

    const keys = consumer_keys(init, &env);

    try out.print("consumer_key:    {s}\n", .{keys.key});
    try out.print("consumer_secret: {s}\n", .{keys.secret});
}

fn authenticate(init: std.process.Init, out: *std.Io.Writer, session: *core.Session) !void {
    const path: ?[]u8 = tokens_path(init) catch null;

    if (path) |value| {
        if (try_restore(init, out, session, value)) return;
    }

    var env = try core.env.load(init.gpa, init.io, core.env.path_default);
    defer env.deinit();

    const email = env.lookup(init.environ_map, "GARMIN_EMAIL") orelse
        return error.MissingGarminEmail;
    const password = env.lookup(init.environ_map, "GARMIN_PASSWORD") orelse
        return error.MissingGarminPassword;

    const keys = consumer_keys(init, &env);

    var mfa = StdinMfa{ .io = init.io, .out = out };

    session.login(&.{
        .credentials = &.{ .email = email, .password = password },
        .mfa = mfa.provider(),
        .consumer_key = keys.key,
        .consumer_secret = keys.secret,
    }) catch |err| {
        try out.print("login failed (HTTP {d}): {s}\n", .{
            session.client.last_status,
            @errorName(err),
        });

        return err;
    };

    if (path) |value| save_tokens(out, session, value);
}

fn try_restore(
    init: std.process.Init,
    out: *std.Io.Writer,
    session: *core.Session,
    path: []const u8,
) bool {
    const directory = std.Io.Dir.cwd();
    const gpa = session.gpa;

    const loaded_or_null = core.tokens.load(gpa, init.io, directory, path) catch |err| {
        out.print(
            "token cache unreadable ({s}); logging in\n",
            .{@errorName(err)},
        ) catch return false;

        return false;
    };

    var loaded = loaded_or_null orelse return false;

    session.restore(loaded) catch |err| {
        loaded.deinit();

        out.print(
            "token refresh failed ({s}); logging in\n",
            .{@errorName(err)},
        ) catch return false;

        return false;
    };

    if (session.connect().token_refreshed) save_tokens(out, session, path);

    return true;
}

fn persist_if_refreshed(init: std.process.Init, out: *std.Io.Writer, session: *core.Session) void {
    if (session.api == null) return;
    if (!session.connect().token_refreshed) return;

    const path = tokens_path(init) catch return;

    save_tokens(out, session, path);
}

fn save_tokens(out: *std.Io.Writer, session: *core.Session, path: []const u8) void {
    const directory = std.Io.Dir.path.dirname(path) orelse ".";

    std.Io.Dir.cwd().createDirPath(session.io, directory) catch |err| {
        out.print("warning: token save failed ({s})\n", .{@errorName(err)}) catch return;

        return;
    };

    session.persist(std.Io.Dir.cwd(), path) catch |err| {
        out.print("warning: token save failed ({s})\n", .{@errorName(err)}) catch return;
    };
}

fn tokens_path(init: std.process.Init) ![]u8 {
    const home = init.environ_map.get("USERPROFILE") orelse
        init.environ_map.get("HOME") orelse
        return error.HomeDirectoryUnknown;

    return init.arena.allocator().print("{s}/{s}/{s}", .{
        home,
        tokens_directory_name,
        tokens_file_name,
    });
}

fn consumer_keys(init: std.process.Init, env: *const core.env.Env) ConsumerKeys {
    const key = env.lookup(init.environ_map, core.consumer.key_variable) orelse
        core.consumer.key_default;
    const secret = env.lookup(init.environ_map, core.consumer.secret_variable) orelse
        core.consumer.secret_default;

    assert(key.len != 0);
    assert(secret.len != 0);

    return .{ .key = key, .secret = secret };
}

fn print_tokens(out: *std.Io.Writer, session: *core.Session) !void {
    const token = &session.connect().token_oauth2;

    try out.print("display_name:  {s}\n", .{session.display_name()});
    try out.print("access_token:  {s}\n", .{token.access_token});
    try out.print("refresh_token: {s}\n", .{token.refresh_token});
    try out.print("expires_at:    {d}\n", .{token.expires_at()});
    try out.print("refresh_until: {d}\n", .{token.refresh_expires_at()});
}

fn cmd_activities(out: *std.Io.Writer, session: *core.Session, args: []const [:0]const u8) !void {
    const start = if (args.len > 2)
        try std.fmt.parseInt(u32, args[2], 10)
    else
        activities_start_default;

    const limit = if (args.len > 3)
        try std.fmt.parseInt(u32, args[3], 10)
    else
        activities_limit_default;

    if (limit == 0 or limit > core.activities.page_max) {
        return error.ActivitiesLimitInvalid;
    }

    var response = try core.activities.list(session.connect(), start, limit);
    defer response.deinit();

    try emit(out, &response);
}

fn cmd_activity(out: *std.Io.Writer, session: *core.Session, args: []const [:0]const u8) !void {
    if (args.len < 3) return error.ActivityUsage;

    var response = try core.activities.by_id(session.connect(), args[2]);
    defer response.deinit();

    try emit(out, &response);
}

fn cmd_weight(out: *std.Io.Writer, session: *core.Session, args: []const [:0]const u8) !void {
    if (args.len < 4) return error.WeightUsage;

    var response = try core.body.body_composition(session.connect(), args[2], args[3]);
    defer response.deinit();

    try emit(out, &response);
}

fn cmd_download(
    init: std.process.Init,
    out: *std.Io.Writer,
    session: *core.Session,
    args: []const [:0]const u8,
) !void {
    if (args.len < 4) return error.DownloadUsage;

    var response = try core.activities.download(session.connect(), args[2]);
    defer response.deinit();

    if (response.status != 200) {
        try out.print("download failed: HTTP {d}\n", .{response.status});

        return error.DownloadRequestFailed;
    }

    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[3], .data = response.body });

    try out.print("wrote {d} bytes to {s}\n", .{ response.body.len, args[3] });
}

fn cmd_raw(out: *std.Io.Writer, session: *core.Session, args: []const [:0]const u8) !void {
    if (args.len < 3) return error.RawUsage;

    var response = try session.connect().get(args[2], null);
    defer response.deinit();

    try out.print("status {d}\n{s}\n", .{ response.status, response.body });
}

fn cmd_download_all(
    init: std.process.Init,
    out: *std.Io.Writer,
    session: *core.Session,
    args: []const [:0]const u8,
) !void {
    if (args.len < 3) return error.DownloadAllUsage;

    const directory = args[2];

    const limit: u32 = if (args.len > 3)
        try std.fmt.parseInt(u32, args[3], 10)
    else
        core.activities.page_max;

    if (limit == 0 or limit > core.activities.page_max) {
        return error.DownloadAllLimitInvalid;
    }

    try std.Io.Dir.cwd().createDirPath(init.io, directory);

    const gpa = session.gpa;
    const delay = std.Io.Duration.fromMilliseconds(download_all_delay_ms);

    var start: u32 = 0;
    var downloaded: u32 = 0;
    var skipped: u32 = 0;
    var failed: u32 = 0;
    var page_index: u32 = 0;

    while (page_index < download_all_pages_max) : (page_index += 1) {
        const ids = try activity_ids(session.connect(), gpa, start, limit);
        defer gpa.free(ids);

        if (ids.len == 0) break;

        for (ids) |id| {
            switch (try download_one(init, out, session, directory, id)) {
                .downloaded => |byte_count| {
                    downloaded += 1;

                    try out.print("[{d}] {d}.zip ({d} bytes)\n", .{ downloaded, id, byte_count });
                    try out.flush();

                    try std.Io.sleep(init.io, delay, .awake);
                },
                .skipped => skipped += 1,
                .failed => failed += 1,
            }
        }

        start += @intCast(ids.len);

        if (ids.len < limit) break;
    } else {
        return error.DownloadAllPagesExceeded;
    }

    try out.print("done: {d} downloaded, {d} skipped, {d} failed\n", .{
        downloaded,
        skipped,
        failed,
    });
}

fn activity_ids(
    connect: *core.Connect,
    gpa: Allocator,
    start: u32,
    limit: u32,
) ![]i64 {
    assert(limit != 0);
    assert(limit <= core.activities.page_max);

    var response = try core.activities.list(connect, start, limit);
    defer response.deinit();

    if (response.status != 200) return error.ActivitiesRequestFailed;

    const parsed = try std.json.parseFromSlice([]ActivityEntry, gpa, response.body, .{
        .ignore_unknown_fields = true,
    });

    defer parsed.deinit();

    const ids = try gpa.alloc(i64, parsed.value.len);
    errdefer gpa.free(ids);

    for (parsed.value, 0..) |entry, index| {
        ids[index] = entry.activityId;
    }

    return ids;
}

fn download_one(
    init: std.process.Init,
    out: *std.Io.Writer,
    session: *core.Session,
    directory: []const u8,
    id: i64,
) !DownloadOutcome {
    var path_buffer: [512]u8 = undefined;
    const path = try std.mem.print(&path_buffer, "{s}/{d}.zip", .{ directory, id });

    if (file_exists(init.io, path)) return .skipped;

    var id_buffer: [32]u8 = undefined;

    const id_text = std.mem.print(&id_buffer, "{d}", .{id}) catch |err| switch (err) {
        error.NoSpaceLeft => @panic("id_buffer too small for an activity id"),
    };

    var response = core.activities.download(session.connect(), id_text) catch |err| {
        try out.print("fail {d}: {s}\n", .{ id, @errorName(err) });
        try out.flush();

        return .failed;
    };

    defer response.deinit();

    if (response.status != 200) {
        try out.print("fail {d}: HTTP {d}\n", .{ id, response.status });
        try out.flush();

        return .failed;
    }

    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = response.body });

    return .{ .downloaded = response.body.len };
}

fn file_exists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;

    return true;
}

fn emit_user_date(
    out: *std.Io.Writer,
    session: *core.Session,
    args: []const [:0]const u8,
    endpoint: anytype,
) !void {
    if (args.len < 3) return error.DateRequired;

    var response = try endpoint(session.connect(), session.display_name(), args[2]);
    defer response.deinit();

    try emit(out, &response);
}

fn emit_date(
    out: *std.Io.Writer,
    session: *core.Session,
    args: []const [:0]const u8,
    endpoint: anytype,
) !void {
    if (args.len < 3) return error.DateRequired;

    var response = try endpoint(session.connect(), args[2]);
    defer response.deinit();

    try emit(out, &response);
}

fn emit_simple(out: *std.Io.Writer, session: *core.Session, endpoint: anytype) !void {
    var response = try endpoint(session.connect());
    defer response.deinit();

    try emit(out, &response);
}

fn emit(out: *std.Io.Writer, response: *core.http.Response) !void {
    if (response.status != 200) {
        try out.print("HTTP {d}\n{s}\n", .{ response.status, response.body });

        return error.RequestFailed;
    }

    try out.print("{s}\n", .{response.body});
}

fn parse_command(text: []const u8) ?Command {
    return command_map.get(text);
}

fn usage(out: *std.Io.Writer) !void {
    try out.writeAll(
        \\usage: zgarmin <command> [args]
        \\
        \\auth:
        \\    consumer                       print the OAuth consumer credentials in use
        \\    login                          authenticate and print tokens
        \\
        \\activities:
        \\    activities [start] [limit]     list activities as JSON
        \\    activity <id>                  activity detail as JSON
        \\    download <id> <path>           download the original FIT zip to path
        \\    download-all <dir> [limit]     download every activity's FIT zip into dir (resumes)
        \\
        \\wellness (date is YYYY-MM-DD):
        \\    summary <date>                 daily summary
        \\    sleep <date>                   sleep data
        \\    steps <date>                   step chart
        \\    hr <date>                      daily heart rate
        \\    hrv <date>                     heart rate variability
        \\    stress <date>                  stress
        \\    spo2 <date>                    pulse ox
        \\    respiration <date>             respiration
        \\    intensity <date>               intensity minutes
        \\
        \\body:
        \\    weight <start> <end>           body composition over a date range
        \\
        \\account:
        \\    profile                        social profile
        \\    settings                       user settings
        \\    devices                        registered devices
        \\    badges                         earned badges
        \\    goals                          active goals
        \\
        \\    raw <path>                     GET an arbitrary connectapi path
        \\
        \\credentials come from GARMIN_EMAIL / GARMIN_PASSWORD (env or .env)
        \\GARMIN_CONSUMER_KEY / GARMIN_CONSUMER_SECRET override the built-in pair
        \\tokens cache to ~/.zgarmin/tokens.json; delete the file to force a fresh login
        \\
    );
}
