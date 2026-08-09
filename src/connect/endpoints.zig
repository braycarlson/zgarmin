const std = @import("std");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const Endpoint = enum {
    activities_count,
    activities_search,
    activity_by_id,
    activity_sub,
    activity_types,
    badges_available,
    badges_earned,
    blood_pressure,
    blood_pressure_entry,
    blood_pressure_range,
    body_battery,
    body_battery_events,
    challenges_adhoc,
    challenges_available,
    challenges_completed,
    challenges_non_completed,
    challenges_virtual,
    cycling_ftp,
    daily_summary,
    device_last_used,
    device_settings,
    devices,
    endurance_score,
    fit_download,
    fitness_age,
    floors,
    gear_activities,
    gear_filter,
    gear_stats,
    gear_unlink,
    goals,
    heart_rate,
    heart_rate_for_date,
    hill_score,
    hrv,
    hydration_all,
    hydration_daily,
    intensity_minutes,
    intensity_minutes_weekly,
    lactate_threshold,
    lifestyle_log,
    max_metrics,
    menstrual_calendar,
    menstrual_day,
    personal_records,
    pregnancy,
    resting_heart_rate,
    respiration,
    sleep,
    social_profile,
    spo2,
    steps,
    steps_daily,
    steps_weekly,
    stress,
    stress_weekly,
    training_readiness,
    training_status,
    user_settings,
    weigh_ins,
    weight_add,
    weight_day,
    weight_delete,
    weight_range,
    workout_by_id,
    workout_fit_download,
    workouts,

    const templates = std.enums.EnumArray(Endpoint, []const u8).init(.{
        .activities_count = "/activitylist-service/activities/count",
        .activities_search = "/activitylist-service/activities/search/activities",
        .activity_by_id = "/activity-service/activity/{s}",
        .activity_sub = "/activity-service/activity/{s}/{s}",
        .activity_types = "/activity-service/activity/activityTypes",
        .badges_available = "/badge-service/badge/available",
        .badges_earned = "/badge-service/badge/earned",
        .blood_pressure = "/bloodpressure-service/bloodpressure",
        .blood_pressure_entry = "/bloodpressure-service/bloodpressure/{s}/{s}",
        .blood_pressure_range = "/bloodpressure-service/bloodpressure/range/{s}/{s}",
        .body_battery = "/wellness-service/wellness/bodyBattery/reports/daily",
        .body_battery_events = "/wellness-service/wellness/bodyBattery/events/{s}",
        .challenges_adhoc = "/adhocchallenge-service/adHocChallenge/historical",
        .challenges_available = "/badgechallenge-service/badgeChallenge/available",
        .challenges_completed = "/badgechallenge-service/badgeChallenge/completed",
        .challenges_non_completed = "/badgechallenge-service/badgeChallenge/non-completed",
        .challenges_virtual = "/badgechallenge-service/virtualChallenge/inProgress",
        .cycling_ftp = "/biometric-service/biometric/latestFunctionalThresholdPower/CYCLING",
        .daily_summary = "/usersummary-service/usersummary/daily/{s}",
        .device_last_used = "/device-service/deviceservice/mylastused",
        .device_settings = "/device-service/deviceservice/device-info/settings/{s}",
        .devices = "/device-service/deviceregistration/devices",
        .endurance_score = "/metrics-service/metrics/endurancescore/stats",
        .fit_download = "/download-service/files/activity/{s}",
        .fitness_age = "/fitnessage-service/fitnessage/{s}",
        .floors = "/wellness-service/wellness/floorsChartData/daily/{s}",
        .gear_activities = "/activitylist-service/activities/{s}/gear",
        .gear_filter = "/gear-service/gear/filterGear",
        .gear_stats = "/gear-service/gear/stats/{s}",
        .gear_unlink = "/gear-service/gear/unlink/{s}/activity/{s}",
        .goals = "/goal-service/goal/goals",
        .heart_rate = "/wellness-service/wellness/dailyHeartRate/{s}",
        .heart_rate_for_date = "/mobile-gateway/heartRate/forDate/{s}",
        .hill_score = "/metrics-service/metrics/hillscore/stats",
        .hrv = "/hrv-service/hrv/{s}",
        .hydration_all = "/usersummary-service/usersummary/hydration/allData/{s}",
        .hydration_daily = "/usersummary-service/usersummary/hydration/daily/{s}",
        .intensity_minutes = "/wellness-service/wellness/daily/im/{s}",
        .intensity_minutes_weekly = "/usersummary-service/stats/im/weekly/{s}/{s}",
        .lactate_threshold = "/biometric-service/biometric/powerToWeight/latest/{s}",
        .lifestyle_log = "/lifestylelogging-service/dailyLog/{s}",
        .max_metrics = "/metrics-service/metrics/maxmet/daily/{s}/{s}",
        .menstrual_calendar = "/periodichealth-service/menstrualcycle/calendar/{s}/{s}",
        .menstrual_day = "/periodichealth-service/menstrualcycle/dayview/{s}",
        .personal_records = "/personalrecord-service/personalrecord/prs/{s}",
        .pregnancy = "/periodichealth-service/menstrualcycle/pregnancysnapshot",
        .resting_heart_rate = "/userstats-service/wellness/daily/{s}",
        .respiration = "/wellness-service/wellness/daily/respiration/{s}",
        .sleep = "/wellness-service/wellness/dailySleepData/{s}",
        .social_profile = "/userprofile-service/socialProfile",
        .spo2 = "/wellness-service/wellness/daily/spo2/{s}",
        .steps = "/wellness-service/wellness/dailySummaryChart/{s}",
        .steps_daily = "/usersummary-service/stats/steps/daily/{s}/{s}",
        .steps_weekly = "/usersummary-service/stats/steps/weekly/{s}/{s}",
        .stress = "/wellness-service/wellness/dailyStress/{s}",
        .stress_weekly = "/usersummary-service/stats/stress/weekly/{s}/{s}",
        .training_readiness = "/metrics-service/metrics/trainingreadiness/{s}",
        .training_status = "/metrics-service/metrics/trainingstatus/aggregated/{s}",
        .user_settings = "/userprofile-service/userprofile/user-settings",
        .weigh_ins = "/weight-service/weight/range/{s}/{s}",
        .weight_add = "/weight-service/user-weight",
        .weight_day = "/weight-service/weight/dayview/{s}",
        .weight_delete = "/weight-service/weight/weight/{s}/byversion/{s}",
        .weight_range = "/weight-service/weight/dateRange",
        .workout_by_id = "/workout-service/workout/{s}",
        .workout_fit_download = "/workout-service/workout/FIT/{s}",
        .workouts = "/workout-service/workouts",
    });

    pub fn path(comptime endpoint: Endpoint) []const u8 {
        const result = comptime endpoint.template();

        comptime if (std.mem.indexOfScalar(u8, result, '{') != null) @compileError(
            "templated endpoint '" ++ @tagName(endpoint) ++ "' requires arguments; call build()",
        );

        return result;
    }

    pub fn build(
        comptime endpoint: Endpoint,
        gpa: Allocator,
        arguments: anytype,
    ) ![]u8 {
        inline for (arguments) |argument| {
            if (argument.len == 0) return error.EndpointArgumentInvalid;

            for (argument) |byte| {
                if (!argument_byte_valid(byte)) return error.EndpointArgumentInvalid;
            }
        }

        const result = try std.fmt.allocPrint(gpa, comptime endpoint.template(), arguments);

        assert(result.len != 0);
        assert(result[0] == '/');

        return result;
    }

    pub fn template(comptime endpoint: Endpoint) []const u8 {
        return templates.get(endpoint);
    }

    fn argument_byte_valid(byte: u8) bool {
        return switch (byte) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
            else => false,
        };
    }
};

