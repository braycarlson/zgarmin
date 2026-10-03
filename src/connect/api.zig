const std = @import("std");

const http = @import("../http.zig");
const Connect = @import("connect.zig");
const Endpoint = @import("endpoints.zig").Endpoint;

const assert = std.debug.assert;

pub const account = struct {
    pub fn social_profile(connect: *Connect) !http.Response {
        return connect.get(Endpoint.social_profile.path(), null);
    }

    pub fn user_settings(connect: *Connect) !http.Response {
        return connect.get(Endpoint.user_settings.path(), null);
    }
};

pub const activities = struct {
    pub const page_max: u32 = 100;

    pub fn list(connect: *Connect, start: u32, limit: u32) !http.Response {
        assert(limit != 0);
        assert(limit <= page_max);

        var buffer: [64]u8 = undefined;
        const query = try std.mem.print(&buffer, "start={d}&limit={d}", .{ start, limit });

        return connect.get(Endpoint.activities_search.path(), query);
    }

    pub fn count(connect: *Connect) !http.Response {
        return connect.get(Endpoint.activities_count.path(), null);
    }

    pub fn types(connect: *Connect) !http.Response {
        return connect.get(Endpoint.activity_types.path(), null);
    }

    pub fn by_id(connect: *Connect, activity_id: []const u8) !http.Response {
        assert(activity_id.len != 0);

        const path = try Endpoint.activity_by_id.build(connect.gpa, .{activity_id});
        defer connect.gpa.free(path);

        return connect.get(path, null);
    }

    pub fn details(connect: *Connect, activity_id: []const u8) !http.Response {
        return activity_sub(connect, activity_id, "details");
    }

    pub fn splits(connect: *Connect, activity_id: []const u8) !http.Response {
        return activity_sub(connect, activity_id, "splits");
    }

    pub fn typed_splits(connect: *Connect, activity_id: []const u8) !http.Response {
        return activity_sub(connect, activity_id, "typedsplits");
    }

    pub fn split_summaries(connect: *Connect, activity_id: []const u8) !http.Response {
        return activity_sub(connect, activity_id, "split_summaries");
    }

    pub fn weather(connect: *Connect, activity_id: []const u8) !http.Response {
        return activity_sub(connect, activity_id, "weather");
    }

    pub fn heart_rate_zones(connect: *Connect, activity_id: []const u8) !http.Response {
        return activity_sub(connect, activity_id, "hrTimeInZones");
    }

    pub fn power_zones(connect: *Connect, activity_id: []const u8) !http.Response {
        return activity_sub(connect, activity_id, "powerTimeInZones");
    }

    pub fn exercise_sets(connect: *Connect, activity_id: []const u8) !http.Response {
        return activity_sub(connect, activity_id, "exerciseSets");
    }

    pub fn download(connect: *Connect, activity_id: []const u8) !http.Response {
        assert(activity_id.len != 0);

        const path = try Endpoint.fit_download.build(connect.gpa, .{activity_id});
        defer connect.gpa.free(path);

        return connect.get(path, null);
    }

    fn activity_sub(
        connect: *Connect,
        activity_id: []const u8,
        suffix: []const u8,
    ) !http.Response {
        assert(activity_id.len != 0);
        assert(suffix.len != 0);

        return connect.get_endpoint(.activity_sub, .{ activity_id, suffix }, null);
    }
};

pub const badges = struct {
    pub const challenge_query: []const u8 = "start=1&limit=100";

    pub fn available(connect: *Connect) !http.Response {
        return connect.get(Endpoint.badges_available.path(), null);
    }

    pub fn earned(connect: *Connect) !http.Response {
        return connect.get(Endpoint.badges_earned.path(), null);
    }

    pub fn adhoc_challenges(connect: *Connect) !http.Response {
        return connect.get(Endpoint.challenges_adhoc.path(), challenge_query);
    }

    pub fn completed_challenges(connect: *Connect) !http.Response {
        return connect.get(Endpoint.challenges_completed.path(), challenge_query);
    }

    pub fn available_challenges(connect: *Connect) !http.Response {
        return connect.get(Endpoint.challenges_available.path(), challenge_query);
    }

    pub fn non_completed_challenges(connect: *Connect) !http.Response {
        return connect.get(Endpoint.challenges_non_completed.path(), challenge_query);
    }

    pub fn virtual_challenges(connect: *Connect) !http.Response {
        return connect.get(Endpoint.challenges_virtual.path(), challenge_query);
    }
};

