<p align="center">
    <picture>
        <source media="(prefers-color-scheme: dark)" srcset="assets/zgarmin-wordmark-on-dark.svg">
        <source media="(prefers-color-scheme: light)" srcset="assets/zgarmin-wordmark-on-light.svg">
        <img alt="zgarmin" src="assets/zgarmin-wordmark-on-light.svg" width="500">
    </picture>
</p>

&nbsp;

<p align="center">
    A client for the Garmin Connect API that authenticates against Garmin's web SSO and pulls activity and health data.
</p>

<p align="center">
    <a href="https://github.com/braycarlson/zgarmin/actions/workflows/ci.yml"><img alt="ci" src="https://img.shields.io/github/actions/workflow/status/braycarlson/zgarmin/ci.yml?branch=main&amp;style=flat-square&amp;label=ci"></a>
    <a href="https://ziglang.org"><img alt="zig" src="https://img.shields.io/badge/zig-0.17.0-orange.svg?style=flat-square"></a>
    <a href="LICENSE"><img alt="license" src="https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square"></a>
</p>

## Overview

Garmin publishes no API for Connect, so this client works the way the mobile app does: a
web SSO login for a service ticket, then OAuth tokens against `connectapi.garmin.com`.

## Features

- **Web SSO login**: The client walks the embed widget, the signin form, and any MFA
  challenge to a service ticket, then trades that ticket for OAuth1 and OAuth2 tokens.
- **Typed endpoints**: There are 67 endpoints behind 77 functions in 14 namespaces, from
  activities and wellness to gear and workouts.
- **Token cache**: The tokens save as JSON through a `.partial` file and a rename, and a
  request answered with a 401 refreshes them and goes out once more.
- **Its own HTTP client**: The client carries a cookie jar, redirect handling, and
  retries, and it withholds cookies from any host outside `garmin.com`.
- **Command line**: The 22 commands cover login, activity download, wellness by date, and
  a raw GET against any `connectapi` path.
- **Dependencies**: There are none outside the Zig toolchain.

## Install

The library ships as a Zig package holding one module, also named `zgarmin`. Fetch it into
your own project and import the module in your `build.zig`.

```
zig fetch --save git+https://github.com/braycarlson/zgarmin
```

```zig
const zgarmin = b.dependency("zgarmin", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("zgarmin", zgarmin.module("zgarmin"));
```

zgarmin requires Zig 0.17.0.

## Credentials

The client reads the account from the process environment and falls back to a `.env` file
in the working directory. The first login caches its tokens in `~/.zgarmin/tokens.json`,
and each later run refreshes them rather than signing in again.

| Variable | Description | Default |
|---|---|---|
| `GARMIN_EMAIL` | The Garmin Connect account email. | None. |
| `GARMIN_PASSWORD` | The account password. | None. |
| `GARMIN_CONSUMER_KEY` | The OAuth consumer key. | The built-in pair. |
| `GARMIN_CONSUMER_SECRET` | The OAuth consumer secret. | The built-in pair. |

An account with multi-factor authentication prompts for the code on stdin.

## Usage

A `Session` owns the HTTP client and the tokens for one account. Log in once, then hand
`session.connect()` to any endpoint function.

```zig
const std = @import("std");

const zgarmin = @import("zgarmin");

pub fn print_activities(
    gpa: std.mem.Allocator,
    io: std.Io,
    credentials: *const zgarmin.Credentials,
) !void {
    var session = try zgarmin.Session.init(gpa, io);
    defer session.deinit();

    try session.login(&.{ .credentials = credentials });

    var response = try zgarmin.activities.list(session.connect(), 0, 20);
    defer response.deinit();

    if (response.status != 200) return error.RequestFailed;

    std.debug.print("{s}\n", .{response.body});
}
```

## Command Line

The justfile wraps the common commands as `just login`, `just activities`,
`just download`, and `just download-all`. Anything else goes through
`just run <command> [args]`.

```console
$ just run
zig build run --
usage: zgarmin <command> [args]

auth:
    consumer                       print the OAuth consumer credentials in use
    login                          authenticate and print tokens

activities:
    activities [start] [limit]     list activities as JSON
    activity <id>                  activity detail as JSON
    download <id> <path>           download the original FIT zip to path
    download-all <dir> [limit]     download every activity's FIT zip into dir (resumes)

wellness (date is YYYY-MM-DD):
    summary <date>                 daily summary
    sleep <date>                   sleep data
    steps <date>                   step chart
    hr <date>                      daily heart rate
    hrv <date>                     heart rate variability
    stress <date>                  stress
    spo2 <date>                    pulse ox
    respiration <date>             respiration
    intensity <date>               intensity minutes

body:
    weight <start> <end>           body composition over a date range

account:
    profile                        social profile
    settings                       user settings
    devices                        registered devices
    badges                         earned badges
    goals                          active goals

    raw <path>                     GET an arbitrary connectapi path

credentials come from GARMIN_EMAIL / GARMIN_PASSWORD (env or .env)
GARMIN_CONSUMER_KEY / GARMIN_CONSUMER_SECRET override the built-in pair
tokens cache to ~/.zgarmin/tokens.json; delete the file to force a fresh login
```

## Development

The recipes below wrap `zig build`, and a bare `just` lists them all. The tidy law is a
test rather than a separate linter, so the mechanical rules run with everything else.

| Command | What it runs |
|---|---|
| `just ci` | The formatting check, compilation, the unit tests, and the fuzzer smoke run. |
| `just test` | Each test suite and the formatting check. |
| `just tidy` | The tidy law on its own. |
| `just fuzz <name> [seed] [events]` | The named fuzzer: `html`, `oauth1`, `canary`, or `smoke`. |
| `just format` | The formatter over `build.zig` and `src`. |

## Licence

MIT. See [LICENSE](LICENSE).
