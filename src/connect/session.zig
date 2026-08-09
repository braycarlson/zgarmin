const std = @import("std");

const http = @import("../http.zig");
const consumer = @import("../auth/consumer.zig");
const oauth2 = @import("../auth/oauth2.zig");
const sso = @import("../auth/sso.zig");
const tokens = @import("../auth/tokens.zig");
const account = @import("api.zig").account;
const Connect = @import("connect.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const LoginError = error{
    DisplayNameMissing,
    LoginFailed,
    OutOfMemory,
    TokenRefreshFailed,
};

pub const Session = struct {
    gpa: Allocator,
    io: std.Io,
    client: *http.Client,
    api: ?Connect = null,
    display_name_owned: ?[]u8 = null,

    pub fn init(gpa: Allocator, io: std.Io) LoginError!Session {
        const client = gpa.create(http.Client) catch {
            return LoginError.OutOfMemory;
        };

        client.* = http.Client.init(gpa, io);

        return .{
            .gpa = gpa,
            .io = io,
            .client = client,
        };
    }

    pub fn deinit(session: *Session) void {
        if (session.display_name_owned) |name| session.gpa.free(name);
        if (session.api) |*api| api.deinit();

        session.client.deinit();
        session.gpa.destroy(session.client);
    }

    pub fn login(session: *Session, options: *const LoginOptions) LoginError!void {
        if (session.api != null) @panic("Session.login called after login");

        assert(session.display_name_owned == null);
        defer assert((session.api == null) == (session.display_name_owned == null));

        var keys = consumer.init(session.gpa, .{
            .key = options.consumer_key,
            .secret = options.consumer_secret,
        }) catch {
            return LoginError.OutOfMemory;
        };

        const granted = sso.login(
            session.gpa,
            session.io,
            session.client,
            &keys,
            options.credentials,
            options.mfa,
        ) catch {
            keys.deinit();

            return LoginError.LoginFailed;
        };

        var api = Connect.init(
            session.gpa,
            session.io,
            session.client,
            keys,
            granted.oauth1,
            granted.oauth2,
        );

        errdefer api.deinit();

        const name = fetch_display_name(&api, session.gpa) catch {
            return LoginError.DisplayNameMissing;
        };

        session.api = api;
        session.display_name_owned = name;
    }

    pub fn restore(session: *Session, loaded: tokens.Loaded) LoginError!void {
        if (session.api != null) @panic("Session.restore called after login");

        assert(session.display_name_owned == null);
        defer assert((session.api == null) == (session.display_name_owned == null));

        var oauth2_token = loaded.oauth2_token;
        var refreshed = false;

        if (oauth2_token.expired(session.io)) {
            oauth2_token = oauth2.exchange(
                session.gpa,
                session.io,
                session.client,
                &loaded.consumer,
                &loaded.oauth1_token,
            ) catch {
                return LoginError.TokenRefreshFailed;
            };

            var stale = loaded.oauth2_token;
            stale.deinit();

            refreshed = true;
        }

        session.api = Connect.init(
            session.gpa,
            session.io,
            session.client,
            loaded.consumer,
            loaded.oauth1_token,
            oauth2_token,
        );

        session.api.?.token_refreshed = refreshed;
        session.display_name_owned = loaded.display_name;
    }

    pub fn persist(
        session: *Session,
        directory: std.Io.Dir,
        path: []const u8,
    ) tokens.TokenError!void {
        const api = session.connect();

        try tokens.save(session.gpa, session.io, directory, path, &.{
            .consumer = &api.consumer,
            .oauth1_token = &api.token_oauth1,
            .oauth2_token = &api.token_oauth2,
            .display_name = session.display_name(),
        });

        api.token_refreshed = false;
    }

    pub fn connect(session: *Session) *Connect {
        if (session.api) |*api| return api;

        @panic("Session.connect called before login");
    }

    pub fn display_name(session: *const Session) []const u8 {
        if (session.display_name_owned) |name| return name;

        @panic("Session.display_name called before login");
    }
};

pub const LoginOptions = struct {
    credentials: *const sso.Credentials,
    mfa: ?sso.MfaProvider = null,
    consumer_key: []const u8 = consumer.key_default,
    consumer_secret: []const u8 = consumer.secret_default,
};

const DisplayNamePayload = struct {
    displayName: []const u8,
};

fn fetch_display_name(api: *Connect, gpa: Allocator) ![]u8 {
    var response = try account.social_profile(api);
    defer response.deinit();

    if (response.status != 200) return error.ProfileRequestFailed;

    const parsed = try std.json.parseFromSlice(DisplayNamePayload, gpa, response.body, .{
        .ignore_unknown_fields = true,
    });

    defer parsed.deinit();

    if (parsed.value.displayName.len == 0) return error.ProfileInvalid;

    return gpa.dupe(u8, parsed.value.displayName);
}