pub const body = struct {
    pub fn body_composition(
        connect: *Connect,
        start_date: []const u8,
        end_date: []const u8,
    ) !http.Response {
        var query_buffer: [96]u8 = undefined;
        const query = try date_range_query(start_date, end_date, &query_buffer);

        return connect.get(Endpoint.weight_range.path(), query);
    }

    pub fn weight_day(connect: *Connect, date: []const u8) !http.Response {
        assert(date.len != 0);

        return connect.get_endpoint(.weight_day, .{date}, null);
    }

    pub fn hydration(connect: *Connect, date: []const u8) !http.Response {
        assert(date.len != 0);

        return connect.get_endpoint(.hydration_all, .{date}, null);
    }

    pub fn blood_pressure(
        connect: *Connect,
        start_date: []const u8,
        end_date: []const u8,
    ) !http.Response {
        assert(start_date.len != 0);
        assert(end_date.len != 0);

        return connect.get_endpoint(.blood_pressure_range, .{ start_date, end_date }, null);
    }

    pub fn weigh_ins(
        connect: *Connect,
        start_date: []const u8,
        end_date: []const u8,
    ) !http.Response {
        assert(start_date.len != 0);
        assert(end_date.len != 0);

        return connect.get_endpoint(.weigh_ins, .{ start_date, end_date }, null);
    }

    pub fn body_battery(
        connect: *Connect,
        start_date: []const u8,
        end_date: []const u8,
    ) !http.Response {
        var query_buffer: [96]u8 = undefined;
        const query = try date_range_query(start_date, end_date, &query_buffer);

        return connect.get(Endpoint.body_battery.path(), query);
    }

    pub fn body_battery_events(connect: *Connect, date: []const u8) !http.Response {
        assert(date.len != 0);

        return connect.get_endpoint(.body_battery_events, .{date}, null);
    }

    pub fn hydration_daily(connect: *Connect, date: []const u8) !http.Response {
        assert(date.len != 0);

        return connect.get_endpoint(.hydration_daily, .{date}, null);
    }

    fn date_range_query(start_date: []const u8, end_date: []const u8, buffer: []u8) ![]const u8 {
        assert(start_date.len != 0);
        assert(end_date.len != 0);

        return std.mem.print(buffer, "startDate={s}&endDate={s}", .{ start_date, end_date });
    }
};

pub const devices = struct {
    pub fn list(connect: *Connect) !http.Response {
        return connect.get(Endpoint.devices.path(), null);
    }

    pub fn last_used(connect: *Connect) !http.Response {
        return connect.get(Endpoint.device_last_used.path(), null);
    }

    pub fn settings(connect: *Connect, device_id: []const u8) !http.Response {
        assert(device_id.len != 0);

        return connect.get_endpoint(.device_settings, .{device_id}, null);
    }
};

pub const gear = struct {
    pub const activities_limit_max: u32 = 1000;

    pub fn list(connect: *Connect, user_profile_primary_key: []const u8) !http.Response {
        assert(user_profile_primary_key.len != 0);

        var query_buffer: [64]u8 = undefined;

        const query = try std.mem.print(
            &query_buffer,
            "userProfilePk={s}",
            .{user_profile_primary_key},
        );

        return connect.get(Endpoint.gear_filter.path(), query);
    }

    pub fn stats(connect: *Connect, gear_uuid: []const u8) !http.Response {
        assert(gear_uuid.len != 0);

        return connect.get_endpoint(.gear_stats, .{gear_uuid}, null);
    }

    pub fn activities(connect: *Connect, gear_uuid: []const u8, limit: u32) !http.Response {
        assert(gear_uuid.len != 0);
        assert(limit != 0);
        assert(limit <= activities_limit_max);

        var query_buffer: [64]u8 = undefined;
        const query = try std.mem.print(&query_buffer, "start=0&limit={d}", .{limit});

        return connect.get_endpoint(.gear_activities, .{gear_uuid}, query);
    }

    pub fn unlink(
        connect: *Connect,
        gear_uuid: []const u8,
        activity_id: []const u8,
    ) !http.Response {
        assert(gear_uuid.len != 0);
        assert(activity_id.len != 0);

        const path = try Endpoint.gear_unlink.build(connect.gpa, .{
            gear_uuid,
            activity_id,
        });

        defer connect.gpa.free(path);

        return connect.request(.PUT, path, &.{});
    }
};