comptime {
    for (std.enums.values(Endpoint)) |endpoint| {
        const url = endpoint.template();

        if (url.len == 0 or url[0] != '/') {
            @compileError(
                "endpoint '" ++ @tagName(endpoint) ++ "' template must be an absolute path",
            );
        }
    }
}

test "path returns a static endpoint" {
    try std.testing.expectEqualStrings(
        "/activitylist-service/activities/count",
        Endpoint.activities_count.path(),
    );
}

test "build formats arguments into the template" {
    const gpa = std.testing.allocator;

    const path = try Endpoint.activity_by_id.build(gpa, .{"12345"});
    defer gpa.free(path);

    try std.testing.expectEqualStrings("/activity-service/activity/12345", path);
}

test "build formats multiple arguments" {
    const gpa = std.testing.allocator;

    const path = try Endpoint.gear_unlink.build(gpa, .{ "uuid-1", "999" });
    defer gpa.free(path);

    try std.testing.expectEqualStrings("/gear-service/gear/unlink/uuid-1/activity/999", path);
}

test "build rejects arguments outside the unreserved byte set" {
    const gpa = std.testing.allocator;

    const invalid = [_][]const u8{ "", "a/b", "a?b", "a#b", "a&b", "a%b", "a b" };

    for (invalid) |argument| {
        try std.testing.expectError(
            error.EndpointArgumentInvalid,
            Endpoint.activity_by_id.build(gpa, .{argument}),
        );
    }
}
