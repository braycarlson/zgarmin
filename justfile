set windows-shell := ["cmd.exe", "/c"]

# Default recipe
default:
    @just --list

# Run the whole continuous integration pipeline
ci:
    zig build ci --summary all

# Compile every artifact without running it
check:
    zig build check --summary all

# Run every test suite and the formatting check
test:
    zig build test --summary all

# Run the colocated unit tests and the tidy law, optionally filtered: just unit tidy
unit filter="":
    zig build test:unit --summary all -- {{filter}}

# Run the tidy check on its own
tidy:
    zig build test:unit -- tidy

# Check that every source file is formatted
fmt:
    zig build test:fmt

# Format every source file in place
format:
    zig fmt build.zig src

# Run any fuzzer by name: just fuzz oauth1 12345 50000
fuzz name="smoke" seed="" events="":
    zig build fuzz -- {{name}} {{seed}} {{events}}

# Run every fuzzer briefly with a fixed seed
smoke:
    zig build fuzz:smoke --summary all

# Print the built-in consumer credentials
consumer:
    zig build run -- consumer

# Authenticate against Garmin Connect and cache the tokens
login:
    zig build run -- login

# List activities: just activities 0 20
activities start="0" limit="20":
    zig build run -- activities {{start}} {{limit}}

# Download one activity: just download <id> <path>
download id path:
    zig build run -- download {{id}} {{path}}

# Download every activity into a directory
download-all directory="activities":
    zig build run -- download-all {{directory}}

# Run the CLI with arbitrary arguments
run *args:
    zig build run -- {{args}}

# Clean build artifacts
[unix]
clean:
    rm -rf zig-out .zig-cache

# Clean build artifacts
[windows]
clean:
    if exist zig-out rmdir /s /q zig-out
    if exist .zig-cache rmdir /s /q .zig-cache