pub const goals = struct {
    pub const list_query: []const u8 = "status=active&start=1&limit=30&sortOrder=asc";

    pub fn list(connect: *Connect) !http.Response {
        return connect.get(Endpoint.goals.path(), list_query);
    }
};

pub const metrics = struct {
    pub fn max_metrics(connect: *Connect, date: []const u8) !http.Response {
        assert(date.len != 0);

        return connect.get_endpoint(.max_metrics, .{ date, date }, null);
    }

    pub fn training_readiness(connect: *Connect, date: []const u8) !http.Response {
        assert(date.len != 0);

        return connect.get_endpoint(.training_readiness, .{date}, null);
    }

    pub fn training_status(connect: *Connect, date: []const u8) !http.Response {
        assert(date.len != 0);

        return connect.get_endpoint(.training_status, .{date}, null);
    }

    pub fn endurance_score(connect: *Connect) !http.Response {
        return connect.get(Endpoint.endurance_score.path(), null);
    }

    pub fn hill_score(connect: *Connect) !http.Response {
        return connect.get(Endpoint.hill_score.path(), null);
    }

    pub fn fitness_age(connect: *Connect, date: []const u8) !http.Response {
        assert(date.len != 0);

        return connect.get_endpoint(.fitness_age, .{date}, null);
    }

    pub fn cycling_ftp(connect: *Connect) !http.Response {
        return connect.get(Endpoint.cycling_ftp.path(), null);
    }

    pub fn lactate_threshold(connect: *Connect, date: []const u8) !http.Response {
        assert(date.len != 0);

        return connect.get_endpoint(.lactate_threshold, .{date}, "sport=Running");
    }
};

pub const mutations = struct {
    pub const WeighIn = struct {
        value: f64,
        unit_key: []const u8,
        date_timestamp: []const u8,
        gmt_timestamp: []const u8,
    };

    pub const BloodPressure = struct {
        systolic: i64,
        diastolic: i64,
        pulse: i64,
        timestamp_local: []const u8,
        timestamp_gmt: []const u8,
        notes: []const u8,
    };

    pub fn add_weigh_in(connect: *Connect, weigh_in: *const WeighIn) !http.Response {
        assert(weigh_in.value > 0);
        assert(weigh_in.unit_key.len != 0);
        assert(weigh_in.date_timestamp.len != 0);
        assert(weigh_in.gmt_timestamp.len != 0);

        const payload = try std.json.Stringify.valueAlloc(connect.gpa, .{
            .dateTimestamp = weigh_in.date_timestamp,
            .gmtTimestamp = weigh_in.gmt_timestamp,
            .unitKey = weigh_in.unit_key,
            .sourceType = "MANUAL",
            .value = weigh_in.value,
        }, .{});

        defer connect.gpa.free(payload);

        return connect.post_json(Endpoint.weight_add.path(), null, payload);
    }

    pub fn delete_weigh_in(
        connect: *Connect,
        calendar_date: []const u8,
        weight_primary_key: []const u8,
    ) !http.Response {
        assert(calendar_date.len != 0);
        assert(weight_primary_key.len != 0);

        const path = try Endpoint.weight_delete.build(connect.gpa, .{
            calendar_date,
            weight_primary_key,
        });

        defer connect.gpa.free(path);

        return connect.delete(path, null);
    }

    pub fn delete_activity(connect: *Connect, activity_id: []const u8) !http.Response {
        assert(activity_id.len != 0);

        const path = try Endpoint.activity_by_id.build(connect.gpa, .{activity_id});
        defer connect.gpa.free(path);

        return connect.delete(path, null);
    }

    pub fn set_blood_pressure(
        connect: *Connect,
        blood_pressure: *const BloodPressure,
    ) !http.Response {
        assert(blood_pressure.systolic > 0);
        assert(blood_pressure.diastolic > 0);
        assert(blood_pressure.timestamp_local.len != 0);
        assert(blood_pressure.timestamp_gmt.len != 0);

        const payload = try std.json.Stringify.valueAlloc(connect.gpa, .{
            .measurementTimestampLocal = blood_pressure.timestamp_local,
            .measurementTimestampGMT = blood_pressure.timestamp_gmt,
            .systolic = blood_pressure.systolic,
            .diastolic = blood_pressure.diastolic,
            .pulse = blood_pressure.pulse,
            .sourceType = "MANUAL",
            .notes = blood_pressure.notes,
        }, .{});

        defer connect.gpa.free(payload);

        return connect.post_json(Endpoint.blood_pressure.path(), null, payload);
    }

    pub fn delete_blood_pressure(
        connect: *Connect,
        calendar_date: []const u8,
        version: []const u8,
    ) !http.Response {
        assert(calendar_date.len != 0);
        assert(version.len != 0);

        const path = try Endpoint.blood_pressure_entry.build(connect.gpa, .{
            calendar_date,
            version,
        });

        defer connect.gpa.free(path);

        return connect.delete(path, null);
    }
};

pub const records = struct {
    pub fn personal_records(connect: *Connect, display_name: []const u8) !http.Response {
        assert(display_name.len != 0);

        return connect.get_endpoint(.personal_records, .{display_name}, null);
    }
};

pub const stats = struct {
    pub const weeks_digits_max: u32 = 10;

    pub fn floors(connect: *Connect, date: []const u8) !http.Response {
        assert(date.len != 0);

        return connect.get_endpoint(.floors, .{date}, null);
    }

    pub fn daily_steps(
        connect: *Connect,
        start_date: []const u8,
        end_date: []const u8,
    ) !http.Response {
        assert(start_date.len != 0);
        assert(end_date.len != 0);

        return connect.get_endpoint(.steps_daily, .{ start_date, end_date }, null);
    }

    pub fn weekly_steps(connect: *Connect, end_date: []const u8, weeks: u32) !http.Response {
        assert(end_date.len != 0);

        var weeks_buffer: [weeks_digits_max]u8 = undefined;
        const weeks_text = format_weeks(weeks, &weeks_buffer);

        return connect.get_endpoint(.steps_weekly, .{ end_date, weeks_text }, null);
    }

    pub fn weekly_stress(connect: *Connect, end_date: []const u8, weeks: u32) !http.Response {
        assert(end_date.len != 0);

        var weeks_buffer: [weeks_digits_max]u8 = undefined;
        const weeks_text = format_weeks(weeks, &weeks_buffer);

        return connect.get_endpoint(.stress_weekly, .{ end_date, weeks_text }, null);
    }

    pub fn weekly_intensity_minutes(
        connect: *Connect,
        start_date: []const u8,
        end_date: []const u8,
    ) !http.Response {
        assert(start_date.len != 0);
        assert(end_date.len != 0);

        return connect.get_endpoint(.intensity_minutes_weekly, .{ start_date, end_date }, null);
    }

    pub fn resting_heart_rate(
        connect: *Connect,
        display_name: []const u8,
        date: []const u8,
    ) !http.Response {
        assert(display_name.len != 0);
        assert(date.len != 0);

        var query_buffer: [64]u8 = undefined;
        const query = try std.mem.print(&query_buffer, "fromDate={s}&metricId=60", .{date});

        return connect.get_endpoint(.resting_heart_rate, .{display_name}, query);
    }

    pub fn lifestyle_logging(connect: *Connect, date: []const u8) !http.Response {
        assert(date.len != 0);

        return connect.get_endpoint(.lifestyle_log, .{date}, null);
    }

    fn format_weeks(weeks: u32, buffer: *[weeks_digits_max]u8) []const u8 {
        assert(weeks != 0);

        return std.mem.print(buffer, "{d}", .{weeks}) catch |err| switch (err) {
            error.NoSpaceLeft => @panic("weeks_digits_max too small for a u32"),
        };
    }
};

pub const wellness = struct {
    pub const buffer_minutes_default: u32 = 60;
    pub const buffer_minutes_max: u32 = 12 * 60;

    pub fn daily_summary(
        connect: *Connect,
        display_name: []const u8,
        date: []const u8,
    ) !http.Response {
        assert(display_name.len != 0);
        assert(date.len != 0);

        var query_buffer: [96]u8 = undefined;
        const query = try std.mem.print(&query_buffer, "calendarDate={s}", .{date});

        return connect.get_endpoint(.daily_summary, .{display_name}, query);
    }

    pub fn steps(connect: *Connect, display_name: []const u8, date: []const u8) !http.Response {
        assert(display_name.len != 0);
        assert(date.len != 0);

        var query_buffer: [96]u8 = undefined;
        const query = try std.mem.print(&query_buffer, "date={s}", .{date});

        return connect.get_endpoint(.steps, .{display_name}, query);
    }

    pub fn heart_rate(
        connect: *Connect,
        display_name: []const u8,
        date: []const u8,
    ) !http.Response {
        assert(display_name.len != 0);
        assert(date.len != 0);

        var query_buffer: [96]u8 = undefined;
        const query = try std.mem.print(&query_buffer, "date={s}", .{date});

        return connect.get_endpoint(.heart_rate, .{display_name}, query);
    }

    pub fn heart_rate_for_date(connect: *Connect, date: []const u8) !http.Response {
        assert(date.len != 0);

        return connect.get_endpoint(.heart_rate_for_date, .{date}, null);
    }

    pub fn sleep(connect: *Connect, display_name: []const u8, date: []const u8) !http.Response {
        return sleep_buffered(connect, display_name, date, buffer_minutes_default);
    }

    pub fn sleep_buffered(
        connect: *Connect,
        display_name: []const u8,
        date: []const u8,
        buffer_minutes: u32,
    ) !http.Response {
        assert(display_name.len != 0);
        assert(date.len != 0);
        assert(buffer_minutes <= buffer_minutes_max);

        var query_buffer: [96]u8 = undefined;

        const query = try std.mem.print(
            &query_buffer,
            "date={s}&nonSleepBufferMinutes={d}",
            .{ date, buffer_minutes },
        );

        return connect.get_endpoint(.sleep, .{display_name}, query);
    }

    pub fn hrv(connect: *Connect, date: []const u8) !http.Response {
        assert(date.len != 0);

        return connect.get_endpoint(.hrv, .{date}, null);
    }

    pub fn stress(connect: *Connect, date: []const u8) !http.Response {
        assert(date.len != 0);

        return connect.get_endpoint(.stress, .{date}, null);
    }

    pub fn spo2(connect: *Connect, date: []const u8) !http.Response {
        assert(date.len != 0);

        return connect.get_endpoint(.spo2, .{date}, null);
    }

    pub fn respiration(connect: *Connect, date: []const u8) !http.Response {
        assert(date.len != 0);

        return connect.get_endpoint(.respiration, .{date}, null);
    }

    pub fn intensity_minutes(connect: *Connect, date: []const u8) !http.Response {
        assert(date.len != 0);

        return connect.get_endpoint(.intensity_minutes, .{date}, null);
    }
};

pub const womens = struct {
    pub fn menstrual_day(connect: *Connect, date: []const u8) !http.Response {
        assert(date.len != 0);

        return connect.get_endpoint(.menstrual_day, .{date}, null);
    }

    pub fn menstrual_calendar(
        connect: *Connect,
        start_date: []const u8,
        end_date: []const u8,
    ) !http.Response {
        assert(start_date.len != 0);
        assert(end_date.len != 0);

        return connect.get_endpoint(.menstrual_calendar, .{ start_date, end_date }, null);
    }

    pub fn pregnancy(connect: *Connect) !http.Response {
        return connect.get(Endpoint.pregnancy.path(), null);
    }
};

pub const workouts = struct {
    pub const list_query: []const u8 =
        "start=0&limit=100&myWorkoutsOnly=true&sharedWorkoutsOnly=false";

    pub fn list(connect: *Connect) !http.Response {
        return connect.get(Endpoint.workouts.path(), list_query);
    }

    pub fn by_id(connect: *Connect, workout_id: []const u8) !http.Response {
        assert(workout_id.len != 0);

        return connect.get_endpoint(.workout_by_id, .{workout_id}, null);
    }

    pub fn download(connect: *Connect, workout_id: []const u8) !http.Response {
        assert(workout_id.len != 0);

        const path = try Endpoint.workout_fit_download.build(connect.gpa, .{workout_id});
        defer connect.gpa.free(path);

        return connect.get(path, null);
    }

    pub fn delete(connect: *Connect, workout_id: []const u8) !http.Response {
        assert(workout_id.len != 0);

        const path = try Endpoint.workout_by_id.build(connect.gpa, .{workout_id});
        defer connect.gpa.free(path);

        return connect.delete(path, null);
    }
};
